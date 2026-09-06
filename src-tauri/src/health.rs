// Health, config, and integrity.
//
// Everything in here answers a question you would otherwise answer by
// running a command and reading a file: is pwsh installed, is yt-dlp current,
// which CONFIG_VERSION is installed, do this video's checksums still verify.
//
// Deliberately read-only. Nothing here installs, updates, or repairs
// anything: `yt-dlp -U` is run by run_ytdlp.ps1's own once-per-24h dependency
// check, and a second updater racing it from a GUI is exactly the kind of
// shared-state collision the pipeline spent v0.71 removing. The buttons this
// pane offers either read something or open a terminal command for you to
// run yourself.

use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use serde::Serialize;
use sha2::{Digest, Sha256};

use crate::paths;
use crate::pipeline::now_secs;

#[derive(Serialize, Clone, Debug)]
pub struct Dependency {
    pub name: &'static str,
    pub found: bool,
    pub path: Option<String>,
    pub version: Option<String>,
    /// required | recommended | optional
    pub importance: &'static str,
    pub note: &'static str,
}

fn first_line(s: &str) -> String {
    s.lines().next().unwrap_or("").trim().to_string()
}

/// How long a `--version` call gets before it is killed.
///
/// Not defensiveness: `yt-dlp --version` on a machine whose network is being
/// filtered, and `pwsh --version` with a slow profile on a network drive, can
/// both sit for a long time, and a Health page that hangs on one of them is
/// indistinguishable from a Health page that is broken. A probe that overruns
/// reports the tool as found with no version rather than blocking the pane.
const PROBE_TIMEOUT: Duration = Duration::from_secs(8);

fn version_of(exe: &Path, args: &[&str]) -> Option<String> {
    let mut child = Command::new(exe)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .ok()?;

    // try_wait rather than wait: there is no timeout in std::process, and
    // every one of these tools writes well under a pipe buffer's worth of
    // output for --version, so nothing can deadlock on an unread pipe while
    // this polls.
    let deadline = Instant::now() + PROBE_TIMEOUT;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) => {
                if Instant::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    return None;
                }
                std::thread::sleep(Duration::from_millis(20));
            }
            Err(_) => return None,
        }
    }

    let out = child.wait_with_output().ok()?;
    let text = if out.stdout.is_empty() {
        String::from_utf8_lossy(&out.stderr).to_string()
    } else {
        String::from_utf8_lossy(&out.stdout).to_string()
    };
    let line = first_line(&text);
    if line.is_empty() {
        None
    } else {
        Some(line)
    }
}

type DepSpec = (
    &'static str,
    &'static str,
    &'static [&'static str],
    &'static str,
    &'static str,
);

/// The probe result, with the time it was taken. Seven `--version` calls cost
/// seconds -- pwsh and yt-dlp are the better part of one each on their own --
/// and the Health pane is opened far more often than a toolchain changes, so
/// the answer is kept and re-used until it is either stale or explicitly
/// refreshed.
/// Unix seconds the probe was taken, and what it found.
type DepProbe = Option<(i64, Vec<Dependency>)>;

fn dep_cache() -> &'static Mutex<DepProbe> {
    static CACHE: OnceLock<Mutex<DepProbe>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(None))
}

const DEP_TTL_SECS: i64 = 300;

/// `force` is the Refresh button: it skips the cache and re-probes, which is
/// what someone who has just installed a missing dependency expects that
/// button to do.
pub fn dependencies(force: bool) -> Vec<Dependency> {
    if !force {
        if let Some((at, deps)) = dep_cache().lock().unwrap().as_ref() {
            if now_secs().saturating_sub(*at) < DEP_TTL_SECS {
                return deps.clone();
            }
        }
    }
    let deps = probe_dependencies();
    *dep_cache().lock().unwrap() = Some((now_secs(), deps.clone()));
    deps
}

/// Probe every tool at once. These are seven independent subprocess spawns
/// with nothing shared between them, so running them one after another simply
/// added up their latencies -- the whole cost of the Health page's first paint
/// used to be this loop.
fn probe_dependencies() -> Vec<Dependency> {
    let handles: Vec<_> = DEP_SPECS
        .iter()
        .map(|spec| {
            let spec: DepSpec = *spec;
            std::thread::spawn(move || probe_one(spec))
        })
        .collect();

    // Collected in spawn order, so the table does not reshuffle itself
    // depending on which tool answered first.
    handles
        .into_iter()
        .filter_map(|h| h.join().ok())
        .collect()
}

fn probe_one(spec: DepSpec) -> Dependency {
    let (name, importance, args, _label, note) = spec;
    let found = paths::which(name).or_else(|| {
        if name == "pwsh" {
            paths::find_pwsh()
        } else if name == "python3" {
            paths::which("python")
        } else {
            None
        }
    });
    Dependency {
        name,
        found: found.is_some(),
        version: found.as_deref().and_then(|p| version_of(p, args)),
        path: found.map(|p| p.to_string_lossy().to_string()),
        importance,
        note,
    }
}

const DEP_SPECS: &[DepSpec] = &[
    (
        "pwsh",
        "required",
        &["--version"],
        "PowerShell 7",
        "Every stage of the pipeline is a PowerShell 7 script. Without it nothing downloads.",
    ),
    (
        "yt-dlp",
        "required",
        &["--version"],
        "yt-dlp",
        "Does all the actual extraction. run_ytdlp.ps1 runs `yt-dlp -U` on a 24h throttle.",
    ),
    (
        "ffmpeg",
        "required",
        &["-version"],
        "ffmpeg",
        "Merging, embedding, thumbnails, and this app's playback remuxes.",
    ),
    (
        "ffprobe",
        "recommended",
        &["-version"],
        "ffprobe",
        "Without it, playback falls back to guessing that an .mkv is WebM-compatible.",
    ),
    (
        "deno",
        "recommended",
        &["--version"],
        "Deno",
        "YouTube's JS challenge needs a JS runtime. Its absence usually shows up as \
         mid-download HTTP 403s rather than an obvious error.",
    ),
    (
        "node",
        "optional",
        &["--version"],
        "Node.js",
        "Runtime for the PO token provider server.",
    ),
    (
        "python3",
        "optional",
        &["--version"],
        "Python 3",
        "Runs archive-viewer.py and installs the PO token plugin.",
    ),
];

#[derive(Serialize, Clone, Debug)]
pub struct InstalledFile {
    pub name: String,
    pub path: String,
    pub present: bool,
    pub size: u64,
    pub modified: Option<i64>,
}

fn stat_file(path: PathBuf, name: &str) -> InstalledFile {
    let md = std::fs::metadata(&path).ok();
    InstalledFile {
        name: name.to_string(),
        present: md.is_some(),
        size: md.as_ref().map(|m| m.len()).unwrap_or(0),
        modified: md
            .as_ref()
            .and_then(|m| m.modified().ok())
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_secs() as i64),
        path: path.to_string_lossy().to_string(),
    }
}

/// The repo holds the sources; the installer copies them to their runtime
/// locations. Editing a file in a clone has no effect on a live install until
/// it is copied over, which is exactly the confusion this list exists to
/// settle -- it reports what is INSTALLED, never what is in a checkout.
pub fn installed_files() -> Vec<InstalledFile> {
    let s = paths::scripts_dir();
    let c = paths::configs_dir();
    vec![
        stat_file(s.join("run_ytdlp.ps1"), "run_ytdlp.ps1"),
        stat_file(s.join("postprocess.ps1"), "postprocess.ps1"),
        stat_file(s.join("ytdl.ps1"), "ytdl.ps1"),
        stat_file(s.join("pot-provider.ps1"), "pot-provider.ps1"),
        stat_file(s.join("archive-viewer.py"), "archive-viewer.py"),
        stat_file(c.join("yt-dlp.conf"), "yt-dlp.conf"),
    ]
}

#[derive(Serialize, Clone, Debug)]
pub struct ConfigInfo {
    pub path: String,
    pub present: bool,
    pub config_version: Option<String>,
    pub body: String,
    pub option_count: usize,
}

/// CONFIG_VERSION is recorded in manifest.json and download.log by both
/// scripts, so the number shown here is the one those files will carry.
pub fn config_info() -> ConfigInfo {
    let path = paths::configs_dir().join("yt-dlp.conf");
    let body = std::fs::read_to_string(&path).unwrap_or_default();
    let version = body.lines().find_map(|l| {
        l.trim()
            .strip_prefix("# CONFIG_VERSION:")
            .map(|v| v.trim().to_string())
    });
    let option_count = body
        .lines()
        .filter(|l| l.trim_start().starts_with("--"))
        .count();
    ConfigInfo {
        present: path.is_file(),
        path: path.to_string_lossy().to_string(),
        config_version: version,
        option_count,
        body,
    }
}

#[derive(Serialize, Clone, Debug, Default)]
pub struct PotStatus {
    pub script_present: bool,
    pub root: String,
    pub server_built: bool,
    pub state: Option<serde_json::Value>,
    pub pid_file: bool,
    pub log_tail: String,
}

/// Mirrors Get-PotPaths in pot-provider.ps1. Read-only: starting and stopping
/// the provider is run_ytdlp.ps1's job, since it is the thing that knows
/// whether a session wants PO tokens at all.
pub fn pot_status() -> PotStatus {
    let root = paths::install_root().join("pot-provider");
    let tail = tail_lines(&root.join("pot-server.log"), 40, 64 * 1024);
    PotStatus {
        script_present: paths::scripts_dir().join("pot-provider.ps1").is_file(),
        server_built: root.join("server").join("build").join("main.js").is_file(),
        state: std::fs::read_to_string(root.join("pot-state.json"))
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok()),
        pid_file: root.join("pot-server.pid").is_file(),
        log_tail: tail,
        root: root.to_string_lossy().to_string(),
    }
}

#[derive(Serialize, Clone, Debug, Default)]
pub struct ArchiveStats {
    pub archive_root: Option<String>,
    pub data_root: String,
    pub videos: usize,
    pub channels: usize,
    pub total_bytes: u64,
    pub global_manifest_entries: Option<usize>,
    pub archive_txt_ids: Option<usize>,
    pub log_dir: String,
    pub history_snapshots: usize,
}

pub fn archive_stats(data_root: &Path, videos: usize, channels: usize, total_bytes: u64) -> ArchiveStats {
    let logs = data_root.join("Archive Logs").join("Logs");
    let history = data_root.join("Archive Logs").join("Archive History");
    let global = data_root.join("Youtube Videos").join("global_manifest.json");

    let global_entries = std::fs::read_to_string(&global)
        .ok()
        .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
        .and_then(|v| match v {
            serde_json::Value::Array(a) => Some(a.len()),
            // A single-video archive serialises as one object, not a
            // one-element array -- ConvertTo-Json unrolls it. Counting that
            // as zero would be wrong in exactly the case a new user sees.
            serde_json::Value::Object(_) => Some(1),
            _ => None,
        });

    let archive_ids = std::fs::read_to_string(logs.join("archive.txt"))
        .ok()
        .map(|s| s.lines().filter(|l| !l.trim().is_empty()).count());

    ArchiveStats {
        archive_root: None,
        data_root: data_root.to_string_lossy().to_string(),
        videos,
        channels,
        total_bytes,
        global_manifest_entries: global_entries,
        archive_txt_ids: archive_ids,
        history_snapshots: std::fs::read_dir(&history)
            .map(|rd| rd.flatten().count())
            .unwrap_or(0),
        log_dir: logs.to_string_lossy().to_string(),
    }
}

#[derive(Serialize, Clone, Debug)]
pub struct ChecksumResult {
    pub checked: usize,
    pub ok: usize,
    pub failed: Vec<String>,
    pub missing: Vec<String>,
    pub present: bool,
}

/// Verify a video folder against its own checksums.sha256.
///
/// The file is standard sha256sum format ("<hash>  <relative/path>"), written
/// by postprocess.ps1 over every file in the folder EXCEPT
/// Logs/video_postprocessing.log -- which is excluded because it is still
/// being appended to at the moment the hashes are computed, and a manifest
/// that always reports one failure teaches you to ignore its failures.
pub fn verify_checksums(video_dir: &Path) -> ChecksumResult {
    let file = video_dir.join("Video metadata").join("checksums.sha256");
    let Ok(body) = std::fs::read_to_string(&file) else {
        return ChecksumResult {
            checked: 0,
            ok: 0,
            failed: Vec::new(),
            missing: Vec::new(),
            present: false,
        };
    };
    let mut checked = 0;
    let mut ok = 0;
    let mut failed = Vec::new();
    let mut missing = Vec::new();

    for line in body.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let Some((hash, rel)) = line.split_once("  ") else { continue };
        let path = video_dir.join(rel.replace('/', std::path::MAIN_SEPARATOR_STR));
        checked += 1;
        if !path.is_file() {
            missing.push(rel.to_string());
            continue;
        }
        match sha256_file(&path) {
            Some(actual) if actual.eq_ignore_ascii_case(hash) => ok += 1,
            _ => failed.push(rel.to_string()),
        }
    }
    ChecksumResult { checked, ok, failed, missing, present: true }
}

fn sha256_file(path: &Path) -> Option<String> {
    let mut fh = std::fs::File::open(path).ok()?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 1024 * 1024];
    loop {
        let n = fh.read(&mut buf).ok()?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Some(hasher.finalize().iter().map(|b| format!("{:02x}", b)).collect())
}

/// The tail of download.log, for the "what happened last time" panel. Not
/// parsed: this file is the pipeline's own record and the GUI has no business
/// interpreting more of it than the session summary line it already reads
/// while a run is live.
pub fn log_tail(path: &Path, lines: usize) -> String {
    tail_lines(path, lines, 1024 * 1024)
}

/// The last `lines` lines of a file, without reading the file.
///
/// download.log is appended to by every run and never rotated by the
/// pipeline, so on a machine that has been archiving for a while it is the
/// largest thing the Health page touches. Reading it whole to keep the last
/// 300 lines meant the pane's cost grew with the age of the install, for a
/// panel whose content is fixed-size. This seeks to the last `max_bytes` and
/// works backwards from there instead, so the cost is constant.
///
/// The first line of that window is dropped when the window did not start at
/// the beginning of the file, because it is almost certainly half a line.
fn tail_lines(path: &Path, lines: usize, max_bytes: u64) -> String {
    let Ok(mut fh) = std::fs::File::open(path) else {
        return String::new();
    };
    let Ok(md) = fh.metadata() else {
        return String::new();
    };
    let start = md.len().saturating_sub(max_bytes);
    if fh.seek(SeekFrom::Start(start)).is_err() {
        return String::new();
    }
    let mut buf = Vec::new();
    if fh.read_to_end(&mut buf).is_err() {
        return String::new();
    }
    let text = String::from_utf8_lossy(&buf).into_owned();
    let window = if start > 0 {
        match text.find('\n') {
            Some(i) => &text[i + 1..],
            None => "",
        }
    } else {
        text.as_str()
    };
    let all: Vec<&str> = window.lines().collect();
    let from = all.len().saturating_sub(lines);
    all[from..].join("\n")
}
