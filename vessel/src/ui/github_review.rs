use pulldown_cmark::{Event, Options, Parser, Tag, TagEnd};
use ratatui::widgets::{List, ListItem, ListState};

use super::*;

pub(super) fn render_github_review(frame: &mut Frame, area: Rect, app: &App) {
    let Some(review) = &app.github_review else {
        return;
    };
    let runs = app.current_review_runs();
    let comments = match &review.detail {
        GitHubDetailState::Ready(detail) => detail.comments.len(),
        _ => 0,
    };
    let sections = review_sections(area, app);
    frame.render_widget(review_header(review), sections[0]);

    let mut tabs = Vec::new();
    for (focus, label) in [
        (GitHubReviewFocus::Description, "Pull Request".to_owned()),
        (GitHubReviewFocus::Reviews, format!("Runs ({})", runs.len())),
        (
            GitHubReviewFocus::Comments,
            format!("Comments ({comments})"),
        ),
    ] {
        let active = focus == review.focus;
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

    match review.focus {
        GitHubReviewFocus::Description => render_github_description(frame, sections[3], review),
        GitHubReviewFocus::Reviews => render_github_runs(frame, sections[3], review, &runs, app),
        GitHubReviewFocus::Comments => {
            super::github_comments::render_comments(frame, sections[3], review)
        }
    }
}

fn review_header(review: &GitHubReviewState) -> Paragraph<'_> {
    let title = match &review.detail {
        GitHubDetailState::Ready(detail) => detail.title.as_str(),
        _ => review.title.as_str(),
    };
    let header = match &review.detail {
        GitHubDetailState::Ready(detail) => {
            let readiness = if detail.is_draft { "Draft" } else { "Ready" };
            let mergeability = display_status(
                detail
                    .merge_state_status
                    .as_deref()
                    .or(detail.mergeable.as_deref())
                    .unwrap_or("UNKNOWN"),
            );
            let ci_status = display_status(detail.ci_status.as_deref().unwrap_or("UNKNOWN"));
            let mut reviewer_spans =
                vec![Span::styled("Reviewers: ", Style::default().fg(MUTED_TEXT))];
            if detail.reviewers.is_empty() {
                reviewer_spans.push(Span::styled("none", Style::default().fg(MUTED_TEXT)));
            } else {
                for (index, reviewer) in detail.reviewers.iter().enumerate() {
                    reviewer_spans.push(Span::styled(
                        reviewer.author.as_str(),
                        Style::default().fg(MUTED_TEXT),
                    ));
                    reviewer_spans.push(Span::styled(
                        format!(" {}", display_status(&reviewer.state)),
                        Style::default().fg(github_status_color(&reviewer.state)),
                    ));
                    if index + 1 < detail.reviewers.len() {
                        reviewer_spans.push(Span::styled("  ·  ", Style::default().fg(MUTED_TEXT)));
                    }
                }
            }
            vec![
                Line::from(vec![
                    Span::styled(format!("#{}  ", review.number), selection_style(true)),
                    Span::styled(
                        title,
                        Style::default().fg(TEXT).add_modifier(Modifier::BOLD),
                    ),
                ]),
                Line::from(vec![
                    Span::styled(
                        format!("{}  ·  ", review.repository),
                        Style::default().fg(MUTED_TEXT),
                    ),
                    Span::styled(
                        format!("{}  ·  ", detail.author),
                        Style::default().fg(MUTED_TEXT),
                    ),
                    Span::styled(
                        readiness,
                        Style::default().fg(github_status_color(readiness)),
                    ),
                ]),
                Line::from(vec![
                    Span::styled("Merge: ", Style::default().fg(MUTED_TEXT)),
                    Span::styled(
                        mergeability.clone(),
                        Style::default().fg(github_status_color(&mergeability)),
                    ),
                    Span::styled("  ·  CI: ", Style::default().fg(MUTED_TEXT)),
                    Span::styled(
                        ci_status.clone(),
                        Style::default().fg(github_status_color(&ci_status)),
                    ),
                    Span::styled("  ·  Ticket: ", Style::default().fg(MUTED_TEXT)),
                    Span::styled(
                        review.ticket_key.as_deref().unwrap_or("not linked"),
                        Style::default().fg(MUTED_TEXT),
                    ),
                ]),
                Line::from(reviewer_spans),
            ]
        }
        GitHubDetailState::Loading => vec![
            Line::from(vec![
                Span::styled(format!("#{}  ", review.number), selection_style(true)),
                Span::styled(
                    title,
                    Style::default().fg(TEXT).add_modifier(Modifier::BOLD),
                ),
            ]),
            Line::styled(
                format!("{}  ·  Loading pull request...", review.repository),
                Style::default().fg(MUTED_TEXT),
            ),
            Line::styled(
                format!(
                    "Ticket: {}",
                    review.ticket_key.as_deref().unwrap_or("not linked")
                ),
                Style::default().fg(MUTED_TEXT),
            ),
        ],
        GitHubDetailState::Error(message) => vec![
            Line::from(vec![
                Span::styled(format!("#{}  ", review.number), selection_style(true)),
                Span::styled(
                    title,
                    Style::default().fg(TEXT).add_modifier(Modifier::BOLD),
                ),
            ]),
            Line::styled(message, Style::default().fg(RED)),
        ],
    };
    Paragraph::new(header).wrap(Wrap { trim: false })
}

pub(super) fn review_sections(area: Rect, app: &App) -> [Rect; 4] {
    let Some(review) = &app.github_review else {
        return [Rect::default(); 4];
    };
    let header_height =
        u16::try_from(review_header(review).line_count(area.width)).unwrap_or(u16::MAX);
    Layout::vertical([
        Constraint::Length(header_height.min(area.height / 2).saturating_add(1)),
        Constraint::Length(2),
        Constraint::Length(if app.notice.is_some() { 2 } else { 0 }),
        Constraint::Min(0),
    ])
    .areas(area)
}

fn render_github_description(frame: &mut Frame, area: Rect, review: &GitHubReviewState) {
    let mut lines = vec![
        Line::styled("● Description", Style::default().fg(TEAL)),
        Line::raw(""),
    ];
    match &review.detail {
        GitHubDetailState::Loading => lines.push(Line::styled(
            "Loading pull request...",
            Style::default().fg(MUTED_TEXT),
        )),
        GitHubDetailState::Error(message) => {
            lines.push(Line::styled(message, Style::default().fg(RED)))
        }
        GitHubDetailState::Ready(detail) => {
            if detail.description.trim().is_empty() {
                lines.push(Line::styled(
                    "No description provided.",
                    Style::default().fg(MUTED_TEXT),
                ));
            } else {
                lines.extend(markdown_lines(&detail.description));
            }
        }
    }
    render_document(frame, area, lines, review.description_scroll);
}

fn render_github_runs(
    frame: &mut Frame,
    area: Rect,
    review: &GitHubReviewState,
    runs: &[&Run],
    app: &App,
) {
    if runs.is_empty() {
        render_document(
            frame,
            area,
            vec![Line::styled(
                "No crew runs for this pull request yet. Ask firstmate, e.g. \"review this PR with Snoop\".",
                Style::default().fg(MUTED_TEXT),
            )],
            0,
        );
        return;
    }
    let latest_completed_review = app
        .latest_completed_review_run(&review.repository, review.number)
        .map(|run| (run.task.as_str(), run.created_at));
    let completed_review_status = match &review.detail {
        GitHubDetailState::Ready(detail) => Some(app.completed_agent_review_status(
            &review.repository,
            review.number,
            &detail.head_commit,
        )),
        _ => None,
    };
    let items = runs
        .iter()
        .enumerate()
        .map(|(index, run)| {
            let freshness = (Some((run.task.as_str(), run.created_at)) == latest_completed_review)
                .then_some(completed_review_status)
                .flatten();
            run_list_item(run, index + 1 == runs.len(), freshness)
        })
        .collect::<Vec<_>>();
    let mut state = ListState::default()
        .with_selected(Some(review.selected.min(items.len().saturating_sub(1))));
    frame.render_stateful_widget(
        List::new(items)
            .style(Style::default().fg(TEXT))
            .highlight_style(selection_style(true))
            .highlight_symbol("› "),
        area,
        &mut state,
    );
}

/// Two-line run entry shared by the PR, ticket, and agent run lists.
pub(super) fn run_list_item(
    run: &Run,
    last: bool,
    freshness: Option<AgentReviewStatus>,
) -> ListItem<'static> {
    let datetime = crate::app::format_time(run.created_at);
    let mut status = vec![
        Span::styled(
            format!("   {datetime}  ·  "),
            Style::default().fg(MUTED_TEXT),
        ),
        Span::styled(
            run.status.label(),
            Style::default()
                .fg(run_status_color(run.status))
                .add_modifier(Modifier::BOLD),
        ),
    ];
    if let Some((label, color)) = freshness.and_then(review_freshness_label) {
        status.push(Span::styled(
            format!("  ({label})"),
            Style::default().fg(color).add_modifier(Modifier::BOLD),
        ));
    }
    if let Some(text) = run.status_text.as_deref().filter(|text| !text.is_empty()) {
        status.push(Span::styled(
            format!("  — {text}"),
            Style::default().fg(MUTED_TEXT),
        ));
    }
    ListItem::new(vec![
        Line::from(vec![
            Span::styled(
                if last { "└─ " } else { "├─ " },
                Style::default().fg(BORDER),
            ),
            Span::raw(format!(
                "{}  {}  {}",
                run.agent().or(run.harness.as_deref()).unwrap_or("crewmate"),
                run.mode(),
                run.task
            )),
        ]),
        Line::from(status),
        Line::raw(""),
    ])
}

pub(super) fn github_status_color(status: &str) -> Color {
    if ["READY", "APPROVED", "SUCCESS", "MERGEABLE", "COMPLETED"]
        .iter()
        .any(|value| status.eq_ignore_ascii_case(value))
    {
        GREEN
    } else if ["DRAFT"]
        .iter()
        .any(|value| status.eq_ignore_ascii_case(value))
    {
        GOLD
    } else if [
        "CHANGES_REQUESTED",
        "CONFLICTING",
        "BLOCKED",
        "FAILURE",
        "FAILED",
        "ERROR",
        "CANCELLED",
    ]
    .iter()
    .any(|value| status.eq_ignore_ascii_case(value))
    {
        RED
    } else {
        MUTED_TEXT
    }
}

pub(super) fn display_status(status: &str) -> String {
    status
        .split(['_', ' '])
        .filter(|word| !word.is_empty())
        .map(|word| {
            let mut characters = word.chars();
            match characters.next() {
                Some(first) => {
                    first.to_uppercase().collect::<String>() + &characters.as_str().to_lowercase()
                }
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

pub(super) fn markdown_lines(markdown: &str) -> Vec<Line<'static>> {
    let base = Style::default().fg(TEXT);
    let mut lines = vec![Vec::new()];
    let mut style = base;
    let mut link_url = None;
    let mut list_depth = 0;
    for event in Parser::new_ext(markdown, Options::all()) {
        match event {
            Event::Start(Tag::Heading { .. }) => {
                finish_markdown_line(&mut lines);
                style = base.add_modifier(Modifier::BOLD);
            }
            Event::End(TagEnd::Heading(_)) => {
                style = base;
                if list_depth == 0 {
                    finish_markdown_block(&mut lines);
                } else {
                    finish_markdown_line(&mut lines);
                }
            }
            Event::End(TagEnd::Paragraph) => {
                if list_depth == 0 {
                    finish_markdown_block(&mut lines);
                } else {
                    finish_markdown_line(&mut lines);
                }
            }
            Event::Start(Tag::Strong) => style = style.add_modifier(Modifier::BOLD),
            Event::End(TagEnd::Strong) => style = base,
            Event::Start(Tag::Emphasis) => style = style.add_modifier(Modifier::ITALIC),
            Event::End(TagEnd::Emphasis) => style = base,
            Event::Start(Tag::Item) => {
                finish_markdown_line(&mut lines);
                lines
                    .last_mut()
                    .unwrap()
                    .push(Span::styled(format!("{}- ", "  ".repeat(list_depth)), base));
            }
            Event::End(TagEnd::Item) => finish_markdown_line(&mut lines),
            Event::Start(Tag::List(_)) => list_depth += 1,
            Event::End(TagEnd::List(_)) => {
                list_depth = list_depth.saturating_sub(1);
                if list_depth == 0 {
                    finish_markdown_block(&mut lines);
                } else {
                    finish_markdown_line(&mut lines);
                }
            }
            Event::Start(Tag::BlockQuote(_)) => {
                finish_markdown_line(&mut lines);
                lines
                    .last_mut()
                    .unwrap()
                    .push(Span::styled("> ", Style::default().fg(GOLD)));
            }
            Event::End(TagEnd::BlockQuote(_)) => {
                if list_depth == 0 {
                    finish_markdown_block(&mut lines);
                } else {
                    finish_markdown_line(&mut lines);
                }
            }
            Event::Start(Tag::CodeBlock(_)) => style = Style::default().fg(GOLD),
            Event::End(TagEnd::CodeBlock) => {
                style = base;
                if list_depth == 0 {
                    finish_markdown_block(&mut lines);
                } else {
                    finish_markdown_line(&mut lines);
                }
            }
            Event::Code(code) => lines
                .last_mut()
                .unwrap()
                .push(Span::styled(code.into_string(), Style::default().fg(GOLD))),
            Event::Rule => {
                finish_markdown_line(&mut lines);
                lines.last_mut().unwrap().push(Span::styled(
                    "────────────────",
                    Style::default().fg(MUTED_TEXT),
                ));
                finish_markdown_block(&mut lines);
            }
            Event::Start(Tag::Link { dest_url, .. }) => link_url = Some(dest_url.into_string()),
            Event::End(TagEnd::Link) => {
                if let Some(url) = link_url.take() {
                    lines
                        .last_mut()
                        .unwrap()
                        .push(Span::styled(format!(" ({url})"), Style::default().fg(BLUE)));
                }
            }
            Event::Start(Tag::TableHead | Tag::TableRow) => finish_markdown_line(&mut lines),
            Event::End(TagEnd::TableHead | TagEnd::TableRow) => finish_markdown_line(&mut lines),
            Event::Start(Tag::TableCell) => {
                if !lines.last().unwrap().is_empty() {
                    lines
                        .last_mut()
                        .unwrap()
                        .push(Span::styled("  │  ", Style::default().fg(BORDER)));
                }
            }
            Event::TaskListMarker(checked) => {
                lines
                    .last_mut()
                    .unwrap()
                    .push(Span::styled(if checked { "[x] " } else { "[ ] " }, base));
            }
            Event::Html(html) | Event::InlineHtml(html) => {
                // GitHub reviews often put visible text inside <details>/<summary> blocks.
                let mut in_tag = false;
                for character in html.chars() {
                    match character {
                        '<' => in_tag = true,
                        '>' if in_tag => in_tag = false,
                        '\n' if !in_tag => finish_markdown_line(&mut lines),
                        _ if !in_tag => lines
                            .last_mut()
                            .unwrap()
                            .push(Span::styled(character.to_string(), base)),
                        _ => {}
                    }
                }
            }
            Event::Text(text) => {
                for (index, line) in text.split('\n').enumerate() {
                    if index > 0 {
                        finish_markdown_line(&mut lines);
                    }
                    if !line.is_empty() {
                        lines
                            .last_mut()
                            .unwrap()
                            .push(Span::styled(line.to_string(), style));
                    }
                }
            }
            Event::SoftBreak | Event::HardBreak => finish_markdown_line(&mut lines),
            _ => {}
        }
    }
    while lines.last().is_some_and(Vec::is_empty) {
        lines.pop();
    }
    lines.into_iter().map(Line::from).collect()
}

fn finish_markdown_line(lines: &mut Vec<Vec<Span<'static>>>) {
    if lines
        .last()
        .is_some_and(|line: &Vec<Span<'static>>| !line.is_empty())
    {
        lines.push(Vec::new());
    }
}

fn finish_markdown_block(lines: &mut Vec<Vec<Span<'static>>>) {
    finish_markdown_line(lines);
    lines.push(Vec::new());
}

fn review_freshness_label(status: AgentReviewStatus) -> Option<(&'static str, Color)> {
    Some(match status {
        AgentReviewStatus::Current => ("current", GREEN),
        AgentReviewStatus::NewCommits => ("new commits", GOLD),
        AgentReviewStatus::Unknown => ("commit unknown", MUTED_TEXT),
        AgentReviewStatus::NotReviewed | AgentReviewStatus::Running => return None,
    })
}

pub(super) fn agent_review_status(status: AgentReviewStatus) -> (&'static str, Color) {
    match status {
        AgentReviewStatus::NotReviewed => ("○", MUTED_TEXT),
        AgentReviewStatus::Unknown => ("●", MUTED_TEXT),
        AgentReviewStatus::Current => ("✓", GREEN),
        AgentReviewStatus::NewCommits => ("✕", RED),
        AgentReviewStatus::Running => ("●", BLUE),
    }
}
