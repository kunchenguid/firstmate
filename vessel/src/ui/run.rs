//! One run: what it was for, what firstmate recorded, and its live pane.

use super::*;
use crate::app::{RunViewFocus, format_time};

pub(super) fn render_run(frame: &mut Frame, area: Rect, app: &App) {
    let Some(view) = &app.run_view else {
        return;
    };
    let Some(run) = app.viewed_run() else {
        render_document(
            frame,
            area,
            vec![
                section_heading(view.task.clone()),
                Line::raw(""),
                Line::raw("This run is no longer in the fleet records."),
            ],
            0,
        );
        return;
    };

    let header = Paragraph::new(run_header(run)).wrap(Wrap { trim: false });
    let header_height = u16::try_from(header.line_count(area.width)).unwrap_or(u16::MAX);
    let sections = Layout::vertical([
        Constraint::Length(header_height.min(area.height / 2) + 1),
        Constraint::Length(2),
        Constraint::Min(0),
    ])
    .split(area);
    frame.render_widget(header, sections[0]);

    let mut tabs = Vec::new();
    for (focus, label) in [
        (
            RunViewFocus::Status,
            format!("Status ({})", run.timeline.len()),
        ),
        (RunViewFocus::Brief, "Brief".to_owned()),
        (
            RunViewFocus::Report,
            if view.report.is_some() {
                "Report".to_owned()
            } else {
                "Report (none)".to_owned()
            },
        ),
        (
            RunViewFocus::Terminal,
            if run.live {
                "Terminal".to_owned()
            } else {
                "Terminal (closed)".to_owned()
            },
        ),
    ] {
        let active = focus == view.focus;
        tabs.push(Span::styled(
            format!("{}{}   ", if active { "● " } else { "" }, label),
            if active {
                selection_style(true)
            } else {
                Style::default().fg(MUTED_TEXT)
            },
        ));
    }
    frame.render_widget(Paragraph::new(Line::from(tabs)), sections[1]);

    let lines = match view.focus {
        RunViewFocus::Status => status_lines(run),
        RunViewFocus::Brief => document_lines(
            view.brief.as_deref(),
            "No brief found in data/<task>/brief.md.",
        ),
        RunViewFocus::Report => document_lines(
            view.report.as_deref(),
            "No report. Scouts write data/<task>/report.md when they finish.",
        ),
        RunViewFocus::Terminal => terminal_lines(app, run),
    };
    render_document(frame, sections[2], lines, view.scroll);
}

fn run_header(run: &Run) -> Vec<Line<'static>> {
    let mut lines = vec![Line::from(vec![
        Span::styled(
            format!("{} ", run_status_symbol(run.status)),
            Style::default()
                .fg(run_status_color(run.status))
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(format!("{}  ", run.task), selection_style(true)),
        Span::styled(
            run.title.clone(),
            Style::default().fg(TEXT).add_modifier(Modifier::BOLD),
        ),
    ])];
    let mut profile = vec![run.mode().to_owned()];
    profile.extend(run.agent().map(str::to_owned));
    profile.extend(run.harness.clone());
    profile.extend(run.model.clone());
    profile.extend(
        run.record
            .as_ref()
            .and_then(|record| record.effort.clone())
            .map(|effort| format!("effort {effort}")),
    );
    profile.extend(
        run.project
            .clone()
            .map(|project| format!("project {project}")),
    );
    lines.push(Line::styled(
        profile.join("  ·  "),
        Style::default().fg(MUTED_TEXT),
    ));
    let mut target = Vec::new();
    target.extend(run.ticket_key.clone().map(|key| format!("Ticket {key}")));
    if let (Some(repo), Some(number)) = (&run.repo, run.pr_number) {
        target.push(format!("PR {repo}#{number}"));
    }
    target.push(format!("Started {}", format_time(run.created_at)));
    if let Some(finished) = run.finished_at {
        target.push(format!("Ended {}", format_time(Some(finished))));
    }
    lines.push(Line::styled(
        target.join("  ·  "),
        Style::default().fg(MUTED_TEXT),
    ));
    lines.push(Line::from(vec![
        Span::styled("Status: ", Style::default().fg(MUTED_TEXT)),
        Span::styled(
            run.status.label(),
            Style::default()
                .fg(run_status_color(run.status))
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            run.status_text
                .as_deref()
                .map(|text| format!("  — {text}"))
                .unwrap_or_default(),
            Style::default().fg(TEXT),
        ),
    ]));
    lines
}

fn status_lines(run: &Run) -> Vec<Line<'static>> {
    let mut lines = Vec::new();
    if !run.open_decisions.is_empty() {
        lines.push(section_heading("Waiting on the captain"));
        lines.push(Line::raw(""));
        for decision in &run.open_decisions {
            lines.push(Line::from(vec![
                Span::styled(
                    format!("◇ {} ", decision.verb),
                    Style::default().fg(CORAL).add_modifier(Modifier::BOLD),
                ),
                Span::styled(
                    decision
                        .key
                        .as_deref()
                        .map(|key| format!("[{key}] "))
                        .unwrap_or_default(),
                    Style::default().fg(MUTED_TEXT),
                ),
                Span::styled(decision.text.clone(), Style::default().fg(TEXT)),
            ]));
        }
        lines.push(Line::styled(
            "Answer in the firstmate session; vessel is read-only.",
            Style::default().fg(MUTED_TEXT),
        ));
        lines.push(Line::raw(""));
    }
    lines.push(section_heading("Status history"));
    lines.push(Line::raw(""));
    if run.timeline.is_empty() {
        lines.push(Line::styled(
            "No status lines recorded. History needs config/fleet-ledger in the firstmate home.",
            Style::default().fg(MUTED_TEXT),
        ));
    }
    for (index, entry) in run.timeline.iter().enumerate() {
        let status = crate::firstmate::runs::RunStatus::from_verb(&entry.state);
        lines.push(Line::from(vec![
            Span::styled(
                if index + 1 == run.timeline.len() {
                    "└─ "
                } else {
                    "├─ "
                },
                Style::default().fg(BORDER),
            ),
            Span::styled(
                format!("{}  ", format_time(Some(entry.ts))),
                Style::default().fg(MUTED_TEXT),
            ),
            Span::styled(
                format!("{:<15}", entry.state),
                Style::default().fg(status.map_or(MUTED_TEXT, run_status_color)),
            ),
            Span::styled(entry.text.clone(), Style::default().fg(TEXT)),
        ]));
    }
    if let Some(record) = &run.record {
        lines.push(Line::raw(""));
        lines.push(section_heading("Request"));
        lines.push(Line::raw(""));
        let mut facts = vec![format!("workflow {}", record.workflow)];
        facts.extend(record.plan_task.clone().map(|plan| format!("plan {plan}")));
        facts.extend(record.pr_head.clone().map(|head| {
            format!(
                "reviewed head {}",
                head.chars().take(10).collect::<String>()
            )
        }));
        facts.extend(
            record
                .request_id
                .clone()
                .map(|id| format!("inbox request {id}")),
        );
        lines.push(Line::styled(
            facts.join("  ·  "),
            Style::default().fg(MUTED_TEXT),
        ));
    }
    lines
}

fn document_lines(text: Option<&str>, missing: &str) -> Vec<Line<'static>> {
    match text {
        Some(text) if !text.trim().is_empty() => markdown_lines(text),
        _ => vec![Line::styled(
            missing.to_owned(),
            Style::default().fg(MUTED_TEXT),
        )],
    }
}

fn terminal_lines(app: &App, run: &Run) -> Vec<Line<'static>> {
    if !run.live {
        return vec![Line::styled(
            "The crewmate's terminal is gone; see Status and Report for what it did.",
            Style::default().fg(MUTED_TEXT),
        )];
    }
    match app.fleet.peek.as_ref().map(|peek| &peek.text) {
        Some(Ok(text)) if !text.is_empty() => text
            .lines()
            .map(|line| Line::styled(line.to_owned(), Style::default().fg(TEXT)))
            .collect(),
        Some(Err(message)) => vec![Line::styled(message.clone(), Style::default().fg(RED))],
        _ => vec![Line::styled(
            "Reading the crewmate's terminal…",
            Style::default().fg(MUTED_TEXT),
        )],
    }
}
