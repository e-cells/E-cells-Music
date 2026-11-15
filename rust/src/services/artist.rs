use serde_json::{json, Value};

use crate::error::AppResult;
use crate::kugou::{
    config, crypto,
    request::{KgRequest, SignatureType},
    session::KgSession,
    signer, transport,
};

#[allow(dead_code)]
pub async fn artist_lists(
    client: &reqwest::Client,
    session: &KgSession,
    musician: i64,
    sextype: i64,
    r#type: i64,
    hotsize: i64,
) -> AppResult<Value> {
    let req = KgRequest::get("/ocean/v6/singer/list")
        .param("musician", musician.to_string())
        .param("sextype", sextype.to_string())
        .param("showtype", "2")
        .param("type", r#type.to_string())
        .param("hotsize", hotsize.to_string())
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn singer_list(
    client: &reqwest::Client,
    session: &KgSession,
    sextype: i64,
    r#type: i64,
    hotsize: i64,
) -> AppResult<Value> {
    let req = KgRequest::get("/ocean/v6/singer/list")
        .param("sextype", sextype.to_string())
        .param("type", r#type.to_string())
        .param("hotsize", hotsize.to_string())
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

/// 歌手 MV 列表（GET openapicdn /kmr/v1/author/videos）。
///
/// tag: official(官方,tag_idx=18) / live(现场,20) / fan(饭制,23) /
/// artist(歌手发布,42419) / 其他视为全部（tag_idx 空）。
pub async fn artist_videos(
    client: &reqwest::Client,
    session: &KgSession,
    id: &str,
    page: i64,
    pagesize: i64,
    tag: &str,
) -> AppResult<Value> {
    let tag_idx = match tag {
        "official" => "18",
        "live" => "20",
        "fan" => "23",
        "artist" => "42419",
        _ => "",
    };
    let req = KgRequest::get("/kmr/v1/author/videos")
        .base_url("https://openapicdn.kugou.com")
        .param("author_id", id)
        .param("is_fanmade", "")
        .param("tag_idx", tag_idx)
        .param("pagesize", pagesize.to_string())
        .param("page", page.to_string())
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

pub async fn artist_detail(
    client: &reqwest::Client,
    session: &KgSession,
    id: &str,
) -> AppResult<Value> {
    let body = json!({ "author_id": id });
    let req = KgRequest::get("/kmr/v3/author")
        .method(reqwest::Method::POST)
        .router("openapi.kugou.com")
        .json_body(body)
        .custom_header("kg-tid", "36")
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

pub async fn artist_audios(
    client: &reqwest::Client,
    session: &KgSession,
    id: &str,
    page: i64,
    pagesize: i64,
    sort: &str,
) -> AppResult<Value> {
    let client_time = chrono::Utc::now().timestamp();
    let body = json!({
        "appid": config::APP_ID,
        "clientver": config::CLIENT_VER,
        "mid": crypto::calc_new_mid(&session.dfid),
        "clienttime": client_time,
        "key": signer::calc_login_key(chrono::Utc::now().timestamp_millis()),
        "author_id": id,
        "pagesize": pagesize,
        "page": page,
        "sort": if sort == "hot" { 1 } else { 2 },
        "area_code": "all"
    });
    let req = KgRequest::get("/kmr/v1/audio_group/author")
        .method(reqwest::Method::POST)
        .base_url("https://openapi.kugou.com")
        .router("openapi.kugou.com")
        .json_body(body)
        .custom_header("kg-tid", "220")
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

pub async fn artist_albums(
    client: &reqwest::Client,
    session: &KgSession,
    id: &str,
    page: i64,
    pagesize: i64,
    sort: &str,
) -> AppResult<Value> {
    let body = json!({
        "author_id": id,
        "pagesize": pagesize,
        "page": page,
        "sort": if sort == "hot" { 3 } else { 1 },
        "category": 1,
        "area_code": "all"
    });
    let req = KgRequest::get("/kmr/v1/author/albums")
        .method(reqwest::Method::POST)
        .router("openapi.kugou.com")
        .json_body(body)
        .custom_header("kg-tid", "36")
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn artist_honour(
    client: &reqwest::Client,
    session: &KgSession,
    id: &str,
    page: i64,
    pagesize: i64,
) -> AppResult<Value> {
    let req = KgRequest::get("/v1/query_singer_honour_detail")
        .method(reqwest::Method::POST)
        .base_url("http://h5activity.kugou.com")
        .param("singer_id", id)
        .param("pagesize", pagesize.to_string())
        .param("page", page.to_string())
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}
