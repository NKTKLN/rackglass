#[allow(dead_code)]
mod fake_prometheus;
use chrono::{TimeDelta, Utc};
use fake_prometheus::{FakePrometheus, gpu, sample, up};
use rackglass::{
    Config, MetricsStore, PromClient,
    model::{GpuStat, NodeHealth, NodeStat},
    prom::{
        client::{PromError, Transport, short_error},
        queries as q,
    },
    store::Ring,
};
use serde_json::json;
use std::{
    collections::HashMap,
    sync::{
        Arc, Condvar, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
    time::{Duration, Instant},
};
fn poll(store: &MetricsStore) {
    store.refresh().expect("poll accepted").join().unwrap();
}
fn store(fake: &FakePrometheus) -> MetricsStore {
    MetricsStore::new(Config::default(), fake.client())
}

#[test]
fn snapshot_nodes_derived_fields_sort_and_health() {
    let fake = FakePrometheus::new(false);
    let store = store(&fake);
    poll(&store);
    let s = store.state();
    assert!(s.healthy);
    assert!(!s.stale);
    assert!(s.error.is_none());
    assert_eq!(s.endpoint, fake.url);
    let snap = s.snapshot.unwrap();
    assert_eq!(snap.nodes.len(), 6);
    assert_eq!(snap.nodes[0].instance, "pve-host");
    assert_eq!(
        snap.vms()
            .iter()
            .map(|n| n.instance.as_str())
            .collect::<Vec<_>>(),
        [
            "vm-amnezia-proxy",
            "vm-gpu-worker-1",
            "vm-node-1",
            "vm-ops-node",
            "vm-vpn"
        ]
    );
    let host = snap.host().unwrap();
    assert_eq!(host.cores, Some(12.0));
    assert_eq!(host.mem_used(), Some(15826522112.0));
    assert!((host.mem_pct().unwrap() - 47.1418).abs() < 0.001);
    assert_eq!(host.swap_pct(), Some(0.0));
    assert!((host.fs_pct().unwrap() - 37.3185).abs() < 0.001);
    assert_eq!(host.load_per_core(), Some(0.055));
    assert!(host.uptime().unwrap().num_seconds() >= 180000);
    assert_eq!(snap.health_of(host), NodeHealth::Ok);
    let down = snap.nodes.iter().find(|n| !n.up).unwrap();
    assert_eq!(down.cpu_pct, None);
    assert_eq!(snap.health_of(down), NodeHealth::Unknown);
    assert_eq!(snap.targets_down(), 1);
    assert!(snap.vm_mem_reported_total() > 13e9);
    assert!(snap.vm_mem_used() > 0.0);
}
#[test]
fn failed_polls_append_gaps_and_keep_last_snapshot() {
    let fake = FakePrometheus::new(false);
    let store = store(&fake);
    poll(&store);
    assert_eq!(
        fake.calls(),
        q::instant_poll_queries(&Config::default()).len()
            + q::gpu_fallback_queries(&Config::default()).len()
    );
    assert_eq!(store.state().gpu_temp_history.values(), [None]);
    let before = fake.calls();
    poll(&store);
    assert_eq!(
        fake.calls() - before,
        q::instant_poll_queries(&Config::default()).len()
    );
    assert!(store.state().snapshot.as_ref().unwrap().gpus[0].stale());
    let last = store.state().last_success;
    fake.data.lock().unwrap().fail = true;
    poll(&store);
    poll(&store);
    let s = store.state();
    assert_eq!(s.error.as_deref(), Some("HTTP 503"));
    assert!(!s.healthy);
    assert_eq!(s.last_success, last);
    assert_eq!(s.consecutive_errors, 2);
    assert_eq!(
        s.cpu_history("pve-host"),
        [Some(9.19), Some(9.19), None, None]
    );
    assert_eq!(s.mem_history("pve-host").last(), Some(&None));
    assert_eq!(s.host_temp_history.values().last(), Some(&None));
    assert!(s.snapshot.is_some());
    fake.data.lock().unwrap().fail = false;
    poll(&store);
    assert_eq!(store.state().consecutive_errors, 0);
    assert!(store.state().healthy);
}
#[test]
fn healthy_dcgm_never_scans_history() {
    let fake = FakePrometheus::new(true);
    let store = store(&fake);
    poll(&store);
    assert_eq!(
        fake.calls(),
        q::instant_poll_queries(&Config::default()).len()
    );
    let s = store.state();
    let g = &s.snapshot.as_ref().unwrap().gpus[0];
    assert!(!g.stale());
    assert_eq!(g.util, Some(73.0));
    assert_eq!(g.model_short(), "V100-SXM2-16GB");
    assert_eq!(g.fb_used_bytes(), Some(9216.0 * 1048576.0));
    assert_eq!(g.age(), Some(TimeDelta::seconds(12)));
    assert_eq!(s.gpu_temp_history.values(), [Some(40.0)]);
    assert_eq!(s.gpu_util_history.values(), [Some(73.0)]);
}
#[test]
fn unnamed_temperatures_sort_and_do_not_guess_package() {
    let fake = FakePrometheus::new(false);
    let store = store(&fake);
    poll(&store);
    let s = store.state().snapshot.unwrap();
    assert_eq!(
        s.temps
            .iter()
            .map(|t| t.sensor.as_str())
            .collect::<Vec<_>>(),
        ["temp1", "temp3", "temp7"]
    );
    assert_eq!(s.cpu_package_temp().unwrap().label, "Tctl");
    assert_eq!(s.other_host_temps().len(), 1);
    assert!(!s.temps[2].named);
    assert_eq!(s.temps[2].label, "temp7");
    assert_eq!(s.temps[0].chip_short(), "pci0000:00_0000:00:18");
    fake.set(
        q::ALL_TEMPS,
        vec![sample(
            json!({"instance":"pve-host","sensor":"temp0"}),
            99.0,
        )],
    );
    poll(&store);
    assert!(store.state().snapshot.unwrap().cpu_package_temp().is_none());
}
#[test]
fn missing_nodes_record_gaps_and_no_targets_is_still_a_success() {
    let fake = FakePrometheus::new(true);
    let store = store(&fake);
    poll(&store);
    fake.set(q::UP, vec![]);
    poll(&store);
    assert!(store.state().healthy);
    assert!(store.state().snapshot.unwrap().nodes.is_empty());
    assert_eq!(store.state().cpu_history("pve-host"), [Some(9.19), None]);
}
#[test]
fn ring_depth_and_nan() {
    let mut r = Ring::default();
    r.add(Some(f64::NAN));
    assert_eq!(r.values(), [None]);
    for i in 0..125 {
        r.add(Some(i as f64));
    }
    assert_eq!(r.values().len(), 120);
    assert_eq!(r.values()[0], Some(5.0));
    r.add(None);
    assert_eq!(r.values().last(), Some(&None));
}
#[test]
fn stale_snapshot_scales_with_poll_interval_and_strict_boundary() {
    let fake = FakePrometheus::new(true);
    let now = Arc::new(Mutex::new(Utc::now()));
    let clock = now.clone();
    let store = MetricsStore::with_clock(
        Config {
            poll_seconds: 20,
            ..Config::default()
        },
        fake.client(),
        Arc::new(move || *clock.lock().unwrap()),
    );
    poll(&store);
    *now.lock().unwrap() += TimeDelta::seconds(60);
    assert!(!store.state().stale);
    *now.lock().unwrap() += TimeDelta::milliseconds(1);
    assert!(store.state().stale);
    assert!(store.state().healthy);
}
#[test]
fn gpu_staleness_boundary_and_missing_age() {
    let mut g = GpuStat {
        exporter_up: true,
        age_seconds: Some(120.0),
        ..Default::default()
    };
    assert!(!g.stale());
    g.age_seconds = Some(120.01);
    assert!(g.stale());
    g.age_seconds = None;
    assert!(!g.stale());
    g.exporter_up = false;
    assert!(g.stale());
}
#[test]
fn missing_zero_and_health_thresholds_are_distinct() {
    let fake = FakePrometheus::new(true);
    let store = store(&fake);
    poll(&store);
    let mut snap = store.state().snapshot.unwrap();
    let mut n = NodeStat {
        instance: "test".into(),
        up: true,
        ..Default::default()
    };
    assert_eq!(snap.health_of(&n), NodeHealth::Unknown);
    assert_eq!(n.mem_pct(), None);
    n.cpu_pct = Some(0.0);
    assert_eq!(snap.health_of(&n), NodeHealth::Ok);
    n.cpu_pct = Some(75.0);
    assert_eq!(snap.health_of(&n), NodeHealth::Warn);
    n.cpu_pct = Some(90.0);
    assert_eq!(snap.health_of(&n), NodeHealth::Critical);
    n.cpu_pct = Some(0.0);
    n.mem_total = Some(0.0);
    n.mem_available = Some(0.0);
    assert_eq!(n.mem_used(), Some(0.0));
    assert_eq!(n.mem_pct(), None);
    n.swap_total = Some(0.0);
    n.swap_free = Some(0.0);
    assert_eq!(n.swap_pct(), None);
    snap.gpus = vec![GpuStat {
        instance: "test".into(),
        exporter_up: true,
        util: Some(95.0),
        ..Default::default()
    }];
    assert_eq!(snap.health_of(&n), NodeHealth::Critical);
    snap.gpus[0].exporter_up = false;
    assert_eq!(snap.health_of(&n), NodeHealth::Ok);
    n.up = false;
    assert_eq!(snap.health_of(&n), NodeHealth::Unknown);
}
#[test]
fn gpu_seeds_from_each_metric_and_temperature_metadata_wins() {
    let fake = FakePrometheus::new(true);
    let store = store(&fake);
    let gpu_queries: Vec<_> = q::instant_poll_queries(&Config::default())
        .into_iter()
        .filter(|(_, q)| q.contains("DCGM"))
        .map(|(_, q)| q)
        .collect();
    for query in &gpu_queries {
        for q in &gpu_queries {
            fake.set(q, vec![]);
        }
        fake.set(query, vec![gpu(42.0)]);
        poll(&store);
        let s = store.state().snapshot.unwrap();
        assert_eq!(s.gpus.len(), 1, "{query}");
        if *query != q::gpu_temp() {
            assert_eq!(s.gpus[0].temp, None);
        }
    }
    let mut temp = gpu(30.0);
    temp["metric"]["modelName"] = json!("temperature metadata");
    fake.set(q::gpu_temp(), vec![temp]);
    poll(&store);
    assert_eq!(
        store.state().snapshot.unwrap().gpus[0].model,
        "temperature metadata"
    );
}
#[test]
fn gpu_primary_relatches_after_replacement_and_absence() {
    let fake = FakePrometheus::new(true);
    let store = store(&fake);
    poll(&store);
    for (_, q) in q::instant_poll_queries(&Config::default()) {
        if q.contains("DCGM") {
            fake.set(q, vec![]);
        }
    }
    let mut replacement = gpu(55.0);
    replacement["metric"]["UUID"] = json!("replacement");
    replacement["metric"]["gpu"] = json!("2");
    fake.set(q::gpu_temp(), vec![replacement.clone()]);
    poll(&store);
    assert_eq!(
        store.state().gpu_temp_history.values(),
        [Some(40.0), Some(55.0)]
    );
    let mut lower = gpu(66.0);
    lower["metric"]["gpu"] = json!("0");
    fake.set(q::gpu_temp(), vec![lower, replacement]);
    poll(&store);
    assert_eq!(
        store.state().gpu_temp_history.values().last(),
        Some(&Some(55.0))
    );
    fake.set(q::gpu_temp(), vec![]);
    poll(&store);
    assert_eq!(store.state().gpu_temp_history.values().last(), Some(&None));
    fake.set(q::gpu_temp(), vec![gpu(22.0)]);
    poll(&store);
    assert_eq!(
        store.state().gpu_temp_history.values().last(),
        Some(&Some(22.0))
    );
}
#[test]
fn fallback_only_for_down_targets_and_fresh_age_wins() {
    let fake = FakePrometheus::new(false);
    fake.set(q::gpu_temp(), vec![gpu(88.0)]);
    fake.set(q::gpu_temp_last(), vec![gpu(33.0)]);
    fake.set(q::GPU_AGE_FRESH, vec![]);
    let store = store(&fake);
    poll(&store);
    let s = store.state().snapshot.unwrap();
    assert_eq!(s.gpus[0].temp, Some(33.0));
    assert_eq!(s.gpus[0].age_seconds, Some(166055.5));
    fake.set(q::GPU_AGE_FRESH, vec![gpu(11.0)]);
    poll(&store);
    assert_eq!(
        store.state().snapshot.unwrap().gpus[0].age_seconds,
        Some(11.0)
    );
    fake.set(q::UP, up(true));
    let before = fake.calls();
    poll(&store);
    assert_eq!(fake.calls() - before, 26);
    assert_eq!(store.state().snapshot.unwrap().gpus[0].temp, Some(88.0));
    fake.set(q::UP, up(false));
    let before = fake.calls();
    poll(&store);
    assert_eq!(fake.calls() - before, 35);
}
#[test]
fn optional_fallback_failure_keeps_nodes_current_and_retries() {
    let fake = FakePrometheus::new(false);
    fake.reply(&q::gpu_temp_last(), 400, "{\"error\":\"scan failed\"}");
    let store = store(&fake);
    poll(&store);
    assert!(store.state().healthy);
    assert_eq!(store.state().snapshot.unwrap().gpus[0].temp, None);
    let before = fake.calls();
    fake.set(q::gpu_temp_last(), vec![gpu(31.0)]);
    poll(&store);
    assert_eq!(fake.calls() - before, 35);
    assert_eq!(store.state().snapshot.unwrap().gpus[0].temp, Some(31.0));
}
#[test]
fn changed_down_targets_do_not_reuse_old_cache() {
    let fake = FakePrometheus::new(false);
    let store = store(&fake);
    poll(&store);
    let mut targets = up(false);
    targets.push(sample(json!({"instance":"new-worker","job":"dcgm"}), 0.0));
    fake.set(q::UP, targets);
    fake.reply(&q::gpu_temp_last(), 500, "bad");
    let before = fake.calls();
    poll(&store);
    assert_eq!(fake.calls() - before, 35);
    assert!(store.state().healthy);
    assert_eq!(store.state().snapshot.unwrap().gpus[0].temp, None);
}
#[test]
fn numeric_gpu_sort_and_instance_first() {
    let fake = FakePrometheus::new(true);
    let store = store(&fake);
    for (_, q) in q::instant_poll_queries(&Config::default()) {
        if q.contains("DCGM") {
            fake.set(q, vec![]);
        }
    }
    let rows = [("z", "0"), ("a", "10"), ("a", "2")]
        .into_iter()
        .map(|(i, g)| sample(json!({"instance":i,"gpu":g}), 10.0))
        .collect();
    fake.set(q::gpu_temp(), rows);
    poll(&store);
    assert_eq!(
        store
            .state()
            .snapshot
            .unwrap()
            .gpus
            .iter()
            .map(|g| format!("{}/{}", g.instance, g.gpu))
            .collect::<Vec<_>>(),
        ["a/2", "a/10", "z/0"]
    );
}
#[test]
fn range_alignment_and_step() {
    for (secs, step) in [
        (0, 15),
        (3600, 15),
        (86400, 360),
        (3720, 16),
        (604800, 2520),
    ] {
        assert_eq!(
            MetricsStore::step_for(Duration::from_secs(secs)),
            Duration::from_secs(step)
        );
    }
    let fake = FakePrometheus::new(true);
    let store = store(&fake);
    let end = Utc::now();
    let series = store
        .load_range(q::RANGE_CPU, Duration::from_secs(3600), Some(end))
        .unwrap();
    assert_eq!(series[0].points.len(), 241);
    assert_eq!(series[0].legend(), "pve-host");
    assert_eq!(series.len(), 5);
    let d = fake.data.lock().unwrap();
    let (path, p) = &d.requests[0];
    assert_eq!(path, "/api/v1/query_range");
    assert_eq!(p["step"], "15s");
    assert_eq!(
        p["end"],
        format!("{:.3}", end.timestamp_millis() as f64 / 1000.0)
    );
    assert_eq!(
        p["start"],
        format!("{:.3}", end.timestamp_millis() as f64 / 1000.0 - 3600.0)
    );
}
#[test]
fn http_errors_and_response_shapes() {
    let fake = FakePrometheus::new(true);
    let client = fake.client();
    for (status, body, expected) in [
        (400, "{\"error\":\"bad PromQL\"}", "bad PromQL"),
        (503, "bad", "HTTP 503"),
        (200, "not json", "invalid JSON response"),
        (200, "[]", "invalid Prometheus response"),
        (
            200,
            "{\"status\":\"error\",\"error\":\"bad query\"}",
            "bad query",
        ),
        (200, "{\"status\":\"weird\"}", "query status=weird"),
        (200, "{}", "query status=null"),
    ] {
        fake.reply("test", status, body);
        assert_eq!(client.instant("test", None).unwrap_err().0, expected);
    }
    fake.reply("test", 200, "{\"status\":\"success\",\"data\":{}}");
    assert!(client.instant("test", None).unwrap().is_empty());
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    drop(listener);
    assert_eq!(
        PromClient::new(url).instant("up", None).unwrap_err().0,
        "connection refused"
    );
}
#[test]
fn short_errors_and_unicode_truncation() {
    for (s, want) in [
        ("TimeoutException: slow", "timeout"),
        ("Connection refused (os error 111)", "connection refused"),
        ("No route to host", "no route to host"),
        ("Network is unreachable", "network unreachable"),
        ("Failed host lookup xyz", "dns lookup failed"),
    ] {
        assert_eq!(short_error(s), want);
    }
    assert_eq!(short_error(&"é".repeat(61)), format!("{}…", "é".repeat(60)));
    assert_eq!(short_error("short"), "short");
}
#[test]
fn instant_parser_skips_bad_rows_and_nonfinite_values() {
    let fake = FakePrometheus::new(true);
    fake.reply("test",200,&json!({"status":"success","data":{"result":[null,5,{}, {"value":["bad","2"]},{"value":[1]}, {"value":[1,"NaN"]},{"value":[1,"+Inf"]},{"value":[1,"-Inf"]},{"metric":{"instance":"x","label":12},"value":[1.2345,"0"]},{"metric":false,"value":[2,3]}]}}).to_string());
    let rows = fake.client().instant("test", Some(Utc::now())).unwrap();
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0].value, 0.0);
    assert_eq!(rows[0].at.timestamp_millis(), 1235);
    assert_eq!(rows[0].labels["label"], "12");
    assert!(rows[1].labels.is_empty());
}
struct StaticBody(String);
impl Transport for StaticBody {
    fn get(&self, _: &str, _: &[(&str, String)]) -> Result<(u16, String), PromError> {
        Ok((200, self.0.clone()))
    }
}
#[test]
fn range_parser_skips_bad_points_and_empty_series() {
    let body = json!({"status":"success","data":{"result":[null,{}, {"values":[[1,"NaN"]]}, {"metric":{"gpu":"2"},"values":[[1,"1.5"],[2,"+Inf"],["bad",3],[4,0],null]}]}});
    let c = PromClient::with_transport("http://fake///", Arc::new(StaticBody(body.to_string())));
    assert_eq!(c.base_url, "http://fake");
    let s = c
        .range("x", Utc::now(), Utc::now(), Duration::from_secs(15))
        .unwrap();
    assert_eq!(s.len(), 1);
    assert_eq!(s[0].legend(), "2");
    assert_eq!(s[0].points.len(), 2);
    assert_eq!(s[0].points[1].v, 0.0);
}
#[test]
fn query_sanitization_and_complete_batches() {
    let dirty = "a\"\\\nb";
    assert_eq!(q::safe(dirty), "ab");
    assert_eq!(q::cpu_for(dirty), q::cpu_for("ab"));
    assert_eq!(q::mem_used_bytes_for(dirty), q::mem_used_bytes_for("ab"));
    assert_eq!(q::mem_pct_for(dirty), q::mem_pct_for("ab"));
    assert_eq!(q::hwmon_temp_for(dirty), q::hwmon_temp_for("ab"));
    assert_eq!(
        q::gpu_temp_for(dirty),
        "DCGM_FI_DEV_GPU_TEMP{instance=\"ab\"}"
    );
    assert_eq!(
        q::gpu_util_for(dirty),
        "DCGM_FI_DEV_GPU_UTIL{instance=\"ab\"}"
    );
    assert!(q::gpu_temp().ends_with("< 120)"));
    assert!(q::gpu_temp_last().contains("[7d]"));
    assert!(q::GPU_AGE_DEEP.contains("[7d:5m]"));
    assert_eq!(q::instant_poll_queries(&Config::default()).len(), 26);
    assert_eq!(q::gpu_fallback_queries(&Config::default()).len(), 9);
    let c = Config {
        net_device_exclude: "a\\.b\"\n".into(),
        ..Default::default()
    };
    assert!(q::net_rx(&c).contains("device!~\"a\\\\.b\\\"\\n\""));
}

/// Gate only expensive queries so tests can prove a node poll finishes while
/// the background TSDB scan is still blocked, without timing guesses.
struct Gated {
    replies: Mutex<HashMap<String, fake_prometheus::Reply>>,
    gate: Arc<(Mutex<(bool, usize)>, Condvar)>,
    calls: AtomicUsize,
}
impl Transport for Gated {
    fn get(&self, _: &str, p: &[(&str, String)]) -> Result<(u16, String), PromError> {
        let q = &p.iter().find(|(k, _)| *k == "query").unwrap().1;
        self.calls.fetch_add(1, Ordering::SeqCst);
        if q.contains("[7d") {
            let mut g = self.gate.0.lock().unwrap();
            g.1 += 1;
            self.gate.1.notify_all();
            while g.0 {
                g = self.gate.1.wait(g).unwrap();
            }
        }
        let r = self
            .replies
            .lock()
            .unwrap()
            .get(q)
            .cloned()
            .unwrap_or_else(|| fake_prometheus::Reply::vector(vec![]));
        Ok((r.status, r.body))
    }
}
#[test]
fn expired_fallback_refreshes_in_background_and_keeps_cache_on_failure() {
    let fake = FakePrometheus::new(false);
    let t = Arc::new(Gated {
        replies: Mutex::new(fake.data.lock().unwrap().replies.clone()),
        gate: Arc::new((Mutex::new((false, 0)), Condvar::new())),
        calls: AtomicUsize::new(0),
    });
    let now = Arc::new(Mutex::new(Utc::now()));
    let clock = now.clone();
    let s = MetricsStore::with_clock(
        Config::default(),
        PromClient::with_transport("fake", t.clone()),
        Arc::new(move || *clock.lock().unwrap()),
    );
    poll(&s);
    t.gate.0.lock().unwrap().0 = true;
    *now.lock().unwrap() += TimeDelta::seconds(60);
    let (tx, rx) = std::sync::mpsc::channel();
    s.on_change(Box::new(move || {
        tx.send(()).unwrap();
    }));
    let h = s.refresh().unwrap();
    rx.recv_timeout(Duration::from_secs(5))
        .expect("nodes must not wait for history");
    h.join().unwrap();
    {
        let g = t.gate.0.lock().unwrap();
        let (g, timeout) = t
            .gate
            .1
            .wait_timeout_while(g, Duration::from_secs(5), |g| g.1 < 18)
            .unwrap();
        assert!(!timeout.timed_out());
        assert!(g.0);
    }
    assert_eq!(s.state().snapshot.unwrap().gpus[0].temp, Some(40.0));
    t.replies.lock().unwrap().insert(
        q::gpu_temp_last(),
        fake_prometheus::Reply::vector(vec![gpu(29.0)]),
    );
    t.gate.0.lock().unwrap().0 = false;
    t.gate.1.notify_all();
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        poll(&s);
        if s.state().snapshot.unwrap().gpus[0].temp == Some(29.0) {
            break;
        }
        assert!(Instant::now() < deadline);
        std::thread::yield_now();
    }
    // Once landed, the cache is fresh and no historical requests run.
    let calls = t.calls.load(Ordering::SeqCst);
    poll(&s);
    assert_eq!(t.calls.load(Ordering::SeqCst) - calls, 26);
    t.replies.lock().unwrap().insert(
        q::gpu_temp_last(),
        fake_prometheus::Reply {
            status: 500,
            body: "bad".into(),
        },
    );
    *now.lock().unwrap() += TimeDelta::seconds(60);
    poll(&s);
    assert!(s.state().healthy);
    assert_eq!(s.state().snapshot.unwrap().gpus[0].temp, Some(29.0));
    s.stop();
}
#[test]
fn overlapping_refresh_dropped_callback_can_read_and_stop_suppresses_publication() {
    let fake = FakePrometheus::new(true);
    fake.data.lock().unwrap().delay = Duration::from_millis(80);
    let store = store(&fake);
    let count = Arc::new(AtomicUsize::new(0));
    let c = count.clone();
    let reader = store.clone();
    store.on_change(Box::new(move || {
        assert!(reader.state().healthy);
        c.fetch_add(1, Ordering::SeqCst);
    }));
    let h = store.refresh().unwrap();
    assert!(store.refresh().is_none());
    h.join().unwrap();
    assert_eq!(count.load(Ordering::SeqCst), 1);
    assert_eq!(fake.calls(), 26);
    let h = store.refresh().unwrap();
    store.stop();
    h.join().unwrap();
    assert_eq!(count.load(Ordering::SeqCst), 1);
    assert_eq!(store.state().cpu_history("pve-host").len(), 1);
    assert!(store.refresh().is_none());
    // Replace the hook to release its intentional store reference.
    store.on_change(Box::new(|| {}));
}
#[test]
fn timer_starts_once_and_stops() {
    let fake = FakePrometheus::new(true);
    let store = MetricsStore::new(
        Config {
            poll_seconds: 1,
            ..Default::default()
        },
        fake.client(),
    );
    let (tx, rx) = std::sync::mpsc::channel();
    store.on_change(Box::new(move || {
        let _ = tx.send(());
    }));
    store.start();
    store.start();
    rx.recv_timeout(Duration::from_secs(5)).unwrap();
    rx.recv_timeout(Duration::from_secs(5)).unwrap();
    store.stop();
    assert_eq!(fake.calls(), 52);
}
#[test]
fn range_fixture_honors_instance_gpu_and_speedtest_paths() {
    let fake = FakePrometheus::new(true);
    let s = store(&fake);
    let window = Duration::from_secs(3600);
    let nodes = s.load_range(&q::cpu_for("vm-vpn"), window, None).unwrap();
    assert_eq!(nodes.len(), 1);
    assert_eq!(nodes[0].instance(), Some("vm-vpn"));
    let gpu = s.load_range(q::RANGE_TEMP_GPU, window, None).unwrap();
    assert_eq!(gpu[0].instance(), Some("vm-gpu-worker-1"));
    let temps = s.load_range(q::RANGE_TEMP_CPU, window, None).unwrap();
    assert_eq!(temps[0].legend(), "Tctl");
    for query in [q::RANGE_SPEEDTEST_DOWN, q::RANGE_SPEEDTEST_UP] {
        let rows = s.load_range(query, window, None).unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].labels["path"], "direct");
        assert_eq!(rows[1].labels["path"], "socks");
    }
}
#[test]
fn http_timeout_is_six_seconds_and_maps_to_short_error() {
    let fake = FakePrometheus::new(true);
    fake.data.lock().unwrap().delay = Duration::from_millis(6250);
    let started = Instant::now();
    assert_eq!(fake.client().instant("up", None).unwrap_err().0, "timeout");
    assert!(started.elapsed() >= Duration::from_secs(5));
    assert!(started.elapsed() < Duration::from_secs(9));
}
#[test]
fn configured_hypervisor_controls_order_and_package_selection() {
    let fake = FakePrometheus::new(true);
    fake.set(
        q::ALL_TEMPS,
        vec![
            sample(json!({"instance":"vm-vpn","label":"Tdie"}), 51.0),
            sample(json!({"instance":"pve-host","label":"Tctl"}), 42.0),
        ],
    );
    let s = MetricsStore::new(
        Config {
            hypervisor: "vm-vpn".into(),
            ..Config::default()
        },
        fake.client(),
    );
    poll(&s);
    let snap = s.state().snapshot.unwrap();
    assert_eq!(snap.nodes[0].instance, "vm-vpn");
    assert_eq!(snap.host().unwrap().instance, "vm-vpn");
    assert_eq!(snap.cpu_package_temp().unwrap().celsius, 51.0);
}
