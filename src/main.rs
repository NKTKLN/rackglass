use rackglass::{Config, MetricsStore, PromClient};
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let cfg = Config::load()?;
    let client = PromClient::new(&cfg.prom_url);
    let store = MetricsStore::new(cfg, client);
    if let Some(poll) = store.refresh() {
        poll.join().map_err(|_| "poll worker panicked")?;
    }
    let state = store.state();
    if let Some(error) = state.error {
        return Err(error.into());
    }
    if let Some(s) = state.snapshot {
        println!(
            "{} nodes ({} down), {} GPUs, {} temperatures; poll {}ms",
            s.nodes.len(),
            s.targets_down(),
            s.gpus.len(),
            s.temps.len(),
            s.fetch_millis
        );
    }
    Ok(())
}
