use super::*;
use crate::app::{JiraDirection, jira_viewport_height};
use crate::jira::Ticket;
use ratatui::{Terminal, backend::TestBackend, buffer::Buffer};

fn ticket(number: usize, feature: &str, status: BoardStatus) -> Ticket {
    Ticket {
        key: format!("REMY-{number}"),
        summary: format!("Work item {number}"),
        feature: feature.into(),
        status,
    }
}

fn draw(app: &App, width: u16, height: u16) -> Buffer {
    let mut terminal = Terminal::new(TestBackend::new(width, height)).unwrap();
    terminal
        .draw(|frame| super::super::render(frame, app))
        .unwrap();
    terminal.backend().buffer().clone()
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

#[test]
fn tree_navigation_uses_feature_and_natural_key_order_not_status() {
    let mut app = App {
        active_tab: 1,
        jira: JiraState::Ready(vec![
            ticket(10, "Checkout", BoardStatus::ToDo),
            ticket(2, "Checkout", BoardStatus::InReview),
            ticket(1, "Checkout", BoardStatus::InProgress),
            ticket(3, "Platform", BoardStatus::OnHold),
        ]),
        jira_selected: 2,
        ..App::default()
    };
    assert_eq!(
        jira_ticket_rows(app.jira.tickets()),
        [(2, 1), (1, 2), (0, 3), (3, 6)]
    );
    for expected in [1, 0, 3, 3] {
        app.move_jira_selection(JiraDirection::Down, 2);
        assert_eq!(app.jira_selected, expected);
    }
}

#[test]
fn tree_keeps_status_labels_and_selected_rows_visible_after_scrolling_and_resize() {
    let mut app = App {
        active_tab: 1,
        jira: JiraState::Ready(
            (1..=30)
                .map(|number| {
                    ticket(
                        number,
                        if number < 20 { "Checkout" } else { "Platform" },
                        BoardStatus::InProgress,
                    )
                })
                .collect(),
        ),
        ..App::default()
    };
    for (width, height) in [(120, 30), (80, 24), (40, 16)] {
        let viewport = jira_viewport_height(height);
        app.scroll_jira(isize::MAX, viewport);
        assert_eq!(
            app.jira_scroll,
            jira_content_height(app.jira.tickets()) - viewport
        );
        assert!(text(&draw(&app, width, height)).contains("REMY-30"));
        app.scroll_jira(isize::MIN, viewport);
        assert_eq!(app.jira_scroll, 0);
        for _ in 0..30 {
            app.move_jira_selection(JiraDirection::Down, viewport);
        }
        let output = text(&draw(&app, width, height));
        let selected = output
            .lines()
            .find(|line| line.contains("REMY-30"))
            .unwrap();
        assert!(selected.contains('›'));
        assert!(selected.contains("In Progress"));
        assert!(!output.contains('┌'));
        assert!(!output.contains('┐'));
    }
    // A stale offset after refresh must not leave an empty page.
    app.jira = JiraState::Ready(vec![ticket(1, "Checkout", BoardStatus::ToDo)]);
    assert!(text(&draw(&app, 80, 24)).contains("REMY-1"));
}

#[test]
fn jira_empty_loading_and_error_states_are_readable() {
    for (state, expected) in [
        (JiraState::Loading, "Loading your assigned Jira tickets"),
        (JiraState::Disabled, "Jira is turned off"),
        (
            JiraState::Ready(Vec::new()),
            "No Jira tickets are assigned to you.",
        ),
        (
            JiraState::Error("Authentication failed".into()),
            "Authentication failed",
        ),
    ] {
        let app = App {
            active_tab: 1,
            jira: state,
            ..App::default()
        };
        assert!(text(&draw(&app, 60, 20)).contains(expected));
        for (width, height) in [(1, 1), (20, 8)] {
            draw(&app, width, height);
        }
    }
}

#[test]
fn plan_remains_readable_after_overscroll() {
    let app = App {
        active_tab: 1,
        plan: Some(PlanState {
            label: "Retry strategy".into(),
            text: "# Plan\n\n- First step\n- Final step".into(),
            scroll: u16::MAX,
        }),
        ..App::default()
    };
    let output = text(&draw(&app, 60, 20));
    assert!(output.contains("Retry strategy"));
    assert!(output.contains("Final step"));
}
