//! fm-dashboard-server - read-only live fleet dashboard HTTP server.
//!
//! Built by `bin/fm-dashboard.sh` via `cargo build --release` when the binary
//! is absent. Stdlib + tiny_http + serde_json only (no async framework).
//!
//! Environment (set by fm-dashboard.sh):
//!   FM_HOME, FM_ROOT_OVERRIDE
//!   FM_DASHBOARD_BIND_HOST, FM_DASHBOARD_BIND_PORT
//!   FM_DASHBOARD_TOKEN
//!   FM_DASHBOARD_STATIC
//!   FM_DASHBOARD_SNAPSHOT  path to fm-fleet-snapshot.sh
//!   FM_STATE_OVERRIDE, FM_DATA_OVERRIDE, FM_CONFIG_OVERRIDE  (tests)

use serde_json::{json, Map, Value};
use std::collections::HashSet;
use std::env;
use std::fs;
use std::io::Read;
use std::net::SocketAddr;
use std::path::{Component, Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tiny_http::{Header, Method, Request, Response, Server, StatusCode};

const SCHEMA_SNAPSHOT: &str = "fm-dashboard-snapshot.v1";
const CACHE_TTL: Duration = Duration::from_secs(4);
const COOKIE_NAME: &str = "fm_dash";

fn main() {
    if let Err(err) = run() {
        eprintln!("fm-dashboard-server: {err}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let cfg = Config::from_env()?;
    assert_bind_host(&cfg.bind_host)?;

    fs::create_dir_all(&cfg.dashboard_state)
        .map_err(|e| format!("cannot create {}: {e}", cfg.dashboard_state.display()))?;

    let addr: SocketAddr = format!("{}:{}", cfg.bind_host, cfg.bind_port)
        .parse()
        .map_err(|e| format!("bad bind address: {e}"))?;

    if addr.ip().is_unspecified() {
        return Err(format!("refusing wildcard bind host {}", cfg.bind_host));
    }

    let server = Server::http(addr).map_err(|e| format!("bind failed on {addr}: {e}"))?;
    eprintln!(
        "fm-dashboard-server: listening on http://{} home={}",
        addr,
        cfg.fm_home.display()
    );

    let state = Arc::new(AppState {
        cfg,
        started: Instant::now(),
        cache: Mutex::new(SnapshotCache::default()),
    });

    for request in server.incoming_requests() {
        if let Err(err) = handle_request(&state, request) {
            eprintln!("fm-dashboard-server: request error: {err}");
        }
    }
    Ok(())
}

struct Config {
    fm_home: PathBuf,
    state: PathBuf,
    data: PathBuf,
    static_dir: PathBuf,
    snapshot_tool: PathBuf,
    dashboard_state: PathBuf,
    bind_host: String,
    bind_port: u16,
    token: String,
}

impl Config {
    fn from_env() -> Result<Self, String> {
        let fm_home = PathBuf::from(env_or("FM_HOME", "."));
        let state = env::var("FM_STATE_OVERRIDE")
            .map(PathBuf::from)
            .unwrap_or_else(|_| fm_home.join("state"));
        let data = env::var("FM_DATA_OVERRIDE")
            .map(PathBuf::from)
            .unwrap_or_else(|_| fm_home.join("data"));
        let fm_root = env::var("FM_ROOT_OVERRIDE")
            .map(PathBuf::from)
            .unwrap_or_else(|_| fm_home.clone());
        let static_dir = env::var("FM_DASHBOARD_STATIC")
            .map(PathBuf::from)
            .unwrap_or_else(|_| fm_root.join("bin").join("fm-dashboard-static"));
        let snapshot_tool = env::var("FM_DASHBOARD_SNAPSHOT")
            .map(PathBuf::from)
            .unwrap_or_else(|_| fm_root.join("bin").join("fm-fleet-snapshot.sh"));
        let bind_host = env_or("FM_DASHBOARD_BIND_HOST", "");
        if bind_host.is_empty() {
            return Err("FM_DASHBOARD_BIND_HOST is required".into());
        }
        let bind_port: u16 = env_or("FM_DASHBOARD_BIND_PORT", "8391")
            .parse()
            .map_err(|_| format!("bad port {:?}", env::var("FM_DASHBOARD_BIND_PORT")))?;
        let token = env_or("FM_DASHBOARD_TOKEN", "");
        if token.is_empty() {
            return Err("FM_DASHBOARD_TOKEN is required".into());
        }
        if !static_dir.is_dir() {
            return Err(format!("static dir missing: {}", static_dir.display()));
        }
        let dashboard_state = state.join("dashboard");
        Ok(Self {
            fm_home: fm_home.canonicalize().unwrap_or(fm_home),
            state: state.canonicalize().unwrap_or(state),
            data: data.canonicalize().unwrap_or(data),
            static_dir: static_dir.canonicalize().unwrap_or(static_dir),
            snapshot_tool,
            dashboard_state,
            bind_host,
            bind_port,
            token,
        })
    }
}

fn env_or(key: &str, default: &str) -> String {
    env::var(key).unwrap_or_else(|_| default.to_string())
}

fn assert_bind_host(host: &str) -> Result<(), String> {
    let h = host.trim();
    match h {
        "" | "0.0.0.0" | "::" | "[::]" | "*" | "[::0]" | "::0" => {
            Err(format!("refusing wildcard bind host {h:?}"))
        }
        _ if h.starts_with("0.0.0.0") => Err(format!("refusing wildcard bind host {h:?}")),
        _ => Ok(()),
    }
}

struct AppState {
    cfg: Config,
    started: Instant,
    cache: Mutex<SnapshotCache>,
}

#[derive(Default)]
struct SnapshotCache {
    body: Option<Vec<u8>>,
    fetched_at: Option<Instant>,
}

impl SnapshotCache {
    fn get_or_build<F>(&mut self, builder: F) -> Result<Vec<u8>, String>
    where
        F: FnOnce() -> Result<Value, String>,
    {
        if let (Some(body), Some(at)) = (&self.body, self.fetched_at) {
            if at.elapsed() < CACHE_TTL {
                return Ok(body.clone());
            }
        }
        let value = builder()?;
        let body = serde_json::to_vec(&value).map_err(|e| format!("json encode: {e}"))?;
        self.body = Some(body.clone());
        self.fetched_at = Some(Instant::now());
        Ok(body)
    }
}

fn handle_request(state: &AppState, request: Request) -> Result<(), String> {
    let method = request.method().clone();
    let url = request.url().to_string();
    let (path, _query) = split_url(&url);
    let head = method == Method::Head;

    match (&method, path.as_str()) {
        (Method::Get | Method::Head, "/healthz") => {
            let body = json!({
                "ok": true,
                "uptime_s": state.started.elapsed().as_secs()
            });
            send_json(request, StatusCode(200), &body, head)
        }
        (Method::Get | Method::Head, "/unlock") => {
            send_html(request, StatusCode(200), UNLOCK_HTML.as_bytes(), head)
        }
        (Method::Post, "/unlock") => handle_unlock(state, request),
        (Method::Get | Method::Head, "/") | (Method::Get | Method::Head, "/index.html") => {
            if !authorized(state, &request) {
                return send_html(request, StatusCode(401), UNLOCK_HTML.as_bytes(), head);
            }
            serve_static(state, request, "index.html", head)
        }
        (Method::Get | Method::Head, "/api/v1/snapshot") => {
            if !authorized(state, &request) {
                return send_json(
                    request,
                    StatusCode(401),
                    &json!({"ok": false, "error": "unauthorized"}),
                    head,
                );
            }
            let body = {
                let mut cache = state
                    .cache
                    .lock()
                    .map_err(|_| "cache lock poisoned".to_string())?;
                cache.get_or_build(|| build_snapshot(state))
            };
            match body {
                Ok(bytes) => send_bytes(
                    request,
                    StatusCode(200),
                    "application/json; charset=utf-8",
                    bytes,
                    head,
                ),
                Err(err) => send_json(
                    request,
                    StatusCode(500),
                    &json!({"ok": false, "error": "snapshot failed", "detail": err}),
                    head,
                ),
            }
        }
        (Method::Get | Method::Head, p) if p == "/app.js" || p == "/app.css" => {
            if !authorized(state, &request) {
                return send_json(
                    request,
                    StatusCode(401),
                    &json!({"ok": false, "error": "unauthorized"}),
                    head,
                );
            }
            serve_static(state, request, p.trim_start_matches('/'), head)
        }
        (Method::Get | Method::Head, p) if p.starts_with("/static/") => {
            if !authorized(state, &request) {
                return send_json(
                    request,
                    StatusCode(401),
                    &json!({"ok": false, "error": "unauthorized"}),
                    head,
                );
            }
            serve_static(state, request, &p["/static/".len()..], head)
        }
        _ => send_json(
            request,
            StatusCode(404),
            &json!({"ok": false, "error": "not found"}),
            false,
        ),
    }
}

fn split_url(url: &str) -> (String, String) {
    match url.split_once('?') {
        Some((p, q)) => (p.to_string(), q.to_string()),
        None => (url.to_string(), String::new()),
    }
}

fn authorized(state: &AppState, request: &Request) -> bool {
    let expected = state.cfg.token.as_str();
    if let Some(auth) = header_value(request, "Authorization") {
        let rest = auth
            .strip_prefix("Bearer ")
            .or_else(|| auth.strip_prefix("bearer "))
            .unwrap_or("");
        if constant_time_eq(rest.trim(), expected) {
            return true;
        }
    }
    if let Some(cookie) = header_value(request, "Cookie") {
        for part in cookie.split(';') {
            let part = part.trim();
            if let Some(val) = part.strip_prefix(&format!("{COOKIE_NAME}=")) {
                if constant_time_eq(val, expected) {
                    return true;
                }
            }
        }
    }
    false
}

fn header_value(request: &Request, name: &str) -> Option<String> {
    let want = name.to_ascii_lowercase();
    request.headers().iter().find_map(|h| {
        let field = h.field.as_str().to_ascii_lowercase();
        if field == want {
            Some(h.value.as_str().to_string())
        } else {
            None
        }
    })
}

fn constant_time_eq(a: &str, b: &str) -> bool {
    let ab = a.as_bytes();
    let bb = b.as_bytes();
    if ab.len() != bb.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in ab.iter().zip(bb.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

fn handle_unlock(state: &AppState, mut request: Request) -> Result<(), String> {
    let mut body = Vec::new();
    request
        .as_reader()
        .take(8192)
        .read_to_end(&mut body)
        .map_err(|e| format!("read body: {e}"))?;
    let ctype = header_value(&request, "Content-Type").unwrap_or_default();
    let token = if ctype.contains("application/json") {
        let v: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
        v.get("token")
            .and_then(|t| t.as_str())
            .unwrap_or("")
            .trim()
            .to_string()
    } else {
        let s = String::from_utf8_lossy(&body);
        form_value(&s, "token").unwrap_or_default()
    };

    if token.is_empty() || !constant_time_eq(&token, &state.cfg.token) {
        if ctype.contains("application/json") {
            return send_json(
                request,
                StatusCode(401),
                &json!({"ok": false, "error": "unauthorized"}),
                false,
            );
        }
        return send_redirect(request, "/unlock?e=1", None);
    }

    let cookie = format!(
        "{COOKIE_NAME}={}; Path=/; Max-Age=15552000; HttpOnly; SameSite=Strict",
        state.cfg.token
    );
    if ctype.contains("application/json") {
        send_json_with_cookie(request, StatusCode(200), &json!({"ok": true}), &cookie)
    } else {
        send_redirect(request, "/", Some(cookie.as_str()))
    }
}

fn form_value(body: &str, key: &str) -> Option<String> {
    for pair in body.split('&') {
        let mut it = pair.splitn(2, '=');
        let k = it.next()?;
        let v = it.next().unwrap_or("");
        if k == key {
            return Some(urlencoding_decode(v));
        }
    }
    None
}

fn urlencoding_decode(s: &str) -> String {
    let mut out = Vec::new();
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b'%' if i + 2 < bytes.len() => {
                let hex = &s[i + 1..i + 3];
                if let Ok(b) = u8::from_str_radix(hex, 16) {
                    out.push(b);
                    i += 3;
                } else {
                    out.push(bytes[i]);
                    i += 1;
                }
            }
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn serve_static(
    state: &AppState,
    request: Request,
    rel: &str,
    head: bool,
) -> Result<(), String> {
    let rel = rel.trim_start_matches('/');
    if rel.is_empty() {
        return send_json(
            request,
            StatusCode(404),
            &json!({"ok": false, "error": "not found"}),
            head,
        );
    }
    for c in Path::new(rel).components() {
        if !matches!(c, Component::Normal(_)) {
            return send_json(
                request,
                StatusCode(404),
                &json!({"ok": false, "error": "not found"}),
                head,
            );
        }
    }
    let candidate = state.cfg.static_dir.join(rel);
    let resolved = match candidate.canonicalize() {
        Ok(p) => p,
        Err(_) => {
            return send_json(
                request,
                StatusCode(404),
                &json!({"ok": false, "error": "not found"}),
                head,
            );
        }
    };
    if !resolved.starts_with(&state.cfg.static_dir) || !resolved.is_file() {
        return send_json(
            request,
            StatusCode(404),
            &json!({"ok": false, "error": "not found"}),
            head,
        );
    }
    let body = fs::read(&resolved).map_err(|e| format!("read static: {e}"))?;
    let ctype = match resolved.extension().and_then(|e| e.to_str()) {
        Some("html") => "text/html; charset=utf-8",
        Some("js") => "application/javascript; charset=utf-8",
        Some("css") => "text/css; charset=utf-8",
        Some("svg") => "image/svg+xml",
        _ => "application/octet-stream",
    };
    send_bytes(request, StatusCode(200), ctype, body, head)
}

fn send_json(
    request: Request,
    status: StatusCode,
    value: &Value,
    head: bool,
) -> Result<(), String> {
    let body = serde_json::to_vec(value).map_err(|e| format!("json: {e}"))?;
    send_bytes(
        request,
        status,
        "application/json; charset=utf-8",
        body,
        head,
    )
}

fn send_json_with_cookie(
    request: Request,
    status: StatusCode,
    value: &Value,
    cookie: &str,
) -> Result<(), String> {
    let body = serde_json::to_vec(value).map_err(|e| format!("json: {e}"))?;
    let mut response = if true {
        Response::from_data(body)
    } else {
        unreachable!()
    }
    .with_status_code(status);
    add_std_headers(&mut response, "application/json; charset=utf-8")?;
    response.add_header(header("Set-Cookie", cookie)?);
    request
        .respond(response)
        .map_err(|e| format!("respond: {e}"))
}

fn send_html(
    request: Request,
    status: StatusCode,
    body: &[u8],
    head: bool,
) -> Result<(), String> {
    send_bytes(
        request,
        status,
        "text/html; charset=utf-8",
        body.to_vec(),
        head,
    )
}

fn send_bytes(
    request: Request,
    status: StatusCode,
    content_type: &str,
    body: Vec<u8>,
    head: bool,
) -> Result<(), String> {
    if head {
        let response = Response::empty(status)
            .with_header(header("Content-Type", content_type)?)
            .with_header(header("Cache-Control", "no-store")?)
            .with_header(header("X-Content-Type-Options", "nosniff")?)
            .with_header(header("Content-Length", &body.len().to_string())?);
        return request
            .respond(response)
            .map_err(|e| format!("respond: {e}"));
    }
    let mut response = Response::from_data(body).with_status_code(status);
    add_std_headers(&mut response, content_type)?;
    request
        .respond(response)
        .map_err(|e| format!("respond: {e}"))
}

fn send_redirect(
    request: Request,
    location: &str,
    cookie: Option<&str>,
) -> Result<(), String> {
    let mut response = Response::empty(StatusCode(303))
        .with_header(header("Location", location)?)
        .with_header(header("Cache-Control", "no-store")?)
        .with_header(header("Content-Length", "0")?);
    if let Some(c) = cookie {
        response.add_header(header("Set-Cookie", c)?);
    }
    request
        .respond(response)
        .map_err(|e| format!("respond: {e}"))
}

fn add_std_headers<R: Read>(
    response: &mut Response<R>,
    content_type: &str,
) -> Result<(), String> {
    response.add_header(header("Content-Type", content_type)?);
    response.add_header(header("Cache-Control", "no-store")?);
    response.add_header(header("X-Content-Type-Options", "nosniff")?);
    Ok(())
}

fn header(name: &str, value: &str) -> Result<Header, String> {
    Header::from_bytes(name.as_bytes(), value.as_bytes()).map_err(|_| "bad header".to_string())
}

// --- Snapshot ---------------------------------------------------------------

fn utc_now() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let (y, mo, d, h, mi, s) = civil_from_days(secs);
    format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z")
}

fn civil_from_days(secs: u64) -> (i32, u32, u32, u32, u32, u32) {
    let days = (secs / 86400) as i64;
    let rem = (secs % 86400) as u32;
    let h = rem / 3600;
    let mi = (rem % 3600) / 60;
    let s = rem % 60;
    let z = days + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = (z - era * 146097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    (y as i32, m as u32, d as u32, h, mi, s)
}

fn build_snapshot(state: &AppState) -> Result<Value, String> {
    let generated = utc_now();
    let mut sources: Vec<Value> = Vec::new();
    let (fleet, primary_ok) = load_fleet(state, &generated, &mut sources);

    if !primary_ok {
        sources.push(json!({
            "id": "fleet-compose-fallback",
            "fetched_at": generated,
            "ok": true,
            "age_s": 0,
            "stale": false,
            "note": "composed from state/data after snapshot tool failure"
        }));
    }

    for (id, note) in [
        ("quota", "wired in wave 2"),
        ("prs", "wired in wave 2"),
        ("trains", "wired in wave 2"),
        ("production", "wired in wave 2"),
        ("events", "wired in wave 2"),
    ] {
        sources.push(json!({
            "id": id,
            "fetched_at": generated,
            "ok": false,
            "age_s": 0,
            "stale": false,
            "deferred": true,
            "note": note
        }));
    }

    let decisions = extract_decisions(&fleet);
    Ok(json!({
        "schema": SCHEMA_SNAPSHOT,
        "generated": generated,
        "fm_home": state.cfg.fm_home.display().to_string(),
        "server": {
            "uptime_s": state.started.elapsed().as_secs(),
            "bind_host": state.cfg.bind_host,
            "bind_port": state.cfg.bind_port
        },
        "sources": sources,
        "fleet": fleet,
        "decisions": decisions,
        "events": Value::Null,
        "open_prs": Value::Null,
        "trains": Value::Null,
        "quota": Value::Null,
        "production": Value::Null,
        "wave": {
            "id": 1,
            "scopes": ["D1", "D2", "D4"],
            "deferred": ["D3", "D5", "D6", "D7", "D8", "D9", "D10"]
        }
    }))
}

fn load_fleet(state: &AppState, generated: &str, sources: &mut Vec<Value>) -> (Value, bool) {
    let tool = &state.cfg.snapshot_tool;
    let mut src = json!({
        "id": "fleet-snapshot",
        "command": tool.display().to_string(),
        "fetched_at": generated,
        "ok": false,
        "age_s": 0,
        "stale": false
    });

    if tool.is_file() {
        let t0 = Instant::now();
        let output = Command::new(tool)
            .arg("--json")
            .current_dir(&state.cfg.fm_home)
            .env("FM_HOME", &state.cfg.fm_home)
            .output();
        let duration_ms = t0.elapsed().as_millis() as u64;
        src.as_object_mut()
            .unwrap()
            .insert("duration_ms".into(), json!(duration_ms));
        match output {
            Ok(out) => {
                let code = out.status.code().unwrap_or(1);
                src.as_object_mut()
                    .unwrap()
                    .insert("exit_code".into(), json!(code));
                if out.status.success() {
                    match serde_json::from_slice::<Value>(&out.stdout) {
                        Ok(v) => {
                            src.as_object_mut().unwrap().insert("ok".into(), json!(true));
                            sources.push(src);
                            return (v, true);
                        }
                        Err(e) => {
                            src.as_object_mut()
                                .unwrap()
                                .insert("error".into(), json!(format!("json decode: {e}")));
                            let stderr = String::from_utf8_lossy(&out.stderr);
                            src.as_object_mut()
                                .unwrap()
                                .insert("stderr_tail".into(), json!(tail_str(&stderr, 400)));
                        }
                    }
                } else {
                    src.as_object_mut()
                        .unwrap()
                        .insert("error".into(), json!(format!("exit {code}")));
                    let stderr = String::from_utf8_lossy(&out.stderr);
                    src.as_object_mut()
                        .unwrap()
                        .insert("stderr_tail".into(), json!(tail_str(&stderr, 400)));
                }
            }
            Err(e) => {
                src.as_object_mut()
                    .unwrap()
                    .insert("error".into(), json!(e.to_string()));
            }
        }
    } else {
        src.as_object_mut().unwrap().insert(
            "error".into(),
            json!("fm-fleet-snapshot.sh missing or not executable"),
        );
    }
    sources.push(src);
    (compose_minimal(state, generated, sources), false)
}

fn tail_str(s: &str, n: usize) -> String {
    let chars: Vec<char> = s.chars().collect();
    if chars.len() <= n {
        s.to_string()
    } else {
        chars[chars.len() - n..].iter().collect()
    }
}

fn compose_minimal(state: &AppState, generated: &str, sources: &mut Vec<Value>) -> Value {
    let mut tasks = Vec::new();
    if let Ok(rd) = fs::read_dir(&state.cfg.state) {
        let mut metas: Vec<PathBuf> = rd
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .filter(|p| p.extension().and_then(|e| e.to_str()) == Some("meta"))
            .collect();
        metas.sort();
        for meta in metas {
            let id = meta
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("")
                .to_string();
            if id.is_empty() {
                continue;
            }
            let text = fs::read_to_string(&meta).unwrap_or_default();
            let mut fields = Map::new();
            for line in text.lines() {
                if let Some((k, v)) = line.split_once('=') {
                    fields.insert(k.trim().to_string(), Value::String(v.trim().to_string()));
                }
            }
            let status_path = state.cfg.state.join(format!("{id}.status"));
            let last_event = if status_path.is_file() {
                fs::read_to_string(&status_path)
                    .ok()
                    .and_then(|s| {
                        s.lines()
                            .rev()
                            .find(|l| !l.is_empty())
                            .map(|l| l.to_string())
                    })
                    .unwrap_or_default()
            } else {
                String::new()
            };
            let report_path = state.cfg.data.join(&id).join("report.md");
            let report_present = report_path.is_file();
            tasks.push(json!({
                "id": id,
                "kind": fields.get("kind").and_then(|v| v.as_str()).unwrap_or(""),
                "harness": fields.get("harness").and_then(|v| v.as_str()).unwrap_or(""),
                "backend": fields.get("backend").and_then(|v| v.as_str()).unwrap_or(""),
                "project": fields.get("project").and_then(|v| v.as_str()).unwrap_or(""),
                "pr": {"url": fields.get("pr").cloned().unwrap_or(Value::Null)},
                "current_state": {
                    "state": "unknown",
                    "source": "compose-fallback",
                    "detail": last_event,
                    "raw": last_event,
                    "observed_at": generated,
                    "freshness": "unknown"
                },
                "hints": {
                    "last_event_text": last_event,
                    "pending_decision": last_event.contains("needs-decision"),
                    "blocked_event": last_event.starts_with("blocked:"),
                    "open_decisions": [],
                    "scout_report_present": report_present
                },
                "paths": {
                    "status_log": {
                        "path": status_path.display().to_string(),
                        "last_event": last_event
                    },
                    "report": {
                        "path": report_path.display().to_string(),
                        "present": report_present
                    }
                }
            }));
        }
    }

    let mut backlog_records = Value::Array(vec![]);
    let t0 = Instant::now();
    let mut src = json!({
        "id": "tasks-axi",
        "fetched_at": generated,
        "ok": false,
        "age_s": 0,
        "stale": false
    });
    match Command::new("tasks-axi")
        .args(["list", "--json"])
        .current_dir(&state.cfg.fm_home)
        .env("FM_HOME", &state.cfg.fm_home)
        .output()
    {
        Ok(out) => {
            let code = out.status.code().unwrap_or(1);
            src.as_object_mut()
                .unwrap()
                .insert("duration_ms".into(), json!(t0.elapsed().as_millis() as u64));
            src.as_object_mut()
                .unwrap()
                .insert("exit_code".into(), json!(code));
            if out.status.success() {
                if let Ok(parsed) = serde_json::from_slice::<Value>(&out.stdout) {
                    if parsed.is_array() {
                        backlog_records = parsed;
                        src.as_object_mut().unwrap().insert("ok".into(), json!(true));
                    } else if let Some(recs) = parsed.get("records").cloned() {
                        backlog_records = recs;
                        src.as_object_mut().unwrap().insert("ok".into(), json!(true));
                    } else if let Some(tasks_v) = parsed.get("tasks").cloned() {
                        backlog_records = tasks_v;
                        src.as_object_mut().unwrap().insert("ok".into(), json!(true));
                    }
                }
            } else {
                let stderr = String::from_utf8_lossy(&out.stderr);
                src.as_object_mut()
                    .unwrap()
                    .insert("error".into(), json!(tail_str(&stderr, 400)));
            }
        }
        Err(e) => {
            src.as_object_mut()
                .unwrap()
                .insert("error".into(), json!(e.to_string()));
            src.as_object_mut()
                .unwrap()
                .insert("duration_ms".into(), json!(t0.elapsed().as_millis() as u64));
        }
    }
    sources.push(src);

    let mut scout_reports = Vec::new();
    if let Ok(rd) = fs::read_dir(&state.cfg.data) {
        let mut paths: Vec<PathBuf> = rd
            .filter_map(|e| e.ok())
            .map(|e| e.path().join("report.md"))
            .filter(|p| p.is_file())
            .collect();
        paths.sort();
        for report in paths {
            let id = report
                .parent()
                .and_then(|p| p.file_name())
                .and_then(|s| s.to_str())
                .unwrap_or("")
                .to_string();
            scout_reports.push(json!({
                "id": id,
                "path": report.display().to_string(),
                "present": true
            }));
        }
    }

    json!({
        "schema": "fm-fleet-snapshot.v1",
        "generated": generated,
        "fm_home": state.cfg.fm_home.display().to_string(),
        "composed_fallback": true,
        "tasks": tasks,
        "backlog": {
            "path": state.cfg.data.join("backlog.md").display().to_string(),
            "present": state.cfg.data.join("backlog.md").is_file(),
            "records": backlog_records
        },
        "scout_reports": scout_reports
    })
}

fn extract_decisions(fleet: &Value) -> Value {
    let records = fleet
        .get("backlog")
        .and_then(|b| b.get("records"))
        .and_then(|r| r.as_array())
        .cloned()
        .unwrap_or_default();

    let mut decisions = Vec::new();
    let mut seen = HashSet::new();
    for rec in records {
        let key = rec
            .get("id")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .trim()
            .to_string();
        if key.is_empty() || !seen.insert(key.clone()) {
            continue;
        }
        let st = rec
            .get("state")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_lowercase();
        if st == "done" || st == "resolved" {
            continue;
        }
        let captain_actionable = rec
            .get("captain_actionable")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        let hold_kind = rec
            .get("hold_kind")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_lowercase();
        let kind = rec
            .get("kind")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_lowercase();
        if !captain_actionable && hold_kind != "captain" && kind != "captain" {
            continue;
        }
        let title = rec
            .get("title")
            .or_else(|| rec.get("raw"))
            .and_then(|v| v.as_str())
            .unwrap_or(&key)
            .to_string();
        let body = rec
            .get("hold_reason")
            .or_else(|| rec.get("blocked_reason"))
            .or_else(|| rec.get("notes"))
            .or_else(|| rec.get("detail"))
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        decisions.push(json!({
            "key": key,
            "title": title,
            "body": body,
            "hold_kind": rec.get("hold_kind").or_else(|| rec.get("kind")).cloned().unwrap_or(json!("")),
            "hold_reason": rec.get("hold_reason").cloned().unwrap_or(json!("")),
            "captain_actionable": captain_actionable,
            "state": rec.get("state").cloned().unwrap_or(json!("")),
            "recommendation": rec.get("recommendation").cloned().unwrap_or(json!("")),
            "options": rec.get("options").cloned().unwrap_or(json!([])),
            "actions_supported": ["answer", "dismiss", "snooze"],
            "origin": rec.get("repo").or_else(|| rec.get("origin_task")).cloned().unwrap_or(json!("")),
            "pr_url": rec.get("pr_url").cloned().unwrap_or(json!("")),
            "report_path": rec.get("report_path").cloned().unwrap_or(json!(""))
        }));
    }
    Value::Array(decisions)
}

const UNLOCK_HTML: &str = r#"<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Fleet dashboard - unlock</title>
<style>
  :root { color-scheme: dark light; }
  body { margin:0; font:15px/1.5 -apple-system,Segoe UI,Helvetica,sans-serif;
    background:#131A17; color:#E9E4D4; min-height:100vh; display:flex;
    align-items:center; justify-content:center; padding:24px; }
  @media (prefers-color-scheme: light) {
    body { background:#F7F3E9; color:#2A2A24; }
    .card { background:#fff; border-color:#D9D2C0; }
    input { background:#fff; color:#2A2A24; border-color:#C9C2AE; }
  }
  .card { width:min(420px,100%); background:#1B2420; border:1px solid #31403A;
    border-radius:12px; padding:22px 20px; }
  h1 { font:400 20px Georgia,serif; margin:0 0 8px; }
  p { margin:0 0 14px; color:#96A198; font-size:13.5px; }
  label { display:block; font:600 11px sans-serif; letter-spacing:.12em;
    text-transform:uppercase; color:#C9A24B; margin-bottom:6px; }
  input { width:100%; box-sizing:border-box; padding:10px 12px; border-radius:8px;
    border:1px solid #31403A; background:#131A17; color:#E9E4D4; font:13px ui-monospace,Menlo,monospace; }
  button { margin-top:12px; width:100%; padding:11px 14px; border:0; border-radius:8px;
    background:#C9A24B; color:#131A17; font:600 13px sans-serif; cursor:pointer; }
  .err { color:#C46A5A; font-size:13px; margin-top:10px; min-height:1.2em; }
</style>
</head>
<body>
  <form class="card" method="post" action="/unlock" id="f">
    <h1>Unlock live fleet</h1>
    <p>Paste the bearer token from <code>config/dashboard-token</code> on the host. It is stored as an HttpOnly cookie on this device.</p>
    <label for="token">Token</label>
    <input id="token" name="token" type="password" autocomplete="current-password" required>
    <button type="submit">Unlock</button>
    <div class="err" id="err"></div>
  </form>
  <script>
    const q = new URLSearchParams(location.search);
    if (q.get('e') === '1') document.getElementById('err').textContent = 'Invalid token.';
  </script>
</body>
</html>
"#;
