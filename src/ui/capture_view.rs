use super::{AppWindow, layout::*, scene::*};
use crate::{
    capture::{CaptureSnapshot, CaptureState, letterbox},
    fmt::{fmt_bytes, fmt_duration},
};
use chrono::TimeDelta;
use slint::{Image, Rgb8Pixel, SharedPixelBuffer};

pub fn update(window: &AppWindow, capture: &CaptureSnapshot) {
    let (tag, ink, accent) = match capture.state {
        CaptureState::Idle => ("STOPPED", DIM, 0x565656),
        CaptureState::Starting => ("OPENING", AMBER, 0x565656),
        CaptureState::Streaming => ("LIVE", GREEN, 0x565656),
        CaptureState::NoSignal => ("NO SIGNAL", AMBER, AMBER),
        CaptureState::Failed => ("ERROR", RED, RED),
    };
    window.set_capture_running(capture.running);
    window.set_capture_title(
        format!("CAPTURE · {}", capture.source_label())
            .to_uppercase()
            .into(),
    );
    window.set_capture_tag(format!("[ {tag} ]").into());
    window.set_capture_color(color(ink));
    window.set_capture_accent(color(accent));
    // Diagnostics update independently from frame pixels. Reuse the image when
    // only the one-second FPS/uptime tick changed.
    window.set_capture_show_frame(capture.frame.is_some() && capture.state != CaptureState::Failed);
    let mut stats = vec![format!("mode: {} · mjpeg", capture.mode.label())];
    if capture.running {
        stats.push(format!("{:.1} fps", capture.fps));
    }
    if let Some(frame) = &capture.frame {
        let viewport = if window.get_video_full() {
            CAPTURE_FULLSCREEN
        } else {
            CAPTURE_VIEWPORT
        };
        let (_, _, width, _) = letterbox((frame.width, frame.height), viewport);
        stats.push(format!("fit {:.0}%", width / frame.width as f32 * 100.));
    }
    if capture.bytes_total > 0 {
        stats.push(format!(
            "{} in",
            fmt_bytes(Some(capture.bytes_total as f64), 0)
        ));
    }
    if capture.frames_dropped > 0 {
        stats.push(format!("{} dropped", capture.frames_dropped));
    }
    if capture.decode_errors > 0 {
        stats.push(format!("{} bad", capture.decode_errors));
    }
    window.set_capture_stats(stats.join("  ·  ").into());
    window.set_capture_uptime(
        capture
            .uptime
            .map(|duration| format!("up {}", fmt_duration(TimeDelta::from_std(duration).ok())))
            .unwrap_or_default()
            .into(),
    );
    let device = capture.device.as_ref().map(|device| device.path.as_str());
    let (title, line1, line2) = match capture.state {
        CaptureState::Failed => (
            "CAPTURE FAILED",
            capture
                .error
                .as_ref()
                .and_then(|e| e.lines().last())
                .unwrap_or("unknown error")
                .to_owned(),
            if capture.devices.is_empty() {
                "no /dev/video* nodes — is the stick plugged in?"
            } else {
                "retrying every 2s"
            },
        ),
        CaptureState::NoSignal => (
            "NO SIGNAL",
            "the card is streaming, the picture is black".into(),
            "nothing connected to its HDMI input?",
        ),
        CaptureState::Idle => (
            "STOPPED",
            format!("press START to open {}", device.unwrap_or("the device")),
            "",
        ),
        _ if capture.frame.is_none() => (
            "OPENING DEVICE…",
            format!(
                "{} · {} · mjpeg",
                device.unwrap_or("?"),
                capture.mode.label()
            ),
            "",
        ),
        _ => ("", String::new(), ""),
    };
    window.set_capture_message(title.into());
    window.set_capture_line1(line1.into());
    window.set_capture_line2(line2.into());
    // The opening message is dim even though its panel tag is amber.
    if capture.state == CaptureState::Starting {
        window.set_capture_message_color(color(DIM));
    } else {
        window.set_capture_message_color(color(ink));
    }
}
pub fn frame_image(frame: &crate::capture::Frame) -> Image {
    Image::from_rgb8(SharedPixelBuffer::<Rgb8Pixel>::clone_from_slice(
        &frame.rgb,
        frame.width,
        frame.height,
    ))
}
