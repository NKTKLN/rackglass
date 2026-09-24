use rackglass::{
    Config,
    ui::{AppWindow, runtime::Runtime},
};
use slint::ComponentHandle;
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let cfg = Config::load()?;
    // Explicit user selections retain precedence, including a renderer suffix.
    let backend = std::env::var("SLINT_BACKEND").unwrap_or_else(|_| {
        if cfg!(feature = "desktop") {
            "winit-software".into()
        } else {
            "linuxkms-software".into()
        }
    });
    slint::BackendSelector::new()
        .backend_name(backend)
        .select()?;
    let window = AppWindow::new()?;
    // Any value but an explicit no, so `=yes` or `=true` in a unit file works.
    let fullscreen = std::env::var("RACKGLASS_FULLSCREEN").is_ok_and(|v| {
        !matches!(
            v.trim().to_ascii_lowercase().as_str(),
            "" | "0" | "false" | "no" | "off"
        )
    });
    if fullscreen {
        window.window().set_fullscreen(true);
    }
    let runtime = Runtime::attach(&window, cfg);
    window.run()?;
    drop(runtime);
    Ok(())
}
