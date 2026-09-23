use crate::app::{jira_content_height, jira_ticket_rows};
use ratatui::widgets::{List, ListItem, ListState};

use super::*;

#[cfg(test)]
mod tests;

pub(super) fn render_jira(frame: &mut Frame, area: Rect, app: &App) {
    let jira = &app.jira;
    let scroll = app.jira_scroll;
    let selected = app.jira_selected;
    let sections = Layout::vertical([Constraint::Length(2), Constraint::Min(0)]).split(area);
    let mut heading = vec![Span::styled("● Jira", selection_style(true))];
    if let JiraState::Ready(tickets) = jira {
        heading.push(Span::styled(
            format!(" ({})  ·  Assigned to you", tickets.len()),
            Style::default().fg(MUTED_TEXT),
        ));
        if area.width >= 100 {
            for (status, label, color) in BOARD_COLUMNS {
                let count = tickets
                    .iter()
                    .filter(|ticket| ticket.status == status)
                    .count();
                heading.push(Span::styled(
                    format!("   {count} "),
                    Style::default().fg(color),
                ));
                heading.push(Span::styled(label, Style::default().fg(MUTED_TEXT)));
            }
        }
    }
    frame.render_widget(Paragraph::new(Line::from(heading)), sections[0]);
    let tickets = match jira {
        JiraState::Ready(tickets) if !tickets.is_empty() => tickets,
        JiraState::Ready(_) => {
            render_document(
                frame,
                sections[1],
                vec![Line::raw("No Jira tickets are assigned to you.")],
                0,
            );
            return;
        }
        JiraState::Loading => {
            render_document(
                frame,
                sections[1],
                vec![Line::raw("Loading your assigned Jira tickets…")],
                0,
            );
            return;
        }
        JiraState::Disabled => {
            render_document(
                frame,
                sections[1],
                vec![Line::raw(
                    "Jira is turned off in config/vessel/vessel.json.",
                )],
                0,
            );
            return;
        }
        JiraState::Error(message) => {
            render_document(
                frame,
                sections[1],
                vec![
                    Line::styled("Jira data unavailable", Style::default().fg(RED)),
                    Line::raw(message),
                    Line::raw(""),
                    Line::raw("Press R to retry."),
                ],
                0,
            );
            return;
        }
    };

    let viewport = sections[1];
    let positions = jira_ticket_rows(tickets);
    let scroll =
        scroll.min(jira_content_height(tickets).saturating_sub(usize::from(viewport.height)));
    let key_width = tickets
        .iter()
        .map(|ticket| Line::raw(&ticket.key).width())
        .max()
        .unwrap_or(0)
        + 2;
    for group in positions
        .chunk_by(|(left, _), (right, _)| tickets[*left].feature == tickets[*right].feature)
    {
        let feature = &tickets[group[0].0].feature;
        if let Some(row) = visible_row(viewport, group[0].1 - 1, scroll) {
            frame.render_widget(
                Paragraph::new(Line::from(vec![
                    Span::styled(format!("  ● {feature}"), Style::default().fg(TEAL)),
                    Span::styled(
                        format!(" ({})", group.len()),
                        Style::default().fg(MUTED_TEXT),
                    ),
                ])),
                row,
            );
        }
        for (position, &(index, line)) in group.iter().enumerate() {
            let Some(row) = visible_row(viewport, line, scroll) else {
                continue;
            };
            let ticket = &tickets[index];
            let selected = index == selected;
            let (symbol, label, color) = ticket_status(ticket.status);
            let columns = Layout::horizontal([
                Constraint::Length(7),
                Constraint::Length(
                    u16::try_from(key_width)
                        .unwrap_or(u16::MAX)
                        .min(row.width / 3),
                ),
                Constraint::Min(0),
                Constraint::Length(12),
            ])
            .split(row);
            frame.render_widget(
                Paragraph::new(Line::from(vec![
                    Span::styled(
                        if selected { "› " } else { "  " },
                        selection_style(selected),
                    ),
                    Span::styled(
                        if position + 1 == group.len() {
                            "└─ "
                        } else {
                            "├─ "
                        },
                        Style::default().fg(BORDER),
                    ),
                    Span::styled(format!("{symbol} "), Style::default().fg(color)),
                ])),
                columns[0],
            );
            frame.render_widget(
                Paragraph::new(ticket.key.as_str()).style(if selected {
                    selection_style(true)
                } else {
                    Style::default().fg(MUTED_TEXT)
                }),
                columns[1],
            );
            frame.render_widget(
                Paragraph::new(super::overview::crew_tagged(
                    &ticket.summary,
                    app.active_run_for_ticket(&ticket.key),
                ))
                .style(attention_style(
                    selected,
                    ticket.status == BoardStatus::InProgress,
                )),
                columns[2],
            );
            frame.render_widget(
                Paragraph::new(label)
                    .right_aligned()
                    .style(Style::default().fg(MUTED_TEXT)),
                columns[3],
            );
        }
    }
}

fn visible_row(viewport: Rect, row: usize, scroll: usize) -> Option<Rect> {
    let offset = row.checked_sub(scroll)?;
    (offset < usize::from(viewport.height))
        .then(|| Rect::new(viewport.x, viewport.y + offset as u16, viewport.width, 1))
}

pub(super) fn ticket_status(status: BoardStatus) -> (&'static str, &'static str, Color) {
    match status {
        BoardStatus::ToDo => ("○", "To Do", GREEN),
        BoardStatus::OnHold => ("✕", "On Hold", RED),
        BoardStatus::InProgress => ("◐", "In Progress", GOLD),
        BoardStatus::InReview => ("◇", "In Review", BLUE),
    }
}

pub(super) fn render_jira_detail(
    frame: &mut Frame,
    area: Rect,
    detail: &JiraDetailState,
    scroll: u16,
    app: &App,
) {
    let detail = match detail {
        JiraDetailState::Ready(detail) => detail,
        JiraDetailState::Loading(key) => {
            render_document(
                frame,
                area,
                vec![
                    section_heading("Jira ticket"),
                    Line::raw(""),
                    Line::raw(format!("Loading {key}…")),
                ],
                0,
            );
            return;
        }
        JiraDetailState::Error { key, message } => {
            render_document(
                frame,
                area,
                vec![
                    section_heading(format!("Could not load {key}")),
                    Line::raw(""),
                    Line::styled(message, Style::default().fg(RED)),
                ],
                0,
            );
            return;
        }
    };
    let runs = app.current_ticket_runs();
    let plans = &app.ticket_plans;
    let header = vec![
        Line::from(vec![
            Span::styled(format!("{}  ", detail.key), selection_style(true)),
            Span::styled(
                &detail.title,
                Style::default().fg(TEXT).add_modifier(Modifier::BOLD),
            ),
        ]),
        Line::styled(
            format!(
                "{}  ·  {}  ·  Reporter: {}",
                detail.status, detail.feature, detail.reporter
            ),
            Style::default().fg(MUTED_TEXT),
        ),
    ];
    let header = Paragraph::new(header).wrap(Wrap { trim: false });
    let header_height = u16::try_from(header.line_count(area.width)).unwrap_or(u16::MAX);
    let sections = Layout::vertical([
        Constraint::Length(header_height.min(area.height / 2) + 1),
        Constraint::Length(2),
        Constraint::Length(if app.notice.is_some() { 2 } else { 0 }),
        Constraint::Min(0),
    ])
    .split(area);
    frame.render_widget(header, sections[0]);
    let mut tabs = Vec::new();
    for (focus, label) in [
        (JiraDetailFocus::Ticket, "Ticket".to_owned()),
        (JiraDetailFocus::Runs, format!("Runs ({})", runs.len())),
        (JiraDetailFocus::Plans, format!("Plans ({})", plans.len())),
    ] {
        let active = focus == app.jira_detail_focus;
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
    if let Some(notice) = &app.notice {
        frame.render_widget(
            Paragraph::new(notice.as_str())
                .style(Style::default().fg(RED))
                .wrap(Wrap { trim: false }),
            sections[2],
        );
    }
    let content = sections[3];
    match app.jira_detail_focus {
        JiraDetailFocus::Ticket => {
            let mut lines = vec![section_heading("Description"), Line::raw("")];
            if detail.description.is_empty() {
                lines.push(Line::styled(
                    "No description.",
                    Style::default().fg(MUTED_TEXT),
                ));
            } else {
                lines.extend(
                    detail
                        .description
                        .lines()
                        .map(|line| Line::styled(line, Style::default().fg(TEXT))),
                );
            }
            lines.extend([
                Line::raw(""),
                section_heading(format!("Comments ({})", detail.comments.len())),
                Line::raw(""),
            ]);
            if detail.comments.is_empty() {
                lines.push(Line::raw("No comments."));
            }
            for comment in &detail.comments {
                lines.push(Line::styled(
                    &comment.author,
                    Style::default().fg(TEXT).add_modifier(Modifier::BOLD),
                ));
                lines.extend(comment.body.lines().map(Line::raw));
                lines.push(Line::raw(""));
            }
            render_document(frame, content, lines, scroll);
        }
        JiraDetailFocus::Runs => render_runs(frame, content, &runs, app.jira_detail_selected),
        JiraDetailFocus::Plans => {
            let items = plans
                .iter()
                .enumerate()
                .map(|(index, plan)| {
                    ListItem::new(Line::from(vec![
                        tree_branch(index + 1 == plans.len()),
                        Span::raw(&plan.label),
                    ]))
                })
                .collect::<Vec<_>>();
            render_items(
                frame,
                content,
                items,
                app.jira_plan_selected,
                "No plans yet. Ask firstmate to plan this ticket, e.g. \"plan it with Stringer\".",
            );
        }
    }
}

fn render_runs(frame: &mut Frame, area: Rect, runs: &[&Run], selected: usize) {
    let items = runs
        .iter()
        .enumerate()
        .map(|(index, run)| super::github_review::run_list_item(run, index + 1 == runs.len(), None))
        .collect::<Vec<_>>();
    render_items(
        frame,
        area,
        items,
        selected,
        "No crew runs for this ticket yet. Ask firstmate, e.g. \"implement it with Slim Charles\".",
    );
}

fn render_items(
    frame: &mut Frame,
    area: Rect,
    items: Vec<ListItem<'_>>,
    selected: usize,
    empty: &str,
) {
    if items.is_empty() {
        render_document(frame, area, vec![Line::raw(empty)], 0);
        return;
    }
    let mut state = ListState::default().with_selected(Some(selected.min(items.len() - 1)));
    frame.render_stateful_widget(
        List::new(items)
            .style(Style::default().fg(TEXT))
            .highlight_style(selection_style(true))
            .highlight_symbol("› "),
        area,
        &mut state,
    );
}

fn tree_branch(last: bool) -> Span<'static> {
    Span::styled(
        if last { "└─ " } else { "├─ " },
        Style::default().fg(BORDER),
    )
}

pub(super) fn render_plan(frame: &mut Frame, area: Rect, plan: &PlanState) {
    let sections = Layout::vertical([Constraint::Length(2), Constraint::Min(0)]).split(area);
    frame.render_widget(
        Paragraph::new(section_heading(format!("Plan  {}", plan.label))),
        sections[0],
    );
    render_document(frame, sections[1], markdown_lines(&plan.text), plan.scroll);
}
