//! Everything vessel observes about a firstmate home, read only.
//!
//! Sources, all documented firstmate contracts:
//! - `state/fleet-ledger.jsonl` (history; `docs/fleet-ledger.md`)
//! - `bin/fm-fleet-snapshot.sh --json` (current state; `fm-fleet-snapshot.v1`)
//! - `bin/fm-peek.sh <task>` (bounded pane tail)
//! - `state/.last-watcher-beat` and `state/.afk` (supervision liveness)
//! - `data/<task>/brief.md` and `report.md`
//! - `data/vessel/runs.jsonl` (vessel's own run records)

pub(crate) mod ledger;
pub(crate) mod runs;
pub(crate) mod session;
pub(crate) mod snapshot;

use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
    sync::mpsc::{self, Receiver, TryRecvError},
    thread,
    time::{Duration, Instant, SystemTime},
};

use ledger::Ledger;
use runs::{Run, RunRecord, build_runs, load_run_records};
use snapshot::{Snapshot, load_snapshot};

use crate::config::Config;

const STAT_INTERVAL: Duration = Duration::from_secs(1);
const SNAPSHOT_MIN_INTERVAL: Duration = Duration::from_secs(5);
const SNAPSHOT_FALLBACK_INTERVAL: Duration = Duration::from_secs(30);
const PEEK_INTERVAL: Duration = Duration::from_secs(2);
/// firstmate's watcher polls every `FM_POLL` (15 s by default); allow a few misses.
const WATCHER_STALE_AFTER: Duration = Duration::from_secs(90);

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) enum WatcherStatus {
    #[default]
    Unknown,
    Alive,
    Stale(Duration),
    Absent,
}

#[derive(Default)]
pub(crate) enum SnapshotState {
    #[default]
    Loading,
    Ready(Snapshot),
    Error(String),
}

pub(crate) struct Peek {
    pub(crate) task: String,
    pub(crate) text: Result<String, String>,
    receiver: Option<Receiver<Result<String, String>>>,
    requested_at: Option<Instant>,
}

pub(crate) struct Fleet {
    home: PathBuf,
    root: PathBuf,
    state_dir: PathBuf,
    runs_file: PathBuf,
    pub(crate) ledger: Ledger,
    pub(crate) ledger_enabled: bool,
    pub(crate) snapshot: SnapshotState,
    snapshot_rx: Option<Receiver<Result<Snapshot, String>>>,
    snapshot_started: Option<Instant>,
    snapshot_wanted: bool,
    pub(crate) records: Vec<RunRecord>,
    records_modified: Option<SystemTime>,
    state_modified: Option<SystemTime>,
    last_stat: Option<Instant>,
    pub(crate) runs: Vec<Run>,
    pub(crate) watcher: WatcherStatus,
    pub(crate) afk: Option<String>,
    pub(crate) notice: Option<String>,
    pub(crate) peek: Option<Peek>,
    pub(crate) refreshed_at: Option<Instant>,
}

impl Default for Fleet {
    fn default() -> Self {
        Self::new(&Config::default())
    }
}

impl Fleet {
    pub(crate) fn new(config: &Config) -> Self {
        Self {
            home: config.fm_home.clone(),
            root: config.fm_root.clone(),
            state_dir: config.state_dir(),
            runs_file: config.runs_file(),
            ledger: Ledger::new(config.ledger_file()),
            ledger_enabled: config.ledger_enabled(),
            snapshot: SnapshotState::Loading,
            snapshot_rx: None,
            snapshot_started: None,
            snapshot_wanted: true,
            records: Vec::new(),
            records_modified: None,
            state_modified: None,
            last_stat: None,
            runs: Vec::new(),
            watcher: WatcherStatus::Unknown,
            afk: None,
            notice: None,
            peek: None,
            refreshed_at: None,
        }
    }

    pub(crate) fn request_refresh(&mut self) {
        self.snapshot_wanted = true;
        self.snapshot_started = None;
    }

    pub(crate) fn run(&self, task: &str) -> Option<&Run> {
        self.runs.iter().find(|run| run.task == task)
    }

    pub(crate) fn snapshot(&self) -> Option<&Snapshot> {
        match &self.snapshot {
            SnapshotState::Ready(snapshot) => Some(snapshot),
            _ => None,
        }
    }

    pub(crate) fn document(&self, task: &str, name: &str) -> Option<String> {
        fs::read_to_string(self.home.join("data").join(task).join(name)).ok()
    }

    /// Advances every source; returns whether anything visible changed.
    pub(crate) fn tick(&mut self) -> bool {
        let mut changed = self.receive_snapshot();
        let due = self
            .last_stat
            .is_none_or(|last| last.elapsed() >= STAT_INTERVAL);
        if due {
            self.last_stat = Some(Instant::now());
            changed |= self.stat_sources();
        }
        self.start_snapshot_if_due();
        changed |= self.update_peek();
        if changed {
            self.rebuild();
        }
        changed
    }

    fn stat_sources(&mut self) -> bool {
        let mut changed = false;
        match self.ledger.poll() {
            Ok(true) => {
                changed = true;
                self.snapshot_wanted = true;
            }
            Ok(false) => {}
            Err(message) => self.notice = Some(message),
        }
        let records_modified = modified(&self.runs_file);
        if records_modified != self.records_modified {
            self.records_modified = records_modified;
            match load_run_records(&self.runs_file) {
                Ok(records) => self.records = records,
                Err(message) => self.notice = Some(message),
            }
            changed = true;
        }
        let state_modified = modified(&self.state_dir);
        if state_modified != self.state_modified {
            self.state_modified = state_modified;
            self.snapshot_wanted = true;
        }
        let watcher = watcher_status(&self.state_dir);
        let afk = fs::read_to_string(self.state_dir.join(".afk"))
            .ok()
            .and_then(|text| text.lines().next().map(|line| line.trim().to_owned()))
            .filter(|line| !line.is_empty());
        if watcher != self.watcher || afk != self.afk {
            self.watcher = watcher;
            self.afk = afk;
            changed = true;
        }
        changed
    }

    fn start_snapshot_if_due(&mut self) {
        if self.snapshot_rx.is_some() {
            return;
        }
        let since_last = self.snapshot_started.map(|started| started.elapsed());
        let due = match since_last {
            None => true,
            Some(elapsed) if self.snapshot_wanted => elapsed >= SNAPSHOT_MIN_INTERVAL,
            Some(elapsed) => elapsed >= SNAPSHOT_FALLBACK_INTERVAL,
        };
        if !due {
            return;
        }
        self.snapshot_wanted = false;
        self.snapshot_started = Some(Instant::now());
        let (sender, receiver) = mpsc::channel();
        let home = self.home.clone();
        let root = self.root.clone();
        thread::spawn(move || {
            let _ = sender.send(load_snapshot(&root, &home));
        });
        self.snapshot_rx = Some(receiver);
    }

    fn receive_snapshot(&mut self) -> bool {
        let Some(receiver) = &self.snapshot_rx else {
            return false;
        };
        match receiver.try_recv() {
            Ok(Ok(snapshot)) => {
                self.snapshot = SnapshotState::Ready(snapshot);
                self.refreshed_at = Some(Instant::now());
            }
            Ok(Err(message)) => {
                if !matches!(self.snapshot, SnapshotState::Ready(_)) {
                    self.snapshot = SnapshotState::Error(message.clone());
                }
                self.notice = Some(message);
            }
            Err(TryRecvError::Empty) => return false,
            Err(TryRecvError::Disconnected) => {}
        }
        self.snapshot_rx = None;
        true
    }

    fn rebuild(&mut self) {
        self.runs = build_runs(&self.records, &self.ledger, self.snapshot());
    }

    pub(crate) fn open_peek(&mut self, task: &str) {
        if self.peek.as_ref().is_some_and(|peek| peek.task == task) {
            return;
        }
        self.peek = Some(Peek {
            task: task.to_owned(),
            text: Ok(String::new()),
            receiver: None,
            requested_at: None,
        });
    }

    pub(crate) fn close_peek(&mut self) {
        self.peek = None;
    }

    fn update_peek(&mut self) -> bool {
        let live = self
            .peek
            .as_ref()
            .and_then(|peek| self.run(&peek.task))
            .is_some_and(Run::is_active);
        let script = self.root.join("bin/fm-peek.sh");
        let home = self.home.clone();
        let Some(peek) = &mut self.peek else {
            return false;
        };
        let mut changed = false;
        if let Some(receiver) = &peek.receiver {
            match receiver.try_recv() {
                Ok(text) => {
                    changed = peek.text != text;
                    peek.text = text;
                    peek.receiver = None;
                }
                Err(TryRecvError::Empty) => {}
                Err(TryRecvError::Disconnected) => peek.receiver = None,
            }
        }
        let due = peek
            .requested_at
            .is_none_or(|requested| requested.elapsed() >= PEEK_INTERVAL);
        if live && due && peek.receiver.is_none() {
            peek.requested_at = Some(Instant::now());
            let (sender, receiver) = mpsc::channel();
            let task = peek.task.clone();
            thread::spawn(move || {
                let _ = sender.send(run_peek(&script, &home, &task));
            });
            peek.receiver = Some(receiver);
        }
        changed
    }
}

fn run_peek(script: &Path, home: &Path, task: &str) -> Result<String, String> {
    let output = Command::new(script)
        .arg(task)
        .current_dir(home)
        .env("FM_HOME", home)
        // The guard's advisory mode never touches its banner bookkeeping in state/.
        .env("FM_GUARD_READ_ONLY", "1")
        .output()
        .map_err(|error| format!("Could not run fm-peek.sh: {error}"))?;
    if output.status.success() {
        Ok(strip_guard_banner(&String::from_utf8_lossy(&output.stdout)))
    } else {
        Err(String::from_utf8_lossy(&output.stderr).trim().to_owned())
    }
}

/// Drops the supervision banner `fm-guard.sh` may print ahead of the pane text.
fn strip_guard_banner(output: &str) -> String {
    let mut lines = output.lines().peekable();
    let mut skipped = false;
    while lines.peek().is_some_and(|line| line.starts_with('●')) {
        lines.next();
        skipped = true;
    }
    if skipped {
        while lines.peek().is_some_and(|line| line.trim().is_empty()) {
            lines.next();
        }
    }
    lines.collect::<Vec<_>>().join("\n")
}

fn modified(path: &Path) -> Option<SystemTime> {
    fs::metadata(path)
        .and_then(|metadata| metadata.modified())
        .ok()
}

fn watcher_status(state_dir: &Path) -> WatcherStatus {
    let Some(beat) = modified(&state_dir.join(".last-watcher-beat")) else {
        return WatcherStatus::Absent;
    };
    match beat.elapsed() {
        Ok(age) if age > WATCHER_STALE_AFTER => {
            WatcherStatus::Stale(Duration::from_secs(age.as_secs() / 60 * 60))
        }
        _ => WatcherStatus::Alive,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn guard_banner_is_removed_from_peeks() {
        assert_eq!(
            strip_guard_banner("●────\n●  WATCHER DOWN\n\n$ cargo test\nok"),
            "$ cargo test\nok"
        );
        assert_eq!(strip_guard_banner("plain\n● bullet"), "plain\n● bullet");
    }

    #[test]
    fn watcher_is_absent_without_a_beacon() {
        let dir = std::env::temp_dir().join(format!("vessel-watch-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();

        assert_eq!(watcher_status(&dir), WatcherStatus::Absent);
        fs::write(dir.join(".last-watcher-beat"), "").unwrap();
        assert_eq!(watcher_status(&dir), WatcherStatus::Alive);
        fs::remove_dir_all(dir).ok();
    }
}
