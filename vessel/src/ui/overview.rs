use std::collections::BTreeMap;

use crate::app::jira_ticket_rows;
use crate::firstmate::WatcherStatus;

use super::*;

pub(super) fn render_overview(frame: &mut Frame, area: Rect, app: &App) {
    let lines = overview_page_lines(app, area.width);
    let selected_line = overview_selected_line(&lines);
    let max_scroll = lines.len().saturating_sub(usize::from(area.height));
    let mut scroll = app
        .overview_scroll_target
        .map(|section| overview_section_start(app, area.width, section).min(max_scroll))
        .unwrap_or_else(|| app.overview_scroll.min(max_scroll));

    if let Some(cursor_line) = selected_line {
        let viewport_h = usize::from(area.height);
        if cursor_line < scroll {
            scroll = cursor_line;
        } else if cursor_line >= scroll.saturating_add(viewport_h) {
            scroll = cursor_line.saturating_sub(viewport_h.saturating_sub(1));
        }
    }

    frame.render_widget(
        Paragraph::new(lines).scroll((u16::try_from(scroll).unwrap_or(u16::MAX), 0)),
        area,
    );
}

fn overview_selected_line(lines: &[Line<'static>]) -> Option<usize> {
    lines.iter().position(|line| {
        line.spans.iter().any(|span| {
            let s = span.content.as_ref();
            s.starts_with("›")
        })
    })
}

fn overview_page_lines(app: &App, width: u16) -> Vec<Line<'static>> {
    let width = usize::from(width);
    let mut lines = Vec::new();
    append_overview_crew(&mut lines, app, width);
    lines.push(overview_separator(width));
    append_overview_jira(&mut lines, app, width);
    lines.push(overview_separator(width));
    append_overview_github(&mut lines, app, width);
    lines
}

fn overview_section_start(app: &App, width: u16, section: OverviewSection) -> usize {
    if section == OverviewSection::Crew {
        return 0;
    }

    let width = usize::from(width);
    let mut lines = Vec::new();
    append_overview_crew(&mut lines, app, width);
    lines.push(overview_separator(width));
    if section == OverviewSection::Jira {
        return lines.len();
    }

    append_overview_jira(&mut lines, app, width);
    lines.len() + 1
}

fn append_overview_crew(lines: &mut Vec<Line<'static>>, app: &App, width: usize) {
    let (working, attention, done) = app.crew_counts();
    let mut heading = vec![
        Span::styled(
            "● Crew",
            selection_style(app.overview_section == OverviewSection::Crew),
        ),
        Span::styled("  ", Style::default().fg(MUTED_TEXT)),
        Span::styled(working.to_string(), Style::default().fg(GOLD)),
        Span::styled(" working", Style::default().fg(MUTED_TEXT)),
        Span::styled("  ·  ", Style::default().fg(MUTED_TEXT)),
        Span::styled(attention.to_string(), Style::default().fg(CORAL)),
        Span::styled(" need you", Style::default().fg(MUTED_TEXT)),
        Span::styled("  ·  ", Style::default().fg(MUTED_TEXT)),
        Span::styled(done.to_string(), Style::default().fg(GREEN)),
        Span::styled(" done", Style::default().fg(MUTED_TEXT)),
    ];
    let (watcher, watcher_color) = match &app.fleet.watcher {
        WatcherStatus::Alive => ("watcher alive".to_owned(), GREEN),
        WatcherStatus::Stale(age) => (format!("watcher quiet {}m", age.as_secs() / 60), GOLD),
        WatcherStatus::Absent => ("no watcher".to_owned(), MUTED_TEXT),
        WatcherStatus::Unknown => (String::new(), MUTED_TEXT),
    };
    if !watcher.is_empty() {
        heading.push(Span::styled("  ·  ", Style::default().fg(MUTED_TEXT)));
        heading.push(Span::styled(watcher, Style::default().fg(watcher_color)));
    }
    if let Some(afk) = &app.fleet.afk {
        heading.push(Span::styled("  ·  ", Style::default().fg(MUTED_TEXT)));
        heading.push(Span::styled(afk.clone(), Style::default().fg(GOLD)));
    }
    lines.push(Line::from(heading));
    match &app.fleet.snapshot {
        crate::firstmate::SnapshotState::Loading if app.runs().is_empty() => {
            lines.push(Line::styled(
                "Reading the firstmate fleet…",
                Style::default().fg(MUTED_TEXT),
            ));
            return;
        }
        crate::firstmate::SnapshotState::Error(message) if app.runs().is_empty() => {
            lines.push(Line::styled(
                "Fleet snapshot unavailable",
                Style::default().fg(RED),
            ));
            lines.push(Line::styled(
                message.clone(),
                Style::default().fg(MUTED_TEXT),
            ));
            return;
        }
        _ => {}
    }
    lines.extend(overview_lines(app, width));
}

fn overview_separator(width: usize) -> Line<'static> {
    Line::styled("─".repeat(width), Style::default().fg(BORDER))
}

fn fit_left(text: impl AsRef<str>, width: usize) -> String {
    let mut text = text.as_ref().chars().take(width).collect::<String>();
    text.push_str(&" ".repeat(width.saturating_sub(text.chars().count())));
    text
}

fn fit_right(text: impl AsRef<str>, width: usize) -> String {
    let text = text.as_ref();
    let text = text
        .chars()
        .rev()
        .take(width)
        .collect::<String>()
        .chars()
        .rev()
        .collect::<String>();
    format!(
        "{}{}",
        " ".repeat(width.saturating_sub(text.chars().count())),
        text
    )
}

fn github_column_widths(width: usize, show_conflicts: bool) -> (usize, usize, usize) {
    let first_percent = if show_conflicts { 60 } else { 80 };
    let first = width * first_percent / 100;
    let conflicts = if show_conflicts { width * 20 / 100 } else { 0 };
    let agent_review = width.saturating_sub(first + conflicts);
    (first, conflicts, agent_review)
}

fn github_section_heading(
    title: &str,
    count: usize,
    statuses: Vec<(usize, &'static str, Color)>,
    width: usize,
    title_style: Style,
) -> Vec<Span<'static>> {
    let count = format!(" ({count})");
    let mut spans = vec![
        Span::styled(title.to_owned(), title_style),
        Span::styled(count.clone(), Style::default().fg(MUTED_TEXT)),
    ];
    let mut used = title.chars().count() + count.chars().count();
    let mut first_status = true;
    for (count, label, color) in statuses {
        let separator = if first_status { "  ·  " } else { "   " };
        let count = format!("{separator}{count} ");
        let extra_width = count.chars().count() + label.chars().count();
        if used + extra_width > width {
            break;
        }
        spans.push(Span::styled(count, Style::default().fg(color)));
        spans.push(Span::styled(label, Style::default().fg(MUTED_TEXT)));
        used += extra_width;
        first_status = false;
    }
    spans.push(Span::raw(" ".repeat(width.saturating_sub(used))));
    spans
}

fn append_overview_jira(lines: &mut Vec<Line<'static>>, app: &App, width: usize) {
    let mut heading = vec![Span::styled(
        "● Jira",
        selection_style(app.overview_section == OverviewSection::Jira),
    )];
    if let JiraState::Ready(tickets) = &app.jira {
        heading.push(Span::styled(
            format!(" ({})  ·  Assigned to you", tickets.len()),
            Style::default().fg(MUTED_TEXT),
        ));
        if width >= 100 {
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
    lines.push(Line::from(heading));

    match &app.jira {
        JiraState::Loading => lines.push(Line::styled(
            "Loading your assigned Jira tickets…",
            Style::default().fg(MUTED_TEXT),
        )),
        JiraState::Disabled => lines.push(Line::styled(
            "Jira is turned off in config/vessel/vessel.json.",
            Style::default().fg(MUTED_TEXT),
        )),
        JiraState::Error(message) => {
            lines.push(Line::styled(
                "Jira data unavailable",
                Style::default().fg(RED),
            ));
            lines.push(Line::styled(
                message.clone(),
                Style::default().fg(MUTED_TEXT),
            ));
            lines.push(Line::styled(
                "Press R to retry.",
                Style::default().fg(MUTED_TEXT),
            ));
        }
        JiraState::Ready(tickets) if tickets.is_empty() => lines.push(Line::styled(
            "No Jira tickets are assigned to you.",
            Style::default().fg(MUTED_TEXT),
        )),
        JiraState::Ready(tickets) => {
            let key_width = tickets
                .iter()
                .map(|ticket| ticket.key.chars().count())
                .max()
                .unwrap_or(0)
                .saturating_add(2)
                .min(width.saturating_div(3));
            let summary_width = width.saturating_sub(7 + key_width + 12);
            let positions = jira_ticket_rows(tickets);
            for group in positions
                .chunk_by(|(left, _), (right, _)| tickets[*left].feature == tickets[*right].feature)
            {
                let feature = &tickets[group[0].0].feature;
                lines.push(Line::styled(
                    format!("  ● {feature} ({})", group.len()),
                    Style::default().fg(TEAL),
                ));
                for (position, &(index, _)) in group.iter().enumerate() {
                    let ticket = &tickets[index];
                    let selected =
                        app.overview_section == OverviewSection::Jira && index == app.jira_selected;
                    let (symbol, label, color) = super::jira::ticket_status(ticket.status);
                    lines.push(Line::from(vec![
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
                        Span::styled(
                            format!("{symbol} "),
                            if selected {
                                selection_style(true)
                            } else {
                                Style::default().fg(color)
                            },
                        ),
                        Span::styled(
                            fit_left(&ticket.key, key_width),
                            if selected {
                                selection_style(true)
                            } else {
                                Style::default().fg(MUTED_TEXT)
                            },
                        ),
                        Span::styled(
                            fit_left(
                                crew_tagged(
                                    &ticket.summary,
                                    app.active_run_for_ticket(&ticket.key),
                                ),
                                summary_width,
                            ),
                            attention_style(selected, ticket.status == BoardStatus::InProgress),
                        ),
                        Span::styled(fit_right(label, 12), Style::default().fg(MUTED_TEXT)),
                    ]));
                }
            }
        }
    }
}

fn append_overview_github(lines: &mut Vec<Line<'static>>, app: &App, width: usize) {
    let my_prs = match &app.github {
        GitHubState::Ready(prs) => Some(prs.as_slice()),
        _ => None,
    };
    let other_prs = match &app.github_others {
        GitHubOthersState::Ready(prs) => Some(prs.as_slice()),
        _ => None,
    };
    let total_count = my_prs.map_or(0, |prs| prs.len()) + other_prs.map_or(0, |prs| prs.len());
    lines.push(Line::from(vec![
        Span::styled(
            "● GitHub",
            selection_style(matches!(
                app.overview_section,
                OverviewSection::GitHubMe | OverviewSection::GitHubOther
            )),
        ),
        Span::styled(
            format!(" ({total_count})  ·  Pull requests"),
            Style::default().fg(MUTED_TEXT),
        ),
    ]));

    if matches!(app.github, GitHubState::Disabled) {
        lines.push(Line::styled(
            "GitHub is turned off in config/vessel/vessel.json.",
            Style::default().fg(MUTED_TEXT),
        ));
        return;
    }
    if let GitHubState::Error(message) = &app.github {
        lines.extend([
            Line::styled("GitHub data unavailable", Style::default().fg(RED)),
            Line::styled(message.clone(), Style::default().fg(MUTED_TEXT)),
            Line::styled("Press R to retry.", Style::default().fg(MUTED_TEXT)),
        ]);
        return;
    }
    if let GitHubOthersState::Error(message) = &app.github_others {
        lines.extend([
            Line::styled("GitHub review data unavailable", Style::default().fg(RED)),
            Line::styled(message.clone(), Style::default().fg(MUTED_TEXT)),
            Line::styled("Press R to retry.", Style::default().fg(MUTED_TEXT)),
        ]);
        return;
    }
    if matches!(&app.github, GitHubState::Loading)
        && matches!(&app.github_others, GitHubOthersState::Loading)
    {
        lines.push(Line::styled(
            "Loading GitHub pull requests…",
            Style::default().fg(MUTED_TEXT),
        ));
        return;
    }

    let my_prs = my_prs.unwrap_or_default();
    let other_prs = other_prs.unwrap_or_default();
    if my_prs.is_empty() && other_prs.is_empty() {
        lines.push(Line::styled(
            "No open pull requests found.",
            Style::default().fg(MUTED_TEXT),
        ));
        return;
    }

    append_overview_my_work(lines, app, my_prs, width);
    if !my_prs.is_empty() && !other_prs.is_empty() {
        lines.push(overview_separator(width));
    }
    append_overview_other_work(lines, app, other_prs, width);
}

fn append_overview_my_work(
    lines: &mut Vec<Line<'static>>,
    app: &App,
    all_pull_requests: &[PullRequest],
    width: usize,
) {
    let selected_section = app.overview_section == OverviewSection::GitHubMe;
    let show_conflicts = all_pull_requests
        .iter()
        .any(|pull_request| pull_request.has_conflicts);
    let (first_width, conflicts_width, agent_review_width) =
        github_column_widths(width, show_conflicts);
    let heading_style = if selected_section {
        selection_style(true)
    } else {
        Style::default().fg(GREEN)
    };
    let mut heading = github_section_heading(
        "  ● My Work",
        all_pull_requests.len(),
        super::github::my_work_status_summary(all_pull_requests),
        first_width,
        heading_style,
    );
    if show_conflicts {
        heading.push(Span::styled(
            fit_right("Conflicts", conflicts_width),
            Style::default().fg(MUTED_TEXT).add_modifier(Modifier::BOLD),
        ));
    }
    heading.push(Span::styled(
        fit_right("Agent Review", agent_review_width),
        Style::default().fg(MUTED_TEXT).add_modifier(Modifier::BOLD),
    ));
    lines.push(Line::from(heading));
    if all_pull_requests.is_empty() {
        return;
    }
    let mut groups: BTreeMap<&str, Vec<&PullRequest>> = BTreeMap::new();
    for pull_request in all_pull_requests {
        groups
            .entry(pull_request.repository.as_str())
            .or_default()
            .push(pull_request);
    }
    for (repository, pull_requests) in groups {
        lines.push(Line::from(vec![
            Span::styled(
                fit_left(
                    format!("  ● {repository} ({})", pull_requests.len()),
                    first_width,
                ),
                Style::default().fg(TEAL),
            ),
            Span::raw(" ".repeat(width.saturating_sub(first_width))),
        ]));
        for (position, pull_request) in pull_requests.iter().enumerate() {
            let selected = selected_section
                && app.github_selected < all_pull_requests.len()
                && std::ptr::eq(*pull_request, &all_pull_requests[app.github_selected]);
            let ticket_key = ticket_key_from_title(&pull_request.title);
            let (agent_review, agent_review_color) =
                super::github_review::agent_review_status(app.agent_review_status(
                    &pull_request.repository,
                    pull_request.number,
                    &pull_request.head_commit,
                ));
            let conflict = if pull_request.has_conflicts {
                "  ✕ Conflicts"
            } else {
                ""
            };
            let (status, status_color) = super::github::pull_request_status(pull_request);
            let branch = if position + 1 == pull_requests.len() {
                "└─ "
            } else {
                "├─ "
            };
            let title = crew_tagged(
                &pull_request.title,
                app.active_run_for_pull_request(&pull_request.repository, pull_request.number),
            );
            let mut row = super::github::pull_request_row(
                &title,
                pull_request.number,
                ticket_key.as_deref(),
                branch,
                status,
                status_color,
                selected,
                pull_request.needs_attention,
                first_width,
            );
            if show_conflicts {
                row.push(Span::styled(
                    fit_right(conflict.trim(), conflicts_width),
                    Style::default().fg(RED),
                ));
            }
            row.push(Span::styled(
                fit_right(agent_review, agent_review_width),
                Style::default().fg(agent_review_color),
            ));
            lines.push(Line::from(row));
        }
    }
}

fn append_overview_other_work(
    lines: &mut Vec<Line<'static>>,
    app: &App,
    all_pull_requests: &[ReviewPullRequest],
    width: usize,
) {
    let (first_width, _, agent_review_width) = github_column_widths(width, false);
    let selected_section = app.overview_section == OverviewSection::GitHubOther;
    let heading_style = if selected_section {
        selection_style(true)
    } else {
        Style::default().fg(GOLD)
    };
    let mut heading = github_section_heading(
        "  ● Other Work",
        all_pull_requests.len(),
        super::github::other_work_status_summary(all_pull_requests),
        first_width,
        heading_style,
    );
    heading.push(Span::styled(
        fit_right("Agent Review", agent_review_width),
        Style::default().fg(MUTED_TEXT).add_modifier(Modifier::BOLD),
    ));
    lines.push(Line::from(heading));
    if all_pull_requests.is_empty() {
        return;
    }
    let mut groups: BTreeMap<&str, Vec<&ReviewPullRequest>> = BTreeMap::new();
    for pull_request in all_pull_requests {
        groups
            .entry(pull_request.repository.as_str())
            .or_default()
            .push(pull_request);
    }
    for (repository, pull_requests) in groups {
        lines.push(Line::from(vec![
            Span::styled(
                fit_left(
                    format!("  ● {repository} ({})", pull_requests.len()),
                    first_width,
                ),
                Style::default().fg(TEAL),
            ),
            Span::raw(" ".repeat(width.saturating_sub(first_width))),
        ]));
        for (position, pull_request) in pull_requests.iter().enumerate() {
            let selected = selected_section
                && app.github_others_selected < all_pull_requests.len()
                && std::ptr::eq(
                    *pull_request,
                    &all_pull_requests[app.github_others_selected],
                );
            let (total_status, total_color) =
                super::github::review_decision_status(pull_request.total_status);
            let (agent_review, agent_review_color) =
                super::github_review::agent_review_status(app.agent_review_status(
                    &pull_request.repository,
                    pull_request.number,
                    &pull_request.head_commit,
                ));
            let ticket_key = ticket_key_from_title(&pull_request.title);
            let branch = if position + 1 == pull_requests.len() {
                "└─ "
            } else {
                "├─ "
            };
            let title = crew_tagged(
                &pull_request.title,
                app.active_run_for_pull_request(&pull_request.repository, pull_request.number),
            );
            let mut row = super::github::pull_request_row(
                &title,
                pull_request.number,
                ticket_key.as_deref(),
                branch,
                total_status,
                total_color,
                selected,
                pull_request.my_status == ReviewDecision::Waiting,
                first_width,
            );
            row.push(Span::styled(
                fit_right(agent_review, agent_review_width),
                Style::default().fg(agent_review_color),
            ));
            lines.push(Line::from(row));
        }
    }
}

fn overview_lines(app: &App, width: usize) -> Vec<Line<'static>> {
    let crew = app.crew();
    let mut lines = Vec::new();
    let mut offset = 0;
    if !crew.needs_you.is_empty() {
        append_run_section(
            &mut lines,
            "Needs you",
            "",
            &crew.needs_you,
            offset,
            app.overview_selected,
            width,
        );
        lines.push(Line::raw(""));
        offset += crew.needs_you.len();
    }
    append_run_section(
        &mut lines,
        "Running crew",
        "No crew at work.",
        &crew.running,
        offset,
        app.overview_selected,
        width,
    );
    offset += crew.running.len();
    lines.push(Line::raw(""));
    append_run_section(
        &mut lines,
        "Finished today",
        "No runs finished in the last day.",
        &crew.recent,
        offset,
        app.overview_selected,
        width,
    );
    let queued = app
        .fleet
        .snapshot()
        .map(|snapshot| {
            snapshot
                .backlog
                .iter()
                .filter(|record| record.state == "queued")
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    if !queued.is_empty() {
        lines.push(Line::raw(""));
        lines.push(section_heading(&format!("Queued ({})", queued.len()), TEAL));
        for (index, record) in queued.iter().enumerate() {
            let hold = record
                .hold_reason
                .as_deref()
                .map(|reason| format!("  held: {reason}"))
                .unwrap_or_default();
            lines.push(Line::from(vec![
                Span::raw("  "),
                list_branch(index + 1 == queued.len()),
                Span::styled("○ ", Style::default().fg(BORDER)),
                Span::styled(
                    fit_left(format!("{}{hold}", record.title), width.saturating_sub(7)),
                    Style::default().fg(MUTED_TEXT),
                ),
            ]));
        }
    }
    lines
}

pub(super) fn overview_scroll_offset(selected_line: usize, viewport_height: usize) -> u16 {
    u16::try_from(selected_line.saturating_sub(viewport_height.saturating_sub(1)))
        .unwrap_or(u16::MAX)
}

fn append_run_section(
    lines: &mut Vec<Line<'static>>,
    title: &str,
    empty_message: &str,
    runs: &[&Run],
    selection_offset: usize,
    selected: usize,
    width: usize,
) {
    lines.push(section_heading(title, TEAL));
    if runs.is_empty() {
        lines.push(Line::from(vec![
            Span::raw("  "),
            list_branch(true),
            Span::styled(empty_message.to_owned(), Style::default().fg(MUTED_TEXT)),
        ]));
        return;
    }
    let mut previous_mode = None;
    for (index, run) in runs.iter().enumerate() {
        let mode = run.mode();
        if previous_mode != Some(mode) {
            if previous_mode.is_some() {
                lines.push(Line::raw(""));
            }
            lines.push(section_heading(mode, TEAL));
            previous_mode = Some(mode);
        }
        let last_in_mode = runs
            .get(index + 1)
            .map(|next| next.mode() != mode)
            .unwrap_or(true);
        lines.push(recent_run_line_with_prefix(
            run,
            selection_offset + index == selected,
            width,
            if last_in_mode { "└─ " } else { "├─ " },
        ));
    }
}

fn list_branch(last: bool) -> Span<'static> {
    Span::styled(
        if last { "└─ " } else { "├─ " },
        Style::default().fg(BORDER),
    )
}

pub(super) fn recent_run_line(run: &Run, selected: bool, width: usize) -> Line<'static> {
    recent_run_line_with_prefix(run, selected, width, "")
}

fn recent_run_line_with_prefix(
    run: &Run,
    selected: bool,
    width: usize,
    prefix: &'static str,
) -> Line<'static> {
    let datetime = crate::app::format_time(run.created_at);
    let agent = run.agent().or(run.harness.as_deref()).unwrap_or("crewmate");
    let status = format!("{} ", run_status_symbol(run.status));
    let target = run_target(run);
    let marker = if selected { "› " } else { "  " };
    let content_width = width.saturating_sub(marker.chars().count() + prefix.chars().count());
    let latest = run
        .status_text
        .as_deref()
        .filter(|text| !text.is_empty())
        .map(|text| format!("  — {text}"))
        .unwrap_or_default();
    let detail = format!("{datetime} {agent} {target} {}{latest}", run.title);
    let detail = detail
        .chars()
        .take(content_width.saturating_sub(status.chars().count()))
        .collect::<String>();
    let spacing = content_width.saturating_sub(detail.chars().count() + status.chars().count());
    let style = if selected {
        selection_style(true)
    } else {
        attention_style(false, run.live)
    };
    let marker_style = if selected {
        Style::default().fg(CORAL).add_modifier(Modifier::BOLD)
    } else {
        Style::default().fg(BORDER)
    };
    let status_style = if selected {
        selection_style(true)
    } else {
        Style::default().fg(run_status_color(run.status))
    };
    Line::from(vec![
        Span::styled(marker, marker_style),
        Span::styled(prefix, Style::default().fg(BORDER)),
        Span::styled(status, status_style.add_modifier(Modifier::BOLD)),
        Span::styled(format!("{detail}{}", " ".repeat(spacing)), style),
    ])
}

/// `#42` for pull request work, the ticket key for ticket work, else the task id.
pub(super) fn run_target(run: &Run) -> String {
    if matches!(
        run.mode(),
        "Review" | "Address" | "Conflicts" | "Description" | "Free"
    ) && let Some(number) = run.pr_number
    {
        return format!("#{number}");
    }
    run.ticket_key.clone().unwrap_or_else(|| run.task.clone())
}

fn section_heading(title: &str, color: Color) -> Line<'static> {
    Line::styled(
        format!("  ● {title}"),
        Style::default().fg(color).add_modifier(Modifier::BOLD),
    )
}

/// Appends `⚓ <task>` when a crew run is working on the item.
pub(super) fn crew_tagged(text: &str, run: Option<&Run>) -> String {
    match run {
        Some(run) => format!("{text}  ⚓ {}", run.task),
        None => text.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn overview_sections_have_navigation_offsets() {
        let app = App::default();
        let jira = overview_section_start(&app, 80, OverviewSection::Jira);
        let github = overview_section_start(&app, 80, OverviewSection::GitHubMe);
        let crew = overview_section_start(&app, 80, OverviewSection::Crew);

        assert_eq!(crew, 0);
        assert!(crew < jira && jira < github);
    }
}
