//! The users API of examples/users, in Rust with axum on tokio: a comparison workload.
//!
//!     cargo build --release && ./target/release/users 8000
//!
//! The same work as benches/go_users: same routes, same limits, same validation rules, same stored answer (the user's
//! canonical compact JSON, id first), hand-written range checks and serde_json into a struct (`deny_unknown_fields`).
//! One thread: the runtime is `current_thread`, so the server uses the one core it is pinned to, as the others do.
//! Release profile with LTO and one codegen unit; otherwise the defaults.
//!
//! Left out, because nothing measures them: /openapi.json. Known differences at the edges, none of them in
//! benches/equivalent.py's cases: serde_json refuses a repeated key (the cancho service keeps the first, Go the last), and
//! `150.0` is not an integer.

use axum::{
    body::Bytes,
    extract::{DefaultBodyLimit, Path, Query, State},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::get,
    serve::ListenerExt,
    Router,
};
use serde::{Deserialize, Serialize};
use std::sync::{Arc, Mutex};

const MAX_USERS: usize = 100_000;
const MAX_BODY: usize = 1 << 20;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct NewUser {
    name: String,
    email: Option<String>,
    age: Option<i64>,
    role: Option<String>,
    tags: Option<Vec<String>>,
}

#[derive(Serialize)]
struct User<'a> {
    id: usize,
    name: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    email: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    age: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    role: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tags: Option<&'a Vec<String>>,
}

#[derive(Default)]
struct Store {
    rows: Vec<Option<Bytes>>, // rows[id-1] is the stored JSON of user id, None once deleted
    live: usize,
}

type Shared = Arc<Mutex<Store>>;

fn problem(status: u16, title: &str, detail: &str) -> Response {
    let body = serde_json::json!({ "title": title, "status": status, "detail": detail }).to_string();
    (
        StatusCode::from_u16(status).unwrap(),
        [(header::CONTENT_TYPE, "application/problem+json")],
        body,
    )
        .into_response()
}

fn reply(status: StatusCode, body: Bytes) -> Response {
    (status, [(header::CONTENT_TYPE, "application/json")], body).into_response()
}

fn between(s: &str, lo: usize, hi: usize) -> bool {
    let n = s.chars().count();
    n >= lo && n <= hi
}

impl NewUser {
    fn valid(&self) -> bool {
        if !between(&self.name, 1, 64) {
            return false;
        }
        if let Some(e) = &self.email {
            if !between(e, 3, 120) {
                return false;
            }
        }
        if let Some(a) = self.age {
            if !(0..=150).contains(&a) {
                return false;
            }
        }
        if let Some(r) = &self.role {
            if r != "admin" && r != "user" && r != "guest" {
                return false;
            }
        }
        if let Some(t) = &self.tags {
            if t.len() > 8 || t.iter().any(|x| !between(x, 1, 16)) {
                return false;
            }
        }
        true
    }
}

async fn create(State(store): State<Shared>, headers: HeaderMap, body: Bytes) -> Response {
    let ct = headers.get(header::CONTENT_TYPE).map(|v| v.as_bytes()).unwrap_or(b"");
    if ct.len() < 16 || !ct[..16].eq_ignore_ascii_case(b"application/json") {
        return problem(415, "Unsupported Media Type", "send Content-Type: application/json");
    }
    let nu: NewUser = match serde_json::from_slice(&body) {
        Ok(n) => n,
        Err(e) => {
            return if e.is_data() {
                problem(422, "Unprocessable Content", &e.to_string())
            } else {
                problem(400, "Bad Request", &e.to_string())
            };
        }
    };
    if !nu.valid() {
        return problem(422, "Unprocessable Content", "the body does not satisfy the schema");
    }
    let mut s = store.lock().unwrap();
    if s.rows.len() >= MAX_USERS {
        return problem(503, "Service Unavailable", "the store is full");
    }
    let id = s.rows.len() + 1;
    let json = serde_json::to_vec(&User {
        id,
        name: &nu.name,
        email: nu.email.as_deref(),
        age: nu.age,
        role: nu.role.as_deref(),
        tags: nu.tags.as_ref(),
    })
    .unwrap();
    let bytes = Bytes::from(json);
    s.rows.push(Some(bytes.clone()));
    s.live += 1;
    let mut r = reply(StatusCode::CREATED, bytes);
    r.headers_mut().insert(header::LOCATION, format!("/users/{id}").parse().unwrap());
    r
}

/// A decimal number of at most 17 digits, else -1.
fn digits(s: &str) -> i64 {
    if s.is_empty() || s.len() > 17 {
        return -1;
    }
    let mut n: i64 = 0;
    for b in s.bytes() {
        if !b.is_ascii_digit() {
            return -1;
        }
        n = n * 10 + i64::from(b - b'0');
    }
    n
}

async fn list(State(store): State<Shared>, Query(q): Query<Vec<(String, String)>>) -> Response {
    let (mut limit, mut offset) = (20i64, 0i64);
    let (mut seen_limit, mut seen_offset) = (false, false);
    for (k, v) in &q {
        match k.as_str() {
            "limit" => {
                if !seen_limit {
                    limit = digits(v);
                    seen_limit = true;
                }
            }
            "offset" => {
                if !seen_offset {
                    offset = digits(v);
                    seen_offset = true;
                }
            }
            _ => return problem(422, "Unprocessable Content", "unknown query parameter: only limit and offset are taken"),
        }
    }
    if !(1..=100).contains(&limit) {
        return problem(422, "Unprocessable Content", "limit must be an integer from 1 to 100");
    }
    if offset < 0 {
        return problem(422, "Unprocessable Content", "offset must be a non-negative integer");
    }
    let s = store.lock().unwrap();
    let mut out: Vec<u8> = Vec::with_capacity(2048);
    out.extend_from_slice(b"{\"total\":");
    out.extend_from_slice(s.live.to_string().as_bytes());
    out.extend_from_slice(b",\"items\":[");
    let (mut taken, mut skipped) = (0i64, 0i64);
    for row in s.rows.iter() {
        if taken >= limit {
            break;
        }
        let Some(row) = row else { continue };
        if skipped < offset {
            skipped += 1;
            continue;
        }
        if taken > 0 {
            out.push(b',');
        }
        out.extend_from_slice(row);
        taken += 1;
    }
    drop(s);
    out.extend_from_slice(b"]}");
    reply(StatusCode::OK, Bytes::from(out))
}

fn one(store: &Shared, id_text: &str, remove: bool) -> Response {
    let id = digits(id_text);
    if id < 1 {
        return problem(422, "Unprocessable Content", "id must be a positive integer");
    }
    let id = id as usize;
    let mut s = store.lock().unwrap();
    let mut row: Option<Bytes> = None;
    if id <= s.rows.len() {
        row = s.rows[id - 1].clone();
        if remove && row.is_some() {
            s.rows[id - 1] = None;
            s.live -= 1;
        }
    }
    drop(s);
    match row {
        None => problem(404, "Not Found", "no such user"),
        Some(_) if remove => StatusCode::NO_CONTENT.into_response(),
        Some(r) => reply(StatusCode::OK, r),
    }
}

async fn get_one(State(store): State<Shared>, Path(id): Path<String>) -> Response {
    one(&store, &id, false)
}

async fn delete_one(State(store): State<Shared>, Path(id): Path<String>) -> Response {
    one(&store, &id, true)
}

async fn health() -> Response {
    reply(StatusCode::OK, Bytes::from_static(b"{\"ok\":true}"))
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let port = std::env::args().nth(1).unwrap_or_else(|| "8000".to_string());
    let store: Shared = Arc::new(Mutex::new(Store::default()));
    let app = Router::new()
        .route("/health", get(health))
        .route("/users", get(list).post(create))
        .route("/users/{id}", get(get_one).delete(delete_one))
        .layer(DefaultBodyLimit::max(MAX_BODY))
        .with_state(store);
    let listener = tokio::net::TcpListener::bind(format!("127.0.0.1:{port}")).await.unwrap();
    let listener = listener.tap_io(|tcp| {
        let _ = tcp.set_nodelay(true);
    });
    axum::serve(listener, app).await.unwrap();
}
