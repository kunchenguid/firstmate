//! Runs: firstmate tasks joined with vessel's run records.
//!
//! `data/vessel/runs.jsonl` (written by `vessel/bin/vessel-record-run.sh`) says
//! which workflow, agent, ticket, and pull request a task was for. The fleet
//! ledger supplies its history and the live snapshot its current state. Tasks
//! firstmate dispatched without vessel still show up, with less context.

use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::Path,
};

use serde_json::Value;

use super::{
    ledger::{Ledger, LedgerKind, TaskHistory},
    snapshot::{OpenDecision, Snapshot, SnapshotTask, status_verb_and_text},
};

/// How far apart (seconds) a run record and its ledger dispatch may be.
const DISPATCH_MATCH_WINDOW: u64 = 15 * 60;

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct RunRecord {
    pub(crate) ts: u64,
    pub(crate) task: String,
    pub(crate) workflow: String,
    pub(crate) agent: Option<String>,
    pub(crate) harness: Option<String>,
    pub(crate) model: Option<String>,
    pub(crate) effort: Option<String>,
    pub(crate) project: Option<String>,
    pub(crate) title: Option<String>,
    pub(crate) ticket_key: Option<String>,
    pub(crate) repo: Option<String>,
    pub(crate) pr_number: Option<u64>,
    pub(crate) pr_url: Option<String>,
    pub(crate) pr_head: Option<String>,
    pub(crate) plan_task: Option<String>,
    pub(crate) request_id: Option<String>,
}

pub(crate) fn parse_run_record(line: &str) -> Option<RunRecord> {
    let value: Value = serde_json::from_str(line).ok()?;
    let text = |field: &str| {
        value
            .get(field)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|text| !text.is_empty())
            .map(str::to_owned)
    };
    Some(RunRecord {
        ts: value.get("ts").and_then(Value::as_u64)?,
        task: text("task")?,
        workflow: text("workflow")?,
        agent: text("agent"),
        harness: text("harness"),
        model: text("model"),
        effort: text("effort"),
        project: text("project"),
        title: text("title"),
        ticket_key: text("ticket_key"),
        repo: text("repo"),
        pr_number: value.get("pr_number").and_then(Value::as_u64),
        pr_url: text("pr_url"),
        pr_head: text("pr_head"),
        plan_task: text("plan_task"),
        request_id: text("request_id"),
    })
}

pub(crate) fn load_run_records(path: &Path) -> Result<Vec<RunRecord>, String> {
    match fs::read_to_string(path) {
        Ok(text) => Ok(text.lines().filter_map(parse_run_record).collect()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Vec::new()),
        Err(error) => Err(format!("Could not read {}: {error}", path.display())),
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd)]
pub(crate) enum RunStatus {
    NeedsDecision,
    Blocked,
    Working,
    Paused,
    Idle,
    Done,
    Merged,
    Completed,
    Failed,
    Closed,
    Unknown,
}

impl RunStatus {
    pub(crate) fn label(self) -> &'static str {
        match self {
            Self::NeedsDecision => "Needs decision",
            Self::Blocked => "Blocked",
            Self::Working => "Working",
            Self::Paused => "Paused",
            Self::Idle => "Idle",
            Self::Done => "Done",
            Self::Merged => "Merged",
            Self::Completed => "Completed",
            Self::Failed => "Failed",
            Self::Closed => "Closed",
            Self::Unknown => "Unknown",
        }
    }

    pub(crate) fn needs_attention(self) -> bool {
        matches!(self, Self::NeedsDecision | Self::Blocked | Self::Failed)
    }

    pub(crate) fn from_verb(verb: &str) -> Option<Self> {
        Some(match verb {
            "working" | "resolved" => Self::Working,
            "needs-decision" | "captain-held" => Self::NeedsDecision,
            "blocked" => Self::Blocked,
            "paused" => Self::Paused,
            "parked" => Self::Idle,
            "done" => Self::Done,
            "failed" => Self::Failed,
            _ => return None,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct TimelineEntry {
    pub(crate) ts: u64,
    pub(crate) state: String,
    pub(crate) text: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct Run {
    pub(crate) task: String,
    /// `implement`, `review`, …; `None` for tasks firstmate dispatched without vessel.
    pub(crate) workflow: Option<String>,
    pub(crate) record: Option<RunRecord>,
    pub(crate) kind: Option<String>,
    pub(crate) project: Option<String>,
    pub(crate) harness: Option<String>,
    pub(crate) model: Option<String>,
    pub(crate) title: String,
    pub(crate) ticket_key: Option<String>,
    pub(crate) repo: Option<String>,
    pub(crate) pr_number: Option<u64>,
    pub(crate) pr_url: Option<String>,
    pub(crate) created_at: Option<u64>,
    pub(crate) finished_at: Option<u64>,
    pub(crate) status: RunStatus,
    pub(crate) status_text: Option<String>,
    pub(crate) timeline: Vec<TimelineEntry>,
    pub(crate) open_decisions: Vec<OpenDecision>,
    pub(crate) live: bool,
    pub(crate) endpoint_exists: Option<bool>,
}

impl Run {
    /// Still doing work. A scout that reported `done` has filed its report;
    /// firstmate only has cleanup left, so it counts as finished while live.
    pub(crate) fn is_active(&self) -> bool {
        self.live && !self.reported_done()
    }

    fn reported_done(&self) -> bool {
        self.kind.as_deref() == Some("scout") && self.status == RunStatus::Done
    }

    pub(crate) fn agent(&self) -> Option<&str> {
        self.record
            .as_ref()
            .and_then(|record| record.agent.as_deref())
    }

    pub(crate) fn pr_head(&self) -> Option<&str> {
        self.record
            .as_ref()
            .and_then(|record| record.pr_head.as_deref())
    }

    /// Display name of the workflow, e.g. `Review`, or `Task` for plain firstmate work.
    pub(crate) fn mode(&self) -> &'static str {
        match self.workflow.as_deref() {
            Some("implement") => "Implement",
            Some("plan") => "Plan",
            Some("review") => "Review",
            Some("address") => "Address",
            Some("conflicts") => "Conflicts",
            Some("description") => "Description",
            Some("ticket") => "Ticket",
            Some("free") => "Free",
            _ if self.kind.as_deref() == Some("scout") => "Scout",
            _ if self.kind.as_deref() == Some("secondmate") => "Secondmate",
            _ => "Task",
        }
    }

    pub(crate) fn matches_pull_request(&self, repository: &str, number: u64) -> bool {
        if self.pr_number != Some(number) {
            return false;
        }
        match self.repo.as_deref() {
            Some(repo) => repo.eq_ignore_ascii_case(repository),
            None => {
                let name = repository.rsplit('/').next().unwrap_or(repository);
                self.project
                    .as_deref()
                    .is_some_and(|project| project.eq_ignore_ascii_case(name))
            }
        }
    }
}

/// Parses `https://github.com/<owner>/<repo>/pull/<n>` into `(owner/repo, n)`.
pub(crate) fn pull_request_from_url(url: &str) -> Option<(String, u64)> {
    let path = url.split("github.com/").nth(1)?;
    let mut parts = path.split('/');
    let owner = parts.next()?;
    let repo = parts.next()?;
    (parts.next()? == "pull").then_some(())?;
    let number = parts.next()?.split(['#', '?']).next()?.parse().ok()?;
    Some((format!("{owner}/{repo}"), number))
}

fn workflow_from_task(task: &str) -> Option<String> {
    let prefix = task.split('-').next()?;
    matches!(
        prefix,
        "implement"
            | "plan"
            | "review"
            | "address"
            | "conflicts"
            | "description"
            | "ticket"
            | "free"
    )
    .then(|| prefix.to_owned())
}

/// Joins run records, ledger history, and the live snapshot, newest first.
pub(crate) fn build_runs(
    records: &[RunRecord],
    ledger: &Ledger,
    snapshot: Option<&Snapshot>,
) -> Vec<Run> {
    let live: BTreeMap<&str, &SnapshotTask> = snapshot
        .map(|snapshot| {
            snapshot
                .tasks
                .iter()
                .map(|task| (task.id.as_str(), task))
                .collect()
        })
        .unwrap_or_default();
    let backlog_titles: BTreeMap<&str, &str> = snapshot
        .map(|snapshot| {
            snapshot
                .backlog
                .iter()
                .filter_map(|record| Some((record.id.as_deref()?, record.title.as_str())))
                .collect()
        })
        .unwrap_or_default();

    let mut used_lives = BTreeSet::new();
    let mut runs = Vec::new();

    let mut records_by_task: BTreeMap<&str, Vec<&RunRecord>> = BTreeMap::new();
    for record in records {
        records_by_task
            .entry(&record.task)
            .or_default()
            .push(record);
    }
    for (task, task_records) in &records_by_task {
        let lives = ledger.histories(task);
        let latest_record = task_records.iter().map(|record| record.ts).max();
        for record in task_records {
            let life_index = matching_life(lives, record.ts, &used_lives, task);
            if let Some(index) = life_index {
                used_lives.insert((task.to_string(), index));
            }
            let life = life_index.map(|index| &lives[index]);
            // Only the newest life of a task id can be the live one.
            let is_latest = Some(record.ts) == latest_record
                && life_index.is_none_or(|index| index + 1 == lives.len());
            let snapshot_task = is_latest.then(|| live.get(task).copied()).flatten();
            runs.push(assemble(
                task,
                Some((*record).clone()),
                life,
                snapshot_task,
                &backlog_titles,
            ));
        }
    }

    for history in ledger.all_histories() {
        let lives = ledger.histories(&history.task);
        let index = lives
            .iter()
            .position(|life| std::ptr::eq(life, history))
            .unwrap_or_default();
        if used_lives.contains(&(history.task.clone(), index))
            || records_by_task.contains_key(history.task.as_str())
        {
            continue;
        }
        let snapshot_task = (index + 1 == lives.len())
            .then(|| live.get(history.task.as_str()).copied())
            .flatten();
        runs.push(assemble(
            &history.task,
            None,
            Some(history),
            snapshot_task,
            &backlog_titles,
        ));
    }

    for (task, snapshot_task) in &live {
        let known = records_by_task.contains_key(task) || !ledger.histories(task).is_empty();
        if !known {
            runs.push(assemble(
                task,
                None,
                None,
                Some(snapshot_task),
                &backlog_titles,
            ));
        }
    }

    runs.sort_by(|left, right| {
        right
            .created_at
            .cmp(&left.created_at)
            .then_with(|| left.task.cmp(&right.task))
    });
    runs
}

fn matching_life(
    lives: &[TaskHistory],
    record_ts: u64,
    used: &BTreeSet<(String, usize)>,
    task: &str,
) -> Option<usize> {
    lives
        .iter()
        .enumerate()
        .filter(|(index, _)| !used.contains(&(task.to_owned(), *index)))
        .filter_map(|(index, life)| Some((index, life.first_ts()?.abs_diff(record_ts))))
        .filter(|(_, distance)| *distance <= DISPATCH_MATCH_WINDOW)
        .min_by_key(|(_, distance)| *distance)
        .map(|(index, _)| index)
}

fn assemble(
    task: &str,
    record: Option<RunRecord>,
    life: Option<&TaskHistory>,
    snapshot_task: Option<&SnapshotTask>,
    backlog_titles: &BTreeMap<&str, &str>,
) -> Run {
    let timeline: Vec<TimelineEntry> = life
        .map(|life| {
            life.statuses
                .iter()
                .filter_map(|event| match &event.kind {
                    LedgerKind::Status { state, text, .. } => Some(TimelineEntry {
                        ts: event.ts,
                        state: state.clone().unwrap_or_default(),
                        text: text.clone(),
                    }),
                    _ => None,
                })
                .collect()
        })
        .unwrap_or_default();

    let merged = life.and_then(|life| life.merged.clone());
    let cleaned_up_at = life.and_then(|life| life.cleaned_up_at);
    let kind = snapshot_task
        .and_then(|task| task.kind.clone())
        .or_else(|| life.and_then(|life| life.kind.clone()));

    let (status, status_text) = match snapshot_task {
        Some(live) => live_status(live, &timeline),
        None => ended_status(kind.as_deref(), merged.is_some(), cleaned_up_at, &timeline),
    };

    let merged_pr = merged.as_ref().and_then(|(_, pr)| pr.clone());
    let pr_url = record
        .as_ref()
        .and_then(|record| record.pr_url.clone())
        .or_else(|| snapshot_task.and_then(|task| task.pr_url.clone()))
        .or_else(|| merged_pr.clone());
    let parsed_pr = pr_url.as_deref().and_then(pull_request_from_url);
    let repo = record
        .as_ref()
        .and_then(|record| record.repo.clone())
        .or_else(|| parsed_pr.as_ref().map(|(repo, _)| repo.clone()));
    let pr_number = record
        .as_ref()
        .and_then(|record| record.pr_number)
        .or_else(|| parsed_pr.as_ref().map(|(_, number)| *number));
    let ticket_key = match &record {
        Some(record) => record.ticket_key.clone(),
        None => crate::github::configured_ticket_key(&task.to_uppercase()),
    };
    let title = record
        .as_ref()
        .and_then(|record| record.title.clone())
        .or_else(|| backlog_titles.get(task).map(|title| (*title).to_owned()))
        .unwrap_or_else(|| task.to_owned());

    let scout_done = kind.as_deref() == Some("scout") && status == RunStatus::Done;
    Run {
        task: task.to_owned(),
        workflow: record
            .as_ref()
            .map(|record| record.workflow.clone())
            .or_else(|| workflow_from_task(task)),
        kind,
        project: record
            .as_ref()
            .and_then(|record| record.project.clone())
            .or_else(|| snapshot_task.and_then(|task| task.project.clone()))
            .or_else(|| life.and_then(|life| life.project.clone())),
        harness: record
            .as_ref()
            .and_then(|record| record.harness.clone())
            .or_else(|| life.and_then(|life| life.harness.clone()))
            .or_else(|| snapshot_task.and_then(|task| task.harness.clone())),
        model: record
            .as_ref()
            .and_then(|record| record.model.clone())
            .or_else(|| life.and_then(|life| life.model.clone())),
        title,
        ticket_key,
        repo,
        pr_number,
        pr_url,
        created_at: life
            .and_then(TaskHistory::first_ts)
            .or_else(|| record.as_ref().map(|record| record.ts)),
        finished_at: if snapshot_task.is_some() && !scout_done {
            None
        } else {
            cleaned_up_at
                .or_else(|| merged.as_ref().map(|(ts, _)| *ts))
                .or_else(|| timeline.last().map(|entry| entry.ts))
        },
        status,
        status_text,
        timeline,
        open_decisions: snapshot_task
            .map(|task| task.open_decisions.clone())
            .unwrap_or_default(),
        live: snapshot_task.is_some(),
        endpoint_exists: snapshot_task.and_then(|task| task.endpoint_exists),
        record,
    }
}

fn live_status(task: &SnapshotTask, timeline: &[TimelineEntry]) -> (RunStatus, Option<String>) {
    let latest_text = task
        .last_event
        .as_deref()
        .map(|raw| status_verb_and_text(raw).1)
        .filter(|text| !text.is_empty())
        .or_else(|| timeline.last().map(|entry| entry.text.clone()));
    if let Some(decision) = task.open_decisions.first() {
        let status = if decision.verb == "blocked" {
            RunStatus::Blocked
        } else {
            RunStatus::NeedsDecision
        };
        return (status, Some(decision.text.clone()));
    }
    let status = task
        .state
        .as_deref()
        .and_then(RunStatus::from_verb)
        .or_else(|| {
            timeline
                .last()
                .and_then(|entry| RunStatus::from_verb(&entry.state))
        })
        .unwrap_or(RunStatus::Unknown);
    (status, latest_text)
}

fn ended_status(
    kind: Option<&str>,
    merged: bool,
    cleaned_up_at: Option<u64>,
    timeline: &[TimelineEntry],
) -> (RunStatus, Option<String>) {
    let latest = timeline.last();
    let text = latest.map(|entry| entry.text.clone());
    if merged {
        return (RunStatus::Merged, text);
    }
    let last_verb = latest.and_then(|entry| RunStatus::from_verb(&entry.state));
    if cleaned_up_at.is_some() {
        let status = match (kind, last_verb) {
            (_, Some(RunStatus::Failed)) => RunStatus::Failed,
            (Some("scout"), _) | (_, Some(RunStatus::Done)) => RunStatus::Completed,
            _ => RunStatus::Closed,
        };
        return (status, text);
    }
    (last_verb.unwrap_or(RunStatus::Unknown), text)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::firstmate::snapshot::parse_snapshot;

    fn ledger_with(records: &str) -> Ledger {
        let path = std::env::temp_dir().join(format!(
            "vessel-runs-{}-{}",
            std::process::id(),
            records.len()
        ));
        std::fs::write(&path, records).unwrap();
        let mut ledger = Ledger::new(path.clone());
        ledger.poll().unwrap();
        std::fs::remove_file(path).ok();
        ledger
    }

    fn record(task: &str, workflow: &str, ts: u64) -> RunRecord {
        RunRecord {
            ts,
            task: task.into(),
            workflow: workflow.into(),
            agent: Some("Snoop".into()),
            repo: Some("acme/webapp".into()),
            pr_number: Some(42),
            ..RunRecord::default()
        }
    }

    const FINISHED_REVIEW: &str = concat!(
        r#"{"v":1,"ts":1000,"event":"task.dispatched","task":"review-webapp-42","kind":"scout","project":"webapp","harness":"pi","model":"gpt-5.6-luna"}"#,
        "\n",
        r#"{"v":1,"ts":1100,"event":"task.status","task":"review-webapp-42","state":"done","key":null,"text":" report ready"}"#,
        "\n",
        r#"{"v":1,"ts":1200,"event":"task.cleaned_up","task":"review-webapp-42"}"#,
        "\n",
    );

    #[test]
    fn parses_run_records() {
        let line = r#"{"v":1,"ts":5,"task":"review-webapp-42","workflow":"review","agent":"Snoop","repo":"acme/webapp","pr_number":42,"pr_head":"abc","ticket_key":null,"extra":"ignored"}"#;
        let record = parse_run_record(line).unwrap();

        assert_eq!(record.workflow, "review");
        assert_eq!(record.pr_number, Some(42));
        assert_eq!(record.pr_head.as_deref(), Some("abc"));
        assert_eq!(record.ticket_key, None);
        assert!(parse_run_record(r#"{"ts":5,"task":"x"}"#).is_none());
    }

    #[test]
    fn finished_runs_keep_their_history_after_cleanup() {
        let ledger = ledger_with(FINISHED_REVIEW);
        let runs = build_runs(&[record("review-webapp-42", "review", 1003)], &ledger, None);

        assert_eq!(runs.len(), 1);
        let run = &runs[0];
        assert_eq!(run.status, RunStatus::Completed);
        assert_eq!(run.mode(), "Review");
        assert_eq!(run.agent(), Some("Snoop"));
        assert_eq!(run.harness.as_deref(), Some("pi"));
        assert_eq!(run.finished_at, Some(1200));
        assert_eq!(run.timeline.len(), 1);
        assert!(run.matches_pull_request("acme/webapp", 42));
        assert!(!run.matches_pull_request("other/webapp", 42));
        assert!(!run.is_active());
    }

    #[test]
    fn live_snapshot_state_wins_and_surfaces_decisions() {
        let snapshot =
            parse_snapshot(include_bytes!("../../tests/fixtures/snapshot.json")).unwrap();
        let ledger = ledger_with("");
        let runs = build_runs(
            &[record("review-webapp-42", "review", 1790141000)],
            &ledger,
            Some(&snapshot),
        );

        let review = runs
            .iter()
            .find(|run| run.task == "review-webapp-42")
            .unwrap();
        assert!(review.live);
        assert_eq!(review.status, RunStatus::NeedsDecision);
        assert_eq!(
            review.status_text.as_deref(),
            Some("review only the API layer?")
        );

        let implement = runs
            .iter()
            .find(|run| run.task == "implement-aa4fi-1234")
            .unwrap();
        assert_eq!(implement.status, RunStatus::Working);
        assert_eq!(implement.workflow.as_deref(), Some("implement"));
        assert_eq!(
            implement.ticket_key, None,
            "no guessing without ticket_projects"
        );
        assert_eq!(implement.title, "Implement AA4FI-1234 login fix");
        assert_eq!(implement.repo.as_deref(), Some("acme/webapp"));
        assert_eq!(implement.pr_number, Some(7));
    }

    #[test]
    fn reruns_of_one_task_id_stay_separate() {
        let second = concat!(
            r#"{"v":1,"ts":5000,"event":"task.dispatched","task":"review-webapp-42","kind":"scout","project":"webapp","harness":"pi","model":null}"#,
            "\n"
        );
        let ledger = ledger_with(&format!("{FINISHED_REVIEW}{second}"));
        let runs = build_runs(
            &[
                record("review-webapp-42", "review", 1003),
                record("review-webapp-42", "review", 5002),
            ],
            &ledger,
            None,
        );

        assert_eq!(runs.len(), 2);
        assert_eq!(runs[0].created_at, Some(5000));
        assert_eq!(runs[0].status, RunStatus::Unknown);
        assert_eq!(runs[1].status, RunStatus::Completed);
    }

    #[test]
    fn ledger_only_tasks_are_listed_and_merges_count_as_merged() {
        let ledger = ledger_with(concat!(
            r#"{"v":1,"ts":10,"event":"task.dispatched","task":"fix-login","kind":"ship","project":"webapp","harness":"claude","model":null}"#,
            "\n",
            r#"{"v":1,"ts":20,"event":"task.merged","task":"fix-login","via":"pr","pr":"https://github.com/acme/webapp/pull/7"}"#,
            "\n",
        ));
        let runs = build_runs(&[], &ledger, None);

        assert_eq!(runs.len(), 1);
        assert_eq!(runs[0].status, RunStatus::Merged);
        assert_eq!(runs[0].mode(), "Task");
        assert!(runs[0].matches_pull_request("acme/webapp", 7));
    }

    #[test]
    fn parses_pull_request_urls() {
        assert_eq!(
            pull_request_from_url("https://github.com/acme/webapp/pull/7#discussion"),
            Some(("acme/webapp".into(), 7))
        );
        assert_eq!(
            pull_request_from_url("https://github.com/acme/webapp"),
            None
        );
    }
}
