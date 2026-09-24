use super::{AppWindow, scene::*};
use crate::{fmt::*, store::StoreState};
use chrono::Local;

fn bytes(v: Option<f64>) -> String { fmt_bytes(v,1) }
fn big(s: &mut Scene, width: f32, value: String, unit: &str, caption: String, ink: u32) {
    let wanted=value.chars().count() as f32*20.4+4.+unit.chars().count() as f32*9.18;
    let scale=(width/wanted).min(1.);
    s.text(10.,17.,value.chars().count() as f32*20.4*scale,value,34.*scale,ink,700);
    s.text(10.+(wanted-4.-unit.chars().count() as f32*9.18)*scale+4.,31.,unit.chars().count() as f32*9.18*scale,unit,15.3*scale,ink,400);
    s.text(10.,54.,width,caption,13.,DIM,400);
}
fn inline(s:&mut Scene,w:f32,y:f32,label:&str,pct:Option<f64>,dim:bool) {
    let ink=if dim {DIM}else{severity(pct)};
    s.text(10.,y+1.3,48.,label,14.,DIM,400);
    s.bar(58.,y,(w-116.).min(211.2),pct,ink);
    s.text(w-58.,y,48.,fmt_pct(pct,0),16.,ink,500).align=1;
}
fn spark(s:&mut Scene,x:f32,y:f32,w:f32,label:&str,values:&[Option<f64>],lo:f64,hi:f64,ink:u32) {
    let label_width=label.len() as f32*7.8;
    s.text(x,y, label_width,label,13.,DIM,400);
    let cells=((w-label_width-5.)/9.6).floor().max(1.) as usize;
    s.text(x+label_width+5.,y-1.5,cells as f32*9.6,spark_text(values,cells,Some(lo),Some(hi)),16.,ink,400);
}
pub fn update(window:&AppWindow,state:&StoreState) {
    window.set_stale_message(if state.stale {format!("STALE · LAST GOOD {} AGO",fmt_duration(state.snapshot_age)).into()}else{"".into()});
    let Some(snap)=&state.snapshot else {
        window.set_dash_message(state.error.as_ref().map(|e|format!("NO DATA · {e}")).unwrap_or_else(||"CONNECTING…".into()).into()); return;
    };
    window.set_dash_message("".into());
    let host=snap.host();let pkg=snap.cpu_package_temp();
    let mut cpu=Scene::default();let mut gpu=Scene::default();let mut memory=Scene::default();
    let temp=pkg.map(|t|t.celsius);let tint=thermal(temp,70.,85.);
    big(&mut cpu,190.,fmt_num(temp,1),"°C",pkg.map(|t|t.label.clone()).unwrap_or_else(||"no sensor".into()),tint);
    for (i,t) in snap.other_host_temps().iter().take(2).enumerate() {
        cpu.text(208.,20.+i as f32*20.2,104.,format!("{} {}",t.label,fmt_temp(Some(t.celsius),0)),14.,thermal(Some(t.celsius),70.,85.),400).align=1;
    }
    cpu.rect(10.,81.5,302.,1.,GRID);
    inline(&mut cpu,322.,86.,"UTIL",host.and_then(|n|n.cpu_pct),false);
    cpu.text(10.,112.1,42.,"LOAD ",14.,DIM,400);
    cpu.text(52.,112.1,160.,format!("{} {} {}",fmt_num(host.and_then(|n|n.load1),2),fmt_num(host.and_then(|n|n.load5),2),fmt_num(host.and_then(|n|n.load15),2)),14.,MID,400);
    cpu.text(236.4,112.1,75.6,format!("{} CORES",fmt_num(host.and_then(|n|n.cores),0)),14.,DIM,400).align=1;
    spark(&mut cpu,10.,170.,157.,"TEMP",&state.host_temp_history.values(),20.,100.,tint);
    spark(&mut cpu,169.,170.,143.,"CPU",&state.cpu_history(host.map(|n|n.instance.as_str()).unwrap_or("")),0.,100.,MID);
    let mut gpu_title="GPU".to_owned();let mut gpu_tag=String::new();
    let stale=snap.gpus.first().is_some_and(|g|g.stale());
    if let Some(g)=snap.gpus.first() {
        gpu_title=format!("GPU · {}",g.model_short()).to_uppercase();
        let tint=if stale{DIM}else{thermal(g.temp,80.,90.)};
        big(&mut gpu,198.,fmt_num(g.temp,0),"°C",if stale {format!("LAST SEEN {} AGO",fmt_duration(g.age()))}else{format!("core · mem {}",fmt_temp(g.mem_temp,0))},tint);
        gpu.text(216.,20.,118.,format!("{} W",fmt_num(g.power_watts,0)),16.,if stale{DIM}else{WHITE},400).align=1;
        gpu.text(216.,40.8,118.,format!("SM {}MHz",fmt_num(g.sm_clock_mhz,0)),13.,DIM,400).align=1;
        gpu.text(216.,57.7,118.,format!("MEM {}MHz",fmt_num(g.mem_clock_mhz,0)),13.,DIM,400).align=1;
        gpu.rect(10.,81.5,324.,1.,GRID);
        inline(&mut gpu,344.,86.,"UTIL",g.util,stale);
        inline(&mut gpu,344.,110.8,"VRAM",g.fb_pct(),stale);
        gpu.stat(10.,131.6,324.,"USED",format!("{} / {}",bytes(g.fb_used_bytes()),bytes(g.fb_total_bytes())),if stale{DIM}else{MID},400,14.);
        spark(&mut gpu,10.,170.,161.,"TEMP",&state.gpu_temp_history.values(),20.,100.,tint);
        spark(&mut gpu,176.,170.,158.,"UTIL",&state.gpu_util_history.values(),0.,100.,MID);
        if stale {gpu_tag="[ DOWN ]".into();}
    } else {gpu.text(10.,90.,324.,"NO GPU SERIES IN TSDB",14.,DIM,400).align=2;}
    let total=host.and_then(|n|n.mem_total);let mem_pct=host.and_then(|n|n.mem_pct());
    big(&mut memory,314.,bytes(host.and_then(|n|n.mem_used())),&format!("/ {}",bytes(total)),"HOST RAM IN USE".into(),severity(mem_pct));
    memory.rect(10.,81.5,314.,1.,GRID);
    inline(&mut memory,334.,86.,"USED",mem_pct,false);
    let swap_color=severity(host.and_then(|n|n.swap_pct()));
    memory.stat(10.,106.8,314.,"SWAP",format!("{} / {}",bytes(host.and_then(|n|n.swap_used())),bytes(host.and_then(|n|n.swap_total))),if swap_color==FG {MID}else{swap_color},if swap_color==FG {400}else{500},14.);
    let ram_count=snap.vms().iter().filter(|n|n.mem_total.is_some()).count();
    let used_count=snap.vms().iter().filter(|n|n.mem_used().is_some()).count();
    let guest_pct=total.filter(|v|*v>0.).map(|v|snap.vm_mem_reported_total()/v*100.);
    memory.stat(10.,125.,314.,&format!("GUEST RAM SUM ({ram_count})"),if ram_count==0 {"--".into()}else{format!("{} · {}",bytes(Some(snap.vm_mem_reported_total())),fmt_pct(guest_pct,0))},MID,400,14.);
    memory.stat(10.,143.2,314.,&format!("VM IN USE ({used_count})"),if used_count==0 {"--".into()}else{bytes(Some(snap.vm_mem_used()))},MID,400,14.);
    spark(&mut memory,10.,170.,314.,"RAM",&state.mem_history(host.map(|n|n.instance.as_str()).unwrap_or("")),0.,100.,MID);
    let guests=snap.vms();let down=guests.iter().filter(|n|!n.up).count();
    window.set_dash_titles(model(vec![format!("CPU · {}",host.map(|h|h.instance.as_str()).unwrap_or("host")).to_uppercase().into(),gpu_title.into(),format!("NODES · {}",guests.len()).into()]));
    window.set_dash_tags(model(vec![if host.is_some_and(|n|!n.up){"[ DOWN ]".into()}else{"".into()},gpu_tag.into(),if down>0{format!("[ {down} DOWN ]").into()}else{"".into()}]));
    window.set_host_down(host.is_some_and(|n|!n.up));window.set_gpu_stale(stale);
    window.set_dash_cpu(cpu.into_model());window.set_dash_gpu(gpu.into_model());window.set_dash_memory(memory.into_model());
    let mut headers=Scene::default();
    for (title,x,w) in header_boxes(996.) {let t=headers.text(x,2.55,w,title,13.,DIM,400);t.align=2;t.tracking=1.;}
    headers.rect(0.,22.,996.,1.,GRID);window.set_dash_headers(headers.into_model());
    let mut rows=Scene::default();let extent=(261./guests.len().max(1) as f32).max(44.);
    let columns=column_boxes(996.);
    for (i,n) in guests.iter().enumerate() {
        let y=i as f32*extent+(extent-20.8)/2.;
        let texts=[if n.up{"●".into()}else{"○".into()},n.instance.clone(),fmt_pct(n.cpu_pct,1),String::new(),fmt_pct(n.mem_pct(),0),String::new(),if n.mem_total.is_some(){format!("{}/{}",bytes(n.mem_used()),bytes(n.mem_total))}else{"--".into()},if n.fs_size.is_some(){format!("{}/{}",bytes(n.fs_used()),bytes(n.fs_size))}else{"--".into()},fmt_duration(n.uptime())];
        for (j,(x,w)) in columns.iter().copied().enumerate() {
            if j==3||j==5 {let pct=if j==3 {n.cpu_pct}else{n.mem_pct()};let bw=(w/9.6).floor()*9.6;rows.bar(x+w-bw,y,bw,pct,severity(pct));continue;}
            let ink=match j {0=>if n.up{GREEN}else{RED},1=>if n.up{WHITE}else{RED},2=>severity(n.cpu_pct),4=>severity(n.mem_pct()),6=>if n.mem_total.is_some(){WHITE}else{DIM},_=>if n.up{MID}else{DIM}};
            let t=rows.text(x,y,w,&texts[j],16.,ink,if [1,2,4].contains(&j)&&n.up{500}else{400});t.align=COLUMNS[j].align;
        }
        if i+1<guests.len(){rows.rect(0.,(i+1) as f32*extent-1.,996.,1.,GRID);}
    }
    if guests.is_empty(){rows.text(0.,120.,996.,"NO GUEST TARGETS",14.,DIM,400).align=2;}
    window.set_rows_height((guests.len() as f32*extent).max(261.));window.set_dash_rows(rows.into_model());
}
pub fn status(window:&AppWindow,state:&StoreState,clock:chrono::DateTime<Local>) {
    let mut s=Scene::default();let mut x=8.;
    for (label,value,ink,weight) in [
        ("status: ".to_owned(),if !state.healthy{"offline"}else if state.stale{"stale"}else{"online"}.to_owned(),if !state.healthy{RED}else if state.stale{AMBER}else{GREEN},700),
        ("time: ".to_owned(),fmt_clock(clock),FG,400),
        ("last request: ".to_owned(),state.snapshot.as_ref().map(|s|format!("{} · {}ms",fmt_clock(s.at.with_timezone(&Local)),s.fetch_millis)).unwrap_or_else(||"--".into()),FG,400),
    ] {
        if x>8. {s.text(x+10.,3.9,8.4,"·",14.,DIM,400);x+=28.4;}
        let lw=label.chars().count() as f32*7.8;s.text(x,4.55,lw,label,13.,DIM,400);x+=lw;
        let vw=value.chars().count() as f32*8.4;s.text(x,3.9,vw,value,14.,ink,weight);x+=vw;
    }
    let keys="1-4 mode · ←→ cycle · r refresh · q quit";let kw=keys.chars().count() as f32*7.8;
    if !state.healthy {s.text(x+28.,4.55,(1006.-kw-x-38.).max(0.),state.error.clone().unwrap_or_else(||"scrape failed".into()),13.,RED,400);}
    s.text(1016.-kw,4.55,kw,keys,13.,DIM,400);window.set_status(s.into_model());
}
