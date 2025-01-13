use std::fmt;

use axum::{
    body::Body,
    http::{Request, StatusCode},
    middleware::Next,
    response::IntoResponse,
};
use clap::ValueEnum;
use serde::{Deserialize, Serialize};
use tokio::time::Instant;
use tracing_subscriber::{
    fmt::{format::FmtSpan, time::ChronoLocal},
    EnvFilter,
};

use crate::config::AppConfig;

#[derive(Clone, ValueEnum, Debug, Serialize, Deserialize, Copy)]
pub enum LogLevel {
    Error,
    Warn,
    Info,
    Debug,
    Trace,
}
impl fmt::Display for LogLevel {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let s = match self {
            LogLevel::Error => "error",
            LogLevel::Warn => "warn",
            LogLevel::Info => "info",
            LogLevel::Debug => "debug",
            LogLevel::Trace => "trace",
        };
        write!(f, "{}", s)
    }
}

pub fn init_logging(cli_log_level: Option<LogLevel>, config_log_level: Option<LogLevel>) {
    let log_level =
        cli_log_level.unwrap_or(config_log_level.unwrap_or(AppConfig::default().log_level));
    let timer = ChronoLocal::new("%Y-%m-%d %H:%M:%S%.3f".to_string());
    tracing_subscriber::fmt()
        .with_timer(timer)
        .with_env_filter(EnvFilter::new(format!("neli=warn,{}", log_level)))
        .with_span_events(FmtSpan::ACTIVE)
        .init();
}

pub async fn log_request_response(
    req: Request<Body>,
    next: Next,
) -> Result<impl IntoResponse, (StatusCode, String)> {
    let path = &req.uri().path().to_string();

    let method = req.method().to_string();
    // Start the timer to measure latency
    let start_time = Instant::now();

    // Pass the request to the next middleware or handler
    let res = next.run(req).await;

    let id = res
        .headers()
        .get("x-request-id")
        .into_iter()
        .flat_map(|x| x.to_str())
        .collect::<String>();
    // Measure the elapsed time
    let latency = start_time.elapsed();
    let status = res.status();
    tracing::debug!(
        id = %id,
        method = %method,
        path = %path,
        latency = ?latency,
        status = status.as_u16(),
        "request handled"
    );
    Ok(res)
}
