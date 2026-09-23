use std::path::PathBuf;

use super::*;
use crate::{
    app::{GitHubDetailState, GitHubReviewFocus, GitHubReviewState, RunViewFocus, RunViewState},
    firstmate::runs::RunStatus,
    jira::TicketDetail,
};

fn temp_file(name: &str) -> PathBuf {
    let directory =
        std::env::temp_dir().join(format!("vessel-context-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&directory);
    directory.join("data/vessel/context.json")
}

fn read(path: &PathBuf) -> Value {
    serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
}

fn tickets() -> Vec<Ticket> {
    vec![
        Ticket {
            key: "AA4FI-1".into(),
            summary: "Login page".into(),
            status: BoardStatus::ToDo,
            feature: "Auth".into(),
        },
        Ticket {
            key: "AA4FI-2".into(),
            summary: "Checkout".into(),
            status: BoardStatus::InReview,
            feature: "Payments".into(),
        },
    ]
}

fn pull_requests() -> Vec<PullRequest> {
    vec![PullRequest {
        repository: "acme/webapp".into(),
        number: 42,
        title: "AA4FI-1 Rate limiting".into(),
        url: "https://github.com/acme/webapp/pull/42".into(),
        head_commit: "abc123".into(),
        has_conflicts: false,
        status: ReviewStatus::ChangesRequested,
        needs_attention: true,
        ci_status: None,
        review_ids: vec![],
        unresolved_thread_ids: vec![],
    }]
}

fn review(selected_feedback: &[&str]) -> GitHubReviewState {
    GitHubReviewState {
        repository: "acme/webapp".into(),
        number: 42,
        title: "Rate limiting".into(),
        url: "https://github.com/acme/webapp/pull/42".into(),
        ticket_key: Some("AA4FI-1".into()),
        ticket: None,
        selected: 0,
        focus: GitHubReviewFocus::Comments,
        description_scroll: 0,
        comment_scroll: 0,
        comment_selected: 0,
        selected_feedback: selected_feedback.iter().map(|id| (*id).into()).collect(),
        collapsed_feedback: Default::default(),
        show_resolved: true,
        detail: GitHubDetailState::Loading,
    }
}

fn run(task: &str) -> Run {
    Run {
        task: task.into(),
        workflow: Some("review".into()),
        record: None,
        kind: None,
        project: None,
        harness: None,
        model: None,
        title: "Rate limiting".into(),
        ticket_key: None,
        repo: Some("acme/webapp".into()),
        pr_number: Some(42),
        pr_url: None,
        created_at: Some(unix_now()),
        finished_at: None,
        status: RunStatus::Working,
        status_text: None,
        timeline: Vec::new(),
        open_decisions: Vec::new(),
        live: true,
        endpoint_exists: None,
    }
}

#[test]
fn focus_is_the_highlighted_list_row() {
    let mut app = App {
        jira: JiraState::Ready(tickets()),
        github: GitHubState::Ready(pull_requests()),
        ..App::default()
    };

    app.active_tab = 1;
    app.jira_selected = 1;
    assert_eq!(app.context_focus()["kind"], "ticket");
    assert_eq!(app.context_focus()["key"], "AA4FI-2");

    app.active_tab = 2;
    let focus = app.context_focus();
    assert_eq!(focus["kind"], "pr");
    assert_eq!(focus["repo"], "acme/webapp");
    assert_eq!(focus["number"], 42);
    assert_eq!(focus["status"], "changes_requested");

    app.active_tab = 0;
    app.overview_section = OverviewSection::GitHubOther;
    app.github_section = GitHubSection::OtherWork;
    assert_eq!(
        app.context_focus(),
        Value::Null,
        "other PRs are still loading"
    );
}

#[test]
fn focus_is_the_open_page() {
    let mut app = App {
        github_review: Some(review(&["thread-1", "thread-2"])),
        ..App::default()
    };
    let focus = app.context_focus();
    assert_eq!(focus["kind"], "pr");
    assert_eq!(focus["ticket_key"], "AA4FI-1");
    assert_eq!(focus["selected_feedback"], json!(["thread-1", "thread-2"]));

    app.github_review = None;
    app.jira_detail = Some(JiraDetailState::Ready(TicketDetail {
        key: "AA4FI-1".into(),
        title: "Login page".into(),
        description: String::new(),
        reporter: String::new(),
        comments: Vec::new(),
        feature: "Auth".into(),
        status: "In Progress".into(),
    }));
    assert_eq!(app.context_focus()["key"], "AA4FI-1");
    assert_eq!(app.context_focus()["summary"], "Login page");

    app.fleet.runs = vec![run("review-webapp-42")];
    app.run_view = Some(RunViewState {
        task: "review-webapp-42".into(),
        created_at: None,
        focus: RunViewFocus::Status,
        scroll: 0,
        brief: None,
        report: None,
    });
    let focus = app.context_focus();
    assert_eq!(focus["kind"], "run");
    assert_eq!(focus["task"], "review-webapp-42");
    assert_eq!(focus["number"], 42);

    app.run_view = None;
    app.jira_detail = None;
    app.active_tab = 0;
    assert_eq!(app.context_focus()["task"], "review-webapp-42", "crew row");
}

#[test]
fn writes_only_when_something_changes() {
    let path = temp_file("changes");
    let mut app = App {
        context: ContextWriter::new(path.clone()),
        jira: JiraState::Ready(tickets()),
        active_tab: 1,
        ..App::default()
    };

    app.publish_context();
    let first = read(&path);
    assert_eq!(first["v"], 1);
    assert_eq!(first["focus"]["key"], "AA4FI-1");
    assert_eq!(first["tickets"][1]["status"], "in_review");
    assert!(first["ts"].is_u64());

    std::fs::remove_file(&path).unwrap();
    app.publish_context();
    assert!(!path.exists(), "unchanged context is not rewritten");

    app.jira_selected = 1;
    app.publish_context();
    assert_eq!(read(&path)["focus"]["key"], "AA4FI-2");

    app.publish_context_on_exit();
    let last = read(&path);
    assert_eq!(last["focus"], Value::Null);
    assert_eq!(last["tickets"].as_array().unwrap().len(), 2);
    std::fs::remove_dir_all(path.ancestors().nth(3).unwrap()).ok();
}

#[test]
fn lists_survive_a_reload_and_disappear_when_disabled() {
    let path = temp_file("lists");
    let mut app = App {
        context: ContextWriter::new(path.clone()),
        github: GitHubState::Ready(pull_requests()),
        ..App::default()
    };
    app.publish_context();
    assert_eq!(read(&path)["my_prs"][0]["ticket_key"], "AA4FI-1");
    assert!(
        read(&path).get("tickets").is_none(),
        "Jira is still loading"
    );

    app.github = GitHubState::Loading;
    app.publish_context();
    assert_eq!(read(&path)["my_prs"][0]["number"], 42);

    app.github = GitHubState::Error("rate limited".into());
    app.publish_context();
    assert_eq!(read(&path)["my_prs"][0]["number"], 42);

    app.github = GitHubState::Disabled;
    app.publish_context();
    assert!(read(&path).get("my_prs").is_none());
    std::fs::remove_dir_all(path.ancestors().nth(3).unwrap()).ok();
}

#[test]
fn app_without_a_path_writes_nothing() {
    let mut app = App::default();
    app.publish_context();
    assert!(app.context.written.is_none());
}
