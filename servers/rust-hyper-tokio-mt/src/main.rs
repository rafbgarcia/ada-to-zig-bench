use std::convert::Infallible;
use std::env;
use std::fs::{File, OpenOptions};
use std::io::{self, Write};
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use bytes::Bytes;
use http_body_util::{BodyExt, Full};
use hyper::body::Incoming;
use hyper::header::{CONNECTION, CONTENT_LENGTH, CONTENT_TYPE};
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper::{Method, Request, Response, StatusCode};
use hyper_util::rt::TokioIo;
use serde::{Deserialize, Serialize};
use serde_json::json;
use tokio::net::TcpListener;
use tokio::signal;
use tokio::time;

const MAX_BODY_BYTES: usize = 1 << 20;
const RUNTIME_NAME: &str = "rust-hyper-tokio-mt";

#[tokio::main(flavor = "multi_thread")]
async fn main() -> io::Result<()> {
    run().await
}

async fn run() -> io::Result<()> {
    let host = env::var("HOST").unwrap_or_else(|_| "127.0.0.1".to_string());
    let ports = parse_ports(
        &env::var("PORTS")
            .or_else(|_| env::var("PORT"))
            .unwrap_or_else(|_| "8080".to_string()),
    )?;
    let metrics = Arc::new(Metrics::new());
    let files = Arc::new(OutputFiles::from_env()?);

    if files.activity_metrics.is_some() {
        let metrics = Arc::clone(&metrics);
        let files = Arc::clone(&files);
        tokio::spawn(async move {
            write_activity_metric(&files, &metrics);
            let mut interval = time::interval(Duration::from_secs(1));
            loop {
                interval.tick().await;
                write_activity_metric(&files, &metrics);
            }
        });
    }

    if files.runtime_metrics.is_some() {
        let metrics = Arc::clone(&metrics);
        let files = Arc::clone(&files);
        tokio::spawn(async move {
            write_runtime_metric(&files, &metrics);
            let mut interval = time::interval(Duration::from_secs(1));
            loop {
                interval.tick().await;
                write_runtime_metric(&files, &metrics);
            }
        });
    }

    if let Some(file) = &files.runtime_events {
        let _ = file.lock().unwrap().write_all(b"");
    }

    for port in ports {
        let addr: SocketAddr = format!("{host}:{port}").parse().map_err(|error| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("invalid listen address: {error}"),
            )
        })?;
        let listener = TcpListener::bind(addr).await?;
        println!("rust hyper tokio multi-thread HTTP JSON server listening on http://{addr}");

        let metrics = Arc::clone(&metrics);
        let files = Arc::clone(&files);
        tokio::spawn(async move {
            loop {
                let (stream, _) = match listener.accept().await {
                    Ok(value) => value,
                    Err(error) => {
                        write_server_event(
                            &files,
                            &metrics,
                            "accept_error",
                            json!({ "reason": error.to_string() }),
                        );
                        continue;
                    }
                };

                metrics.accepted_connections.fetch_add(1, Ordering::Relaxed);
                metrics.active_connections.fetch_add(1, Ordering::Relaxed);
                let metrics_for_connection = Arc::clone(&metrics);
                let metrics_for_service = Arc::clone(&metrics);
                let files_for_service = Arc::clone(&files);

                tokio::spawn(async move {
                    let io = TokioIo::new(stream);
                    let service = service_fn(move |request| {
                        handle_request(
                            request,
                            Arc::clone(&metrics_for_service),
                            Arc::clone(&files_for_service),
                        )
                    });
                    if let Err(error) = http1::Builder::new()
                        .keep_alive(true)
                        .serve_connection(io, service)
                        .await
                    {
                        let _ = error;
                    }
                    metrics_for_connection
                        .active_connections
                        .fetch_sub(1, Ordering::Relaxed);
                    metrics_for_connection
                        .closed_connections
                        .fetch_add(1, Ordering::Relaxed);
                });
            }
        });
    }

    signal::ctrl_c().await?;
    Ok(())
}

async fn handle_request(
    request: Request<Incoming>,
    metrics: Arc<Metrics>,
    files: Arc<OutputFiles>,
) -> Result<Response<Full<Bytes>>, Infallible> {
    if request.uri().path() == "/health" {
        return Ok(json_response(
            StatusCode::OK,
            json!({
                "ok": true,
                "active_connections": metrics.active_connections.load(Ordering::Relaxed),
                "active_requests": metrics.active_requests.load(Ordering::Relaxed),
                "accepted_connections_total": metrics.accepted_connections.load(Ordering::Relaxed),
                "closed_connections_total": metrics.closed_connections.load(Ordering::Relaxed),
                "requests_started_total": metrics.requests_started.load(Ordering::Relaxed),
                "responses_completed_total": metrics.responses_completed.load(Ordering::Relaxed),
                "total_errors": metrics.request_errors.load(Ordering::Relaxed),
            }),
        ));
    }

    if request.uri().path() == "/runtime" {
        return Ok(json_response(StatusCode::OK, runtime_sample(&metrics)));
    }

    if request.uri().path() != "/json" || request.method() != Method::POST {
        return Ok(json_response(
            StatusCode::NOT_FOUND,
            json!({ "error": "not_found" }),
        ));
    }

    metrics.active_requests.fetch_add(1, Ordering::Relaxed);
    metrics.requests_started.fetch_add(1, Ordering::Relaxed);
    let response = match read_json_request(request).await {
        Ok(message) => {
            let response = ResponseMessage {
                id: message.id,
                len: message.payload.len(),
                checksum: checksum(message.payload.as_bytes()),
            };
            record_response(&metrics, StatusCode::OK);
            json_response(StatusCode::OK, response)
        }
        Err(reason) => {
            metrics.request_errors.fetch_add(1, Ordering::Relaxed);
            record_response(&metrics, StatusCode::BAD_REQUEST);
            write_server_event(
                &files,
                &metrics,
                "request_error",
                json!({ "reason": reason, "status_code": 400 }),
            );
            json_response(StatusCode::BAD_REQUEST, json!({ "error": reason }))
        }
    };
    metrics.active_requests.fetch_sub(1, Ordering::Relaxed);
    Ok(response)
}

async fn read_json_request(request: Request<Incoming>) -> Result<RequestMessage, &'static str> {
    let mut body = request.into_body();
    let mut bytes = Vec::new();
    while let Some(frame) = body.frame().await {
        let frame = frame.map_err(|_| "invalid_json")?;
        if let Some(chunk) = frame.data_ref() {
            if bytes.len() + chunk.len() > MAX_BODY_BYTES {
                return Err("body_too_large");
            }
            bytes.extend_from_slice(chunk);
        }
    }
    let value: serde_json::Value = serde_json::from_slice(&bytes).map_err(|_| "invalid_json")?;
    let Some(id) = value.get("id").and_then(|field| field.as_u64()) else {
        return Err("invalid_request");
    };
    let Some(payload) = value.get("payload").and_then(|field| field.as_str()) else {
        return Err("invalid_request");
    };
    Ok(RequestMessage {
        id,
        payload: payload.to_string(),
    })
}

fn json_response(status: StatusCode, value: impl Serialize) -> Response<Full<Bytes>> {
    let body = serde_json::to_vec(&value)
        .unwrap_or_else(|_| b"{\"error\":\"serialization_error\"}".to_vec());
    Response::builder()
        .status(status)
        .header(CONNECTION, "keep-alive")
        .header(CONTENT_TYPE, "application/json")
        .header(CONTENT_LENGTH, body.len().to_string())
        .body(Full::new(Bytes::from(body)))
        .unwrap()
}

fn record_response(metrics: &Metrics, status: StatusCode) {
    metrics.responses_completed.fetch_add(1, Ordering::Relaxed);
    if status.is_success() {
        metrics.responses_2xx.fetch_add(1, Ordering::Relaxed);
    } else if status.is_client_error() {
        metrics.responses_4xx.fetch_add(1, Ordering::Relaxed);
    } else if status.is_server_error() {
        metrics.responses_5xx.fetch_add(1, Ordering::Relaxed);
    }
}

fn checksum(payload: &[u8]) -> u32 {
    let mut value = 2166136261u32;
    for byte in payload {
        value ^= u32::from(*byte);
        value = value.wrapping_mul(16777619);
    }
    value
}

fn write_activity_metric(files: &OutputFiles, metrics: &Metrics) {
    let value = json!({
        "ts": now_iso(),
        "elapsed_seconds": metrics.elapsed_seconds(),
        "active_connections": metrics.active_connections.load(Ordering::Relaxed),
        "accepted_connections_total": metrics.accepted_connections.load(Ordering::Relaxed),
        "closed_connections_total": metrics.closed_connections.load(Ordering::Relaxed),
        "active_requests": metrics.active_requests.load(Ordering::Relaxed),
        "requests_started_total": metrics.requests_started.load(Ordering::Relaxed),
        "responses_completed_total": metrics.responses_completed.load(Ordering::Relaxed),
        "responses_2xx_total": metrics.responses_2xx.load(Ordering::Relaxed),
        "responses_4xx_total": metrics.responses_4xx.load(Ordering::Relaxed),
        "responses_5xx_total": metrics.responses_5xx.load(Ordering::Relaxed),
        "request_errors_total": metrics.request_errors.load(Ordering::Relaxed),
    });
    files.write_json_line(&files.activity_metrics, &value);
}

fn write_runtime_metric(files: &OutputFiles, metrics: &Metrics) {
    files.write_json_line(&files.runtime_metrics, &runtime_sample(metrics));
}

fn write_server_event(
    files: &OutputFiles,
    metrics: &Metrics,
    event: &str,
    fields: serde_json::Value,
) {
    if files.server_events.is_none() {
        return;
    }
    let mut value = json!({
        "ts": now_iso(),
        "elapsed_seconds": metrics.elapsed_seconds(),
        "event": event,
    });
    if let (Some(target), Some(source)) = (value.as_object_mut(), fields.as_object()) {
        for (key, item) in source {
            target.insert(key.clone(), item.clone());
        }
    }
    files.write_json_line(&files.server_events, &value);
}

fn runtime_sample(metrics: &Metrics) -> serde_json::Value {
    let rss_bytes = read_rss_bytes().unwrap_or(0);
    let heap_bytes = allocated_bytes();
    json!({
        "ts": now_iso(),
        "elapsed_seconds": metrics.elapsed_seconds(),
        "runtime": RUNTIME_NAME,
        "rss_bytes": rss_bytes,
        "heap_total_bytes": heap_bytes,
        "heap_used_bytes": heap_bytes,
    })
}

fn read_rss_bytes() -> Option<u64> {
    let statm = std::fs::read_to_string("/proc/self/statm").ok()?;
    let rss_pages = statm.split_whitespace().nth(1)?.parse::<u64>().ok()?;
    Some(rss_pages * page_size())
}

fn allocated_bytes() -> u64 {
    #[cfg(target_os = "linux")]
    unsafe {
        let info = libc::mallinfo2();
        info.uordblks as u64
    }
    #[cfg(not(target_os = "linux"))]
    {
        0
    }
}

fn page_size() -> u64 {
    #[cfg(unix)]
    unsafe {
        libc::sysconf(libc::_SC_PAGESIZE) as u64
    }
    #[cfg(not(unix))]
    {
        4096
    }
}

fn parse_ports(value: &str) -> io::Result<Vec<u16>> {
    let mut ports = Vec::new();
    for item in value.split(',') {
        let trimmed = item.trim();
        if trimmed.is_empty() {
            continue;
        }
        let port = trimmed.parse::<u16>().map_err(|_| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "PORTS must contain valid TCP ports",
            )
        })?;
        if !ports.contains(&port) {
            ports.push(port);
        }
    }
    if ports.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "PORTS must contain at least one TCP port",
        ));
    }
    Ok(ports)
}

fn now_iso() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}

#[derive(Deserialize)]
struct RequestMessage {
    id: u64,
    payload: String,
}

#[derive(Serialize)]
struct ResponseMessage {
    id: u64,
    len: usize,
    checksum: u32,
}

struct Metrics {
    started_at: Instant,
    active_connections: AtomicUsize,
    accepted_connections: AtomicU64,
    closed_connections: AtomicU64,
    active_requests: AtomicUsize,
    requests_started: AtomicU64,
    responses_completed: AtomicU64,
    request_errors: AtomicU64,
    responses_2xx: AtomicU64,
    responses_4xx: AtomicU64,
    responses_5xx: AtomicU64,
}

impl Metrics {
    fn new() -> Self {
        Self {
            started_at: Instant::now(),
            active_connections: AtomicUsize::new(0),
            accepted_connections: AtomicU64::new(0),
            closed_connections: AtomicU64::new(0),
            active_requests: AtomicUsize::new(0),
            requests_started: AtomicU64::new(0),
            responses_completed: AtomicU64::new(0),
            request_errors: AtomicU64::new(0),
            responses_2xx: AtomicU64::new(0),
            responses_4xx: AtomicU64::new(0),
            responses_5xx: AtomicU64::new(0),
        }
    }

    fn elapsed_seconds(&self) -> u64 {
        self.started_at.elapsed().as_secs()
    }
}

struct OutputFiles {
    activity_metrics: Option<Mutex<File>>,
    server_events: Option<Mutex<File>>,
    runtime_metrics: Option<Mutex<File>>,
    runtime_events: Option<Mutex<File>>,
}

impl OutputFiles {
    fn from_env() -> io::Result<Self> {
        Ok(Self {
            activity_metrics: open_optional("ACTIVITY_METRICS_PATH")?,
            server_events: open_optional("SERVER_EVENTS_PATH")?,
            runtime_metrics: open_optional("RUNTIME_METRICS_PATH")?,
            runtime_events: open_optional("RUNTIME_EVENTS_PATH")?,
        })
    }

    fn write_json_line(&self, target: &Option<Mutex<File>>, value: &serde_json::Value) {
        if let Some(file) = target {
            if let Ok(mut file) = file.lock() {
                let _ = serde_json::to_writer(&mut *file, value);
                let _ = file.write_all(b"\n");
            }
        }
    }
}

fn open_optional(name: &str) -> io::Result<Option<Mutex<File>>> {
    let Ok(path) = env::var(name) else {
        return Ok(None);
    };
    if path.trim().is_empty() {
        return Ok(None);
    }
    Ok(Some(Mutex::new(
        OpenOptions::new()
            .create(true)
            .append(true)
            .open(PathBuf::from(path))?,
    )))
}
