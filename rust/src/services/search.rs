use serde_json::json;
use serde_json::Value;

use crate::error::{AppError, AppResult};
use crate::kugou::{
    crypto,
    models::{SearchResultData, SongInfo},
    request::{KgRequest, SignatureType},
    session::KgSession,
    transport,
};

pub async fn search_raw(
    client: &reqwest::Client,
    session: &KgSession,
    keyword: &str,
    page: i64,
    pagesize: i64,
    search_type: &str,
) -> AppResult<Value> {
    let req = KgRequest::get(format!(
        "/{}/search/{}",
        if search_type == "song" { "v3" } else { "v1" },
        search_type
    ))
    .param("keyword", keyword)
    .param("page", page.to_string())
    .param("pagesize", pagesize.to_string())
    .param("platform", "AndroidFilter")
    .param("iscorrection", "1");
    // 对齐 KuGouMusicApi 参考实现（module/search.js 的通用分支）：
    // song/album 之外的类型（special 歌单/lyric/author/mv）额外带
    // albumhide=0、nocollect=0，缺参时 complexsearch 会拒答或返回空。
    let req = if search_type != "song" && search_type != "album" {
        req.param("albumhide", "0").param("nocollect", "0")
    } else {
        req
    };
    let req = req
        .router("complexsearch.kugou.com")
        .signature_type(SignatureType::Default);

    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn search_songs(
    client: &reqwest::Client,
    session: &KgSession,
    keyword: &str,
    page: i64,
    pagesize: i64,
) -> AppResult<Vec<SongInfo>> {
    let v = search_raw(client, session, keyword, page, pagesize, "song").await?;
    let data: SearchResultData = serde_json::from_value(v)
        .map_err(|e| AppError::Internal(format!("解析搜索结果失败: {e}")))?;
    Ok(data.songs)
}

pub async fn search_hot(client: &reqwest::Client, session: &KgSession) -> AppResult<Value> {
    let req = KgRequest::get("/api/v3/search/hot_tab")
        .param("navid", "1")
        .param("plat", "2")
        .router("msearch.kugou.com")
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn search_default(
    client: &reqwest::Client,
    session: &KgSession,
    userid: &str,
    vip_type: &str,
) -> AppResult<Value> {
    let uid: i64 = userid.parse().unwrap_or(0);
    let body = json!({
        "plat": 0,
        "userid": uid,
        "tags": "{}",
        "vip_type": vip_type,
        "m_type": 0,
        "own_ads": {},
        "ability": "3",
        "sources": [],
        "bitmap": 2,
        "mode": "normal"
    });
    let req = KgRequest::get("/searchnofocus/v1/search_no_focus_word")
        .method(reqwest::Method::POST)
        .param("clientver", "12329")
        .json_body(body)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(clippy::too_many_arguments)]
pub async fn search_suggest(
    client: &reqwest::Client,
    session: &KgSession,
    keyword: &str,
    album_tip: i64,
    correct_tip: i64,
    mv_tip: i64,
    music_tip: i64,
) -> AppResult<Value> {
    let req = KgRequest::get("/v2/getSearchTip")
        .param("keyword", keyword)
        .param("AlbumTipCount", album_tip.to_string())
        .param("CorrectTipCount", correct_tip.to_string())
        .param("MVTipCount", mv_tip.to_string())
        .param("MusicTipCount", music_tip.to_string())
        .param("radiotip", "1")
        .router("searchtip.kugou.com")
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn search_mixed(
    client: &reqwest::Client,
    session: &KgSession,
    keyword: &str,
) -> AppResult<Value> {
    let time_ms = chrono::Utc::now().timestamp_millis();
    let requestid = format!(
        "{}_0",
        crypto::md5_str(&format!("bdaa53d04e7475feb9024164a47032f9{}", time_ms))
    );

    let req = KgRequest::get("/v3/search/mixed")
        .param("ab_tag", "0")
        .param("ability", "511")
        .param("albumhide", "0")
        .param("apiver", "22")
        .param("area_code", "1")
        .param("clientver", "20125")
        .param("cursor", "0")
        .param("is_gpay", "0")
        .param("iscorrection", "1")
        .param("keyword", keyword)
        .param("nocollect", "0")
        .param("osversion", "16.5")
        .param("platform", "IOSFilter")
        .param("recver", "2")
        .param("req_ai", "1")
        .param("requestid", requestid)
        .param("search_ability", "3")
        .param("sec_aggre", "1")
        .param("sec_aggre_bitmap", "0")
        .param("style_type", "3")
        .param("tag", "em")
        .router("complexsearch.kugou.com")
        .signature_type(SignatureType::Default);

    let req = req.custom_header("kg-clienttimems", time_ms.to_string());
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn search_complex(
    client: &reqwest::Client,
    session: &KgSession,
    keyword: &str,
    page: i64,
    pagesize: i64,
) -> AppResult<Value> {
    let req = KgRequest::get("/v6/search/complex")
        .base_url("https://complexsearch.kugou.com")
        .param("platform", "AndroidFilter")
        .param("keyword", keyword)
        .param("page", page.to_string())
        .param("pagesize", pagesize.to_string())
        .param("cursor", "0")
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}
