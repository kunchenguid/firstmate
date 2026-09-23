use super::*;

pub(super) fn my_work_status_summary(
    pull_requests: &[PullRequest],
) -> Vec<(usize, &'static str, Color)> {
    let mut counts = [0; 5];
    for pull_request in pull_requests {
        counts[match pull_request.status {
            ReviewStatus::Draft => 0,
            ReviewStatus::Approved => 1,
            ReviewStatus::Waiting => 2,
            ReviewStatus::ChangesRequested => 3,
        }] += 1;
        if pull_request.has_conflicts {
            counts[4] += 1;
        }
    }
    [
        (counts[0], "Draft", BORDER),
        (counts[1], "Approved", GREEN),
        (counts[2], "Waiting", TEAL),
        (counts[3], "Changes Requested", RED),
        (counts[4], "Conflicts", RED),
    ]
    .into_iter()
    .filter(|(count, _, _)| *count > 0)
    .collect()
}

pub(super) fn other_work_status_summary(
    pull_requests: &[ReviewPullRequest],
) -> Vec<(usize, &'static str, Color)> {
    let mut counts = [0; 3];
    for pull_request in pull_requests {
        counts[match pull_request.total_status {
            ReviewDecision::Approved => 0,
            ReviewDecision::Waiting => 1,
            ReviewDecision::ChangesRequested => 2,
        }] += 1;
    }
    [
        (counts[0], "Approved", GREEN),
        (counts[1], "Waiting", BLUE),
        (counts[2], "Changes Requested", RED),
    ]
    .into_iter()
    .filter(|(count, _, _)| *count > 0)
    .collect()
}

fn github_columns(row: Rect, show_conflicts: bool) -> Vec<Rect> {
    let constraints = if show_conflicts {
        vec![
            Constraint::Percentage(60),
            Constraint::Percentage(20),
            Constraint::Percentage(20),
        ]
    } else {
        vec![Constraint::Percentage(80), Constraint::Percentage(20)]
    };
    Layout::horizontal(constraints).split(row).to_vec()
}

pub(super) fn pull_request_row(
    title: &str,
    number: u64,
    ticket_key: Option<&str>,
    branch: &str,
    status_symbol: &str,
    status_color: Color,
    selected: bool,
    needs_attention: bool,
    width: usize,
) -> Vec<Span<'static>> {
    let marker = if selected { "› " } else { "  " };
    let status = format!("{status_symbol} ");
    let ticket_key = ticket_key.map(|key| format!("{key}  ")).unwrap_or_default();
    let number = format!("#{number}  ");
    let fixed_width = marker.chars().count()
        + branch.chars().count()
        + status.chars().count()
        + ticket_key.chars().count()
        + number.chars().count();
    let title = title
        .chars()
        .take(width.saturating_sub(fixed_width))
        .collect::<String>();
    let used_width = fixed_width + title.chars().count();
    let identifier_style = if selected {
        selection_style(true)
    } else {
        Style::default().fg(MUTED_TEXT)
    };
    vec![
        Span::styled(marker, selection_style(selected)),
        Span::styled(branch.to_owned(), Style::default().fg(BORDER)),
        Span::styled(
            status,
            if selected {
                selection_style(true)
            } else {
                Style::default().fg(status_color)
            },
        ),
        Span::styled(ticket_key, identifier_style),
        Span::styled(number, identifier_style),
        Span::styled(title, attention_style(selected, needs_attention)),
        Span::raw(" ".repeat(width.saturating_sub(used_width))),
    ]
}

pub(super) fn render_github_page(frame: &mut Frame, area: Rect, app: &App) {
    let sections = Layout::vertical([Constraint::Length(2), Constraint::Min(0)]).split(area);

    let my_prs = match &app.github {
        GitHubState::Ready(prs) => Some(prs.as_slice()),
        _ => None,
    };
    let other_prs = match &app.github_others {
        GitHubOthersState::Ready(prs) => Some(prs.as_slice()),
        _ => None,
    };

    let mut heading = vec![Span::styled("● GitHub", selection_style(true))];
    let total_count = my_prs.map_or(0, |p| p.len()) + other_prs.map_or(0, |p| p.len());
    heading.push(Span::styled(
        format!(" ({total_count})  ·  Pull requests"),
        Style::default().fg(MUTED_TEXT),
    ));

    if let Some(prs) = my_prs {
        let approved = prs
            .iter()
            .filter(|pr| pr.status == ReviewStatus::Approved)
            .count();
        let waiting = prs
            .iter()
            .filter(|pr| pr.status == ReviewStatus::Waiting)
            .count();
        let changes = prs
            .iter()
            .filter(|pr| pr.status == ReviewStatus::ChangesRequested)
            .count();
        let conflicts = prs.iter().filter(|pr| pr.has_conflicts).count();

        if area.width >= 100 {
            heading.push(Span::styled(
                format!("   {approved} "),
                Style::default().fg(GREEN),
            ));
            heading.push(Span::styled("Approved", Style::default().fg(MUTED_TEXT)));
            heading.push(Span::styled(
                format!("   {waiting} "),
                Style::default().fg(TEAL),
            ));
            heading.push(Span::styled("Waiting", Style::default().fg(MUTED_TEXT)));
            if changes > 0 {
                heading.push(Span::styled(
                    format!("   {changes} "),
                    Style::default().fg(RED),
                ));
                heading.push(Span::styled(
                    "Changes Requested",
                    Style::default().fg(MUTED_TEXT),
                ));
            }
            if conflicts > 0 {
                heading.push(Span::styled(
                    format!("   {conflicts} "),
                    Style::default().fg(RED),
                ));
                heading.push(Span::styled("Conflicts", Style::default().fg(MUTED_TEXT)));
            }
        }
    }

    frame.render_widget(Paragraph::new(Line::from(heading)), sections[0]);

    if let GitHubState::Error(message) = &app.github {
        render_document(
            frame,
            sections[1],
            vec![
                Line::styled("GitHub data unavailable", Style::default().fg(RED)),
                Line::raw(message),
                Line::raw(""),
                Line::raw("Press R to retry."),
            ],
            0,
        );
        return;
    }

    if let GitHubOthersState::Error(message) = &app.github_others {
        render_document(
            frame,
            sections[1],
            vec![
                Line::styled("GitHub review data unavailable", Style::default().fg(RED)),
                Line::raw(message),
                Line::raw(""),
                Line::raw("Press R to retry."),
            ],
            0,
        );
        return;
    }

    if matches!(&app.github, GitHubState::Loading)
        && matches!(&app.github_others, GitHubOthersState::Loading)
    {
        render_document(
            frame,
            sections[1],
            vec![Line::raw("Loading GitHub pull requests…")],
            0,
        );
        return;
    }

    let my_prs = my_prs.unwrap_or_default();
    let other_prs = other_prs.unwrap_or_default();

    if my_prs.is_empty() && other_prs.is_empty() {
        render_document(
            frame,
            sections[1],
            vec![Line::raw("No open pull requests found.")],
            0,
        );
        return;
    }

    let show_conflicts = my_prs.iter().any(|pull_request| pull_request.has_conflicts);
    let viewport = sections[1];

    // Compute line layout and find selected row for scrolling
    // Line layout:
    // Section header (e.g. "  ● My Work") -> 1 line
    // Repo header (e.g. "  ● repo") -> 1 line
    //   PR row (e.g. "  ├─ ● #123 Title") -> 1 line
    let mut total_lines = 0;
    let mut selected_line = None;

    let my_groups = group_pull_requests(my_prs);
    let mut other_groups = BTreeMap::<&str, Vec<&ReviewPullRequest>>::new();
    for pull_request in other_prs {
        other_groups
            .entry(pull_request.repository.as_str())
            .or_default()
            .push(pull_request);
    }

    // Measure total lines & find selected line
    if !my_prs.is_empty() {
        total_lines += 2; // "My Work" section header + column headers
        for prs in my_groups.values() {
            total_lines += 1; // repo header
            for pr in prs {
                if app.github_section == GitHubSection::MyWork
                    && app.github_selected < my_prs.len()
                    && std::ptr::eq(*pr, &my_prs[app.github_selected])
                {
                    selected_line = Some(total_lines);
                }
                total_lines += 1;
            }
        }
    } else {
        total_lines += 2;
    }

    if !my_prs.is_empty() && !other_prs.is_empty() {
        total_lines += 1; // space between sections
    }

    if !other_prs.is_empty() {
        total_lines += 2; // "Other Work" section header + column headers
        for prs in other_groups.values() {
            total_lines += 1; // repo header
            for pr in prs {
                if app.github_section == GitHubSection::OtherWork
                    && app.github_others_selected < other_prs.len()
                    && std::ptr::eq(*pr, &other_prs[app.github_others_selected])
                {
                    selected_line = Some(total_lines);
                }
                total_lines += 1;
            }
        }
    }

    let scroll = selected_line
        .map(|line| {
            let v_h = usize::from(viewport.height);
            if total_lines > v_h {
                line.saturating_sub(v_h.min(5))
            } else {
                0
            }
        })
        .unwrap_or_default();
    let viewport_top = scroll;
    let viewport_bottom = viewport_top + usize::from(viewport.height);

    let mut current_line = 0;

    // Helper macro / closure to render visible lines
    // Render My Work
    if !my_prs.is_empty() {
        if current_line >= viewport_top && current_line < viewport_bottom {
            let y = viewport.y + (current_line - viewport_top) as u16;
            let row = Rect::new(viewport.x, y, viewport.width, 1);
            let is_active_section = app.github_section == GitHubSection::MyWork;
            let header_columns = github_columns(row, show_conflicts);
            let agent_review_column = if show_conflicts { 2 } else { 1 };
            let mut section_heading = vec![
                Span::styled(
                    "  ● My Work",
                    if is_active_section {
                        selection_style(true)
                    } else {
                        Style::default().fg(GREEN)
                    },
                ),
                Span::styled(
                    format!(" ({})", my_prs.len()),
                    Style::default().fg(MUTED_TEXT),
                ),
            ];
            for (count, label, color) in my_work_status_summary(my_prs) {
                section_heading.push(Span::styled(
                    format!("   {count} "),
                    Style::default().fg(color),
                ));
                section_heading.push(Span::styled(label, Style::default().fg(MUTED_TEXT)));
            }
            frame.render_widget(
                Paragraph::new(Line::from(section_heading)),
                header_columns[0],
            );
            if show_conflicts {
                frame.render_widget(
                    Paragraph::new("Conflicts")
                        .style(Style::default().fg(MUTED_TEXT).add_modifier(Modifier::BOLD))
                        .alignment(Alignment::Right),
                    header_columns[1],
                );
            }
            frame.render_widget(
                Paragraph::new("Agent Review")
                    .style(Style::default().fg(MUTED_TEXT).add_modifier(Modifier::BOLD))
                    .alignment(Alignment::Right),
                header_columns[agent_review_column],
            );
        }
        current_line += 2;

        for (repo, prs) in &my_groups {
            if current_line >= viewport_top && current_line < viewport_bottom {
                let y = viewport.y + (current_line - viewport_top) as u16;
                let row = Rect::new(viewport.x, y, viewport.width, 1);
                frame.render_widget(
                    Paragraph::new(Line::from(vec![
                        Span::styled(format!("  ● {repo}"), Style::default().fg(TEAL)),
                        Span::styled(format!(" ({})", prs.len()), Style::default().fg(MUTED_TEXT)),
                    ])),
                    row,
                );
            }
            current_line += 1;

            for (position, pr) in prs.iter().enumerate() {
                if current_line >= viewport_top && current_line < viewport_bottom {
                    let y = viewport.y + (current_line - viewport_top) as u16;
                    let row = Rect::new(viewport.x, y, viewport.width, 1);
                    let is_selected = app.github_section == GitHubSection::MyWork
                        && app.github_selected < my_prs.len()
                        && std::ptr::eq(*pr, &my_prs[app.github_selected]);

                    let (status_symbol, status_color) = pull_request_status(pr);
                    let columns = github_columns(row, show_conflicts);
                    let agent_review_column = if show_conflicts { 2 } else { 1 };

                    let branch = if position + 1 == prs.len() {
                        "└─ "
                    } else {
                        "├─ "
                    };
                    let ticket_key = ticket_key_from_title(&pr.title);
                    frame.render_widget(
                        Paragraph::new(Line::from(pull_request_row(
                            &pr.title,
                            pr.number,
                            ticket_key.as_deref(),
                            branch,
                            status_symbol,
                            status_color,
                            is_selected,
                            pr.needs_attention,
                            usize::from(columns[0].width),
                        ))),
                        columns[0],
                    );

                    if pr.has_conflicts {
                        frame.render_widget(
                            Paragraph::new("✕ Conflicts")
                                .style(Style::default().fg(RED).add_modifier(Modifier::BOLD))
                                .alignment(Alignment::Right),
                            columns[1],
                        );
                    }

                    let (agent_review, agent_review_color) = agent_review_status(
                        app.agent_review_status(&pr.repository, pr.number, &pr.head_commit),
                    );
                    frame.render_widget(
                        Paragraph::new(agent_review)
                            .style(
                                Style::default()
                                    .fg(agent_review_color)
                                    .add_modifier(Modifier::BOLD),
                            )
                            .alignment(Alignment::Right),
                        columns[agent_review_column],
                    );
                }
                current_line += 1;
            }
        }
    } else {
        if current_line >= viewport_top && current_line < viewport_bottom {
            let y = viewport.y + (current_line - viewport_top) as u16;
            let row = Rect::new(viewport.x, y, viewport.width, 1);
            let is_active_section = app.github_section == GitHubSection::MyWork;
            frame.render_widget(
                Paragraph::new(Line::from(vec![
                    Span::styled(
                        "  ● My Work",
                        if is_active_section {
                            selection_style(true)
                        } else {
                            Style::default().fg(GREEN)
                        },
                    ),
                    Span::styled(" (0)", Style::default().fg(MUTED_TEXT)),
                ])),
                row,
            );
        }
        current_line += 2;
    }

    // Render Other Work
    if !my_prs.is_empty() && !other_prs.is_empty() {
        if current_line >= viewport_top && current_line < viewport_bottom {
            let y = viewport.y + (current_line - viewport_top) as u16;
            frame.render_widget(
                Paragraph::new("─".repeat(usize::from(viewport.width)))
                    .style(Style::default().fg(BORDER)),
                Rect::new(viewport.x, y, viewport.width, 1),
            );
        }
        current_line += 1;
    }
    if !other_prs.is_empty() {
        if current_line >= viewport_top && current_line < viewport_bottom {
            let y = viewport.y + (current_line - viewport_top) as u16;
            let row = Rect::new(viewport.x, y, viewport.width, 1);
            let is_active_section = app.github_section == GitHubSection::OtherWork;
            let header_columns = github_columns(row, false);
            let mut section_heading = vec![
                Span::styled(
                    "  ● Other Work",
                    if is_active_section {
                        selection_style(true)
                    } else {
                        Style::default().fg(GOLD)
                    },
                ),
                Span::styled(
                    format!(" ({})", other_prs.len()),
                    Style::default().fg(MUTED_TEXT),
                ),
            ];
            for (count, label, color) in other_work_status_summary(other_prs) {
                section_heading.push(Span::styled(
                    format!("   {count} "),
                    Style::default().fg(color),
                ));
                section_heading.push(Span::styled(label, Style::default().fg(MUTED_TEXT)));
            }
            frame.render_widget(
                Paragraph::new(Line::from(section_heading)),
                header_columns[0],
            );
            frame.render_widget(
                Paragraph::new("Agent Review")
                    .style(Style::default().fg(MUTED_TEXT).add_modifier(Modifier::BOLD))
                    .alignment(Alignment::Right),
                header_columns[1],
            );
        }
        current_line += 2;

        for (repo, prs) in &other_groups {
            if current_line >= viewport_top && current_line < viewport_bottom {
                let y = viewport.y + (current_line - viewport_top) as u16;
                let row = Rect::new(viewport.x, y, viewport.width, 1);
                frame.render_widget(
                    Paragraph::new(Line::from(vec![
                        Span::styled(format!("  ● {repo}"), Style::default().fg(TEAL)),
                        Span::styled(format!(" ({})", prs.len()), Style::default().fg(MUTED_TEXT)),
                    ])),
                    row,
                );
            }
            current_line += 1;

            for (position, pr) in prs.iter().enumerate() {
                if current_line >= viewport_top && current_line < viewport_bottom {
                    let y = viewport.y + (current_line - viewport_top) as u16;
                    let row = Rect::new(viewport.x, y, viewport.width, 1);
                    let is_selected = app.github_section == GitHubSection::OtherWork
                        && app.github_others_selected < other_prs.len()
                        && std::ptr::eq(*pr, &other_prs[app.github_others_selected]);

                    let (status_symbol, status_color) = review_decision_status(pr.total_status);
                    let columns = github_columns(row, false);

                    let branch = if position + 1 == prs.len() {
                        "└─ "
                    } else {
                        "├─ "
                    };
                    let ticket_key = ticket_key_from_title(&pr.title);
                    frame.render_widget(
                        Paragraph::new(Line::from(pull_request_row(
                            &pr.title,
                            pr.number,
                            ticket_key.as_deref(),
                            branch,
                            status_symbol,
                            status_color,
                            is_selected,
                            pr.my_status == ReviewDecision::Waiting,
                            usize::from(columns[0].width),
                        ))),
                        columns[0],
                    );

                    let (agent_review, agent_review_color) = agent_review_status(
                        app.agent_review_status(&pr.repository, pr.number, &pr.head_commit),
                    );
                    frame.render_widget(
                        Paragraph::new(agent_review)
                            .style(
                                Style::default()
                                    .fg(agent_review_color)
                                    .add_modifier(Modifier::BOLD),
                            )
                            .alignment(Alignment::Right),
                        columns[1],
                    );
                }
                current_line += 1;
            }
        }
    }
}

pub(super) fn group_pull_requests(
    pull_requests: &[PullRequest],
) -> BTreeMap<&str, Vec<&PullRequest>> {
    let mut groups = BTreeMap::new();
    for pull_request in pull_requests {
        groups
            .entry(pull_request.repository.as_str())
            .or_insert_with(Vec::new)
            .push(pull_request);
    }
    groups
}

pub(super) fn pull_request_status(pull_request: &PullRequest) -> (&'static str, Color) {
    match pull_request.status {
        ReviewStatus::Draft => ("○", BORDER),
        ReviewStatus::Waiting => ("◐", GOLD),
        ReviewStatus::ChangesRequested => ("✕", RED),
        ReviewStatus::Approved => ("✓", GREEN),
    }
}

pub(super) fn review_decision_status(decision: ReviewDecision) -> (&'static str, Color) {
    match decision {
        ReviewDecision::Waiting => ("◐", GOLD),
        ReviewDecision::ChangesRequested => ("✕", RED),
        ReviewDecision::Approved => ("✓", GREEN),
    }
}
