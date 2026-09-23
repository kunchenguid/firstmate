//! `bin/fm-fleet-snapshot.sh --json` (schema `fm-fleet-snapshot.v1`).
//!
//! Only the members vessel renders are read, each optional, so additive
//! upstream schema changes never break parsing.

use std::{path::Path, process::Command};

use serde_json::Value;

pub(crate) const SNAPSHOT_SCHEMA: &str = "fm-fleet-snapshot.v1";

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct Snapshot {
    pub(crate) generated: Option<String>,
    pub(crate) tasks: Vec<SnapshotTask>,
    pub(crate) backlog: Vec<BacklogRecord>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct SnapshotTask {
    pub(crate) id: String,
    pub(crate) kind: Option<String>,
    pub(crate) harness: Option<String>,
    pub(crate) mode: Option<String>,
    pub(crate) project: Option<String>,
    pub(crate) backend: Option<String>,
    /// `working|parked|done|blocked|paused|failed|unknown` from `fm-crew-state.sh`.
    pub(crate) state: Option<String>,
    pub(crate) state_detail: Option<String>,
    pub(crate) last_event: Option<String>,
    pub(crate) last_event_age: Option<u64>,
    pub(crate) open_decisions: Vec<OpenDecision>,
    pub(crate) pr_url: Option<String>,
    pub(crate) endpoint_exists: Option<bool>,
    pub(crate) report_present: bool,
    pub(crate) worktree: Option<String>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct OpenDecision {
    pub(crate) verb: String,
    pub(crate) key: Option<String>,
    pub(crate) text: String,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct BacklogRecord {
    /// `in_flight`, `queued`, or `done`.
    pub(crate) state: String,
    pub(crate) id: Option<String>,
    pub(crate) title: String,
    pub(crate) kind: Option<String>,
    pub(crate) repo: Option<String>,
    pub(crate) hold_reason: Option<String>,
    pub(crate) captain_actionable: bool,
}

pub(crate) fn load_snapshot(fm_root: &Path, fm_home: &Path) -> Result<Snapshot, String> {
    let output = Command::new(fm_root.join("bin/fm-fleet-snapshot.sh"))
        .arg("--json")
        .current_dir(fm_home)
        .env("FM_HOME", fm_home)
        .output()
        .map_err(|error| format!("Could not run fm-fleet-snapshot.sh: {error}"))?;
    if !output.status.success() {
        return Err(format!(
            "fm-fleet-snapshot.sh failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    parse_snapshot(&output.stdout)
}

pub(crate) fn parse_snapshot(json: &[u8]) -> Result<Snapshot, String> {
    let value: Value = serde_json::from_slice(json)
        .map_err(|error| format!("Could not parse the fleet snapshot: {error}"))?;
    match value.get("schema").and_then(Value::as_str) {
        Some(SNAPSHOT_SCHEMA) => {}
        Some(other) => return Err(format!("Unsupported fleet snapshot schema {other}")),
        None => return Err("The fleet snapshot has no schema".into()),
    }
    Ok(Snapshot {
        generated: string(&value, "/generated"),
        tasks: value
            .get("tasks")
            .and_then(Value::as_array)
            .map(|tasks| tasks.iter().filter_map(parse_task).collect())
            .unwrap_or_default(),
        backlog: value
            .pointer("/backlog/records")
            .and_then(Value::as_array)
            .map(|records| records.iter().filter_map(parse_backlog_record).collect())
            .unwrap_or_default(),
    })
}

fn parse_task(task: &Value) -> Option<SnapshotTask> {
    Some(SnapshotTask {
        id: string(task, "/id")?,
        kind: string(task, "/kind"),
        harness: string(task, "/harness"),
        mode: string(task, "/mode"),
        project: string(task, "/project"),
        backend: string(task, "/backend"),
        state: string(task, "/current_state/state"),
        state_detail: string(task, "/current_state/detail"),
        last_event: string(task, "/paths/status_log/last_event/raw")
            .or_else(|| string(task, "/hints/last_event_text")),
        last_event_age: task
            .pointer("/paths/status_log/last_event/age_seconds")
            .and_then(Value::as_u64),
        open_decisions: task
            .pointer("/hints/open_decisions")
            .and_then(Value::as_array)
            .map(|decisions| decisions.iter().map(parse_decision).collect())
            .unwrap_or_default(),
        pr_url: string(task, "/pr/url"),
        endpoint_exists: task.pointer("/endpoint/exists").and_then(Value::as_bool),
        report_present: task
            .pointer("/paths/report/present")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        worktree: string(task, "/paths/worktree/path"),
    })
}

fn parse_decision(decision: &Value) -> OpenDecision {
    OpenDecision {
        verb: string(decision, "/verb").unwrap_or_else(|| "needs-decision".into()),
        key: string(decision, "/key"),
        text: string(decision, "/summary").unwrap_or_default(),
    }
}

fn parse_backlog_record(record: &Value) -> Option<BacklogRecord> {
    let structured = record
        .get("structured")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let title = if structured {
        string(record, "/title")
    } else {
        string(record, "/raw").map(|raw| raw.trim_start_matches(['-', ' ']).to_owned())
    }?;
    Some(BacklogRecord {
        state: string(record, "/state")?,
        id: string(record, "/id"),
        title,
        kind: string(record, "/kind"),
        repo: string(record, "/repo"),
        hold_reason: string(record, "/hold_reason"),
        captain_actionable: record
            .get("captain_actionable")
            .and_then(Value::as_bool)
            .unwrap_or(false),
    })
}

fn string(value: &Value, pointer: &str) -> Option<String> {
    value
        .pointer(pointer)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .map(str::to_owned)
}

/// Splits a status line such as `needs-decision key=api at=1790: which shape?`
/// into its verb and text.
pub(crate) fn status_verb_and_text(raw: &str) -> (String, String) {
    let (head, text) = raw.split_once(':').unwrap_or((raw, ""));
    let verb = head.split_whitespace().next().unwrap_or_default();
    (verb.to_owned(), text.trim().to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    pub(crate) const SNAPSHOT: &str = include_str!("../../tests/fixtures/snapshot.json");

    #[test]
    fn parses_tasks_backlog_and_decisions() {
        let snapshot = parse_snapshot(SNAPSHOT.as_bytes()).unwrap();

        assert_eq!(snapshot.tasks.len(), 2);
        let task = &snapshot.tasks[0];
        assert_eq!(task.id, "implement-aa4fi-1234");
        assert_eq!(task.kind.as_deref(), Some("ship"));
        assert_eq!(task.state.as_deref(), Some("working"));
        assert_eq!(
            task.pr_url.as_deref(),
            Some("https://github.com/acme/webapp/pull/7")
        );
        let review = &snapshot.tasks[1];
        assert_eq!(review.open_decisions.len(), 1);
        assert_eq!(review.open_decisions[0].key.as_deref(), Some("scope"));
        assert_eq!(snapshot.backlog.len(), 4);
        assert_eq!(snapshot.backlog[0].title, "Implement AA4FI-1234 login fix");
        assert_eq!(snapshot.backlog[2].state, "queued");
    }

    /// Contract check against the firstmate scripts in this checkout: the real
    /// snapshot of a generated home must still carry every member vessel reads.
    #[test]
    fn upstream_snapshot_still_provides_the_fields_vessel_reads() {
        let crate_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
        let root = crate_dir.parent().unwrap();
        let home = std::env::temp_dir().join(format!("vessel-contract-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        let status = Command::new(crate_dir.join("tests/demo-home.sh"))
            .arg(&home)
            .stdout(std::process::Stdio::null())
            .status()
            .unwrap();
        assert!(status.success());

        let snapshot = load_snapshot(root, &home).unwrap();

        let implement = snapshot
            .tasks
            .iter()
            .find(|task| task.id == "implement-aa4fi-1234")
            .expect("tasks[] lists task metadata");
        assert_eq!(implement.kind.as_deref(), Some("ship"));
        assert_eq!(implement.harness.as_deref(), Some("pi"));
        assert_eq!(implement.project.as_deref(), Some("webapp"));
        assert_eq!(
            implement.pr_url.as_deref(),
            Some("https://github.com/acme/webapp/pull/7")
        );
        assert!(implement.state.is_some(), "current_state.state");
        assert!(implement.last_event.is_some(), "status_log.last_event");
        let queued = snapshot
            .backlog
            .iter()
            .find(|record| record.state == "queued")
            .expect("backlog records");
        assert_eq!(queued.id.as_deref(), Some("plan-aa4fi-99"));
        assert_eq!(queued.title, "Plan AA4FI-99 checkout redesign");
        std::fs::remove_dir_all(home).ok();
    }

    #[test]
    fn rejects_other_schemas() {
        assert!(parse_snapshot(br#"{"schema":"fm-fleet-snapshot.v2"}"#).is_err());
    }

    #[test]
    fn splits_status_lines() {
        assert_eq!(
            status_verb_and_text("needs-decision key=api at=1790: which shape?"),
            ("needs-decision".into(), "which shape?".into())
        );
        assert_eq!(
            status_verb_and_text("working"),
            ("working".into(), String::new())
        );
    }
}
