use std::collections::HashMap;
use std::sync::RwLock;

use serde_json::{json, Value};

use crate::error::{AppError, AppResult};
use crate::kugou::session::KgSession;
use crate::kugou::session_store::FileSessionStore;
use crate::services::{
    album, artist, comment, discover, external_playlist, fm, identify, login, lyric, playlist,
    rank, report, search, song, user, video, youth,
};

/// 登录态等可变部分。读写均经 [`KugouEngine::state`] 的短锁完成，
/// 锁从不跨网络 await 持有（见结构体注释）。
struct EngineState {
    session: KgSession,
    store: FileSessionStore,
}

pub struct KugouEngine {
    client: reqwest::Client,
    /// 内部可变的会话状态：FRB 对 opaque 类型的调用会按参数可变性加
    /// 读/写锁并跨整个 await 持有。此前 `&mut Engine` 让所有请求（含
    /// 耗时 2-15s 的识曲上传）串行在一把写锁上，识别期间搜索/歌单/
    /// 自动下一曲全部排队。改为 `&self` + 内部 RwLock 后 FRB 只拿读锁
    /// （读读并存），登录态写入只占毫秒级同步段落。
    state: RwLock<EngineState>,
}

impl KugouEngine {
    pub async fn new(data_dir: String) -> Self {
        let _ = rustls::crypto::ring::default_provider().install_default();

        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(15))
            .pool_max_idle_per_host(3)
            .pool_idle_timeout(std::time::Duration::from_secs(10))
            .gzip(true)
            .build()
            .expect("failed to build reqwest client");

        let store = FileSessionStore::new(&data_dir);
        let mut session = store.load().unwrap_or_default();
        session.normalize();
        store.save(&session);

        Self {
            client,
            state: RwLock::new(EngineState { session, store }),
        }
    }

    /// 当前会话快照（廉价克隆，纯字符串）。所有读路径拿快照后即刻放锁，
    /// 后续网络请求期间不持任何锁。
    fn session_snapshot(&self) -> KgSession {
        self.state
            .read()
            .expect("engine state lock poisoned")
            .session
            .clone()
    }

    pub async fn request(
        &self,
        method: &str,
        path: &str,
        query: &str,
        body: Option<&str>,
    ) -> AppResult<String> {
        let mut params: HashMap<String, String> = if query.is_empty() {
            HashMap::new()
        } else {
            serde_json::from_str(query).unwrap_or_default()
        };

        // 将 body 中的字段也合并到 params，兼容前端通过 body 传参的情况
        if let Some(body_str) = body {
            if let Ok(body_map) = serde_json::from_str::<HashMap<String, Value>>(body_str) {
                for (k, v) in body_map {
                    let val = match v {
                        Value::String(s) => s,
                        other => other.to_string(),
                    };
                    params.entry(k).or_insert(val);
                }
            }
        }

        let session = self.session_snapshot();
        let result = self
            .dispatch_inner(&session, method, path, &params, body)
            .await?;

        // 会话失效（status=0 + 20xxx 错误码）时自动刷新 token 并重放一次。
        // 酷狗 token 会在长期未使用 / 多端登录后被上游作废，车机长时间待机后
        // 首次播放/加载歌单常命中此情况；此前只能靠用户手动重新登录恢复。
        // 刷新成功则重放原请求，对用户完全无感；失败则返回原始失败响应。
        if !Self::is_session_invalid_response(&result)
            || path.starts_with("/login/")
            || path.starts_with("/captcha/")
        {
            return Self::encode_result(result);
        }
        let refreshed = login::refresh_token(&self.client, "", &session).await;
        let retry_session = match refreshed {
            Ok(resp) => {
                let session = self.persist_login(&resp);
                tracing::info!(path, "会话已失效，自动刷新 token 后重试原请求");
                Some(session)
            }
            Err(e) => {
                // 并发请求可能都撞上会话失效：本请求刷新失败时，若期间另一
                // 请求已刷新成功（会话已变化），直接借新会话重放。
                let current = self.session_snapshot();
                if current.token != session.token || current.userid != session.userid {
                    Some(current)
                } else {
                    tracing::warn!(path, error = %e, "会话失效且 token 刷新失败，保持原响应");
                    None
                }
            }
        };
        let result = match retry_session {
            Some(session) => {
                self.dispatch_inner(&session, method, path, &params, body)
                    .await?
            }
            None => result,
        };
        Self::encode_result(result)
    }

    fn encode_result(result: Value) -> AppResult<String> {
        serde_json::to_string(&result).map_err(|e| AppError::Internal(e.to_string()))
    }

    pub fn set_session_fields(&self, userid: &str, token: &str, t1: &str) {
        let mut state = self.state.write().expect("engine state lock poisoned");
        if userid.is_empty() || token.is_empty() {
            state.session.logout();
        } else {
            state.session.update_auth(userid, token, "", "", t1);
        }
        state.store.save(&state.session);
    }

    /// 登出：清会话并持久化（login/logout 端点用）。
    fn logout_internal(&self) {
        let mut state = self.state.write().expect("engine state lock poisoned");
        state.session.logout();
        state.store.save(&state.session);
    }

    /// 听歌识曲:上传 PCM,返回候选歌曲(JSON 透传,候选解析在 Dart 侧之外
    /// 统一走 identify::parse_candidates,见 api::identify_music)。
    pub async fn identify(&self, pcm: Vec<u8>) -> AppResult<Value> {
        let session = self.session_snapshot();
        identify::identify_music(&self.client, &session, pcm).await
    }

    /// 判断上游响应是否为"会话失效/需要登录"（status=0 + 20xxx 错误码）。
    ///
    /// 实测：/song/url 返回 `{"errcode":20028,"error":"本次请求需要验证","status":0}`，
    /// /user/playlist 返回 `{"error_code":20017,"status":0}`；20xxx 系列均为登录态类错误。
    fn is_session_invalid_response(v: &Value) -> bool {
        if v.get("status").and_then(|s| s.as_i64()) != Some(0) {
            return false;
        }
        let code = v
            .get("error_code")
            .and_then(|c| c.as_i64())
            .or_else(|| v.get("errcode").and_then(|c| c.as_i64()));
        matches!(code, Some(c) if (20000..20100).contains(&c))
    }

    /// 将登录类响应写入会话并持久化（登录/二维码/token 刷新端点共用）。
    /// 返回写入后的会话快照，供 token 刷新重放路径复用。
    fn persist_login(&self, resp: &Value) -> KgSession {
        let mut state = self.state.write().expect("engine state lock poisoned");
        let userid = resp
            .get("userid")
            .and_then(|v| {
                v.as_i64()
                    .map(|i| i.to_string())
                    .or_else(|| v.as_str().map(|s| s.to_string()))
            })
            .unwrap_or_default();
        let token = resp.get("token").and_then(|v| v.as_str()).unwrap_or("");
        if userid.is_empty() || userid == "0" || token.is_empty() {
            return state.session.clone();
        }
        let vip_type = resp
            .get("vip_type")
            .and_then(|v| {
                v.as_i64()
                    .map(|i| i.to_string())
                    .or_else(|| v.as_str().map(|s| s.to_string()))
            })
            .unwrap_or_else(|| "0".to_string());
        let vip_token = resp.get("vip_token").and_then(|v| v.as_str()).unwrap_or("");
        let t1 = resp.get("t1").and_then(|v| v.as_str()).unwrap_or("");
        state
            .session
            .update_auth(&userid, token, &vip_type, vip_token, t1);
        state.store.save(&state.session);
        state.session.clone()
    }

    async fn dispatch_inner(
        &self,
        session: &KgSession,
        method: &str,
        path: &str,
        params: &HashMap<String, String>,
        body: Option<&str>,
    ) -> AppResult<Value> {
        let client = &self.client;

        match (method, path) {
            ("POST", "/captcha/sent") => {
                let mobile = params.get("mobile").map(|s| s.as_str()).unwrap_or("");
                login::send_sms_code(client, session, mobile).await
            }
            ("POST", "/login/cellphone") => {
                let mobile = params.get("mobile").map(|s| s.as_str()).unwrap_or("");
                let code = params.get("code").map(|s| s.as_str()).unwrap_or("");
                let userid = params.get("userid").map(|s| s.as_str());
                let resp =
                    login::login_by_mobile(client, "", session, mobile, code, userid).await?;
                self.persist_login(&resp);
                Ok(resp)
            }
            ("POST", "/login/token") => {
                let resp = login::refresh_token(client, "", session).await?;
                self.persist_login(&resp);
                Ok(resp)
            }
            ("POST", "/login/logout") => {
                login::logout(client, "", session).await;
                self.logout_internal();
                Ok(json!(null))
            }
            ("GET", "/login/qr/key") => login::get_qr_key(client, session).await,
            ("GET", "/login/qr/check") => {
                let key = params.get("key").map(|s| s.as_str()).unwrap_or("");
                let resp = login::check_qr_status(client, "", session, key).await?;
                self.persist_login(&resp);
                Ok(resp)
            }
            // 微信扫码三件套：create 生成二维码 / check 轮询微信长轮询接口 /
            // openplat 用 wx_code 换酷狗会话（partnerid=36）。
            ("GET", "/login/wx/create") => login::wx_qr_create(client).await,
            ("GET", "/login/wx/check") => {
                let uuid = params.get("uuid").map(|s| s.as_str()).unwrap_or("");
                login::wx_qr_check(client, uuid).await
            }
            ("POST", "/login/openplat") => {
                let code = params.get("code").map(|s| s.as_str()).unwrap_or("");
                let resp = login::login_by_openplat(client, "", session, code).await?;
                self.persist_login(&resp);
                Ok(resp)
            }

            ("GET", "/search") => {
                let keyword = params
                    .get("keywords")
                    .or_else(|| params.get("keyword"))
                    .map(|s| s.as_str())
                    .unwrap_or("");
                let page = params
                    .get("page")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(1i64);
                let pagesize = params
                    .get("pagesize")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(30i64);
                let search_type = params.get("type").map(|s| s.as_str()).unwrap_or("song");
                search::search_raw(client, session, keyword, page, pagesize, search_type).await
            }
            ("GET", "/search/hot") => search::search_hot(client, session).await,
            ("GET", "/search/suggest") => {
                let keyword = params
                    .get("keywords")
                    .or_else(|| params.get("keyword"))
                    .map(|s| s.as_str())
                    .unwrap_or("");
                search::search_suggest(client, session, keyword, 0, 0, 0, 10).await
            }

            ("GET", "/song/url") => {
                let hash = params.get("hash").map(|s| s.as_str()).unwrap_or("");
                let quality = params.get("quality").map(|s| s.as_str());
                let album_id = params.get("album_id").map(|s| s.as_str());
                let album_audio_id = params.get("album_audio_id").map(|s| s.as_str());
                let free_part = params
                    .get("free_part")
                    .map(|s| s == "1" || s == "true")
                    .unwrap_or(false);
                song::get_play_url(
                    client,
                    session,
                    hash,
                    quality,
                    album_id,
                    album_audio_id,
                    free_part,
                )
                .await
            }

            ("GET", "/song/climax") => {
                // 上游 Dart songClimax(hash) 传单个 hash；兼容逗号分隔多 hash
                let hash = params.get("hash").map(|s| s.as_str()).unwrap_or("");
                song::get_song_climax(client, session, hash).await
            }

            // ===== MV / 视频：播放直链、详情（含清晰度）、歌曲反查 MV、
            // 歌手 MV 列表、场景 MV 列表（首页「MV 精选」数据源）=====
            ("GET", "/video/url") => {
                let hash = params.get("hash").map(|s| s.as_str()).unwrap_or("");
                video::video_url(client, session, hash).await
            }
            ("GET", "/video/detail") => {
                // Dart 侧契约参数为 id；兼容 ids，逗号分隔可批量
                let ids = params
                    .get("id")
                    .or_else(|| params.get("ids"))
                    .map(|s| s.as_str())
                    .unwrap_or("");
                video::video_detail(client, session, ids).await
            }
            ("GET", "/kmr/audio/mv") => {
                // album_audio_id 逗号分隔批量；fields 默认 h264,h265（兼容性优先）
                let ids = params
                    .get("album_audio_id")
                    .or_else(|| params.get("ids"))
                    .map(|s| s.as_str())
                    .unwrap_or("");
                let fields = params
                    .get("fields")
                    .map(|s| s.as_str())
                    .unwrap_or("h264,h265");
                video::kmr_audio_mv(client, session, ids, fields).await
            }
            ("GET", "/scene/video/list") => {
                let tag_id = params.get("tag_id").map(|s| s.as_str()).unwrap_or("");
                let page = params
                    .get("page")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(1i64);
                let pagesize = params
                    .get("pagesize")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(30i64);
                video::scene_videos(client, session, tag_id, page, pagesize).await
            }
            ("GET", "/search/lyric") => {
                let hash = params.get("hash").map(|s| s.as_str());
                let album_audio_id = params.get("album_audio_id").map(|s| s.as_str());
                let keyword = params.get("keyword").map(|s| s.as_str());
                let man = params.get("man").map(|s| s.as_str());
                lyric::search_lyric(client, session, hash, album_audio_id, keyword, man).await
            }
            ("GET", "/lyric") => {
                let id = params.get("id").map(|s| s.as_str()).unwrap_or("");
                let accesskey = params.get("accesskey").map(|s| s.as_str()).unwrap_or("");
                let fmt = params.get("fmt").map(|s| s.as_str()).unwrap_or("krc");
                let decode = params
                    .get("decode")
                    .map(|s| s != "0" && s != "false")
                    .unwrap_or(true);
                lyric::get_lyric(client, session, id, accesskey, fmt, decode).await
            }

            ("GET", "/user/detail") => user::user_detail(client, session).await,
            ("GET", "/user/playlist") => {
                let page = params
                    .get("page")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(1i64);
                let pagesize = params
                    .get("pagesize")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(30i64);
                user::user_playlist(client, session, page, pagesize).await
            }
            ("GET", "/user/cloud") => {
                let page = params
                    .get("page")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(1i64);
                let pagesize = params
                    .get("pagesize")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(30i64);
                user::user_cloud(client, session, page, pagesize).await
            }
            ("GET", "/user/cloud/url") => {
                let hash = params.get("hash").map(|s| s.as_str()).unwrap_or("");
                let album_audio_id = params.get("album_audio_id").map(|s| s.as_str());
                let audio_id = params.get("audio_id").map(|s| s.as_str());
                let name = params.get("name").map(|s| s.as_str());
                user::user_cloud_url(client, session, hash, album_audio_id, audio_id, name).await
            }

            ("GET", "/top/playlist") => {
                let category_id = params
                    .get("category_id")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(0i64);
                let page = params
                    .get("page")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(1i64);
                discover::recommend_playlists(client, session, category_id, page).await
            }
            ("GET", "/top/song") => {
                // 上游 Dart topSongs() 传 `type`（默认 21608，对应酷狗新歌速递 rank_id，
                // .NET DiscoveryController.GetNewSong 直接把 type 透传为 body["rank_id"]）；
                // fork 旧 Dart 传 `rank_id`。两者都兼容，默认 21608 与上游一致。
                let rank_id = params
                    .get("type")
                    .or_else(|| params.get("rank_id"))
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(21608i64);
                let page = params
                    .get("page")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(1i64);
                discover::new_songs(client, session, rank_id, page).await
            }
            ("GET", "/top/album") => {
                let page = params
                    .get("page")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(1i64);
                let pagesize = params
                    .get("pagesize")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(30i64);
                discover::top_album(client, session, page, pagesize).await
            }
            ("GET", "/recommend/songs") => discover::recommend_songs(client, session).await,
            ("GET", "/ai/recommend") => {
                let album_audio_ids = params
                    .get("album_audio_ids")
                    .map(|s| s.as_str())
                    .unwrap_or("");
                discover::ai_recommend(client, session, album_audio_ids).await
            }
            ("GET", "/personal/fm") => {
                let hash = params.get("hash").map(|s| s.as_str());
                let songid = params.get("songid").map(|s| s.as_str());
                let playtime = params.get("playtime").and_then(|s| s.parse().ok());
                let action = params
                    .get("action")
                    .map(|s| s.as_str())
                    .unwrap_or("refresh");
                let mode = params.get("mode").map(|s| s.as_str()).unwrap_or("normal");
                let song_pool_id = params
                    .get("song_pool_id")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(0i64);
                let is_overplay = params
                    .get("is_overplay")
                    .map(|s| s == "1" || s == "true")
                    .unwrap_or(false);
                let remain_song_cnt = params
                    .get("remain_song_cnt")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(0i64);
                discover::personal_fm(
                    client,
                    session,
                    hash,
                    songid,
                    playtime,
                    action,
                    mode,
                    song_pool_id,
                    is_overplay,
                    remain_song_cnt,
                )
                .await
            }

            ("GET", "/rank/list") => {
                let withsong = params
                    .get("withsong")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(0i64);
                rank::rank_list(client, session, withsong).await
            }
            ("GET", "/rank/info") => {
                let rankid = params
                    .get("rankid")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(0i64);
                let rank_cid = params
                    .get("rank_cid")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(0i64);
                let album_img = params
                    .get("album_img")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(1i64);
                let zone = params.get("zone").map(|s| s.as_str()).unwrap_or("");
                rank::rank_info(client, session, rankid, rank_cid, album_img, zone).await
            }
            ("GET", "/rank/audio") => {
                let rankid = params
                    .get("rankid")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(0i64);
                let rank_cid = params
                    .get("rank_cid")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(0i64);
                let page = params
                    .get("page")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(1i64);
                let pagesize = params
                    .get("pagesize")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(30i64);
                rank::rank_audio(client, session, rankid, rank_cid, page, pagesize).await
            }
            ("GET", "/rank/top") => rank::rank_top(client, session).await,

            ("GET", "/album/shop") => album::album_shop(client, session).await,
            ("GET", "/album/detail") => {
                // 歌曲信息页：专辑名 / 发行时间 / 简介（与 /album/songs 同一套 id 契约）。
                let album_id = params
                    .get("album_id")
                    .or_else(|| params.get("id"))
                    .map(|s| s.as_str())
                    .unwrap_or("");
                album::album_detail(client, session, album_id).await
            }
            ("GET", "/album/songs") => {
                // Dart 侧契约参数为 id（旧服务器同款）；兼容 album_id 旧名。
                let album_id = params
                    .get("album_id")
                    .or_else(|| params.get("id"))
                    .map(|s| s.as_str())
                    .unwrap_or("");
                let page = params
                    .get("page")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(1i64);
                let pagesize = params
                    .get("pagesize")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(30i64);
                album::album_songs(client, session, album_id, page, pagesize).await
            }

            ("GET", "/fm/recommend") => fm::fm_recommend(client, session).await,
            ("GET", "/fm/songs") => {
                // Dart 侧契约参数为 fmid/type（旧服务器同款）；兼容 fm_ids/fmtype
                let fm_ids = params
                    .get("fmid")
                    .or_else(|| params.get("fm_ids"))
                    .map(|s| s.as_str())
                    .unwrap_or("");
                let fmtype = params
                    .get("type")
                    .or_else(|| params.get("fmtype"))
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(2i64);
                let offset = params
                    .get("offset")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(0i64);
                let size = params
                    .get("size")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(30i64);
                fm::fm_songs(client, session, fm_ids, fmtype, offset, size).await
            }
            ("GET", "/fm/class") => fm::fm_class(client, session).await,
            ("GET", "/fm/image") => {
                // Dart 侧契约参数为 fmid；兼容 fm_ids
                let fm_ids = params
                    .get("fmid")
                    .or_else(|| params.get("fm_ids"))
                    .map(|s| s.as_str())
                    .unwrap_or("");
                fm::fm_image(client, session, fm_ids).await
            }

            ("GET", "/playlist/similar") => {
                // ids 为 global_collection_id，逗号分隔多个
                let ids = params.get("ids").map(|s| s.as_str()).unwrap_or("");
                playlist::playlist_similar(client, session, ids).await
            }
            ("GET", "/playlist/detail") => {
                // Dart: ids；兼容 id
                let id = params
                    .get("ids")
                    .or_else(|| params.get("id"))
                    .map(|s| s.as_str())
                    .unwrap_or("");
                playlist::playlist_info(client, session, id).await
            }
            ("GET", "/playlist/track/all") => {
                let id = params.get("id").map(|s| s.as_str()).unwrap_or("");
                let pagesize = params
                    .get("pagesize")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(30i64);
                // 酷狗接口用 begin_idx（起始下标），.NET: beginIdx = (page-1)*pageSize
                // Dart 传 page；兼容直接传 begin_idx
                let begin_idx = params
                    .get("begin_idx")
                    .and_then(|s| s.parse().ok())
                    .or_else(|| {
                        params
                            .get("page")
                            .and_then(|s| s.parse::<i64>().ok())
                            .map(|page| {
                                let p = if page < 1 { 1 } else { page };
                                (p - 1) * pagesize
                            })
                    })
                    .unwrap_or(0i64);
                playlist::playlist_tracks(client, session, id, begin_idx, pagesize).await
            }
            ("POST", "/playlist/external/parse") => {
                // Dart body: { sourceText };兼容 body 里的 SourceText / query 传参
                let body_val: Value =
                    serde_json::from_str(body.unwrap_or("{}")).unwrap_or_default();
                let source_text = first_str(
                    &[&body_val],
                    params,
                    &["sourceText", "SourceText", "source_text"],
                )
                .unwrap_or_default();
                let result = external_playlist::parse(client, &source_text).await?;
                serde_json::to_value(result)
                    .map_err(|e| AppError::Internal(format!("序列化解析结果失败: {e}")))
            }
            ("POST", "/playlist/create") => {
                // Dart 走 query: name / type；兼容 body: name / is_pri
                let body_val: Value =
                    serde_json::from_str(body.unwrap_or("{}")).unwrap_or_default();
                let name =
                    first_str(&[&body_val], params, &["name"]).unwrap_or_else(|| "新歌单".into());
                let is_pri = first_i64(&[&body_val], params, &["is_pri", "type"]).unwrap_or(0);
                playlist::create_playlist(client, session, &name, is_pri).await
            }
            ("POST", "/playlist/add") => {
                // Dart 走 query: name / list_create_gid
                let body_val: Value =
                    serde_json::from_str(body.unwrap_or("{}")).unwrap_or_default();
                let name = first_str(&[&body_val], params, &["name"]).unwrap_or_default();
                let global_collection_id = first_str(
                    &[&body_val],
                    params,
                    &["list_create_gid", "global_collection_id"],
                )
                .unwrap_or_default();
                playlist::collect_playlist(client, session, &name, &global_collection_id).await
            }
            ("POST", "/playlist/del") => {
                // Dart 走 query: listid
                let body_val: Value =
                    serde_json::from_str(body.unwrap_or("{}")).unwrap_or_default();
                let listid =
                    first_str(&[&body_val], params, &["listid", "listId"]).unwrap_or_default();
                playlist::delete_playlist(client, session, &listid).await
            }
            ("POST", "/playlist/tracks/add") => {
                // Dart body: { listId, songs: [{ name, hash, albumId, mixSongId }] }
                let body_val: Value =
                    serde_json::from_str(body.unwrap_or("{}")).unwrap_or_default();
                let listid =
                    first_str(&[&body_val], params, &["listId", "listid"]).unwrap_or_default();
                let songs = parse_add_songs(body_val.get("songs"));
                playlist::add_tracks(client, session, &listid, &songs).await
            }
            ("POST", "/playlist/tracks/del") => {
                // Dart: query listid + fileids（逗号分隔）；兼容 body listid + file_ids 数组
                let body_val: Value =
                    serde_json::from_str(body.unwrap_or("{}")).unwrap_or_default();
                let listid =
                    first_str(&[&body_val], params, &["listid", "listId"]).unwrap_or_default();
                let file_ids = parse_file_ids(&body_val, params);
                playlist::remove_tracks(client, session, &listid, &file_ids).await
            }

            ("GET", "/artist/detail") => {
                let id = params.get("id").map(|s| s.as_str()).unwrap_or("");
                artist::artist_detail(client, session, id).await
            }
            ("GET", "/artist/audios") => {
                let id = params.get("id").map(|s| s.as_str()).unwrap_or("");
                let page = params
                    .get("page")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(1i64);
                let pagesize = params
                    .get("pagesize")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(30i64);
                let sort = params.get("sort").map(|s| s.as_str()).unwrap_or("hot");
                artist::artist_audios(client, session, id, page, pagesize, sort).await
            }
            ("GET", "/artist/albums") => {
                // 上游 Dart artistAlbums(id, page, pageSize, sort: 'new')
                let id = params.get("id").map(|s| s.as_str()).unwrap_or("");
                let page = params
                    .get("page")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(1i64);
                let pagesize = params
                    .get("pagesize")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(30i64);
                let sort = params.get("sort").map(|s| s.as_str()).unwrap_or("new");
                artist::artist_albums(client, session, id, page, pagesize, sort).await
            }
            ("GET", "/artist/videos") => {
                // tag: official(官方)/live(现场)/fan(饭制)/artist(歌手发布)/all
                let id = params.get("id").map(|s| s.as_str()).unwrap_or("");
                let page = params
                    .get("page")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(1i64);
                let pagesize = params
                    .get("pagesize")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(30i64);
                let tag = params.get("tag").map(|s| s.as_str()).unwrap_or("all");
                artist::artist_videos(client, session, id, page, pagesize, tag).await
            }

            ("GET", "/comment/music") => {
                let mixsongid = params.get("mixsongid").map(|s| s.as_str()).unwrap_or("");
                let page = params
                    .get("page")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(1i64);
                let pagesize = params
                    .get("pagesize")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(20i64);
                let show_classify = params
                    .get("show_classify")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(1i64);
                let show_hotword_list = params
                    .get("show_hotword_list")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(1i64);
                comment::music_comments(
                    client,
                    session,
                    mixsongid,
                    page,
                    pagesize,
                    show_classify,
                    show_hotword_list,
                )
                .await
            }

            ("GET", "/user/vip/detail") => user::user_vip_detail(client, session).await,
            ("GET", "/youth/month/vip/record") => youth::month_vip_record(client, session).await,
            ("GET", "/youth/day/vip") => youth::receive_one_day_vip(client, session).await,
            ("GET", "/youth/day/vip/upgrade") => youth::upgrade_vip(client, session).await,

            ("POST", "/listen/timeadd") => report::listen_time_add(client, session).await,

            _ => Err(AppError::Other(format!(
                "Unknown route: {} {}",
                method, path
            ))),
        }
    }
}

fn first_str(bodies: &[&Value], params: &HashMap<String, String>, keys: &[&str]) -> Option<String> {
    for key in keys {
        for body in bodies {
            if let Some(v) = body.get(*key) {
                if let Some(s) = v.as_str() {
                    if !s.is_empty() {
                        return Some(s.to_string());
                    }
                }
                if let Some(n) = v.as_i64() {
                    return Some(n.to_string());
                }
                if let Some(n) = v.as_u64() {
                    return Some(n.to_string());
                }
            }
        }
        if let Some(s) = params.get(*key) {
            if !s.is_empty() {
                return Some(s.clone());
            }
        }
    }
    None
}

fn first_i64(bodies: &[&Value], params: &HashMap<String, String>, keys: &[&str]) -> Option<i64> {
    for key in keys {
        for body in bodies {
            if let Some(v) = body.get(*key) {
                if let Some(n) = v.as_i64() {
                    return Some(n);
                }
                if let Some(s) = v.as_str() {
                    if let Ok(n) = s.parse::<i64>() {
                        return Some(n);
                    }
                }
            }
        }
        if let Some(s) = params.get(*key) {
            if let Ok(n) = s.parse::<i64>() {
                return Some(n);
            }
        }
    }
    None
}

/// 兼容 Dart camelCase payload 与 Rust snake_case 字段。
fn parse_add_songs(raw: Option<&Value>) -> Vec<playlist::AddSongItem> {
    let Some(arr) = raw.and_then(|v| v.as_array()) else {
        return Vec::new();
    };
    arr.iter()
        .filter_map(|item| {
            let name = item
                .get("name")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let hash = item
                .get("hash")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            if name.is_empty() || hash.is_empty() {
                return None;
            }
            let album_id = item
                .get("albumId")
                .or_else(|| item.get("album_id"))
                .map(value_to_string)
                .unwrap_or_default();
            let mix_song_id = item
                .get("mixSongId")
                .or_else(|| item.get("mixsongid"))
                .or_else(|| item.get("mix_song_id"))
                .map(value_to_string)
                .unwrap_or_default();
            Some(playlist::AddSongItem {
                name,
                hash,
                album_id,
                mix_song_id,
            })
        })
        .collect()
}

fn parse_file_ids(body: &Value, params: &HashMap<String, String>) -> Vec<i64> {
    if let Some(arr) = body
        .get("file_ids")
        .or_else(|| body.get("fileids"))
        .and_then(|v| v.as_array())
    {
        return arr
            .iter()
            .filter_map(|v| {
                v.as_i64()
                    .or_else(|| v.as_str().and_then(|s| s.parse().ok()))
            })
            .collect();
    }
    let raw = params
        .get("fileids")
        .or_else(|| params.get("file_ids"))
        .cloned()
        .or_else(|| {
            body.get("fileids")
                .or_else(|| body.get("file_ids"))
                .and_then(|v| v.as_str().map(|s| s.to_string()))
        })
        .unwrap_or_default();
    raw.split(',')
        .filter_map(|s| s.trim().parse::<i64>().ok())
        .collect()
}

fn value_to_string(v: &Value) -> String {
    if let Some(s) = v.as_str() {
        return s.to_string();
    }
    if let Some(n) = v.as_i64() {
        return n.to_string();
    }
    if let Some(n) = v.as_u64() {
        return n.to_string();
    }
    String::new()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn session_invalid_detection() {
        // 实测形态：/song/url 用失效 token
        assert!(KugouEngine::is_session_invalid_response(&json!({
            "errcode": 20028, "error": "本次请求需要验证", "status": 0
        })));
        // 实测形态：/user/playlist 用失效 token
        assert!(KugouEngine::is_session_invalid_response(&json!({
            "error_code": 20017, "status": 0
        })));
        // 成功响应不应误判
        assert!(!KugouEngine::is_session_invalid_response(&json!({
            "status": 1, "error_code": 0, "url": "https://example.com/a.mp3"
        })));
        // 非登录类错误码不应触发刷新
        assert!(!KugouEngine::is_session_invalid_response(&json!({
            "status": 0, "error_code": 9001, "err": "缺参"
        })));
        // 缺 status 或 status 非 0 不应触发
        assert!(!KugouEngine::is_session_invalid_response(&json!({
            "error_code": 20017
        })));
        assert!(!KugouEngine::is_session_invalid_response(&json!({
            "status": 2, "error_code": 20017
        })));
        // 无错误码时不应触发
        assert!(!KugouEngine::is_session_invalid_response(&json!({
            "status": 0, "msg": "服务内部错误"
        })));
    }

    /// 联网探针：实测 /fm/recommend 与 /fm/songs 的真实返回结构。
    /// 仅手动运行：`cargo test --lib fm_live_probe -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn fm_live_probe() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let dir = std::env::temp_dir().join("fm_probe_session");
            std::fs::create_dir_all(&dir).unwrap();
            // 可选：通过 KG_SESSION_FILE 指定登录会话文件（复制到临时目录，不回写、不打印内容）
            if let Ok(path) = std::env::var("KG_SESSION_FILE") {
                let src = std::path::PathBuf::from(path);
                if src.exists() {
                    std::fs::copy(src, dir.join("kg_session.json")).unwrap();
                }
            }
            let engine = KugouEngine::new(dir.to_string_lossy().to_string()).await;

            let rec = engine
                .request("GET", "/fm/recommend", "{}", None)
                .await
                .expect("fm/recommend failed");
            let rec_v: serde_json::Value = serde_json::from_str(&rec).unwrap();
            println!(
                "== /fm/recommend 顶层键: {:?}",
                rec_v.as_object().map(|m| m.keys().collect::<Vec<_>>())
            );

            // 递归收集带 fmid 的对象作为电台候选
            fn collect_stations(v: &serde_json::Value, out: &mut Vec<serde_json::Value>) {
                match v {
                    serde_json::Value::Object(map) => {
                        if map.contains_key("fmid") {
                            out.push(v.clone());
                        }
                        for child in map.values() {
                            collect_stations(child, out);
                        }
                    }
                    serde_json::Value::Array(list) => {
                        for child in list {
                            collect_stations(child, out);
                        }
                    }
                    _ => {}
                }
            }
            let mut stations = Vec::new();
            collect_stations(&rec_v, &mut stations);
            println!("== 推荐电台数量: {}", stations.len());
            for s in stations.iter().take(3) {
                println!(
                    "== 电台: fmid={:?} fmname={:?} fmtype={:?} rcmdlist长度={:?}",
                    s.get("fmid"),
                    s.get("fmname"),
                    s.get("fmtype").or_else(|| s.get("type")),
                    s.get("rcmdlist")
                        .and_then(|l| l.as_array())
                        .map(|a| a.len())
                );
            }
            assert!(!stations.is_empty(), "推荐电台为空，结构可能变化");

            #[allow(dead_code)]
            fn count_songs(v: &serde_json::Value) -> (usize, Option<Vec<String>>) {
                match v {
                    serde_json::Value::Object(map) => {
                        if map.contains_key("hash") {
                            return (1, Some(map.keys().cloned().collect::<Vec<_>>()));
                        }
                        let mut total = 0;
                        let mut keys = None;
                        for child in map.values() {
                            let (n, k) = count_songs(child);
                            total += n;
                            keys = keys.or(k);
                        }
                        (total, keys)
                    }
                    serde_json::Value::Array(list) => {
                        let mut total = 0;
                        let mut keys = None;
                        for child in list {
                            let (n, k) = count_songs(child);
                            total += n;
                            keys = keys.or(k);
                        }
                        (total, keys)
                    }
                    _ => (0, None),
                }
            }

            // 对照实验：引擎路径不同 size 多次调用（FM 为随机歌单，需排除偶发性）
            let station = &stations[0];
            let fmid = station["fmid"].as_str().unwrap_or_default().to_string();
            let fmtype = station
                .get("fmtype")
                .or_else(|| station.get("type"))
                .and_then(|t| t.as_i64())
                .unwrap_or(2);
            fn count_songs_only(v: &serde_json::Value) -> usize {
                match v {
                    serde_json::Value::Object(map) => {
                        if map.contains_key("hash") {
                            return 1;
                        }
                        map.values().map(count_songs_only).sum()
                    }
                    serde_json::Value::Array(list) => list.iter().map(count_songs_only).sum(),
                    _ => 0,
                }
            }
            let mut max_count = 0usize;
            // 引擎完整链路（Dart 契约参数；值须为字符串，与 rust_api_client 的编码一致）
            for _ in 0..2 {
                let query = format!(
                    r#"{{"fmid":"{}","type":"{}","offset":"-1","size":"20"}}"#,
                    fmid, fmtype
                );
                let songs = engine
                    .request("GET", "/fm/songs", &query, None)
                    .await
                    .expect("fm/songs failed");
                let songs_v: serde_json::Value = serde_json::from_str(&songs).unwrap();
                let n = count_songs_only(&songs_v);
                println!("== /fm/songs size=20 => 歌曲数 {}", n);
                max_count = max_count.max(n);
            }
            assert!(
                max_count > 1,
                "电台歌曲应多于 1 首，实际最多 {} 首",
                max_count
            );

            // /fm/class：分类电台分组
            let class = engine
                .request("GET", "/fm/class", "{}", None)
                .await
                .expect("fm/class failed");
            let class_v: serde_json::Value = serde_json::from_str(&class).unwrap();
            let mut class_stations = Vec::new();
            collect_stations(&class_v, &mut class_stations);
            println!("== /fm/class 分类电台数量: {}", class_stations.len());

            // /fm/image（Dart 契约参数 fmid）
            let img_query = format!(r#"{{"fmid":"{}"}}"#, fmid);
            let img = engine
                .request("GET", "/fm/image", &img_query, None)
                .await
                .expect("fm/image failed");
            let img_v: serde_json::Value = serde_json::from_str(&img).unwrap();
            println!(
                "== /fm/image 返回: {}",
                &img_v.to_string()[..img_v.to_string().len().min(300)]
            );
        });
    }
}
