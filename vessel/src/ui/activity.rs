//! The fleet ledger as a newest-first activity feed.

use super::*;
use crate::{app::format_time, firstmate::ledger::LedgerKind};

pub(super) fn render_activity(frame: &mut Frame, area: Rect, app: &App) {
    let Some(activity) = &app.activity else {
        return;
    };
    let sections = Layout::vertical([Constraint::Length(2), Constraint::Min(0)]).split(area);
    let events = app.fleet.ledger.events();
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled("● Activity", selection_style(true)),
            Span::styled(
                format!("  ·  {} events from the fleet ledger", events.len()),
                Style::default().fg(MUTED_TEXT),
            ),
        ])),
        sections[0],
    );
    let lines = if !app.fleet.ledger_enabled && events.is_empty() {
        vec![
            Line::styled("The fleet ledger is off.", Style::default().fg(TEXT)),
            Line::raw(""),
            Line::raw(
                "Turn it on in the firstmate home to record dispatches, status lines, merges, and cleanups:",
            ),
            Line::styled("  touch config/fleet-ledger", Style::default().fg(GOLD)),
        ]
    } else if events.is_empty() {
        vec![Line::raw("No fleet activity recorded yet.")]
    } else {
        events.iter().rev().map(event_line).collect()
    };
    render_document(frame, sections[1], lines, activity.scroll);
}

fn event_line(event: &crate::firstmate::ledger::LedgerEvent) -> Line<'static> {
    let (symbol, color, text) = match &event.kind {
        LedgerKind::Dispatched {
            kind,
            project,
            harness,
            model,
        } => (
            "●",
            BLUE,
            format!(
                "dispatched {} on {}{}{}",
                kind.as_deref().unwrap_or("task"),
                project.as_deref().unwrap_or("?"),
                harness
                    .as_deref()
                    .map(|harness| format!(" with {harness}"))
                    .unwrap_or_default(),
                model
                    .as_deref()
                    .map(|model| format!(" ({model})"))
                    .unwrap_or_default()
            ),
        ),
        LedgerKind::Status { state, text, .. } => {
            let state = state.as_deref().unwrap_or("status");
            let status = crate::firstmate::runs::RunStatus::from_verb(state);
            (
                status.map_or("·", run_status_symbol),
                status.map_or(MUTED_TEXT, run_status_color),
                format!("{state}: {text}"),
            )
        }
        LedgerKind::Merged { via, pr } => (
            "✓",
            GREEN,
            format!(
                "merged via {}{}",
                via.as_deref().unwrap_or("?"),
                pr.as_deref().map(|pr| format!(" {pr}")).unwrap_or_default()
            ),
        ),
        LedgerKind::CleanedUp => ("○", MUTED_TEXT, "cleaned up".to_owned()),
    };
    Line::from(vec![
        Span::styled(
            format!("{}  ", format_time(Some(event.ts))),
            Style::default().fg(MUTED_TEXT),
        ),
        Span::styled(format!("{symbol} "), Style::default().fg(color)),
        Span::styled(
            format!("{:<28} ", event.task),
            Style::default().fg(TEXT).add_modifier(Modifier::BOLD),
        ),
        Span::styled(text, Style::default().fg(TEXT)),
    ])
}
