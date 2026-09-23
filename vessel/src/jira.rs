use std::{
    cmp::Ordering,
    env,
    io::Read,
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};

use serde_json::Value;

const ACLI_TIMEOUT: Duration = Duration::from_secs(30);
const FEATURE_WORKERS: usize = 8;
const DEFAULT_JIRA_JQL: &str = "assignee = currentUser() AND resolution = EMPTY AND status != \"Won't do\" ORDER BY updated DESC";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum BoardStatus {
    ToDo,
    OnHold,
    InProgress,
    InReview,
}

#[derive(Clone, Debug)]
pub(crate) struct Ticket {
    pub(crate) key: String,
    pub(crate) summary: String,
    pub(crate) status: BoardStatus,
    pub(crate) feature: String,
}

pub(crate) fn compare_jira_keys(left: &str, right: &str) -> Ordering {
    fn parts(key: &str) -> Option<(&str, u64)> {
        let (project, number) = key.rsplit_once('-')?;
        Some((project, number.parse().ok()?))
    }

    match (parts(left), parts(right)) {
        (Some((left_project, left_number)), Some((right_project, right_number))) => left_project
            .cmp(right_project)
            .then(left_number.cmp(&right_number))
            .then(left.cmp(right)),
        _ => left.cmp(right),
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct TicketComment {
    pub(crate) author: String,
    pub(crate) body: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct TicketDetail {
    pub(crate) key: String,
    pub(crate) title: String,
    pub(crate) description: String,
    pub(crate) reporter: String,
    pub(crate) comments: Vec<TicketComment>,
    pub(crate) feature: String,
    pub(crate) status: String,
}

static JQL: std::sync::OnceLock<String> = std::sync::OnceLock::new();

/// Overrides the ticket search (config `jira_jql`, else `$VESSEL_JIRA_JQL`).
pub(crate) fn set_jql(jql: String) {
    let _ = JQL.set(jql);
}

pub(crate) fn load_jira_tickets() -> Result<Vec<Ticket>, String> {
    let jql = JQL
        .get()
        .cloned()
        .or_else(|| env::var("VESSEL_JIRA_JQL").ok())
        .unwrap_or_else(|| DEFAULT_JIRA_JQL.into());
    let output = run_acli(&[
        "jira",
        "workitem",
        "search",
        "--jql",
        &jql,
        "--fields",
        "key,summary,status",
        "--paginate",
        "--json",
    ])?;
    let mut issues: Value = serde_json::from_slice(&output)
        .map_err(|error| format!("Could not parse Jira search output: {error}"))?;
    let issues = issues
        .as_array_mut()
        .ok_or_else(|| "Jira search returned an unexpected response".to_string())?;
    issues.retain(|issue| !is_wont_do(issue));

    if issues.is_empty() {
        return Ok(Vec::new());
    }

    let worker_count = issues.len().min(FEATURE_WORKERS);
    let chunk_size = issues.len().div_ceil(worker_count);

    thread::scope(|scope| {
        let workers = issues
            .chunks(chunk_size)
            .map(|chunk| {
                scope.spawn(move || {
                    chunk
                        .iter()
                        .map(|issue| {
                            let key = issue
                                .get("key")
                                .and_then(Value::as_str)
                                .ok_or_else(|| "A Jira ticket has no key".to_string())?;
                            ticket_from_json(issue, find_feature(key)?)
                        })
                        .collect::<Result<Vec<_>, String>>()
                })
            })
            .collect::<Vec<_>>();

        let mut tickets = Vec::with_capacity(issues.len());
        for worker in workers {
            tickets.extend(
                worker
                    .join()
                    .map_err(|_| "A Jira Feature lookup stopped unexpectedly".to_string())??,
            );
        }
        Ok(tickets)
    })
}

pub(crate) fn is_wont_do(issue: &Value) -> bool {
    issue
        .pointer("/fields/status/name")
        .and_then(Value::as_str)
        .is_some_and(|status| status.eq_ignore_ascii_case("Won't do"))
}

pub(crate) fn load_jira_ticket_detail(key: &str, feature: String) -> Result<TicketDetail, String> {
    let output = run_acli(&[
        "jira",
        "workitem",
        "view",
        key,
        "--fields",
        "summary,description,reporter,comment,status",
        "--json",
    ])?;
    let issue: Value = serde_json::from_slice(&output)
        .map_err(|error| format!("Could not parse Jira ticket {key}: {error}"))?;
    ticket_detail_from_json(&issue, feature)
}

pub(crate) fn ticket_detail_from_json(
    issue: &Value,
    feature: String,
) -> Result<TicketDetail, String> {
    let key = issue
        .get("key")
        .and_then(Value::as_str)
        .ok_or_else(|| "Jira ticket has no key".to_string())?;
    let title = issue
        .pointer("/fields/summary")
        .and_then(Value::as_str)
        .unwrap_or("Untitled ticket");
    let description = issue
        .pointer("/fields/description")
        .map(jira_rich_text)
        .filter(|description| !description.is_empty())
        .unwrap_or_else(|| "No description.".into());
    let reporter = issue
        .pointer("/fields/reporter/displayName")
        .and_then(Value::as_str)
        .unwrap_or("Unknown reporter");
    let status = issue
        .pointer("/fields/status/name")
        .and_then(Value::as_str)
        .unwrap_or("Unknown status");
    let comments = issue
        .pointer("/fields/comment/comments")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .map(|comment| TicketComment {
            author: comment
                .pointer("/author/displayName")
                .and_then(Value::as_str)
                .unwrap_or("Unknown author")
                .into(),
            body: comment
                .get("body")
                .map(jira_rich_text)
                .filter(|body| !body.is_empty())
                .unwrap_or_else(|| "Empty comment.".into()),
        })
        .collect();

    Ok(TicketDetail {
        key: key.into(),
        title: title.into(),
        description,
        reporter: reporter.into(),
        comments,
        feature,
        status: status.into(),
    })
}

fn jira_rich_text(value: &Value) -> String {
    fn append(value: &Value, output: &mut String) {
        if let Some(text) = value.get("text").and_then(Value::as_str) {
            output.push_str(text);
            return;
        }

        if value.get("type").and_then(Value::as_str) == Some("hardBreak") {
            output.push('\n');
            return;
        }

        if let Some(content) = value.get("content").and_then(Value::as_array) {
            let is_list = matches!(
                value.get("type").and_then(Value::as_str),
                Some("bulletList" | "orderedList")
            );
            for child in content {
                if is_list {
                    output.push_str("- ");
                }
                append(child, output);
            }
        }

        if matches!(
            value.get("type").and_then(Value::as_str),
            Some("paragraph" | "heading" | "listItem")
        ) && !output.ends_with('\n')
        {
            output.push('\n');
        }
    }

    if let Some(text) = value.as_str() {
        return text.into();
    }

    let mut output = String::new();
    append(value, &mut output);
    output.trim().to_string()
}

fn find_feature(ticket_key: &str) -> Result<String, String> {
    let mut current_key = ticket_key.to_string();

    for _ in 0..6 {
        let output = run_acli(&[
            "jira",
            "workitem",
            "view",
            &current_key,
            "--fields",
            "parent",
            "--json",
        ])?;
        let issue: Value = serde_json::from_slice(&output)
            .map_err(|error| format!("Could not parse Jira ticket {current_key}: {error}"))?;
        let Some(parent) = issue.pointer("/fields/parent") else {
            return Ok("No Feature".into());
        };
        let Some(parent_key) = parent.get("key").and_then(Value::as_str) else {
            return Ok("No Feature".into());
        };
        let issue_type = parent
            .pointer("/fields/issuetype/name")
            .and_then(Value::as_str)
            .unwrap_or_default();

        if issue_type.eq_ignore_ascii_case("feature") {
            let summary = parent
                .pointer("/fields/summary")
                .and_then(Value::as_str)
                .unwrap_or("Untitled Feature");
            return Ok(format!("{parent_key}  {summary}"));
        }

        current_key = parent_key.to_string();
    }

    Ok("No Feature".into())
}

fn ticket_from_json(issue: &Value, feature: String) -> Result<Ticket, String> {
    let key = issue
        .get("key")
        .and_then(Value::as_str)
        .ok_or_else(|| "A Jira ticket has no key".to_string())?;
    let summary = issue
        .pointer("/fields/summary")
        .and_then(Value::as_str)
        .unwrap_or("Untitled ticket");
    let status_name = issue
        .pointer("/fields/status/name")
        .and_then(Value::as_str)
        .unwrap_or("To Do");
    let status_category = issue
        .pointer("/fields/status/statusCategory/key")
        .and_then(Value::as_str)
        .unwrap_or("new");

    Ok(Ticket {
        key: key.into(),
        summary: summary.into(),
        status: board_status(status_name, status_category),
        feature,
    })
}

pub(crate) fn board_status(name: &str, category: &str) -> BoardStatus {
    let name = name.to_ascii_lowercase();
    let contains = |words: &[&str]| words.iter().any(|word| name.contains(word));

    if contains(&["hold", "blocked", "waiting", "paused"]) {
        BoardStatus::OnHold
    } else if contains(&["review", "verify", "validation", "testing", "qa"]) {
        BoardStatus::InReview
    } else if category.eq_ignore_ascii_case("indeterminate")
        || contains(&["progress", "implement", "develop", "reopened"])
    {
        BoardStatus::InProgress
    } else {
        BoardStatus::ToDo
    }
}

fn run_acli(arguments: &[&str]) -> Result<Vec<u8>, String> {
    let executable = env::var("VESSEL_ACLI").unwrap_or_else(|_| "acli".into());
    run_command(&executable, arguments, ACLI_TIMEOUT)
}

pub(crate) fn run_command(
    executable: &str,
    arguments: &[&str],
    timeout: Duration,
) -> Result<Vec<u8>, String> {
    let mut child = Command::new(executable)
        .args(arguments)
        .env("PAGER", "cat")
        .env("ACLI_PAGER", "cat")
        .env("NO_COLOR", "1")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| format!("Could not run {executable}: {error}"))?;

    let mut stdout = child.stdout.take().unwrap();
    let mut stderr = child.stderr.take().unwrap();
    let stdout_reader = thread::spawn(move || {
        let mut output = Vec::new();
        stdout.read_to_end(&mut output).map(|_| output)
    });
    let stderr_reader = thread::spawn(move || {
        let mut output = Vec::new();
        stderr.read_to_end(&mut output).map(|_| output)
    });

    let started = Instant::now();
    let status = loop {
        if let Some(status) = child
            .try_wait()
            .map_err(|error| format!("Could not wait for {executable}: {error}"))?
        {
            break status;
        }
        if started.elapsed() >= timeout {
            let _ = child.kill();
            let _ = child.wait();
            let _ = stdout_reader.join();
            let _ = stderr_reader.join();
            return Err(format!(
                "{executable} timed out after {} seconds; press r to retry",
                timeout.as_secs()
            ));
        }
        thread::sleep(Duration::from_millis(25));
    };

    let stdout = stdout_reader
        .join()
        .map_err(|_| format!("Could not read {executable} output"))?
        .map_err(|error| format!("Could not read {executable} output: {error}"))?;
    let stderr = stderr_reader
        .join()
        .map_err(|_| format!("Could not read {executable} errors"))?
        .map_err(|error| format!("Could not read {executable} errors: {error}"))?;

    if status.success() {
        Ok(stdout)
    } else {
        let message = String::from_utf8_lossy(&stderr).trim().to_string();
        Err(if message.is_empty() {
            format!("{executable} exited with {status}")
        } else {
            message
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn board_status_maps_workflow_names_to_columns() {
        assert_eq!(
            board_status("On Hold", "indeterminate"),
            BoardStatus::OnHold
        );
        assert_eq!(
            board_status("Code Review", "indeterminate"),
            BoardStatus::InReview
        );
        assert_eq!(
            board_status("Doing", "indeterminate"),
            BoardStatus::InProgress
        );
        assert_eq!(board_status("Selected", "new"), BoardStatus::ToDo);
    }

    #[test]
    fn tickets_parse_summary_status_and_feature() {
        let issue = serde_json::json!({
            "key": "AA4FI-7",
            "fields": {"summary": "Ship it", "status": {"name": "In Progress", "statusCategory": {"key": "indeterminate"}}}
        });

        let ticket = ticket_from_json(&issue, "Checkout".into()).unwrap();

        assert_eq!(ticket.key, "AA4FI-7");
        assert_eq!(ticket.summary, "Ship it");
        assert_eq!(ticket.status, BoardStatus::InProgress);
        assert_eq!(ticket.feature, "Checkout");
    }

    #[test]
    fn wont_do_tickets_are_filtered() {
        assert!(is_wont_do(
            &serde_json::json!({"fields": {"status": {"name": "Won't Do"}}})
        ));
        assert!(!is_wont_do(
            &serde_json::json!({"fields": {"status": {"name": "To Do"}}})
        ));
    }
}
