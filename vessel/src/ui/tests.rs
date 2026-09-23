use ratatui::{Terminal, backend::TestBackend, buffer::Buffer};

use super::{
    github::{group_pull_requests, pull_request_status, review_decision_status},
    *,
};
use crate::{
    app::{GitHubDetailState, GitHubReviewState, JiraDetailFocus, JiraDetailState},
    firstmate::{
        runs::{RunRecord, TimelineEntry},
        snapshot::OpenDecision,
    },
    github::PullRequestDetail,
    jira::TicketDetail,
};

fn draw(app: &App, width: u16, height: u16) -> String {
    let mut terminal = Terminal::new(TestBackend::new(width, height)).unwrap();
    terminal.draw(|frame| render(frame, app)).unwrap();
    text(terminal.backend().buffer())
}

fn text(buffer: &Buffer) -> String {
    (0..buffer.area.height)
        .map(|row| {
            (0..buffer.area.width)
                .map(|column| buffer[(column, row)].symbol())
                .collect::<String>()
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn run(task: &str, workflow: &str, status: RunStatus, live: bool, at: u64) -> Run {
    Run {
        task: task.into(),
        workflow: Some(workflow.into()),
        record: Some(RunRecord {
            ts: at,
            task: task.into(),
            workflow: workflow.into(),
            agent: Some(
                if workflow == "review" {
                    "Snoop"
                } else {
                    "Slim Charles"
                }
                .into(),
            ),
            pr_head: Some("abc123".into()),
            ..RunRecord::default()
        }),
        kind: Some(
            if workflow == "review" {
                "scout"
            } else {
                "ship"
            }
            .into(),
        ),
        project: Some("webapp".into()),
        harness: Some("pi".into()),
        model: Some("gpt-5.6-luna".into()),
        title: format!("Title of {task}"),
        ticket_key: Some("AA4FI-7".into()),
        repo: Some("acme/webapp".into()),
        pr_number: Some(42),
        pr_url: Some("https://github.com/acme/webapp/pull/42".into()),
        created_at: Some(at),
        finished_at: (!live).then_some(at + 60),
        status,
        status_text: Some(format!("{task} latest status")),
        timeline: vec![TimelineEntry {
            ts: at + 30,
            state: "working".into(),
            text: "halfway there".into(),
        }],
        open_decisions: Vec::new(),
        live,
        endpoint_exists: Some(live),
    }
}

fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

fn app_with_runs(runs: Vec<Run>) -> App {
    let mut app = App::default();
    app.fleet.runs = runs;
    app
}

#[test]
fn crew_overview_puts_decisions_first_and_marks_the_selection() {
    let now = now();
    let mut waiting = run(
        "review-webapp-42",
        "review",
        RunStatus::NeedsDecision,
        true,
        now - 60,
    );
    waiting.status_text = Some("review only the API?".into());
    let app = app_with_runs(vec![
        run(
            "implement-aa4fi-7",
            "implement",
            RunStatus::Working,
            true,
            now - 120,
        ),
        waiting,
        run(
            "plan-aa4fi-7",
            "plan",
            RunStatus::Completed,
            false,
            now - 600,
        ),
    ]);

    let screen = draw(&app, 140, 40);

    let needs_you = screen.find("Needs you").unwrap();
    let running = screen.find("Running crew").unwrap();
    let finished = screen.find("Finished today").unwrap();
    assert!(needs_you < running && running < finished, "{screen}");
    let selected = screen.lines().find(|line| line.contains('›')).unwrap();
    assert!(
        selected.contains("◇") && selected.contains("#42"),
        "{selected}"
    );
    assert!(selected.contains("review only the API?"));
    assert!(screen.contains("◐") && screen.contains("AA4FI-7"));
    assert!(screen.contains("1 working") && screen.contains("1 need you"));
}

#[test]
fn run_view_shows_profile_history_decisions_and_documents() {
    let now = now();
    let mut review = run(
        "review-webapp-42",
        "review",
        RunStatus::NeedsDecision,
        true,
        now - 60,
    );
    review.open_decisions = vec![OpenDecision {
        verb: "needs-decision".into(),
        key: Some("scope".into()),
        text: "API only?".into(),
    }];
    let mut app = app_with_runs(vec![review]);
    app.open_run("review-webapp-42".into(), Some(now - 60));
    if let Some(view) = &mut app.run_view {
        view.report = Some("# Findings\n\n- **Race** in the limiter".into());
    }

    let status = draw(&app, 120, 30);
    assert!(
        status.contains("Review  ·  Snoop  ·  pi  ·  gpt-5.6-luna"),
        "{status}"
    );
    assert!(status.contains("Ticket AA4FI-7  ·  PR acme/webapp#42"));
    assert!(status.contains("[scope] API only?"));
    assert!(status.contains("halfway there"));
    assert!(status.contains("vessel is read-only"));

    app.toggle_run_view_focus(2);
    let report = draw(&app, 120, 30);
    assert!(report.contains("Race in the limiter"), "{report}");
    assert!(!report.contains("**"));
}

#[test]
fn pull_request_runs_show_history_and_review_freshness() {
    let now = now();
    let app = App {
        github_review: Some(GitHubReviewState {
            repository: "acme/webapp".into(),
            number: 42,
            title: "Rate limiting".into(),
            url: "https://github.com/acme/webapp/pull/42".into(),
            ticket_key: None,
            ticket: None,
            selected: 0,
            focus: GitHubReviewFocus::Reviews,
            description_scroll: 0,
            comment_scroll: 0,
            comment_selected: 0,
            selected_feedback: Default::default(),
            collapsed_feedback: Default::default(),
            show_resolved: true,
            detail: GitHubDetailState::Ready(PullRequestDetail {
                title: "Rate limiting".into(),
                head_commit: "def456".into(),
                description: String::new(),
                author: "me".into(),
                is_draft: false,
                review_decision: None,
                mergeable: None,
                merge_state_status: None,
                ci_status: None,
                reviewers: Vec::new(),
                comments: Vec::new(),
            }),
        }),
        ..app_with_runs(vec![
            run(
                "address-webapp-42",
                "address",
                RunStatus::Working,
                true,
                now - 60,
            ),
            run(
                "review-webapp-42",
                "review",
                RunStatus::Completed,
                false,
                now - 3600,
            ),
            {
                let mut other = run("review-api-42", "review", RunStatus::Completed, false, now);
                other.repo = Some("acme/api".into());
                other
            },
        ])
    };

    let screen = draw(&app, 120, 30);

    assert!(screen.contains("Runs (2)"), "{screen}");
    assert!(screen.contains("Slim Charles  Address  address-webapp-42"));
    assert!(screen.contains("Snoop  Review  review-webapp-42"));
    assert!(screen.contains("Completed  (new commits)"));
    assert!(!screen.contains("review-api-42"));
}

#[test]
fn ticket_detail_lists_runs_and_plans() {
    let now = now();
    let mut app = app_with_runs(vec![
        run(
            "implement-aa4fi-7",
            "implement",
            RunStatus::Merged,
            false,
            now - 60,
        ),
        run(
            "plan-aa4fi-7",
            "plan",
            RunStatus::Completed,
            false,
            now - 600,
        ),
    ]);
    app.jira_detail = Some(JiraDetailState::Ready(TicketDetail {
        key: "AA4FI-7".into(),
        title: "Login redirect".into(),
        description: "Users lose their page.".into(),
        reporter: "pm".into(),
        comments: Vec::new(),
        feature: "Auth".into(),
        status: "In Progress".into(),
    }));
    app.jira_detail_focus = JiraDetailFocus::Runs;

    let runs = draw(&app, 120, 30);
    assert!(runs.contains("Runs (2)"), "{runs}");
    assert!(runs.contains("Merged"));
    assert!(runs.contains("plan-aa4fi-7") && runs.contains("implement-aa4fi-7"));

    app.ticket_plans = vec![crate::app::PlanOption {
        label: "Stringer - today".into(),
        text: "# Plan".into(),
    }];
    app.jira_detail_focus = JiraDetailFocus::Plans;
    assert!(draw(&app, 120, 30).contains("Stringer - today"));
}

#[test]
fn agent_settings_list_and_editor_render() {
    let mut app = App {
        agents: vec![crate::agents::Agent {
            name: "Snoop".into(),
            mode: "Review".into(),
            harness: "pi".into(),
            model: String::new(),
            effort: String::new(),
            instructions: "Be thorough.".into(),
            instructions_file: Some("snoop.md".into()),
        }],
        harnesses: vec!["claude".into(), "pi".into()],
        ..App::default()
    };
    app.select_tab(3);
    app.open_selected_settings_section();

    let list = draw(&app, 120, 30);
    assert!(list.contains("Agents (1)"), "{list}");
    assert!(list.contains("Review · pi · default model"));

    app.open_selected_agent();
    app.toggle_agent_settings_focus();
    app.toggle_agent_settings_focus();
    app.move_agent_option(-1);
    let editor = draw(&app, 120, 40);
    assert!(editor.contains("Agent: Snoop"), "{editor}");
    assert!(editor.contains("claude"));
    assert!(editor.contains("harness default"));
    assert_eq!(app.agents[0].harness, "claude", "saved back to the app");
}

#[test]
fn run_statuses_use_remy_glyphs() {
    assert_eq!(run_status_symbol(RunStatus::Working), "◐");
    assert_eq!(run_status_symbol(RunStatus::NeedsDecision), "◇");
    assert_eq!(run_status_symbol(RunStatus::Failed), "✕");
    assert_eq!(run_status_symbol(RunStatus::Merged), "✓");
    assert_eq!(run_status_color(RunStatus::Blocked), RED);
    assert_eq!(run_status_color(RunStatus::Completed), GREEN);
}

#[test]
fn overview_scroll_keeps_the_selected_row_visible() {
    assert_eq!(overview_scroll_offset(2, 5), 0);
    assert_eq!(overview_scroll_offset(5, 5), 1);
    assert_eq!(overview_scroll_offset(10, 5), 6);
}

#[test]
fn markdown_description_renders_structure_without_markup_tokens() {
    let lines = markdown_lines("# Summary\n\n**Important** and `code`\n\n- one");
    let text = lines
        .iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join("\n");

    assert!(text.contains("Summary"));
    assert!(text.contains("Important"));
    assert!(text.contains("code"));
    assert!(text.contains("- one"));
    assert!(!text.contains("**"));
}

#[test]
fn markdown_paragraphs_keep_a_blank_line() {
    let lines = markdown_lines("First paragraph.\n\nSecond paragraph.");

    assert_eq!(lines.len(), 3);
    assert_eq!(lines[0].to_string(), "First paragraph.");
    assert!(lines[1].to_string().is_empty());
    assert_eq!(lines[2].to_string(), "Second paragraph.");
}

#[test]
fn markdown_list_items_do_not_get_extra_blank_lines() {
    let lines = markdown_lines("- one\n- two");

    assert_eq!(lines.len(), 2);
    assert_eq!(lines[0].to_string(), "  - one");
    assert_eq!(lines[1].to_string(), "  - two");
}

#[test]
fn github_pull_requests_are_grouped_by_repository() {
    let pull_request = |repository: &str, number| PullRequest {
        repository: repository.into(),
        number,
        title: format!("PR {number}"),
        url: format!("https://github.test/{repository}/{number}"),
        head_commit: String::new(),
        has_conflicts: false,
        status: ReviewStatus::Waiting,
        needs_attention: false,
        ci_status: None,
        review_ids: vec![],
        unresolved_thread_ids: vec![],
    };
    let pull_requests = vec![
        pull_request("org/b", 1),
        pull_request("org/a", 2),
        pull_request("org/b", 3),
    ];

    let groups = group_pull_requests(&pull_requests);

    assert_eq!(
        groups.keys().copied().collect::<Vec<_>>(),
        ["org/a", "org/b"]
    );
    assert_eq!(groups["org/b"].len(), 2);
}

#[test]
fn github_statuses_use_compact_symbols() {
    let pull_request = |status| PullRequest {
        repository: "org/project".into(),
        number: 42,
        title: "Review this".into(),
        url: "https://github.test/org/project/42".into(),
        head_commit: String::new(),
        has_conflicts: false,
        status,
        needs_attention: matches!(status, ReviewStatus::Draft | ReviewStatus::ChangesRequested),
        ci_status: None,
        review_ids: vec![],
        unresolved_thread_ids: vec![],
    };

    assert_eq!(
        pull_request_status(&pull_request(ReviewStatus::Draft)),
        ("○", BORDER)
    );
    assert_eq!(
        pull_request_status(&pull_request(ReviewStatus::Waiting)),
        ("◐", GOLD)
    );
    assert_eq!(
        pull_request_status(&pull_request(ReviewStatus::ChangesRequested)),
        ("✕", RED)
    );
    assert_eq!(
        pull_request_status(&pull_request(ReviewStatus::Approved)),
        ("✓", GREEN)
    );
    assert_eq!(review_decision_status(ReviewDecision::Waiting), ("◐", GOLD));
    assert_eq!(
        review_decision_status(ReviewDecision::Approved),
        ("✓", GREEN)
    );
}

#[test]
fn agent_review_status_uses_compact_symbols() {
    assert_eq!(agent_review_status(AgentReviewStatus::NotReviewed).0, "○");
    assert_eq!(agent_review_status(AgentReviewStatus::Unknown).0, "●");
    assert_eq!(agent_review_status(AgentReviewStatus::Current).0, "✓");
    assert_eq!(agent_review_status(AgentReviewStatus::NewCommits).0, "✕");
    assert_eq!(agent_review_status(AgentReviewStatus::Running).0, "●");
}
