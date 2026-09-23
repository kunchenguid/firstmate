//! Incremental reader for firstmate's fleet activity ledger.
//!
//! Contract: `docs/fleet-ledger.md` in the firstmate home. Records are JSON
//! Lines with `v`, `ts`, `event`, and `task`; unknown members and events are
//! ignored. Delivery is at least once, so repeated records are dropped here.

use std::{
    collections::{BTreeMap, BTreeSet},
    fs::File,
    io::{Read, Seek, SeekFrom},
    path::{Path, PathBuf},
};

use serde_json::Value;

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) enum LedgerKind {
    Dispatched {
        kind: Option<String>,
        project: Option<String>,
        harness: Option<String>,
        model: Option<String>,
    },
    Status {
        state: Option<String>,
        key: Option<String>,
        text: String,
    },
    Merged {
        via: Option<String>,
        pr: Option<String>,
    },
    CleanedUp,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct LedgerEvent {
    pub(crate) ts: u64,
    pub(crate) task: String,
    pub(crate) kind: LedgerKind,
}

impl LedgerEvent {
    /// Identity used to drop repeated deliveries of the same record.
    fn identity(&self) -> String {
        match &self.kind {
            LedgerKind::Dispatched { .. } => format!("dispatched|{}|{}", self.task, self.ts),
            LedgerKind::Status { state, key, text } => format!(
                "status|{}|{}|{}|{}",
                self.task,
                state.as_deref().unwrap_or_default(),
                key.as_deref().unwrap_or_default(),
                text
            ),
            LedgerKind::Merged { via, pr } => format!(
                "merged|{}|{}|{}",
                self.task,
                via.as_deref().unwrap_or_default(),
                pr.as_deref().unwrap_or_default()
            ),
            LedgerKind::CleanedUp => format!("cleaned|{}", self.task),
        }
    }
}

pub(crate) fn parse_ledger_line(line: &str) -> Option<LedgerEvent> {
    let value: Value = serde_json::from_str(line).ok()?;
    let ts = value.get("ts").and_then(Value::as_u64)?;
    let task = value.get("task").and_then(Value::as_str)?.to_owned();
    let text = |field: &str| value.get(field).and_then(Value::as_str).map(str::to_owned);
    let kind = match value.get("event").and_then(Value::as_str)? {
        "task.dispatched" => LedgerKind::Dispatched {
            kind: text("kind"),
            project: text("project"),
            harness: text("harness"),
            model: text("model"),
        },
        "task.status" => LedgerKind::Status {
            state: text("state"),
            key: text("key"),
            text: text("text").unwrap_or_default().trim().to_owned(),
        },
        "task.merged" => LedgerKind::Merged {
            via: text("via"),
            pr: text("pr"),
        },
        "task.cleaned_up" => LedgerKind::CleanedUp,
        _ => return None,
    };
    Some(LedgerEvent { ts, task, kind })
}

/// One life of a task id: from its dispatch (or first record) until cleanup.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct TaskHistory {
    pub(crate) task: String,
    pub(crate) dispatched_at: Option<u64>,
    pub(crate) kind: Option<String>,
    pub(crate) project: Option<String>,
    pub(crate) harness: Option<String>,
    pub(crate) model: Option<String>,
    pub(crate) statuses: Vec<LedgerEvent>,
    pub(crate) merged: Option<(u64, Option<String>)>,
    pub(crate) cleaned_up_at: Option<u64>,
    seen: BTreeSet<String>,
}

impl TaskHistory {
    pub(crate) fn first_ts(&self) -> Option<u64> {
        self.dispatched_at
            .or_else(|| self.statuses.first().map(|event| event.ts))
    }
}

#[derive(Debug)]
pub(crate) struct Ledger {
    path: PathBuf,
    offset: u64,
    partial: String,
    events: Vec<LedgerEvent>,
    tasks: BTreeMap<String, Vec<TaskHistory>>,
}

impl Ledger {
    pub(crate) fn new(path: PathBuf) -> Self {
        Self {
            path,
            offset: 0,
            partial: String::new(),
            events: Vec::new(),
            tasks: BTreeMap::new(),
        }
    }

    pub(crate) fn path(&self) -> &Path {
        &self.path
    }

    /// All distinct events in file order.
    pub(crate) fn events(&self) -> &[LedgerEvent] {
        &self.events
    }

    /// Every recorded life of `task`, oldest first.
    pub(crate) fn histories(&self, task: &str) -> &[TaskHistory] {
        self.tasks.get(task).map(Vec::as_slice).unwrap_or_default()
    }

    pub(crate) fn all_histories(&self) -> impl Iterator<Item = &TaskHistory> {
        self.tasks.values().flatten()
    }

    /// Reads records appended since the last poll. Returns whether anything new arrived.
    pub(crate) fn poll(&mut self) -> Result<bool, String> {
        let mut file = match File::open(&self.path) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
            Err(error) => return Err(format!("Could not read the fleet ledger: {error}")),
        };
        let length = file
            .metadata()
            .map_err(|error| format!("Could not read the fleet ledger: {error}"))?
            .len();
        if length < self.offset {
            // Truncated (`: > state/fleet-ledger.jsonl`): start over.
            *self = Self::new(self.path.clone());
        }
        if length == self.offset {
            return Ok(false);
        }
        file.seek(SeekFrom::Start(self.offset))
            .map_err(|error| format!("Could not read the fleet ledger: {error}"))?;
        let mut bytes = Vec::new();
        file.take(length - self.offset)
            .read_to_end(&mut bytes)
            .map_err(|error| format!("Could not read the fleet ledger: {error}"))?;
        self.offset += bytes.len() as u64;
        self.partial.push_str(&String::from_utf8_lossy(&bytes));
        let mut changed = false;
        while let Some(newline) = self.partial.find('\n') {
            let line = self.partial[..newline].to_owned();
            self.partial.drain(..=newline);
            if let Some(event) = parse_ledger_line(&line) {
                changed |= self.push(event);
            }
        }
        Ok(changed)
    }

    fn push(&mut self, event: LedgerEvent) -> bool {
        let lives = self.tasks.entry(event.task.clone()).or_default();
        let starts_new_life = match (&event.kind, lives.last()) {
            (_, None) => true,
            (LedgerKind::Dispatched { .. }, Some(life)) => {
                life.cleaned_up_at.is_some() || life.dispatched_at.is_some_and(|at| at != event.ts)
            }
            (_, Some(life)) => life.cleaned_up_at.is_some() && life.cleaned_up_at < Some(event.ts),
        };
        if starts_new_life {
            lives.push(TaskHistory {
                task: event.task.clone(),
                ..TaskHistory::default()
            });
        }
        let life = lives.last_mut().expect("a task life exists");
        let identity = event.identity();
        if !life.seen.insert(identity) {
            return false;
        }
        match &event.kind {
            LedgerKind::Dispatched {
                kind,
                project,
                harness,
                model,
            } => {
                life.dispatched_at = Some(event.ts);
                life.kind.clone_from(kind);
                life.project.clone_from(project);
                life.harness.clone_from(harness);
                life.model.clone_from(model);
            }
            LedgerKind::Status { .. } => life.statuses.push(event.clone()),
            LedgerKind::Merged { pr, .. } => life.merged = Some((event.ts, pr.clone())),
            LedgerKind::CleanedUp => life.cleaned_up_at = Some(event.ts),
        }
        self.events.push(event);
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    const RECORDS: &str = concat!(
        r#"{"v":1,"ts":100,"event":"task.status","task":"fix-login","state":"working","key":null,"text":" early"}"#,
        "\n",
        r#"{"v":1,"ts":101,"event":"task.dispatched","task":"fix-login","kind":"ship","project":"webapp","harness":"claude","model":null,"future":1}"#,
        "\n",
        r#"{"v":1,"ts":110,"event":"task.status","task":"fix-login","state":"working","key":null,"text":" bug reproduced"}"#,
        "\n",
        r#"{"v":1,"ts":111,"event":"task.status","task":"fix-login","state":"working","key":null,"text":" bug reproduced"}"#,
        "\n",
        r#"{"v":1,"ts":112,"event":"task.renamed","task":"fix-login"}"#,
        "\n",
        r#"{"v":1,"ts":200,"event":"task.merged","task":"fix-login","via":"pr","pr":"https://github.com/acme/webapp/pull/7"}"#,
        "\n",
        r#"{"v":1,"ts":210,"event":"task.cleaned_up","task":"fix-login"}"#,
        "\n",
    );

    fn temp_file(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!("vessel-ledger-{}-{name}", std::process::id()))
    }

    #[test]
    fn parses_known_events_and_ignores_unknown_ones() {
        let events = RECORDS
            .lines()
            .filter_map(parse_ledger_line)
            .collect::<Vec<_>>();

        assert_eq!(events.len(), 6);
        assert!(matches!(
            &events[1].kind,
            LedgerKind::Dispatched { harness: Some(harness), model: None, .. } if harness == "claude"
        ));
        assert!(
            matches!(&events[2].kind, LedgerKind::Status { text, .. } if text == "bug reproduced")
        );
    }

    #[test]
    fn folds_duplicates_and_early_status_into_one_task_life() {
        let path = temp_file("fold");
        std::fs::write(&path, RECORDS).unwrap();
        let mut ledger = Ledger::new(path.clone());

        assert!(ledger.poll().unwrap());
        let histories = ledger.histories("fix-login");

        assert_eq!(histories.len(), 1);
        assert_eq!(histories[0].dispatched_at, Some(101));
        assert_eq!(histories[0].statuses.len(), 2);
        assert_eq!(histories[0].first_ts(), Some(101));
        assert_eq!(
            histories[0].merged,
            Some((200, Some("https://github.com/acme/webapp/pull/7".into())))
        );
        assert_eq!(histories[0].cleaned_up_at, Some(210));
        assert_eq!(ledger.events().len(), 5);
        std::fs::remove_file(path).ok();
    }

    #[test]
    fn reads_appended_records_and_waits_for_complete_lines() {
        let path = temp_file("append");
        std::fs::write(&path, "").unwrap();
        let mut ledger = Ledger::new(path.clone());
        let mut file = std::fs::OpenOptions::new()
            .append(true)
            .open(&path)
            .unwrap();

        write!(file, "{}", &RECORDS[..40]).unwrap();
        assert!(!ledger.poll().unwrap());
        write!(file, "{}", &RECORDS[40..]).unwrap();
        assert!(ledger.poll().unwrap());
        assert!(!ledger.poll().unwrap());
        assert_eq!(ledger.histories("fix-login").len(), 1);
        std::fs::remove_file(path).ok();
    }

    #[test]
    fn a_reused_task_id_after_cleanup_starts_a_new_life() {
        let path = temp_file("reuse");
        let again = r#"{"v":1,"ts":300,"event":"task.dispatched","task":"fix-login","kind":"ship","project":"webapp","harness":"pi","model":"gpt-5.6-luna"}"#;
        std::fs::write(&path, format!("{RECORDS}{again}\n")).unwrap();
        let mut ledger = Ledger::new(path.clone());

        ledger.poll().unwrap();

        let histories = ledger.histories("fix-login");
        assert_eq!(histories.len(), 2);
        assert_eq!(histories[1].harness.as_deref(), Some("pi"));
        assert_eq!(histories[1].cleaned_up_at, None);
        std::fs::remove_file(path).ok();
    }

    #[test]
    fn truncation_resets_the_reader() {
        let path = temp_file("truncate");
        std::fs::write(&path, RECORDS).unwrap();
        let mut ledger = Ledger::new(path.clone());
        ledger.poll().unwrap();

        std::fs::write(&path, "").unwrap();
        ledger.poll().unwrap();

        assert!(ledger.events().is_empty());
        std::fs::remove_file(path).ok();
    }

    #[test]
    fn missing_ledger_is_not_an_error() {
        let mut ledger = Ledger::new(temp_file("missing"));
        assert_eq!(ledger.poll(), Ok(false));
    }
}
