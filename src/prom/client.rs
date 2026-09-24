//! Thin blocking Prometheus HTTP API v1 client: instant and range queries.
use crate::config::REQUEST_TIMEOUT;
use chrono::{DateTime, Utc};
use serde_json::Value;
use std::{
    collections::BTreeMap,
    error::Error,
    fmt,
    sync::Arc,
    time::{Duration, Instant},
};

pub type Labels = BTreeMap<String, String>;
#[derive(Clone, Debug)]
pub struct PromSample {
    pub labels: Labels,
    pub value: f64,
    pub at: DateTime<Utc>,
}
impl PromSample {
    pub fn instance(&self) -> Option<&str> {
        self.labels.get("instance").map(String::as_str)
    }
}
#[derive(Clone, Debug)]
pub struct PromPoint {
    /// Unix seconds.
    pub t: f64,
    pub v: f64,
}
#[derive(Clone, Debug)]
pub struct PromSeries {
    pub labels: Labels,
    pub points: Vec<PromPoint>,
}
impl PromSeries {
    pub fn instance(&self) -> Option<&str> {
        self.labels.get("instance").map(String::as_str)
    }
    /// Best available human name for a legend entry.
    pub fn legend(&self) -> &str {
        ["label", "instance", "gpu"]
            .iter()
            .find_map(|k| self.labels.get(*k).map(String::as_str))
            .unwrap_or("?")
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PromError(pub String);
impl fmt::Display for PromError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}
impl Error for PromError {}

/// Injectable transport keeps polling independent of sockets and makes failures testable.
pub trait Transport: Send + Sync {
    fn get(&self, url: &str, params: &[(&str, String)]) -> Result<(u16, String), PromError>;
}
struct HttpTransport(ureq::Agent);
impl Transport for HttpTransport {
    fn get(&self, url: &str, params: &[(&str, String)]) -> Result<(u16, String), PromError> {
        let started = Instant::now();
        let mut req = self.0.get(url);
        for (k, v) in params {
            req = req.query(k, v);
        }
        let mut res = req.call().map_err(http_error)?;
        let status = res.status().as_u16();
        let body = res.body_mut().read_to_string().map_err(http_error)?;
        // Socket deadlines can be rounded by the OS. A response that arrives
        // after the budget is still a timeout, even if the read succeeded.
        if started.elapsed() >= REQUEST_TIMEOUT {
            return Err(PromError("timeout".into()));
        }
        Ok((status, body))
    }
}
fn http_error(e: ureq::Error) -> PromError {
    let mut s = e.to_string();
    let mut source = e.source();
    while let Some(e) = source {
        s.push_str(": ");
        s.push_str(&e.to_string());
        source = e.source();
    }
    PromError(short_error(&s))
}
/// Exception text trimmed to fit a one-line status bar.
pub fn short_error(s: &str) -> String {
    let lower = s.to_lowercase();
    for (needles, msg) in [
        (&["timeoutexception", "timed out", "timeout"][..], "timeout"),
        (&["connection refused"][..], "connection refused"),
        (&["no route to host"][..], "no route to host"),
        (&["network is unreachable"][..], "network unreachable"),
        (
            &[
                "failed host lookup",
                "dns",
                "failed to lookup address",
                "name or service not known",
            ][..],
            "dns lookup failed",
        ),
    ] {
        if needles.iter().any(|n| lower.contains(n)) {
            return msg.into();
        }
    }
    if s.chars().count() > 60 {
        format!("{}…", s.chars().take(60).collect::<String>())
    } else {
        s.into()
    }
}
#[derive(Clone)]
pub struct PromClient {
    pub base_url: String,
    transport: Arc<dyn Transport>,
}
impl PromClient {
    pub fn new(base_url: impl Into<String>) -> Self {
        let agent: ureq::Agent = ureq::Agent::config_builder()
            .timeout_global(Some(REQUEST_TIMEOUT))
            .http_status_as_error(false)
            .build()
            .into();
        Self::with_transport(base_url, Arc::new(HttpTransport(agent)))
    }
    pub fn with_transport(base_url: impl Into<String>, transport: Arc<dyn Transport>) -> Self {
        Self {
            base_url: base_url.into().trim_end_matches('/').into(),
            transport,
        }
    }
    fn get(&self, path: &str, params: &[(&str, String)]) -> Result<Value, PromError> {
        let (status, text) = self
            .transport
            .get(&format!("{}{path}", self.base_url), params)?;
        let parsed = serde_json::from_str::<Value>(&text);
        if status != 200 {
            // Prometheus puts useful messages in the body even on 4xx.
            return Err(PromError(
                parsed
                    .ok()
                    .and_then(|v| v["error"].as_str().map(str::to_owned))
                    .unwrap_or_else(|| format!("HTTP {status}")),
            ));
        }
        let body = parsed.map_err(|_| PromError("invalid JSON response".into()))?;
        if !body.is_object() {
            return Err(PromError("invalid Prometheus response".into()));
        }
        if body["status"] != "success" {
            return Err(PromError(
                body["error"]
                    .as_str()
                    .map(str::to_owned)
                    .unwrap_or_else(|| format!("query status={}", raw_string(&body["status"]))),
            ));
        }
        Ok(body)
    }
    pub fn instant(
        &self,
        query: &str,
        at: Option<DateTime<Utc>>,
    ) -> Result<Vec<PromSample>, PromError> {
        let mut params = vec![("query", query.into())];
        if let Some(at) = at {
            params.push(("time", unix(at)));
        }
        let body = self.get("/api/v1/query", &params)?;
        Ok(rows(&body)
            .iter()
            .filter_map(|row| {
                let (t, v) = point(&row["value"])?;
                Some(PromSample {
                    labels: labels(&row["metric"]),
                    value: v,
                    at: DateTime::from_timestamp_millis((t * 1000.0).round() as i64)?,
                })
            })
            .collect())
    }
    pub fn range(
        &self,
        query: &str,
        start: DateTime<Utc>,
        end: DateTime<Utc>,
        step: Duration,
    ) -> Result<Vec<PromSeries>, PromError> {
        let body = self.get(
            "/api/v1/query_range",
            &[
                ("query", query.into()),
                ("start", unix(start)),
                ("end", unix(end)),
                ("step", format!("{}s", step.as_secs())),
            ],
        )?;
        Ok(rows(&body)
            .iter()
            .filter_map(|row| {
                let points: Vec<_> = row["values"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|p| point(p).map(|(t, v)| PromPoint { t, v }))
                    .collect();
                if points.is_empty() {
                    None
                } else {
                    Some(PromSeries {
                        labels: labels(&row["metric"]),
                        points,
                    })
                }
            })
            .collect())
    }
}
fn unix(t: DateTime<Utc>) -> String {
    format!("{:.3}", t.timestamp_millis() as f64 / 1000.0)
}
fn rows(body: &Value) -> &[Value] {
    body["data"]["result"]
        .as_array()
        .map(Vec::as_slice)
        .unwrap_or_default()
}
fn raw_string(v: &Value) -> String {
    v.as_str()
        .map(str::to_owned)
        .unwrap_or_else(|| v.to_string())
}
fn labels(v: &Value) -> Labels {
    v.as_object()
        .into_iter()
        .flatten()
        .map(|(k, v)| (k.clone(), raw_string(v)))
        .collect()
}
/// Prometheus encodes values as strings, including NaN and +Inf. Neither is data.
fn point(p: &Value) -> Option<(f64, f64)> {
    let p = p.as_array()?;
    let t = p.first()?.as_f64()?;
    let v: f64 = raw_string(p.get(1)?).trim().parse().ok()?;
    v.is_finite().then_some((t, v))
}
