use std::collections::BTreeSet;

use crossterm::event::KeyCode;
use ratatui::{Terminal, backend::TestBackend};

use super::*;
use crate::input::handle_github_comments_key;

fn comment(id: &str, body: &str) -> PullRequestComment {
    PullRequestComment {
        created_at: Some("2026-09-14T09:00:00Z".into()),
        review_state: None,
        id: Some(id.into()),
        url: None,
        author: "reviewer".into(),
        body: body.into(),
        thread: None,
        resolved: false,
        path: None,
        line: None,
        diff_hunk: None,
    }
}

fn app(comments: Vec<PullRequestComment>) -> App {
    App {
        github_review: Some(GitHubReviewState {
            repository: "org/repo".into(),
            number: 42,
            title: "Improve PR discussions".into(),
            url: "https://github.test/org/repo/pull/42".into(),
            ticket_key: None,
            ticket: None,
            selected: 0,
            focus: GitHubReviewFocus::Comments,
            description_scroll: 0,
            comment_scroll: 0,
            comment_selected: 0,
            selected_feedback: BTreeSet::new(),
            collapsed_feedback: BTreeSet::new(),
            show_resolved: true,
            detail: GitHubDetailState::Ready(PullRequestDetail {
                title: "Improve PR discussions".into(),
                head_commit: String::new(),
                description: String::new(),
                author: "author".into(),
                is_draft: false,
                review_decision: None,
                mergeable: None,
                merge_state_status: None,
                ci_status: None,
                reviewers: Vec::new(),
                comments,
            }),
        }),
        ..App::default()
    }
}

fn screen(app: &App, area: Rect) -> String {
    let mut terminal = Terminal::new(TestBackend::new(area.width, area.height)).unwrap();
    terminal.draw(|frame| render(frame, app)).unwrap();
    terminal
        .backend()
        .buffer()
        .content()
        .chunks(usize::from(area.width))
        .map(|row| {
            row.iter()
                .map(|cell| cell.symbol())
                .collect::<String>()
                .trim_end()
                .to_owned()
        })
        .collect::<Vec<_>>()
        .join("\n")
}

#[test]
fn renders_reviews_markdown_and_resolved_thread_replies() {
    let mut review = comment(
        "review",
        "Please **retry** failures.\n\n- Handle `timeout`\n- Keep the result",
    );
    review.review_state = Some("CHANGES_REQUESTED".into());
    let mut root = comment("root", "Check this branch.");
    root.thread = Some("thread".into());
    root.resolved = true;
    root.path = Some("src/main.rs".into());
    root.line = Some(42);
    root.diff_hunk = Some(" old code\n+retry()".into());
    let mut reply = comment("reply", "Fixed in the latest push.");
    reply.thread = Some("thread".into());
    reply.resolved = true;
    let app = app(vec![review, root, reply]);
    let text = screen(&app, Rect::new(0, 0, 100, 40));
    for expected in [
        "3/3 messages",
        "Review · Changes Requested",
        "Please retry failures.",
        "Handle timeout",
        "Resolved Thread",
        "src/main.rs:42",
        "2 messages",
        "+retry()",
        "Fixed in the latest push.",
    ] {
        assert!(text.contains(expected), "Missing {expected}:\n{text}");
    }
    assert!(!text.contains("**retry**"));
}

#[test]
fn wrapped_comments_use_rendered_rows_for_selection_at_different_sizes() {
    for (width, height) in [(44, 24), (80, 30), (120, 40)] {
        let area = Rect::new(0, 0, width, height);
        let mut app = app(vec![
            comment("long", &"a long line with wide 界 characters ".repeat(80)),
            comment("next", "Visible selected comment"),
        ]);
        app.notice = Some("An extra notice consumes rows".into());
        handle_github_comments_key(&mut app, KeyCode::Down, area);
        let text = screen(&app, area);
        assert!(
            text.contains("Visible selected comment"),
            "{width}x{height}:\n{text}"
        );
        assert!(text.contains("› [ ] ▾ Comment"), "{text}");
        assert_eq!(app.github_review.as_ref().unwrap().comment_selected, 1);
    }
}

#[test]
fn page_keys_reach_the_tail_of_a_single_comment_and_home_returns_to_the_start() {
    let area = Rect::new(0, 0, 70, 25);
    let body = format!(
        "START OF COMMENT\n\n{}\n\nFINAL COMMENT LINE",
        "wrapped prose for a long review comment ".repeat(220)
    );
    let mut app = app(vec![comment("long", &body)]);
    assert!(screen(&app, area).contains("START OF COMMENT"));
    handle_github_comments_key(&mut app, KeyCode::PageDown, area);
    assert!(!screen(&app, area).contains("START OF COMMENT"));
    assert_eq!(app.github_review.as_ref().unwrap().comment_selected, 0);
    for _ in 0..100 {
        handle_github_comments_key(&mut app, KeyCode::PageDown, area);
    }
    assert!(screen(&app, area).contains("FINAL COMMENT LINE"));
    handle_github_comments_key(&mut app, KeyCode::Home, area);
    assert!(screen(&app, area).contains("START OF COMMENT"));
    handle_github_comments_key(&mut app, KeyCode::End, area);
    assert!(screen(&app, area).contains("FINAL COMMENT LINE"));
    handle_github_comments_key(&mut app, KeyCode::Enter, area);
    let text = screen(&app, area);
    assert!(text.contains("▸ Comment"));
    assert!(text.contains("reviewer: START OF COMMENT"));
}

#[test]
fn resolved_filter_has_an_explicit_empty_state_and_restores_comments() {
    let mut root = comment("resolved", "Resolved feedback remains readable");
    root.thread = Some("thread".into());
    root.resolved = true;
    let mut app = app(vec![root]);
    let area = Rect::new(0, 0, 100, 30);
    app.toggle_github_resolved();
    let text = screen(&app, area);
    assert!(text.contains("0/1 messages"));
    assert!(text.contains("All discussions are resolved. Press R"));
    app.toggle_github_resolved();
    assert!(screen(&app, area).contains("Resolved feedback remains readable"));
}

#[test]
fn reload_preserves_expansion_and_marks_by_comment_id() {
    let mut app = app(vec![
        comment("one", "First comment"),
        comment("two", "Second comment"),
    ]);
    let area = Rect::new(0, 0, 100, 30);
    handle_github_comments_key(&mut app, KeyCode::Down, area);
    handle_github_comments_key(&mut app, KeyCode::Enter, area);
    handle_github_comments_key(&mut app, KeyCode::Char(' '), area);
    let review = app.github_review.as_ref().unwrap();
    let GitHubDetailState::Ready(mut detail) = review.detail.clone() else {
        panic!()
    };
    detail
        .comments
        .insert(0, comment("new", "Newly loaded review"));
    let (sender, receiver) = std::sync::mpsc::channel();
    sender.send(Ok(detail)).unwrap();
    app.github_detail_rx = Some(receiver);
    app.update_github_detail();
    let review = app.github_review.as_ref().unwrap();
    assert_eq!(review.collapsed_feedback, BTreeSet::from(["two".into()]));
    assert_eq!(review.selected_feedback, BTreeSet::from(["two".into()]));
    let text = screen(&app, area);
    assert!(text.contains("First comment"));
    assert!(text.contains("[x] ▸ Comment"));
    assert!(text.contains("reviewer: Second comment"));
}

#[test]
#[ignore = "Run python3 vessel/tests/pr_comments_smoke.py to supply an offline gh fixture"]
fn cli_discussion_smoke() {
    let output = std::env::var("VESSEL_COMMENTS_SMOKE_DIR").expect("Run the smoke script");
    let detail = crate::github::load_pull_request_detail("fixture/comments", 42).unwrap();
    assert_eq!(detail.comments.len(), 203);
    assert_eq!(
        detail
            .comments
            .iter()
            .filter(|comment| comment.body == "LAST ISSUE COMMENT")
            .count(),
        1
    );
    let mut app = app(Vec::new());
    app.github_review.as_mut().unwrap().detail = GitHubDetailState::Ready(detail);
    let area = Rect::new(0, 0, 100, 30);
    let initial = screen(&app, area);
    assert!(initial.contains("203/203 messages"));
    std::fs::write(format!("{output}/initial.txt"), initial).unwrap();
    handle_github_comments_key(&mut app, KeyCode::End, area);
    let tail = screen(&app, area);
    assert!(tail.contains("FINAL THREAD REPLY"));
    std::fs::write(format!("{output}/thread-tail.txt"), tail).unwrap();
    handle_github_comments_key(&mut app, KeyCode::Up, area);
    let review = screen(&app, area);
    assert!(review.contains("Review · Changes Requested"));
    assert!(review.contains("Please retry failures."));
    std::fs::write(format!("{output}/review.txt"), review).unwrap();
    handle_github_comments_key(&mut app, KeyCode::Down, area);
    handle_github_comments_key(&mut app, KeyCode::Enter, area);
    let collapsed = screen(&app, area);
    assert!(collapsed.contains("▸ Resolved Thread"));
    assert!(collapsed.contains("101 messages"));
    std::fs::write(format!("{output}/collapsed.txt"), collapsed).unwrap();
}

#[test]
fn review_tables_checklists_and_html_summaries_keep_their_text() {
    let body = "<details>\n<summary>Review details</summary>\n\n| File | Finding |\n| --- | --- |\n| main.rs | Retry failures |\n\n- [x] Checked\n- [ ] Follow up\n\n</details>";
    let text = screen(
        &app(vec![comment("review", body)]),
        Rect::new(0, 0, 100, 35),
    );
    for expected in [
        "Review details",
        "File  │  Finding",
        "main.rs  │  Retry failures",
        "[x] Checked",
        "[ ] Follow up",
    ] {
        assert!(text.contains(expected), "Missing {expected}:\n{text}");
    }
}

#[test]
fn mouse_scrolling_and_navigation_after_resize_reach_the_selected_comment() {
    let mut app = app(vec![
        comment("long", &"Long comment text ".repeat(200)),
        comment("last", "Last comment is visible"),
    ]);
    let wide = Rect::new(0, 0, 120, 30);
    let narrow = Rect::new(0, 0, 44, 24);
    handle_github_comments_key(&mut app, KeyCode::End, wide);
    let (ranges, height) = github_comments_navigation(&app, narrow);
    app.reveal_github_comment(&ranges, height);
    assert!(screen(&app, narrow).contains("Last comment is visible"));
    handle_github_comments_key(&mut app, KeyCode::Home, narrow);
    crate::input::handle_mouse_scroll(&mut app, 3, narrow);
    assert_eq!(app.github_review.as_ref().unwrap().comment_scroll, 3);
    crate::input::handle_mouse_scroll(&mut app, -3, narrow);
    assert_eq!(app.github_review.as_ref().unwrap().comment_scroll, 0);
}
