//! MV / 视频相关服务：播放地址、详情（含清晰度）、歌曲反查 MV、场景 MV 列表。
//!
//! 契约对齐 KuGouMusicApi（module/video_url.js、video_detail.js、
//! kmr_audio_mv.js、scene_video_list.js）与 api.json 的同名端点。

use serde_json::{json, Value};

use crate::error::AppResult;
use crate::kugou::{
    config, crypto,
    request::{KgRequest, SignatureType},
    session::KgSession,
    signer, transport,
};

/// 获取视频播放直链（GET /v2/interface/index，x-router: trackermv）。
///
/// 与歌曲 /v5/url 同族：Default 签名 + V5 额外 `key` 参数（transport 层对
/// `SignatureType::V5` 且带 `hash` 参数的请求自动注入 `calc_v5_key`）。
/// 清晰度由传入的 hash 决定——搜索结果的 MvHash 是标清，高清/超清 hash
/// 需先经 [`video_detail`]（show_resolution=1）换取。
pub async fn video_url(client: &reqwest::Client, session: &KgSession, hash: &str) -> AppResult<Value> {
    let dfid = if session.dfid.trim().is_empty() || session.dfid == "-" {
        crypto::random_string(24)
    } else {
        session.dfid.clone()
    };
    let req = KgRequest::get("/v2/interface/index")
        .param("backupdomain", "1")
        .param("cmd", "123")
        .param("ext", "mp4")
        .param("ismp3", "0")
        .param("hash", hash.to_lowercase())
        .param("pid", "1")
        .param("type", "1")
        .router("trackermv.kugou.com")
        .signature_type(SignatureType::V5)
        .specific_dfid(dfid);
    transport::send(client, session, &req).await
}

/// 视频详情（POST kmr.service /v1/video，show_resolution=1）。
///
/// 返回 title/cover/duration/singer 及各清晰度视频 hash（换取不同分辨率
/// 播放地址用）。`ids` 为视频 id（搜索结果 MvID），逗号分隔可批量。
/// 自 media_catalog.rs（未编译的闲置模块）迁移而来，body key 与
/// KuGouMusicApi signParamsKey 的 lite 变体一致（calc_login_key）。
pub async fn video_detail(client: &reqwest::Client, session: &KgSession, ids: &str) -> AppResult<Value> {
    let now = chrono::Utc::now().timestamp();
    let mid = crypto::calc_new_mid(&session.dfid);
    let data: Vec<Value> = ids.split(',').filter(|s| !s.trim().is_empty())
        .map(|id| json!({ "video_id": id.trim() })).collect();
    let body = json!({
        "appid": config::APP_ID, "clientver": config::CLIENT_VER, "clienttime": now,
        "mid": mid, "uuid": crypto::md5_str(&format!("{}{}", session.dfid, mid)),
        "dfid": session.dfid, "token": session.token,
        "key": signer::calc_login_key(now), "show_resolution": 1, "data": data
    });
    let req = KgRequest::get("/v1/video")
        .method(reqwest::Method::POST)
        .clear_default_params()
        .router("kmr.service.kugou.com")
        .json_body(body)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

/// 按 album_audio_id（MixSongID）批量反查歌曲对应的 MV。
///
/// POST openapi /kmr/v1/audio/mv（kg-tid: 38）。`ids` 逗号分隔批量；
/// `fields` 控制返回格式（h264/h265/mkv/tags/authors），播放场景固定
/// 传 "h264,h265"——h264 兼容性最好（部分车机/老设备无 h265 硬解）。
pub async fn kmr_audio_mv(
    client: &reqwest::Client,
    session: &KgSession,
    ids: &str,
    fields: &str,
) -> AppResult<Value> {
    let data: Vec<Value> = ids.split(',').filter(|s| !s.trim().is_empty())
        .map(|id| json!({ "album_audio_id": id.trim() })).collect();
    let body = json!({ "data": data, "fields": fields });
    let req = KgRequest::get("/kmr/v1/audio/mv")
        .method(reqwest::Method::POST)
        .router("openapi.kugou.com")
        .custom_header("kg-tid", "38")
        .json_body(body)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

/// 场景 MV 列表（POST /scene/v1/distribution/video_list）。
///
/// 首页「MV 精选」栏目数据源。自 media_catalog.rs（未编译的闲置模块）
/// 迁移而来。
pub async fn scene_videos(
    client: &reqwest::Client,
    session: &KgSession,
    tag_id: &str,
    page: i64,
    page_size: i64,
) -> AppResult<Value> {
    let body = json!({
        "appid": config::APP_ID, "clientver": config::CLIENT_VER, "token": session.token,
        "userid": session.userid, "tag_id": tag_id, "page": page, "page_size": page_size, "exposed_data": []
    });
    let req = KgRequest::get("/scene/v1/distribution/video_list")
        .method(reqwest::Method::POST)
        .json_body(body)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}
