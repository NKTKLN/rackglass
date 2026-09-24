use super::{AppWindow,chart::{Chart,ChartCache},scene::*};
use crate::{fmt::*,model::{NodeHealth,NodeStat},store::StoreState};
use chrono::{DateTime,Local};
fn bytes(v:Option<f64>)->String{fmt_bytes(v,1)}
fn metric(s:&mut Scene,x:f32,caption:&str,pct:Option<f64>,lines:[(&str,String);4]) {
    let w=231.33333;
    s.caption(x,0.,w,caption);
    s.text(x,18.9,w,fmt_pct(pct,1),30.,severity(pct),700).h=33.;
    s.bar(x,53.9,192.,pct,severity(pct));
    for (i,(label,value)) in lines.into_iter().enumerate(){s.stat(x,80.7+i as f32*18.2,w,label,value,WHITE,500,14.);}
}
pub fn selected<'a>(state:&'a StoreState,key:&str)->Option<&'a NodeStat>{
    state.snapshot.as_ref().and_then(|s|s.nodes.iter().find(|n|n.instance==key).or(s.nodes.first()))
}
pub fn update(window:&AppWindow,state:&StoreState,key:&str,charts:&[Chart;4],cache:&mut ChartCache,loading:bool) {
    let Some(snap)=&state.snapshot else{window.set_node_message("NO DATA".into());return;};
    let Some(n)=selected(state,key) else{window.set_node_message("NO NODE TARGETS".into());return;};
    window.set_node_message("".into());
    window.set_node_title(format!("{} · {}",n.instance,n.role).to_uppercase().into());
    window.set_node_tag(if n.up{"[ UP ]"}else{"[ DOWN ]"}.into());window.set_node_tag_color(color(if n.up{GREEN}else{RED}));
    let mut targets=Scene::default();
    // 12px vertical padding + two font line boxes + 2px border, then a 3px gap.
    let tile_height=51.7;let stride=tile_height+3.;
    for (i,node) in snap.nodes.iter().enumerate() {
        let y=i as f32*stride;let lit=node.instance==n.instance;
        if lit{targets.rect(0.,y,242.,tile_height,WHITE);}
        targets.text(7.,y+15.45,9.6,if lit{"▸"}else{" "},16.,if lit{BG}else{DIM},400);
        targets.text(20.6,y+16.75,8.4,if node.up{"●"}else{"○"},14.,if node.up{GREEN}else{RED},400);
        targets.text(35.,y+7.,186.,&node.instance,16.,if !node.up{RED}else if lit{BG}else{FG},if lit{700}else{400});
        targets.text(35.,y+27.8,186.,if node.is_hypervisor{"hypervisor"}else{&node.role},13.,if lit{GRID}else{DIM},400);
        let (glyph,ink)=match snap.health_of(node){NodeHealth::Ok=>("✓",GREEN),NodeHealth::Warn=>("▲",AMBER),NodeHealth::Critical=>("!",RED),NodeHealth::Unknown=>("·",DIM)};
        targets.text(221.,y+15.45,14.,glyph,16.,if lit{BG}else{ink},700).align=2;
    }
    window.set_targets_height(snap.nodes.len() as f32*stride);window.set_node_targets(targets.into_model());
    let mut s=Scene::default();
    metric(&mut s,0.,"CPU",n.cpu_pct,[
        ("cores",fmt_num(n.cores,0)),("iowait",fmt_pct(n.io_wait_pct,1)),("load 1/5/15",format!("{} {} {}",fmt_num(n.load1,2),fmt_num(n.load5,2),fmt_num(n.load15,2))),("load/core",fmt_num(n.load_per_core(),2)),
    ]);
    metric(&mut s,241.33333,"MEMORY",n.mem_pct(),[("used",bytes(n.mem_used())),("available",bytes(n.mem_available)),("total",bytes(n.mem_total)),("swap",format!("{} / {}",bytes(n.swap_used()),bytes(n.swap_total)))]);
    metric(&mut s,482.66666,"ROOT FS",n.fs_pct(),[("used",bytes(n.fs_used())),("avail",bytes(n.fs_avail)),("size",bytes(n.fs_size)),("uptime",fmt_duration(n.uptime()))]);
    s.rect(0.,160.,714.,1.,GRID);
    let sensors=snap.temps_for(&n.instance);let gpus=snap.gpus_for(&n.instance);
    let net_width=if sensors.is_empty(){714.}else{280.};
    s.caption(0.,167.5,net_width,"NETWORK");
    s.stat(0.,188.4,net_width,"receive",fmt_rate(n.net_rx),CYAN,500,16.);
    s.stat(0.,209.2,net_width,"transmit",fmt_rate(n.net_tx),CYAN,500,16.);
    s.caption(0.,238.,net_width,"BOOT");
    let boot=n.boot_time.and_then(|t|DateTime::from_timestamp_millis((t*1000.).round() as i64)).map(|t|fmt_date(t.with_timezone(&Local))).unwrap_or_else(||"--".into());
    s.stat(0.,258.9,net_width,"booted",boot,WHITE,500,16.);
    s.stat(0.,279.7,net_width,"uptime",fmt_duration(n.uptime()),WHITE,500,16.);
    if !sensors.is_empty(){
        s.caption(294.,167.5,420.,"HWMON SENSORS");
        for (i,t) in sensors.iter().take(4).enumerate(){let y=188.4+i as f32*22.8;
            s.text(294.,y,82.,&t.label,16.,MID,400);
            s.text(376.,y,74.,fmt_temp(Some(t.celsius),1),16.,thermal(Some(t.celsius),70.,85.),500).align=1;
            s.bar(458.,y,134.4,Some(t.celsius),thermal(Some(t.celsius),70.,85.));
            s.text(600.4,y+1.95,113.6,t.chip_short(),13.,DIM,400);
        }
    }
    let mut y=300.5;
    if !gpus.is_empty(){
        s.rect(0.,y+6.5,714.,1.,GRID);y+=14.;s.caption(0.,y,714.,"GPU");y+=20.9;
        for g in &gpus{
            let title=format!("gpu{} · {}",g.gpu,g.model_short());let tw=title.chars().count() as f32*9.6;
            s.text(0.,y,tw,title,16.,MID,400);
            if g.stale(){s.text(tw+8.,y+1.95,714.-tw-8.,g.age().map(|a|format!("[ DOWN · {} OLD ]",fmt_duration(Some(a)))).unwrap_or_else(||"[ DOWN ]".into()),13.,AMBER,700);}
            y+=22.8;
            for (i,(label,value,ink)) in [("utilisation",fmt_pct(g.util,0),severity(g.util)),("temperature",fmt_temp(g.temp,1),thermal(g.temp,75.,88.)),("memory temp",fmt_temp(g.mem_temp,1),WHITE)].into_iter().enumerate(){s.stat(0.,y+i as f32*18.2,350.,label,value,ink,500,14.);}
            for (i,(label,value)) in [("vram",format!("{} / {}",bytes(g.fb_used_bytes()),bytes(g.fb_total_bytes()))),("power",g.power_watts.map(|p|format!("{p:.0} W")).unwrap_or_else(||"--".into())),("clocks sm/mem",if g.sm_clock_mhz.is_none()&&g.mem_clock_mhz.is_none(){"--".into()}else{format!("{} / {} MHz",fmt_num(g.sm_clock_mhz,0),fmt_num(g.mem_clock_mhz,0))})].into_iter().enumerate(){s.stat(364.,y+i as f32*18.2,350.,label,value,WHITE,500,14.);}
            y+=60.6;
        }
    }
    s.rect(0.,y+5.5,714.,1.,GRID);y+=12.;s.caption(0.,y,300.,"LAST 1H");
    if loading{s.text(500.,y,214.,"LOADING…",13.,AMBER,400).align=1;}
    y+=20.9;
    for (i,caption) in ["CPU %","MEMORY USED · GiB","TEMPERATURE °C","GPU UTILISATION %"].iter().enumerate(){
        if (i==2&&sensors.is_empty()&&gpus.is_empty())||(i==3&&gpus.is_empty()){continue;}
        s.caption(0.,y,714.,*caption);y+=18.9;
        s.append_at(&cache.render(&charts[i],714,132),0.,y);y+=142.;
    }
    window.set_detail_height(y);window.set_node_detail(s.into_model());
}
