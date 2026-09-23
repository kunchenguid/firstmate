//! Publishing what the captain sees to `data/vessel/context.json`.
//!
//! firstmate cannot see the TUI, so "review this PR" means nothing to it on
//! its own. vessel writes the item on screen (`focus`) and the Jira and GitHub
//! lists it has loaded. The `vessel-workflows` skill reads them to resolve
//! loose targets. The file is a hint: the skill still fetches the live PR or
//! ticket before it writes a brief.
//!
//! Schema v1, readers ignore unknown fields. `ts` is the last write, refreshed
//! at least every [`HEARTBEAT`], so a file older than a few heartbeats means
//! vessel is gone.

use std::{
    path::PathBuf,
    time::{Duration, Instant},
};

use serde_json::{Map, Value, json};

use crate::{
    app::{
        App, GitHubOthersState, GitHubSection, GitHubState, JiraDetailState, JiraState,
        OverviewSection, unix_now,
    },
    config::write_atomic,
    firstmate::runs::Run,
    github::{PullRequest, ReviewDecision, ReviewPullRequest, ReviewStatus, ticket_key_from_title},
    jira::{BoardStatus, Ticket},
};

const HEARTBEAT: Duration = Duration::from_secs(5 * 60);

/// Writes the context file when its contents change. Without a path (tests,
/// `App::default()`) it does nothing.
#[derive(Default)]
pub(crate) struct ContextWriter {
    path: Option<PathBuf>,
    written: Option<(String, Instant)>,
    /// Last loaded lists, kept while a refresh is in flight or has failed so a
    /// slow reload never reads as "the captain has no pull requests".
    my_prs: Option<Value>,
    review_prs: Option<Value>,
    tickets: Option<Value>,
}

impl ContextWriter {
    pub(crate) fn new(path: PathBuf) -> Self {
        Self {
            path: Some(path),
            ..Self::default()
        }
    }
}

impl App {
    /// Called once per frame; writes only when something changed.
    pub(crate) fn publish_context(&mut self) {
        let focus = self.context_focus();
        self.write_context(focus);
    }

    /// Called on quit: the lists stay useful, the focus does not.
    pub(crate) fn publish_context_on_exit(&mut self) {
        self.write_context(Value::Null);
    }

    fn write_context(&mut self, focus: Value) {
        if self.context.path.is_none() {
            return;
        }
        self.refresh_context_lists();
        let context = &self.context;
        let mut document = Map::new();
        document.insert("v".into(), json!(1));
        document.insert("focus".into(), focus);
        for (key, list) in [
            ("my_prs", &context.my_prs),
            ("review_prs", &context.review_prs),
            ("tickets", &context.tickets),
        ] {
            if let Some(list) = list {
                document.insert(key.into(), list.clone());
            }
        }
        let contents = Value::Object(document.clone()).to_string();
        if context
            .written
            .as_ref()
            .is_some_and(|(last, at)| *last == contents && at.elapsed() < HEARTBEAT)
        {
            return;
        }
        let Some(path) = &context.path else {
            return;
        };
        document.insert("ts".into(), json!(unix_now()));
        let Ok(stamped) = serde_json::to_string_pretty(&document) else {
            return;
        };
        let written = path
            .parent()
            .is_some_and(|directory| std::fs::create_dir_all(directory).is_ok())
            && write_atomic(path, &(stamped + "\n")).is_ok();
        if written {
            self.context.written = Some((contents, Instant::now()));
        }
    }

    fn refresh_context_lists(&mut self) {
        match &self.github {
            GitHubState::Ready(pull_requests) => {
                self.context.my_prs = Some(pull_requests.iter().map(my_pr).collect());
            }
            GitHubState::Disabled => self.context.my_prs = None,
            GitHubState::Loading | GitHubState::Error(_) => {}
        }
        match &self.github_others {
            GitHubOthersState::Ready(pull_requests) => {
                self.context.review_prs = Some(pull_requests.iter().map(review_pr).collect());
            }
            GitHubOthersState::Disabled => self.context.review_prs = None,
            GitHubOthersState::Loading | GitHubOthersState::Error(_) => {}
        }
        match &self.jira {
            JiraState::Ready(tickets) => {
                self.context.tickets = Some(tickets.iter().map(ticket).collect());
            }
            JiraState::Disabled => self.context.tickets = None,
            JiraState::Loading | JiraState::Error(_) => {}
        }
    }

    /// The item on screen, following the same precedence as `ui::render`.
    pub(crate) fn context_focus(&self) -> Value {
        if let Some(view) = &self.run_view {
            return self
                .fleet
                .run(&view.task)
                .map_or_else(|| json!({"kind": "run", "task": view.task}), run_focus);
        }
        if self.activity.is_some() || self.agent_settings.is_some() {
            return Value::Null;
        }
        if let Some(detail) = &self.jira_detail {
            return match detail {
                JiraDetailState::Ready(ticket) => json!({
                    "kind": "ticket",
                    "key": ticket.key,
                    "summary": ticket.title,
                    "status": ticket.status,
                    "feature": ticket.feature,
                }),
                JiraDetailState::Loading(key) | JiraDetailState::Error { key, .. } => {
                    json!({"kind": "ticket", "key": key})
                }
            };
        }
        if let Some(review) = &self.github_review {
            return json!({
                "kind": "pr",
                "repo": review.repository,
                "number": review.number,
                "title": review.title,
                "url": review.url,
                "ticket_key": review.ticket_key,
                "selected_feedback": review.selected_feedback,
            });
        }
        match self.active_tab {
            0 => match self.overview_section {
                OverviewSection::Crew => self
                    .crew_runs()
                    .get(self.overview_selected)
                    .map_or(Value::Null, |run| run_focus(run)),
                OverviewSection::Jira => self.highlighted_ticket(),
                OverviewSection::GitHubMe | OverviewSection::GitHubOther => {
                    self.highlighted_pull_request()
                }
            },
            1 => self.highlighted_ticket(),
            2 => self.highlighted_pull_request(),
            _ => Value::Null,
        }
    }

    fn highlighted_ticket(&self) -> Value {
        let JiraState::Ready(tickets) = &self.jira else {
            return Value::Null;
        };
        tickets
            .get(self.jira_selected)
            .map_or(Value::Null, |selected| {
                let mut value = ticket(selected);
                value["kind"] = json!("ticket");
                value
            })
    }

    fn highlighted_pull_request(&self) -> Value {
        let value = match (self.github_section, &self.github, &self.github_others) {
            (GitHubSection::MyWork, GitHubState::Ready(pull_requests), _) => {
                pull_requests.get(self.github_selected).map(my_pr)
            }
            (GitHubSection::OtherWork, _, GitHubOthersState::Ready(pull_requests)) => pull_requests
                .get(self.github_others_selected)
                .map(review_pr),
            _ => None,
        };
        value.map_or(Value::Null, |mut value| {
            value["kind"] = json!("pr");
            value
        })
    }
}

fn run_focus(run: &Run) -> Value {
    json!({
        "kind": "run",
        "task": run.task,
        "workflow": run.workflow,
        "title": run.title,
        "ticket_key": run.ticket_key,
        "repo": run.repo,
        "number": run.pr_number,
        "url": run.pr_url,
    })
}

fn my_pr(pull_request: &PullRequest) -> Value {
    json!({
        "repo": pull_request.repository,
        "number": pull_request.number,
        "title": pull_request.title,
        "url": pull_request.url,
        "head": pull_request.head_commit,
        "status": review_status(pull_request.status),
        "has_conflicts": pull_request.has_conflicts,
        "needs_attention": pull_request.needs_attention,
        "ticket_key": ticket_key_from_title(&pull_request.title),
    })
}

fn review_pr(pull_request: &ReviewPullRequest) -> Value {
    json!({
        "repo": pull_request.repository,
        "number": pull_request.number,
        "title": pull_request.title,
        "url": pull_request.url,
        "head": pull_request.head_commit,
        "my_status": review_decision(pull_request.my_status),
        "total_status": review_decision(pull_request.total_status),
        "ticket_key": ticket_key_from_title(&pull_request.title),
    })
}

fn ticket(ticket: &Ticket) -> Value {
    json!({
        "key": ticket.key,
        "summary": ticket.summary,
        "status": board_status(ticket.status),
        "feature": ticket.feature,
    })
}

const fn review_status(status: ReviewStatus) -> &'static str {
    match status {
        ReviewStatus::Draft => "draft",
        ReviewStatus::Waiting => "waiting",
        ReviewStatus::ChangesRequested => "changes_requested",
        ReviewStatus::Approved => "approved",
    }
}

const fn review_decision(decision: ReviewDecision) -> &'static str {
    match decision {
        ReviewDecision::Waiting => "waiting",
        ReviewDecision::ChangesRequested => "changes_requested",
        ReviewDecision::Approved => "approved",
    }
}

const fn board_status(status: BoardStatus) -> &'static str {
    match status {
        BoardStatus::ToDo => "to_do",
        BoardStatus::OnHold => "on_hold",
        BoardStatus::InProgress => "in_progress",
        BoardStatus::InReview => "in_review",
    }
}

#[cfg(test)]
mod tests;
