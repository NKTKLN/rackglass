//! Boxes the Rust side lays scenes into, in design pixels. Slint derives the
//! same boxes from its own layout; these are the one place Rust states them,
//! so a panel that changes size has one number to update, not five.

/// DASH node table: inner width of the panel, and the height its rows share.
pub const TABLE_WIDTH: f32 = 996.;
pub const TABLE_VIEWPORT: f32 = 261.;

/// NODES target list: tile width and the scrolling viewport.
pub const TARGET_WIDTH: f32 = 242.;
pub const TARGETS_VIEWPORT: f32 = 486.;

/// NODES detail column: content width and the scrolling viewport.
pub const DETAIL_WIDTH: f32 = 714.;
pub const DETAIL_VIEWPORT: f32 = 484.;
/// One history chart inside the detail column.
pub const NODE_CHART: (u32, u32) = (714, 132);

/// One of the four GRAPHS panels.
pub const GRAPH_CHART: (u32, u32) = (489, 211);

/// Where the capture picture is fitted, framed and fullscreen.
pub const CAPTURE_VIEWPORT: (f32, f32) = (1004., 452.);
pub const CAPTURE_FULLSCREEN: (f32, f32) = (1024., 600.);
