//! Opt in with RACKGLASS_LIVE_PROM_URL=... cargo test --test live_smoke -- --ignored.
use rackglass::{
    Config, MetricsStore, PromClient,
    prom::queries::{self as q, InstantQuery as Q},
};
use std::time::Duration;
fn config() -> Config {
    Config {
        prom_url: std::env::var("RACKGLASS_LIVE_PROM_URL").expect("set RACKGLASS_LIVE_PROM_URL"),
        ..Config::default()
    }
}
#[test]
#[ignore = "requires RACKGLASS_LIVE_PROM_URL and a reachable cluster"]
fn instant_and_fallback_expressions() {
    let cfg = config();
    let c = PromClient::new(&cfg.prom_url);
    for (key, query) in q::instant_poll_queries(&cfg) {
        let rows = c.instant(&query, None).unwrap();
        let optional = matches!(
            key,
            Q::GpuTemp
                | Q::GpuUtil
                | Q::GpuFbUsed
                | Q::GpuFbFree
                | Q::GpuPower
                | Q::GpuSmClock
                | Q::GpuMemClock
                | Q::GpuMemTemp
                | Q::GpuAgeFresh
        );
        if !optional {
            assert!(!rows.is_empty(), "{key:?} returned nothing");
        }
        println!("{key:?}: {} series", rows.len());
    }
    for (key, query) in q::gpu_fallback_queries() {
        let rows = c.instant(&query, None).unwrap();
        println!("fallback {key:?}: {} series", rows.len());
    }
}
#[test]
#[ignore = "requires RACKGLASS_LIVE_PROM_URL and a reachable cluster"]
fn coherent_poll_and_range_matrices() {
    let cfg = config();
    let s = MetricsStore::new(cfg.clone(), PromClient::new(&cfg.prom_url));
    s.refresh().unwrap().join().unwrap();
    let state = s.state();
    assert!(state.error.is_none(), "{:?}", state.error);
    let snap = state.snapshot.unwrap();
    assert!(!snap.nodes.is_empty());
    let host = snap.host().expect("hypervisor target");
    assert!(host.cores.unwrap() > 0.0);
    assert!(host.mem_total.unwrap() > 0.0);
    assert!(snap.cpu_package_temp().is_some());
    let end = chrono::Utc::now();
    for query in [
        q::RANGE_CPU,
        q::RANGE_MEM_PCT,
        q::RANGE_TEMP_CPU,
        q::RANGE_TEMP_GPU,
        q::RANGE_GPU_UTIL,
        &q::net_rx(&cfg),
    ] {
        let rows = s
            .load_range(query, Duration::from_secs(3600), Some(end))
            .unwrap();
        assert!(!rows.is_empty(), "{query}");
        assert!(rows[0].points.len() > 10, "{query}");
    }
}
