use super::{AppWindow,scene::*};
use crate::{capture::{CaptureSnapshot,CaptureState,letterbox},fmt::{fmt_bytes,fmt_duration}};
use slint::{Image,Rgb8Pixel,SharedPixelBuffer};
use chrono::TimeDelta;

pub fn update(window:&AppWindow,c:&CaptureSnapshot) {
    let (tag,ink,accent)=match c.state {
        CaptureState::Idle=>("STOPPED",DIM,0x565656),CaptureState::Starting=>("OPENING",AMBER,0x565656),
        CaptureState::Streaming=>("LIVE",GREEN,0x565656),CaptureState::NoSignal=>("NO SIGNAL",AMBER,AMBER),CaptureState::Failed=>("ERROR",RED,RED),
    };
    window.set_capture_running(c.running);window.set_capture_title(format!("CAPTURE · {}",c.source_label()).to_uppercase().into());
    window.set_capture_tag(format!("[ {tag} ]").into());window.set_capture_color(color(ink));window.set_capture_accent(color(accent));
    // Diagnostics update independently from frame pixels. Reuse the image when
    // only the one-second FPS/uptime tick changed.
    window.set_capture_show_frame(c.frame.is_some()&&c.state!=CaptureState::Failed);
    let mut stats=vec![format!("mode: {} · mjpeg",c.mode.label())];
    if c.running{stats.push(format!("{:.1} fps",c.fps));}
    if let Some(frame)=&c.frame {
        let viewport=if window.get_video_full(){(1024.,600.)}else{(1004.,452.)};
        let (_,_,w,_)=letterbox((frame.width,frame.height),viewport);
        stats.push(format!("fit {:.0}%",w/frame.width as f32*100.));
    }
    if c.bytes_total>0{stats.push(format!("{} in",fmt_bytes(Some(c.bytes_total as f64),0)));}
    if c.frames_dropped>0{stats.push(format!("{} dropped",c.frames_dropped));}
    if c.decode_errors>0{stats.push(format!("{} bad",c.decode_errors));}
    window.set_capture_stats(stats.join("  ·  ").into());
    window.set_capture_uptime(c.uptime.map(|d|format!("up {}",fmt_duration(TimeDelta::from_std(d).ok()))).unwrap_or_default().into());
    let device=c.device.as_ref().map(|d|d.path.as_str());
    let (title,line1,line2)=match c.state {
        CaptureState::Failed=>("CAPTURE FAILED",c.error.as_ref().and_then(|e|e.lines().last()).unwrap_or("unknown error").to_owned(),if c.devices.is_empty(){"no /dev/video* nodes — is the stick plugged in?"}else{"retrying every 2s"}),
        CaptureState::NoSignal=>("NO SIGNAL","the card is streaming, the picture is black".into(),"nothing connected to its HDMI input?"),
        CaptureState::Idle=>("STOPPED",format!("press START to open {}",device.unwrap_or("the device")),""),
        _ if c.frame.is_none()=>("OPENING DEVICE…",format!("{} · {} · mjpeg",device.unwrap_or("?"),c.mode.label()),""),
        _=>("",String::new(),""),
    };
    window.set_capture_message(title.into());window.set_capture_line1(line1.into());window.set_capture_line2(line2.into());
    // The opening message is dim even though its panel tag is amber.
    if c.state==CaptureState::Starting {window.set_capture_message_color(color(DIM));}
    else{window.set_capture_message_color(color(ink));}
}
pub fn frame_image(frame:&crate::capture::Frame)->Image {
    Image::from_rgb8(SharedPixelBuffer::<Rgb8Pixel>::clone_from_slice(&frame.rgb,frame.width,frame.height))
}
