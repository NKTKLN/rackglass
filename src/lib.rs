//! The non-UI Prometheus dashboard core.
pub mod config;
pub mod fmt;
pub mod model;
pub mod prom;
pub mod store;
pub use config::Config;
pub use prom::client::PromClient;
pub use store::MetricsStore;
