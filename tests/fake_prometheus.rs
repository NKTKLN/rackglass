//! Local stand-in for the Proxmox host, four guests and a V100 worker.
use chrono::Utc;
use rackglass::{Config, PromClient, prom::queries as q};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    thread::{self, JoinHandle},
    time::Duration,
};

#[derive(Clone, Debug)]
pub struct Reply {
    pub status: u16,
    pub body: String,
}
impl Reply {
    pub fn vector(rows: Vec<Value>) -> Self {
        Self {
            status: 200,
            body: json!({"status":"success","data":{"resultType":"vector","result":rows}})
                .to_string(),
        }
    }
}
#[derive(Default)]
pub struct Data {
    pub replies: HashMap<String, Reply>,
    pub requests: Vec<(String, HashMap<String, String>)>,
    pub fail: bool,
    pub delay: Duration,
}
pub struct FakePrometheus {
    pub url: String,
    pub data: Arc<Mutex<Data>>,
    stop: Arc<AtomicBool>,
    worker: Option<JoinHandle<()>>,
}
impl FakePrometheus {
    pub fn new(gpu_up: bool) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let data = Arc::new(Mutex::new(Data {
            replies: cluster(gpu_up),
            ..Default::default()
        }));
        let stop = Arc::new(AtomicBool::new(false));
        let d = data.clone();
        let s = stop.clone();
        let worker = thread::spawn(move || {
            let mut workers = Vec::new();
            for stream in listener.incoming() {
                if s.load(Ordering::Acquire) {
                    break;
                }
                let d = d.clone();
                workers.push(thread::spawn(move || serve(stream.unwrap(), &d)));
            }
            for w in workers {
                w.join().unwrap();
            }
        });
        Self {
            url,
            data,
            stop,
            worker: Some(worker),
        }
    }
    pub fn client(&self) -> PromClient {
        PromClient::new(&self.url)
    }
    pub fn set(&self, query: impl Into<String>, rows: Vec<Value>) {
        self.data
            .lock()
            .unwrap()
            .replies
            .insert(query.into(), Reply::vector(rows));
    }
    pub fn reply(&self, query: &str, status: u16, body: &str) {
        self.data.lock().unwrap().replies.insert(
            query.into(),
            Reply {
                status,
                body: body.into(),
            },
        );
    }
    pub fn calls(&self) -> usize {
        self.data.lock().unwrap().requests.len()
    }
    pub fn queries(&self) -> Vec<String> {
        self.data
            .lock()
            .unwrap()
            .requests
            .iter()
            .map(|(_, p)| p["query"].clone())
            .collect()
    }
}
impl Drop for FakePrometheus {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        let _ = TcpStream::connect(self.url.trim_start_matches("http://"));
        if let Some(w) = self.worker.take() {
            w.join().unwrap();
        }
    }
}
fn decode(s: &str) -> String {
    let mut bytes = Vec::new();
    let mut it = s.bytes();
    while let Some(b) = it.next() {
        if b == b'%' {
            let a = it.next().unwrap();
            let b = it.next().unwrap();
            bytes.push(u8::from_str_radix(std::str::from_utf8(&[a, b]).unwrap(), 16).unwrap());
        } else {
            bytes.push(if b == b'+' { b' ' } else { b });
        }
    }
    String::from_utf8(bytes).unwrap()
}
fn serve(mut stream: TcpStream, data: &Mutex<Data>) {
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    let mut request = Vec::new();
    let mut buf = [0; 1024];
    while !request.windows(4).any(|w| w == b"\r\n\r\n") {
        let n = stream.read(&mut buf).unwrap();
        if n == 0 {
            return;
        }
        request.extend_from_slice(&buf[..n]);
    }
    let text = String::from_utf8(request).unwrap();
    let target = text.split_whitespace().nth(1).unwrap();
    let (path, qs) = target.split_once('?').unwrap();
    let params: HashMap<_, _> = qs
        .split('&')
        .map(|p| {
            let (k, v) = p.split_once('=').unwrap();
            (decode(k), decode(v))
        })
        .collect();
    let (reply, delay) = {
        let mut d = data.lock().unwrap();
        d.requests.push((path.into(), params.clone()));
        let reply = if d.fail {
            Reply {
                status: 503,
                body: "connection refused".into(),
            }
        } else if path.ends_with("query_range") {
            range_reply(&params["query"], params["end"].parse().unwrap())
        } else {
            d.replies
                .get(&params["query"])
                .cloned()
                .unwrap_or_else(|| Reply::vector(vec![]))
        };
        (reply, d.delay)
    };
    thread::sleep(delay);
    let _ = write!(
        stream,
        "HTTP/1.1 {} Response\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        reply.status,
        reply.body.len(),
        reply.body
    );
}
pub fn sample(labels: Value, v: f64) -> Value {
    json!({"metric":labels,"value":[Utc::now().timestamp_millis() as f64/1000.0,v.to_string()]})
}
pub fn gpu(v: f64) -> Value {
    sample(
        json!({"instance":"vm-gpu-worker-1","job":"dcgm","gpu":"0","device":"nvidia0","modelName":"Tesla V100-SXM2-16GB","UUID":"GPU-v100"}),
        v,
    )
}
pub fn up(gpu_up: bool) -> Vec<Value> {
    let mut rows: Vec<_> = NODES
        .iter()
        .map(|(i, r)| sample(json!({"instance":i,"role":r,"job":"node"}), 1.0))
        .collect();
    rows.push(sample(
        json!({"instance":"vm-gpu-worker-1","role":"gpu-workers","job":"node"}),
        if gpu_up { 1.0 } else { 0.0 },
    ));
    rows.push(sample(
        json!({"instance":"vm-gpu-worker-1","role":"gpu","job":"dcgm"}),
        if gpu_up { 1.0 } else { 0.0 },
    ));
    rows.push(sample(
        json!({"instance":"localhost:9090","job":"prometheus"}),
        1.0,
    ));
    rows
}
const NODES: [(&str, &str); 5] = [
    ("pve-host", "hypervisor"),
    ("vm-node-1", "nodes"),
    ("vm-ops-node", "operations"),
    ("vm-vpn", "vpn"),
    ("vm-amnezia-proxy", "proxy"),
];
fn vector(values: [f64; 5]) -> Vec<Value> {
    NODES
        .iter()
        .zip(values)
        .map(|((i, r), v)| sample(json!({"instance":i,"role":r,"job":"node"}), v))
        .collect()
}
fn cluster(gpu_up: bool) -> HashMap<String, Reply> {
    let cfg = Config::default();
    let mut m = HashMap::new();
    for (_, q) in q::instant_poll_queries(&cfg)
        .into_iter()
        .chain(q::gpu_fallback_queries())
    {
        m.insert(q, Reply::vector(vec![]));
    }
    let mut set = |q: &str, rows| {
        m.insert(q.into(), Reply::vector(rows));
    };
    set(q::UP, up(gpu_up));
    for (query, values) in [
        (q::CPU_BUSY, [9.19, 10.60, 0.67, 0.33, 0.38]),
        (q::CORES, [12.0, 2.0, 2.0, 1.0, 1.0]),
        (
            q::MEM_TOTAL,
            [
                33572134912.0,
                8257101824.0,
                2978578432.0,
                937627648.0,
                937627648.0,
            ],
        ),
        (
            q::MEM_AVAILABLE,
            [
                17745612800.0,
                2990116864.0,
                2232578048.0,
                517435392.0,
                509181952.0,
            ],
        ),
        (
            q::FS_SIZE,
            [
                100861726720.0,
                65445814272.0,
                65445814272.0,
                9283444736.0,
                15523123200.0,
            ],
        ),
        (
            q::FS_AVAIL,
            [
                63221596160.0,
                51153305600.0,
                53294276608.0,
                5926871040.0,
                12062707712.0,
            ],
        ),
        (q::SWAP_TOTAL, [8589930496.0, 0.0, 0.0, 0.0, 0.0]),
        (q::SWAP_FREE, [8589930496.0, 0.0, 0.0, 0.0, 0.0]),
        (q::LOAD1, [0.66; 5]),
        (q::LOAD5, [0.71; 5]),
        (q::LOAD15, [0.60; 5]),
        (q::CPU_IO_WAIT, [0.12; 5]),
        (q::BOOT_TIME, [Utc::now().timestamp() as f64 - 180000.0; 5]),
    ] {
        set(query, vector(values));
    }
    set(&q::net_rx(&cfg), vector([5574.87; 5]));
    set(&q::net_tx(&cfg), vector([1103.31; 5]));
    set(
        q::ALL_TEMPS,
        vec![
            sample(
                json!({"instance":"pve-host","chip":"pci0000:00_0000:00:18_3","sensor":"temp3","label":"Tccd1"}),
                46.5,
            ),
            sample(
                json!({"instance":"pve-host","chip":"pci0000:00_0000:00:18_3","sensor":"temp7"}),
                39.25,
            ),
            sample(
                json!({"instance":"pve-host","chip":"pci0000:00_0000:00:18_3","sensor":"temp1","label":"Tctl"}),
                43.375,
            ),
        ],
    );
    for (metric, live, dead) in [
        ("DCGM_FI_DEV_GPU_TEMP", 40.0, 40.0),
        ("DCGM_FI_DEV_GPU_UTIL", 73.0, 0.0),
        ("DCGM_FI_DEV_MEMORY_TEMP", 38.0, 38.0),
        ("DCGM_FI_DEV_FB_USED", 9216.0, 0.0),
        ("DCGM_FI_DEV_FB_FREE", 7154.0, 16370.0),
        ("DCGM_FI_DEV_POWER_USAGE", 212.4, 24.9),
        ("DCGM_FI_DEV_SM_CLOCK", 1380.0, 135.0),
        ("DCGM_FI_DEV_MEM_CLOCK", 877.0, 877.0),
    ] {
        set(
            &q::fresh_gpu(metric),
            vec![gpu(if gpu_up { live } else { dead })],
        );
        set(&q::last_gpu(metric), vec![gpu(dead)]);
    }
    set(
        q::GPU_AGE_FRESH,
        vec![gpu(if gpu_up { 12.0 } else { 166055.5 })],
    );
    set(q::GPU_AGE_DEEP, vec![gpu(166055.5)]);
    m
}

fn range_reply(query: &str, end: f64) -> Reply {
    let points = |base: f64| -> Vec<Value> {
        (0..=240)
            .rev()
            .map(|i| {
                json!([
                    end - i as f64 * 15.0,
                    format!("{:.2}", base + (i % 7) as f64 - 3.0)
                ])
            })
            .collect()
    };
    let rows: Vec<Value> = if query.contains("DCGM") {
        vec![
            json!({"metric":{"instance":"vm-gpu-worker-1","gpu":"0","modelName":"Tesla V100-SXM2-16GB"},"values":points(65.0)}),
        ]
    } else if query.contains("speedtest_download") || query.contains("speedtest_upload") {
        let bases = if query.contains("upload") {
            [431e6, 66e6]
        } else {
            [222e6, 165e6]
        };
        ["direct","socks"].into_iter().zip(bases).map(|(path,base)| {
            let values: Vec<_> = (0..=240).rev().map(|i| json!([end-i as f64*15.0,format!("{:.0}",base+(i%5) as f64*1e6)])).collect();
            json!({"metric":{"instance":"vm-ops-node","job":"node","path":path},"values":values})
        }).collect()
    } else if query.contains("node_hwmon") {
        vec![
            json!({"metric":{"instance":"pve-host","label":"Tctl","sensor":"temp1"},"values":points(44.0)}),
        ]
    } else {
        let pinned = query
            .split_once("instance=\"")
            .and_then(|(_, s)| s.split_once('"').map(|(i, _)| i));
        NODES
            .iter()
            .zip([9.19, 10.60, 0.67, 0.33, 0.38])
            .filter(|((i, _), _)| pinned.is_none_or(|p| p == *i))
            .map(
                |((i, r), cpu)| json!({"metric":{"instance":i,"role":r},"values":points(cpu+10.0)}),
            )
            .collect()
    };
    Reply {
        status: 200,
        body: json!({"status":"success","data":{"resultType":"matrix","result":rows}}).to_string(),
    }
}
