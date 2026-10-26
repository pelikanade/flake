//! The status panel: a small pixel renderer for the phone's own display.
//!
//! It draws in landscape coordinates (2400x1080) and blits them, rotated, into
//! the portrait framebuffer (1080x2400, 32bpp, stride 4352). Owning the
//! framebuffer is what buys true colour and antialiased type on a device whose
//! GPU has no firmware: there is no GL here, only memory.
//!
//! fbcon keeps the console, so the panel takes the display away from it while it
//! draws (`vtcon1/bind = 0`) and gives it back on the way out — which is also
//! the whole recovery story: stopping this program repaints the console.
//!
//! The cheap facts are read here, straight from /proc and /sys. Everything that
//! needs a process or the cluster API comes from /run/alioth-panel/status.env,
//! which `alioth-panel-collect` refreshes every 30 s; the sample's age is drawn
//! with it, so a stale panel is visible as one.
//!
//! `--once [seconds]` draws one frame, holds it, and exits — the way to look at
//! a frame on the device without handing the panel over to it.

use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::{Seek, SeekFrom, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;
use std::thread::sleep;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use fontdue::{Font, FontSettings};
use tiny_skia::{Color, Paint, Pixmap, Rect, Transform};

/// Landscape canvas we draw in, and the portrait framebuffer we blit into.
const W: usize = 2400;
const H: usize = 1080;
const FB_STRIDE: usize = 4352;
const FB_HEIGHT: usize = 2400;

const FB_PATH: &str = "/dev/fb0";
const VTCON_PATH: &str = "/sys/class/vtconsole/vtcon1/bind";
const RUN_DIR: &str = "/run/alioth-panel";

/// `Left` is what this phone wanted when kmscon was drawing its console
/// (`rotate=left`); flipping this flips the panel.
const ROTATE_LEFT: bool = true;

const FONT_PX: u32 = 38;

// --- palette ----------------------------------------------------------------
// AMOLED: black is off, lit pixels cost power and burn in. So: black ground,
// nothing white, colour only for state (green ok, amber attention, red fault).
const INK: u32 = 0xBDBDBD; // values
const DIM: u32 = 0x6B6B6B; // labels, units, section names
const RULE: u32 = 0x262626; // hairlines under section names and the header
const BAR: u32 = 0x5A5A5A; // a gauge's normal fill: a gauge, not a status
const TRACK: u32 = 0x1A1A1A; // a gauge's unfilled part
const OK: u32 = 0x3FA66B;
const WARN: u32 = 0xD29A3C;
const HOT: u32 = 0xE0564A;
const CHARGE: u32 = 0x58A9D0;
// --- end palette ------------------------------------------------------------

const O_RDWR: i32 = 0o2;

fn solid(rgb: u32) -> Paint<'static> {
    let mut paint = Paint::default();
    paint.set_color(Color::from_rgba8(
        ((rgb >> 16) & 0xFF) as u8,
        ((rgb >> 8) & 0xFF) as u8,
        (rgb & 0xFF) as u8,
        255,
    ));
    paint
}

struct Canvas {
    pixmap: Pixmap,
    regular: Font,
    bold: Font,
    cache: HashMap<(char, bool, u32), (fontdue::Metrics, Vec<u8>)>,
}

impl Canvas {
    fn new(regular: &[u8], bold: &[u8]) -> Result<Self, String> {
        let settings = FontSettings::default();
        let regular = Font::from_bytes(regular, settings).map_err(|e| format!("regular font: {e}"))?;
        let bold = Font::from_bytes(bold, settings).map_err(|e| format!("bold font: {e}"))?;
        let pixmap = Pixmap::new(W as u32, H as u32).ok_or("canvas allocation failed")?;
        Ok(Self {
            pixmap,
            regular,
            bold,
            cache: HashMap::new(),
        })
    }

    fn clear(&mut self) {
        self.pixmap.fill(Color::from_rgba8(0, 0, 0, 255));
    }

    /// A glyph at `px` pixels, rasterised once and kept.
    fn glyph(&mut self, ch: char, bold: bool, px: u32) -> &(fontdue::Metrics, Vec<u8>) {
        let key = (ch, bold, px);
        if !self.cache.contains_key(&key) {
            // Rasterise first: the font borrow has to end before the cache is
            // written, and the pair is small (one glyph).
            let glyph = {
                let font = if bold { &self.bold } else { &self.regular };
                font.rasterize(ch, px as f32)
            };
            self.cache.insert(key, glyph);
        }
        &self.cache[&key]
    }

    fn width_px(&mut self, text: &str, bold: bool, px: u32) -> i32 {
        text.chars()
            .map(|c| self.glyph(c, bold, px).0.advance_width)
            .sum::<f32>() as i32
    }

    fn text_width(&mut self, text: &str, bold: bool) -> i32 {
        self.width_px(text, bold, FONT_PX)
    }

    /// `text`, cut short with an ellipsis so that it fits in `max` pixels.
    fn fit(&mut self, text: &str, bold: bool, max: i32) -> String {
        if self.text_width(text, bold) <= max {
            return text.to_string();
        }
        let mut kept: Vec<char> = text.chars().collect();
        while kept.pop().is_some() {
            let candidate: String = kept.iter().collect::<String>() + "…";
            if self.text_width(&candidate, bold) <= max {
                return candidate;
            }
        }
        "…".to_string()
    }

    /// Draw a string at the body size, left edge at `x`, baseline at `baseline`.
    /// Returns the x the pen ended at, so callers can lay out after it.
    fn text(&mut self, x: i32, baseline: i32, text: &str, rgb: u32, bold: bool) -> i32 {
        self.text_px(x, baseline, text, rgb, bold, FONT_PX)
    }

    /// Draw a string with its right edge at `right`.
    fn text_right(&mut self, right: i32, baseline: i32, text: &str, rgb: u32, bold: bool) {
        let w = self.text_width(text, bold);
        self.text(right - w, baseline, text, rgb, bold);
    }

    /// Draw a string at `px` pixels. Returns the x the pen ended at.
    fn text_px(&mut self, x: i32, baseline: i32, text: &str, rgb: u32, bold: bool, px: u32) -> i32 {
        let target = [
            ((rgb >> 16) & 0xFF) as u32,
            ((rgb >> 8) & 0xFF) as u32,
            (rgb & 0xFF) as u32,
        ];
        let mut pen = x as f32;
        for ch in text.chars() {
            let (metrics, bitmap) = self.glyph(ch, bold, px).clone();
            let left = pen as i32 + metrics.xmin;
            let top = baseline - (metrics.ymin + metrics.height as i32);
            for row in 0..metrics.height {
                for col in 0..metrics.width {
                    let coverage = bitmap[row * metrics.width + col] as u32;
                    if coverage == 0 {
                        continue;
                    }
                    let px = left + col as i32;
                    let py = top + row as i32;
                    if px < 0 || py < 0 || px >= W as i32 || py >= H as i32 {
                        continue;
                    }
                    let offset = ((py as u32 * W as u32 + px as u32) * 4) as usize;
                    let data = self.pixmap.data_mut();
                    for channel in 0..3 {
                        let under = data[offset + channel] as u32;
                        data[offset + channel] =
                            ((under * (255 - coverage) + target[channel] * coverage) / 255) as u8;
                    }
                    data[offset + 3] = 255;
                }
            }
            pen += metrics.advance_width;
        }
        pen as i32
    }

    fn rect(&mut self, x: i32, y: i32, w: i32, h: i32, rgb: u32) {
        if w <= 0 || h <= 0 {
            return;
        }
        if let Some(rect) = Rect::from_xywh(x as f32, y as f32, w as f32, h as f32) {
            self.pixmap.fill_path(
                &tiny_skia::PathBuilder::from_rect(rect),
                &solid(rgb),
                tiny_skia::FillRule::Winding,
                Transform::identity(),
                None,
            );
        }
    }

    /// A track with a filled fraction, for load and memory.
    fn bar(&mut self, x: i32, y: i32, w: i32, h: i32, fraction: f32, rgb: u32) {
        self.rect(x, y, w, h, TRACK);
        self.rect(x, y, (w as f32 * fraction.clamp(0.0, 1.0)) as i32, h, rgb);
    }
}

struct Screen {
    file: File,
    fb: Vec<u8>,
}

impl Screen {
    fn open() -> std::io::Result<Self> {
        Ok(Self {
            file: OpenOptions::new()
                .write(true)
                .custom_flags(O_RDWR)
                .open(FB_PATH)?,
            fb: vec![0; FB_STRIDE * FB_HEIGHT],
        })
    }

    /// Rotate the canvas into the framebuffer and write all of it in one go.
    fn blit(&mut self, pixmap: &Pixmap) -> std::io::Result<()> {
        let pixels = pixmap.data();
        for y in 0..H {
            for x in 0..W {
                let (fx, fy) = if ROTATE_LEFT {
                    (y, W - 1 - x)
                } else {
                    (H - 1 - y, x)
                };
                let src = (y * W + x) * 4;
                let dst = fy * FB_STRIDE + fx * 4;
                self.fb[dst] = pixels[src + 2];
                self.fb[dst + 1] = pixels[src + 1];
                self.fb[dst + 2] = pixels[src];
            }
        }
        self.file.seek(SeekFrom::Start(0))?;
        self.file.write_all(&self.fb)
    }
}

fn bind_vtcon(on: bool) {
    let _ = fs::write(VTCON_PATH, if on { "1" } else { "0" });
}

fn read_trimmed(path: &str) -> String {
    fs::read_to_string(path)
        .map(|s| s.trim().to_string())
        .unwrap_or_default()
}

fn env_map() -> HashMap<String, String> {
    let mut map = HashMap::new();
    if let Ok(text) = fs::read_to_string(format!("{RUN_DIR}/status.env")) {
        for line in text.lines() {
            if let Some((key, value)) = line.split_once('=') {
                map.insert(key.to_string(), value.to_string());
            }
        }
    }
    map
}

/// The panel's clock: UTC+8, where the person reading it lives. An offset
/// rather than a zone, so a frame never depends on the phone's tz data.
fn utc_clock() -> String {
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
        + 8 * 3600;
    let day = seconds % 86400;
    format!("{:02}:{:02}:{:02}", day / 3600, (day % 3600) / 60, day % 60)
}

struct Link {
    state: String,
    rx: u64,
    tx: u64,
}

impl Link {
    fn read(iface: &str) -> Self {
        Self {
            state: read_trimmed(&format!("/sys/class/net/{iface}/operstate")),
            rx: read_trimmed(&format!("/sys/class/net/{iface}/statistics/rx_bytes"))
                .parse()
                .unwrap_or(0),
            tx: read_trimmed(&format!("/sys/class/net/{iface}/statistics/tx_bytes"))
                .parse()
                .unwrap_or(0),
        }
    }

    fn state_or(&self, fallback: &str) -> String {
        if self.state.is_empty() {
            fallback.to_string()
        } else {
            self.state.clone()
        }
    }
}

/// The facts this program reads itself, every tick.
struct Local {
    host: String,
    uptime: String,
    load: (String, String, String, String),
    mem_used: u64,
    mem_total: u64,
    temp_max: i64,
    temp_cpu7: i64,
    temp_pmic: i64,
    cpu_freq: String,
    battery_capacity: String,
    battery_status: String,
    battery_voltage: String,
    battery_current: String,
    battery_temp: String,
    charger_online: String,
    charger_max: String,
    charger_enabled: String,
    wifi: Link,
    usb: Link,
    tailnet: Link,
}

fn sample_local() -> Local {
    let uptime_seconds: u64 = read_trimmed("/proc/uptime")
        .split('.')
        .next()
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    let load_text = read_trimmed("/proc/loadavg");
    let mut parts = load_text.split_whitespace();
    let load = (
        parts.next().unwrap_or("?").to_string(),
        parts.next().unwrap_or("?").to_string(),
        parts.next().unwrap_or("?").to_string(),
        parts.next().unwrap_or("?").to_string(),
    );

    let mut mem_total = 0u64;
    let mut mem_available = 0u64;
    if let Ok(text) = fs::read_to_string("/proc/meminfo") {
        for line in text.lines() {
            let mut field = line.split_whitespace();
            match (field.next(), field.next()) {
                (Some("MemTotal:"), Some(kb)) => mem_total = kb.parse::<u64>().unwrap_or(0) / 1024,
                (Some("MemAvailable:"), Some(kb)) => {
                    mem_available = kb.parse::<u64>().unwrap_or(0) / 1024
                }
                _ => {}
            }
        }
    }

    let mut temp_max = 0i64;
    let mut temp_cpu7 = 0i64;
    let mut temp_pmic = 0i64;
    if let Ok(entries) = fs::read_dir("/sys/class/thermal") {
        for entry in entries.flatten() {
            let base = entry.path();
            let value: i64 = fs::read_to_string(base.join("temp"))
                .ok()
                .and_then(|s| s.trim().parse().ok())
                .unwrap_or(0);
            temp_max = temp_max.max(value);
            match fs::read_to_string(base.join("type"))
                .unwrap_or_default()
                .trim()
            {
                "cpu7-top-thermal" => temp_cpu7 = value,
                "pm8150b-thermal" => temp_pmic = value,
                _ => {}
            }
        }
    }

    let frequency = |policy: &str| -> String {
        fs::read_to_string(format!(
            "/sys/devices/system/cpu/cpufreq/{policy}/scaling_cur_freq"
        ))
        .ok()
        .and_then(|s| s.trim().parse::<u64>().ok())
        .map(|khz| (khz / 1000).to_string())
        .unwrap_or_else(|| "?".to_string())
    };

    Local {
        host: read_trimmed("/proc/sys/kernel/hostname"),
        uptime: format!(
            "{}d{:02}h{:02}m",
            uptime_seconds / 86400,
            (uptime_seconds % 86400) / 3600,
            (uptime_seconds % 3600) / 60
        ),
        load,
        mem_used: mem_total.saturating_sub(mem_available),
        mem_total,
        temp_max,
        temp_cpu7,
        temp_pmic,
        cpu_freq: format!(
            "{} / {} / {} MHz",
            frequency("policy0"),
            frequency("policy4"),
            frequency("policy7")
        ),
        battery_capacity: read_trimmed("/sys/class/power_supply/qcom-battery/capacity"),
        battery_status: read_trimmed("/sys/class/power_supply/qcom-battery/status"),
        battery_voltage: read_trimmed("/sys/class/power_supply/qcom-battery/voltage_now"),
        battery_current: read_trimmed("/sys/class/power_supply/qcom-battery/current_now"),
        battery_temp: read_trimmed("/sys/class/power_supply/qcom-battery/temp"),
        charger_online: read_trimmed("/sys/class/power_supply/pm8150b-charger/online"),
        charger_max: read_trimmed("/sys/class/power_supply/pm8150b-charger/current_max"),
        charger_enabled: read_trimmed("/sys/class/power_supply/pm8150b-charger/charging_enabled"),
        wifi: Link::read("wlp1s0"),
        usb: Link::read("usb0"),
        tailnet: Link::read("tailscale0"),
    }
}

// --- layout -----------------------------------------------------------------
// Three bands, most important first. The top band is load, memory and the
// busiest process, in large type: they are read first. Under it, the supporting
// detail in four smaller columns — network, cluster, host, battery (quiet). The
// last band ranks the pods, so the numbers above are explained by what is
// spending them.
//
// Vertical rhythm: 40 px rows and 56 px from a band's last baseline to the
// next section's baseline. Five ranking rows leave a 48 px lower margin.
const MARGIN: i32 = 64;
const RIGHT: i32 = W as i32 - MARGIN;
/// Hero cells: load, memory, busiest process.
const HERO_X: [i32; 3] = [64, 816, 1568];
const HERO_W: [i32; 3] = [720, 720, 768];
const HERO_Y: i32 = 232;
const BIG_PX: u32 = 96;
const BIG_BASE: i32 = 342;
const HERO_BAR_Y: i32 = 356;
const HERO_SUB: i32 = 420;
/// Supporting detail, four columns.
const DETAIL_Y: i32 = 476;
const DETAIL_FIRST: i32 = 546;
const DETAIL_ROW: i32 = 40;
const COL_X: [i32; 4] = [64, 608, 1152, 1824];
const COL_W: [i32; 4] = [512, 512, 640, 512];
/// Pod rankings, last.
const RANK_Y: i32 = 802;
const RANK_FIRST: i32 = 872;
const RANK_ROW: i32 = 40;
const RANK_W: i32 = 1104;
const RANK_X: [i32; 2] = [MARGIN, RIGHT - RANK_W];
/// Inside a detail column: a label, then a value; a gauge sits between them.
const LABEL_W: i32 = 184;
const GAUGE_W: i32 = 120;
/// Network column: where the address starts after the state word.
const ADDR_X: i32 = 130;
const STATE_W: i32 = 112;

fn detail_y(index: i32) -> i32 {
    DETAIL_FIRST + index * DETAIL_ROW
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// A status.env value, or "n/a" when the collector left it empty.
fn field(env: &HashMap<String, String>, key: &str) -> String {
    match env.get(key).map(|v| v.trim()) {
        Some(v) if !v.is_empty() => v.to_string(),
        _ => "n/a".to_string(),
    }
}

/// Every run of decimal digits in `text`, in order.
fn numbers(text: &str) -> Vec<u64> {
    text.split(|c: char| !c.is_ascii_digit())
        .filter_map(|s| s.parse().ok())
        .collect()
}

/// A sysfs integer in some unit, divided down: 4020000 µV is 4.02 V.
fn scaled(text: &str, divide: f64) -> Option<f64> {
    text.parse::<f64>().ok().map(|v| v / divide)
}

/// Seconds as one or two units: `42s`, `29m`, `3h12m`.
fn span(seconds: u64) -> String {
    if seconds < 120 {
        format!("{seconds}s")
    } else if seconds < 7200 {
        format!("{}m", seconds / 60)
    } else {
        format!("{}h{:02}m", seconds / 3600, (seconds % 3600) / 60)
    }
}

/// A pod row from `rank_cpu` or `rank_mem`: the name and both measures as written,
/// and both as numbers for the bars.
struct Pod {
    name: String,
    cpu: String,
    mem: String,
    cpu_m: f64,
    mem_mi: f64,
}

fn ranking(list: &str) -> Vec<Pod> {
    list.split('|')
        .filter_map(|row| {
            let f: Vec<&str> = row.split_whitespace().collect();
            if f.len() < 3 {
                return None;
            }
            Some(Pod {
                name: f[0].to_string(),
                cpu: f[1].to_string(),
                mem: f[2].to_string(),
                cpu_m: millicores(f[1]),
                mem_mi: mebibytes(f[2]),
            })
        })
        .collect()
}

/// `27m` or `1` (cores) as millicores.
fn millicores(text: &str) -> f64 {
    match text.strip_suffix('m') {
        Some(n) => n.parse().unwrap_or(0.0),
        None => text.parse::<f64>().unwrap_or(0.0) * 1000.0,
    }
}

/// `28Mi`, `1Gi`, `512Ki` as MiB.
fn mebibytes(text: &str) -> f64 {
    if let Some(n) = text.strip_suffix("Gi") {
        n.parse::<f64>().unwrap_or(0.0) * 1024.0
    } else if let Some(n) = text.strip_suffix("Mi") {
        n.parse().unwrap_or(0.0)
    } else if let Some(n) = text.strip_suffix("Ki") {
        n.parse::<f64>().unwrap_or(0.0) / 1024.0
    } else {
        0.0
    }
}

/// Section name in dim caps with a hairline under it.
fn section(c: &mut Canvas, x: i32, w: i32, y: i32, name: &str) {
    c.text(x, y, name, DIM, true);
    c.rect(x, y + 20, w, 2, RULE);
}

/// A label, then a value in the shared value column, clipped to the column.
fn pair(c: &mut Canvas, x: i32, w: i32, y: i32, label: &str, value: &str, tone: u32) {
    c.text(x, y, label, DIM, false);
    let value = c.fit(value, false, w - LABEL_W);
    c.text(x + LABEL_W, y, &value, tone, false);
}

/// A label, a gauge, and a value after it, clipped to the column.
fn gauge(c: &mut Canvas, x: i32, w: i32, y: i32, label: &str, fraction: f64, fill: u32, value: &str, tone: u32) {
    c.text(x, y, label, DIM, false);
    c.bar(x + LABEL_W, y - 24, GAUGE_W, 14, fraction as f32, fill);
    let value = c.fit(value, false, w - LABEL_W - GAUGE_W - 14);
    c.text(x + LABEL_W + GAUGE_W + 14, y, &value, tone, false);
}

/// Up is quiet green, down is red, anything else is named as it is.
fn link_state(state: &str) -> (String, u32) {
    match state {
        "up" => ("up".to_string(), OK),
        "down" => ("down".to_string(), HOT),
        other => (other.to_string(), DIM),
    }
}

/// Label and value pairs run in one line.
fn flow(c: &mut Canvas, mut x: i32, y: i32, items: &[(&str, String, u32)]) {
    for (label, value, tone) in items {
        x = c.text(x, y, label, DIM, false) + 12;
        x = c.text(x, y, value, *tone, false) + 44;
    }
}

/// A pod state, shortened so that a row of counts fits a column.
fn short_state(state: &str) -> String {
    match state {
        "Running" => "run".to_string(),
        "Completed" | "Succeeded" => "done".to_string(),
        "Pending" => "pend".to_string(),
        "CrashLoopBackOff" => "crashloop".to_string(),
        "ContainerCreating" => "creating".to_string(),
        other => other.to_lowercase(),
    }
}

fn pod_counts(rows: &[(&str, &str)]) -> String {
    rows.iter()
        .map(|(count, state)| format!("{count} {}", short_state(state)))
        .collect::<Vec<_>>()
        .join("  ")
}

/// The number of a hero cell in large type, its unit beside it, a note at the right.
fn hero_number(c: &mut Canvas, x: i32, w: i32, value: &str, tone: u32, unit: &str, note: &str) {
    let end = c.text_px(x, BIG_BASE, value, tone, true, BIG_PX);
    c.text(end + 24, BIG_BASE, unit, DIM, false);
    c.text_right(x + w, BIG_BASE, note, DIM, false);
}

/// Load average against the core count: the one-minute figure is the number.
fn load_cell(c: &mut Canvas, local: &Local, cores: f64) {
    let (x, w) = (HERO_X[0], HERO_W[0]);
    section(c, x, w, HERO_Y, "LOAD");
    let one = local.load.0.parse::<f64>().ok();
    let tone = match one {
        Some(l) if l > 2.0 * cores => HOT,
        Some(l) if l > cores => WARN,
        _ => INK,
    };
    hero_number(c, x, w, &local.load.0, tone, "1m", &format!("{} cores", cores as u64));
    let fill = match one {
        Some(l) if l > cores => tone,
        _ => BAR,
    };
    c.bar(x, HERO_BAR_Y, w, 14, one.map_or(0.0, |l| (l / cores) as f32), fill);
    flow(
        c,
        x,
        HERO_SUB,
        &[("5m", local.load.1.clone(), INK), ("15m", local.load.2.clone(), INK)],
    );
}

/// Memory in use, and how much is still available.
fn memory_cell(c: &mut Canvas, local: &Local) {
    let (x, w) = (HERO_X[1], HERO_W[1]);
    section(c, x, w, HERO_Y, "MEMORY");
    let total = local.mem_total as f64 / 1024.0;
    let used = local.mem_used as f64 / 1024.0;
    let fraction = if local.mem_total > 0 {
        local.mem_used as f64 / local.mem_total as f64
    } else {
        0.0
    };
    let tone = if fraction > 0.9 { WARN } else { INK };
    hero_number(c, x, w, &format!("{used:.1}"), tone, "GiB", &format!("of {total:.1} GiB"));
    c.bar(x, HERO_BAR_Y, w, 14, fraction as f32, if fraction > 0.9 { WARN } else { BAR });
    flow(
        c,
        x,
        HERO_SUB,
        &[("available", format!("{:.1} GiB", total - used), INK)],
    );
}

/// What the CPUs are doing right now, and which process is doing most of it.
fn cpu_cell(c: &mut Canvas, env: &HashMap<String, String>) {
    let (x, w) = (HERO_X[2], HERO_W[2]);
    section(c, x, w, HERO_Y, "CPU");
    let top = field(env, "top");
    let (name, _) = top.rsplit_once(' ').unwrap_or(("n/a", top.as_str()));
    let used = field(env, "cpu_used");
    let share = used.parse::<f64>().ok();
    let hot = share.map_or(false, |p| p > 90.0);
    let pct = if used.is_empty() {
        "n/a".to_string()
    } else {
        format!("{used}%")
    };
    hero_number(c, x, w, &pct, if hot { WARN } else { INK }, "", "of all cores");
    c.bar(
        x,
        HERO_BAR_Y,
        w,
        14,
        share.map_or(0.0, |p| (p / 100.0) as f32),
        if hot { WARN } else { BAR },
    );
    flow(c, x, HERO_SUB, &[("process", name.to_string(), INK)]);
}

fn header(c: &mut Canvas, local: &Local, env: &HashMap<String, String>, age: Option<u64>) {
    let host = if local.host.is_empty() { "n/a" } else { local.host.as_str() };
    let end = c.text_px(MARGIN, 100, host, INK, true, 64);
    let after_up = c.text(end + 40, 100, &format!("up {}", local.uptime), DIM, false);
    let k3s = field(env, "k3s_short");
    let version = k3s.split_whitespace().nth(2).unwrap_or("n/a").to_string();
    flow(
        c,
        after_up + 44,
        100,
        &[("gen", field(env, "gen"), INK), ("k3s", version, INK)],
    );

    let utc_w = c.text_width("UTC+8", false);
    c.text(RIGHT - utc_w, 100, "UTC+8", DIM, false);
    let clock = utc_clock();
    let clock_w = c.width_px(&clock, true, 64);
    let clock_x = RIGHT - utc_w - 16 - clock_w;
    c.text_px(clock_x, 100, &clock, INK, true, 64);

    let (age_text, age_tone) = match age {
        Some(seconds) => {
            let tone = if seconds < 90 {
                DIM
            } else if seconds < 240 {
                WARN
            } else {
                HOT
            };
            (span(seconds), tone)
        }
        None => ("n/a".to_string(), HOT),
    };
    let label_w = c.text_width("data ", false);
    let age_w = c.text_width(&age_text, false);
    let data_x = clock_x - 48 - label_w - age_w;
    let after_label = c.text(data_x, 100, "data ", DIM, false);
    c.text(after_label, 100, &age_text, age_tone, false);

    let services = field(env, "services_ok");
    let services_tone = if services.contains("异常") || services == "n/a" { HOT } else { OK };
    let firewall = field(env, "firewall");
    let rules = numbers(&firewall).first().copied().unwrap_or(0);
    let firewall_tone = if firewall.contains("nftables ok") { OK } else { HOT };
    let watchdog = field(env, "watchdog");
    let watchdog = watchdog.split_whitespace().last().unwrap_or("n/a").to_string();
    let watchdog_tone = if watchdog.starts_with('0') || watchdog == "n/a" { WARN } else { INK };

    flow(
        c,
        MARGIN,
        152,
        &[
            ("services", services, services_tone),
            ("firewall", format!("{rules} rules"), firewall_tone),
            ("watchdog", watchdog, watchdog_tone),
        ],
    );
    c.rect(MARGIN, 180, RIGHT - MARGIN, 2, RULE);
}

/// Battery and charger: values in the same ink as everything else, with the
/// charger named by what the port actually negotiated.
fn power(c: &mut Canvas, local: &Local, env: &HashMap<String, String>, x: i32, w: i32) {
    section(c, x, w, DETAIL_Y, "POWER");
    let capacity = local.battery_capacity.parse::<i64>().ok();
    let level = capacity.map_or_else(|| "n/a".to_string(), |p| format!("{p}%"));
    pair(c, x, w, detail_y(0), "battery", &level, INK);
    let held = local.charger_enabled == "0";
    pair(c, x, w, detail_y(1), "charge", if held { "held" } else { "on" }, INK);
    let volts = scaled(&local.battery_voltage, 1e6)
        .map_or_else(|| "n/a".to_string(), |v| format!("{v:.2} V"));
    pair(c, x, w, detail_y(2), "voltage", &volts, INK);
    let amps = scaled(&local.battery_current, 1e6)
        .map_or_else(|| "n/a".to_string(), |a| format!("{:.2} A", a.abs()));
    pair(c, x, w, detail_y(3), "current", &amps, INK);
    let temp = scaled(&local.battery_temp, 10.0)
        .map_or_else(|| "n/a".to_string(), |t| format!("{t:.1} °C"));
    pair(c, x, w, detail_y(4), "temp", &temp, INK);
    let charger = field(env, "charger");
    pair(c, x, w, detail_y(5), "charger", &charger, INK);
}

/// Temperatures, clocks, tasks and the disk.
fn host(c: &mut Canvas, local: &Local, env: &HashMap<String, String>, x: i32, w: i32) {
    section(c, x, w, DETAIL_Y, "HOST");
    let temps = [
        ("hottest", local.temp_max),
        ("cpu7", local.temp_cpu7),
        ("pmic", local.temp_pmic),
    ];
    for (i, (label, milli)) in temps.iter().enumerate() {
        let y = detail_y(i as i32);
        if *milli == 0 {
            pair(c, x, w, y, label, "n/a", DIM);
            continue;
        }
        let degrees = *milli as f64 / 1000.0;
        let fill = if degrees >= 75.0 {
            HOT
        } else if degrees >= 60.0 {
            WARN
        } else {
            BAR
        };
        gauge(c, x, w, y, label, degrees / 90.0, fill, &format!("{degrees:.1}°C"), INK);
    }
    let mhz = local.cpu_freq.trim_end_matches(" MHz").replace(" / ", "/");
    pair(c, x, w, detail_y(3), "MHz", &mhz, INK);
    let (running, total) = local.load.3.split_once('/').unwrap_or(("n/a", "n/a"));
    pair(c, x, w, detail_y(4), "tasks", &format!("{running} / {total}"), INK);
    let disk = field(env, "disk").replace(" (", " ").replace(')', "");
    pair(c, x, w, detail_y(5), "disk", &disk, INK);
}

/// Three links: each a state and an address, with its throughput under it.
fn network(c: &mut Canvas, local: &Local, env: &HashMap<String, String>, rates: &[(f32, f32); 3], x: i32, w: i32) {
    section(c, x, w, DETAIL_Y, "NETWORK");
    let tailnet = field(env, "tailnet");
    let backend = tailnet.split_whitespace().next().unwrap_or("n/a").to_string();
    let tailnet_state = if backend == "Running" {
        ("up".to_string(), OK)
    } else {
        (backend, HOT)
    };
    let links: [(&str, (String, u32), String); 3] = [
        ("wifi", link_state(&local.wifi.state_or("n/a")), field(env, "wifi_addr")),
        ("usb", link_state(&local.usb.state_or("n/a")), field(env, "usb_addr")),
        ("tailnet", tailnet_state, field(env, "ts_addr")),
    ];
    for (i, (name, (state, tone), addr)) in links.iter().enumerate() {
        let y = detail_y(2 * i as i32);
        c.text(x, y, name, DIM, false);
        let state = c.fit(state, false, STATE_W);
        c.text(x + LABEL_W, y, &state, *tone, false);
        c.text(x + LABEL_W + ADDR_X, y, addr, INK, false);
        let (rx, tx) = rates[i];
        c.text(
            x + LABEL_W,
            detail_y(2 * i as i32 + 1),
            &format!("↓ {rx:.2}  ↑ {tx:.2} MiB/s"),
            DIM,
            false,
        );
    }
}

/// k3s, node, deployments, tailscale peers, and pods by state.
fn cluster(c: &mut Canvas, env: &HashMap<String, String>, x: i32, w: i32) {
    section(c, x, w, DETAIL_Y, "CLUSTER");

    let k3s = field(env, "k3s_short");
    let k3s_tokens: Vec<&str> = k3s.split_whitespace().collect();
    let (k3s_state, k3s_tone) = match k3s_tokens.as_slice() {
        ["readyz", "ok", ..] => ("ready", OK),
        ["readyz", ..] => ("not ready", HOT),
        _ => (k3s.as_str(), HOT),
    };
    pair(c, x, w, detail_y(0), "k3s", k3s_state, k3s_tone);

    let nodes = field(env, "nodes_short");
    let node_tokens: Vec<&str> = nodes.split_whitespace().collect();
    let node_states: Vec<(&str, &str)> = node_tokens
        .chunks(2)
        .filter_map(|p| match p {
            [name, status] => Some((*name, *status)),
            _ => None,
        })
        .collect();
    let node_tone = if !node_states.is_empty() && node_states.iter().all(|(_, s)| *s == "Ready") {
        OK
    } else {
        HOT
    };
    let node_text = node_states
        .iter()
        .map(|(name, status)| format!("{name} {status}"))
        .collect::<Vec<_>>()
        .join(", ");
    let node_text = if node_text.is_empty() { "n/a".to_string() } else { node_text };
    pair(c, x, w, detail_y(1), "node", &node_text, node_tone);

    let detail = field(env, "k3s_detail");
    let deploys: Vec<(u64, u64)> = detail
        .split_whitespace()
        .filter(|t| t.contains('/') && t.chars().all(|ch| ch.is_ascii_digit() || ch == '/'))
        .filter_map(|t| {
            let (ready, want) = t.split_once('/')?;
            Some((ready.parse::<u64>().ok()?, want.parse::<u64>().ok()?))
        })
        .collect();
    let ready = deploys.iter().filter(|(a, b)| a == b).count();
    let deploy_tone = if !deploys.is_empty() && ready == deploys.len() { OK } else { WARN };
    pair(
        c,
        x,
        w,
        detail_y(2),
        "deploys",
        &format!("{ready}/{} ready", deploys.len()),
        deploy_tone,
    );

    let tailnet = field(env, "tailnet");
    match numbers(&tailnet).as_slice() {
        [total, online, ..] => {
            let fraction = *online as f64 / (*total).max(1) as f64;
            gauge(c, x, w, detail_y(3), "peers", fraction, BAR, &format!("{online}/{total}"), INK);
        }
        _ => pair(c, x, w, detail_y(3), "peers", "n/a", DIM),
    }

    let pods = field(env, "pods_short");
    let counts: Vec<(&str, &str)> = pods
        .split_whitespace()
        .collect::<Vec<_>>()
        .chunks(2)
        .filter_map(|p| match p {
            [count, state] => Some((*count, *state)),
            _ => None,
        })
        .collect();
    let (healthy, problems): (Vec<(&str, &str)>, Vec<(&str, &str)>) = counts
        .into_iter()
        .partition(|(_, s)| matches!(*s, "Running" | "Completed" | "Succeeded"));
    if problems.is_empty() {
        let text = if healthy.is_empty() {
            "n/a".to_string()
        } else {
            pod_counts(&healthy)
        };
        pair(c, x, w, detail_y(4), "pods", &text, if healthy.is_empty() { DIM } else { INK });
    } else {
        let worst = if problems.iter().all(|(_, s)| matches!(*s, "Pending" | "ContainerCreating")) {
            WARN
        } else {
            HOT
        };
        pair(c, x, w, detail_y(4), "pods", &pod_counts(&problems), worst);
        if !healthy.is_empty() {
            pair(c, x, w, detail_y(5), "", &pod_counts(&healthy), DIM);
        }
    }
}

/// Pod rankings across the middle band: the same pods sorted by CPU on the left,
/// by memory on the right, each with a bar for the sorted measure.
fn rankings(c: &mut Canvas, env: &HashMap<String, String>) {
    let by_cpu = ranking(&field(env, "rank_cpu"));
    let by_mem = ranking(&field(env, "rank_mem"));
    for (x, pods, by_mem_table) in [(RANK_X[0], &by_cpu, false), (RANK_X[1], &by_mem, true)] {
        section(c, x, RANK_W, RANK_Y, if by_mem_table { "PODS BY MEMORY" } else { "PODS BY CPU" });
        c.text_right(x + RANK_W - 230, RANK_Y, "cpu", DIM, false);
        c.text_right(x + RANK_W, RANK_Y, "mem", DIM, false);
        rank_table(c, x, pods, by_mem_table);
    }
}

fn rank_table(c: &mut Canvas, x: i32, pods: &[Pod], by_mem: bool) {
    if pods.is_empty() {
        c.text(x, RANK_FIRST, "no pod metrics", DIM, false);
        return;
    }
    let metric = |p: &Pod| if by_mem { p.mem_mi } else { p.cpu_m };
    let max = pods.iter().map(metric).fold(0.0, f64::max);
    for (i, pod) in pods.iter().take(6).enumerate() {
        let y = RANK_FIRST + i as i32 * RANK_ROW;
        let name = c.fit(&pod.name, false, 540);
        c.text(x, y, &name, INK, false);
        let share = if max > 0.0 { metric(pod) / max } else { 0.0 };
        c.bar(x + 580, y - 22, 130, 12, share as f32, BAR);
        let (cpu_tone, mem_tone) = if by_mem { (DIM, INK) } else { (INK, DIM) };
        c.text_right(x + RANK_W - 230, y, &pod.cpu, cpu_tone, false);
        c.text_right(x + RANK_W, y, &pod.mem, mem_tone, false);
    }
}

/// Draw one frame. This function is the whole interface: whatever it paints is
/// what the phone shows.
///
/// Available to you:
///   canvas — `clear`, `text`, `text_px`, `text_right`, `text_width`, `width_px`,
///            `fit`, `rect`, `bar`; colour is 0xRRGGBB
///   local  — the device facts read straight off /proc and /sys (struct `Local`)
///   env    — the collector's `status.env` key/values, see `collect.sh`
///   rates  — last measured (rx, tx) MiB/s, in the order wifi, usb, tailnet
///   sample_age — seconds since the collector took its sample; when the caller
///            has none, it is worked out from `sample_epoch` in env
fn draw(
    canvas: &mut Canvas,
    local: &Local,
    env: &HashMap<String, String>,
    rates: &[(f32, f32); 3],
    sample_age: Option<u64>,
) {
    canvas.clear();
    let cores = std::thread::available_parallelism()
        .map(|n| n.get() as f64)
        .unwrap_or(1.0);
    let age = sample_age.or_else(|| {
        env.get("sample_epoch")
            .and_then(|s| s.parse::<u64>().ok())
            .map(|epoch| unix_now().saturating_sub(epoch))
    });

    header(canvas, local, env, age);
    load_cell(canvas, local, cores);
    memory_cell(canvas, local);
    cpu_cell(canvas, env);
    rankings(canvas, env);
    power(canvas, local, env, COL_X[0], COL_W[0]);
    host(canvas, local, env, COL_X[1], COL_W[1]);
    network(canvas, local, env, rates, COL_X[2], COL_W[2]);
    cluster(canvas, env, COL_X[3], COL_W[3]);
}

/// Read a status.env-style file: the collector's own format, so a copy of the
/// phone's file renders the phone's panel on a workstation.
fn read_status_file(path: &str) -> HashMap<String, String> {
    fs::read_to_string(path)
        .map(|text| {
            text.lines()
                .filter_map(|line| line.split_once('='))
                .map(|(key, value)| (key.to_string(), value.to_string()))
                .collect::<HashMap<String, String>>()
        })
        .unwrap_or_default()
}

/// The screenshot writer, so a frame can be looked at off the device.
mod png;

fn main() {
    // `--png <path>` renders one frame to an image and exits — the way the
    // layout is checked on a workstation, where there is no /dev/fb0 to own.
    let args: Vec<String> = std::env::args().skip(1).collect();
    let png_path = args
        .iter()
        .position(|a| a == "--png")
        .and_then(|index| args.get(index + 1))
        .cloned();
    let once = args.first().map(|a| a == "--once").unwrap_or(false);
    let hold = if once {
        args.get(1).and_then(|s| s.parse::<u64>().ok()).unwrap_or(20)
    } else {
        0
    };

    let font_dir = std::env::var("ALIOTH_PANEL_FONT_DIR").unwrap_or_default();
    let find_font = |name: &str| -> Option<Vec<u8>> {
        let candidates = [
            format!("{font_dir}/{name}"),
            format!("/run/current-system/sw/share/fonts/truetype/{name}"),
            format!("/run/current-system/sw/share/fonts/{name}"),
        ];
        candidates.iter().find_map(|path| fs::read(path).ok())
    };
    let regular = match find_font("MapleMono-NF-CN-Regular.ttf") {
        Some(bytes) => bytes,
        None => {
            eprintln!("alioth-panel: MapleMono-NF-CN-Regular.ttf not found (set ALIOTH_PANEL_FONT_DIR)");
            std::process::exit(1);
        }
    };
    let bold = find_font("MapleMono-NF-CN-Bold.ttf").unwrap_or_else(|| regular.clone());

    let mut canvas = match Canvas::new(&regular, &bold) {
        Ok(canvas) => canvas,
        Err(error) => {
            eprintln!("alioth-panel: {error}");
            std::process::exit(1);
        }
    };

    if let Some(path) = png_path {
        let local = sample_local();
        let env = match std::env::var("ALIOTH_PANEL_STATUS") {
            Ok(status) => read_status_file(&status),
            Err(_) => env_map(),
        };
        draw(&mut canvas, &local, &env, &[(0.0, 0.0); 3], None);
        match png::write(&path, W as u32, H as u32, canvas.pixmap.data()) {
            Ok(()) => println!("alioth-panel: wrote {path}"),
            Err(error) => {
                eprintln!("alioth-panel: {error}");
                std::process::exit(1);
            }
        }
        return;
    }

    let mut screen = match Screen::open() {
        Ok(screen) => screen,
        Err(error) => {
            eprintln!("alioth-panel: cannot open {FB_PATH}: {error}");
            std::process::exit(1);
        }
    };

    let _ = fs::create_dir_all(RUN_DIR);
    bind_vtcon(false);

    let started = Instant::now();
    let mut previous = Instant::now();
    let mut counters: [(u64, u64); 3] = [(0, 0); 3];
    let mut rates: [(f32, f32); 3] = [(0.0, 0.0); 3];
    let mut frames: u64 = 0;

    loop {
        let local = sample_local();
        let env = env_map();

        // Throughput since the last tick, in MiB/s.
        let elapsed = Instant::now().duration_since(previous).as_secs_f32().max(0.5);
        let links = [&local.wifi, &local.usb, &local.tailnet];
        for (index, link) in links.iter().enumerate() {
            let (previous_rx, previous_tx) = counters[index];
            if frames > 0 {
                let delta_rx = link.rx.saturating_sub(previous_rx) as f32;
                let delta_tx = link.tx.saturating_sub(previous_tx) as f32;
                rates[index] = (
                    delta_rx / 1_048_576.0 / elapsed,
                    delta_tx / 1_048_576.0 / elapsed,
                );
            }
            counters[index] = (link.rx, link.tx);
        }
        previous = Instant::now();

        let sample_age = env
            .get("sample_epoch")
            .and_then(|s| s.parse::<u64>().ok())
            .map(|epoch| {
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map(|now| now.as_secs().saturating_sub(epoch))
                    .unwrap_or(0)
            });

        draw(&mut canvas, &local, &env, &rates, sample_age);

        if let Err(error) = screen.blit(&canvas.pixmap) {
            eprintln!("alioth-panel: cannot write {FB_PATH}: {error}");
            bind_vtcon(true);
            std::process::exit(1);
        }
        frames += 1;
        let _ = fs::write(
            Path::new(RUN_DIR).join("geometry"),
            format!("{W}x{H} canvas, font {FONT_PX} px, frames {frames}\n"),
        );

        if once && started.elapsed() >= Duration::from_secs(hold) {
            break;
        }
        // The preview ticks at the panel's own pace rather than spinning: the
        // frame is the same size either way, and a phone is not a space heater.
        sleep(Duration::from_secs(2));
    }

    bind_vtcon(true);
}
