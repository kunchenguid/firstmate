use super::form::{heading, push_stacked_field};
use super::*;
use crate::app::AgentSettingsState;

pub(super) fn render_settings(
    frame: &mut Frame,
    area: Rect,
    settings: &AgentSettingsState,
    app: &App,
) {
    let navigation = Line::from(
        ["Agents", "Home"]
            .into_iter()
            .enumerate()
            .map(|(index, label)| {
                let selected = settings.sidebar_selected == index;
                Span::styled(
                    format!(
                        "{}{label}{}",
                        if selected && settings.focus == AgentSettingsFocus::Sidebar {
                            "› "
                        } else if selected {
                            "● "
                        } else {
                            ""
                        },
                        if index == 0 { "  " } else { "" },
                    ),
                    if selected {
                        selection_style(true)
                    } else {
                        Style::default().fg(MUTED_TEXT)
                    },
                )
            })
            .collect::<Vec<_>>(),
    );
    let navigation = Paragraph::new(navigation).wrap(Wrap { trim: false });
    let navigation_height = navigation.line_count(area.width) as u16 + 1;
    let notice = Paragraph::new(settings.notice.as_deref().unwrap_or_default())
        .style(Style::default().fg(RED))
        .wrap(Wrap { trim: false });
    let notice_height = if settings.notice.is_some() {
        notice.line_count(area.width).min(2) as u16
    } else {
        0
    };
    let sections = Layout::vertical([
        Constraint::Length(2),
        Constraint::Length(navigation_height),
        Constraint::Min(0),
        Constraint::Length(notice_height),
    ])
    .split(area);
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled("● Settings", selection_style(true)),
            Span::styled(
                "  ·  Agents firstmate uses for vessel workflows",
                Style::default().fg(MUTED_TEXT),
            ),
        ])),
        sections[0],
    );
    frame.render_widget(navigation, sections[1]);
    frame.render_widget(notice, sections[3]);

    let area = sections[2];
    let mut lines = Vec::new();
    let mut focused_row = 0;
    if settings.agent_runs.is_some() {
        agent_run_lines(&mut lines, &mut focused_row, area.width, settings, app);
    } else if settings.sidebar_selected == 1 {
        home_lines(&mut lines, app);
    } else {
        agent_lines(&mut lines, &mut focused_row, area.width, settings);
    }
    let scroll = overview_scroll_offset(focused_row.saturating_add(1), usize::from(area.height));
    render_document(frame, area, lines, scroll);
}

fn agent_lines(
    lines: &mut Vec<Line<'static>>,
    focused_row: &mut usize,
    width: u16,
    settings: &AgentSettingsState,
) {
    if matches!(
        settings.focus,
        AgentSettingsFocus::Sidebar | AgentSettingsFocus::Agents | AgentSettingsFocus::Home
    ) {
        lines.push(heading(format!("Agents ({})", settings.agents.len())));
        lines.push(Line::raw(""));
        if settings.agents.is_empty() {
            lines.push(Line::raw("No agents configured. Press A to add an agent."));
        }
        for (index, agent) in settings.agents.iter().enumerate() {
            push_list_row(
                lines,
                focused_row,
                width,
                settings.focus == AgentSettingsFocus::Agents && index == settings.agent,
                agent.name.clone(),
                &[
                    agent.mode.as_str(),
                    agent.harness.as_str(),
                    if agent.model.is_empty() {
                        "default model"
                    } else {
                        agent.model.as_str()
                    },
                ]
                .join(" · "),
            );
        }
        lines.push(Line::raw(""));
        lines.push(Line::styled(
            "Ask firstmate for a workflow (\"review acme/web#42\", \"implement AA4FI-1 with Slim Charles\"); it dispatches with the matching agent.",
            Style::default().fg(MUTED_TEXT),
        ));
        return;
    }
    let Some(agent) = settings.agents.get(settings.agent) else {
        lines.push(Line::raw("No agent selected. Press B to return to Agents."));
        return;
    };
    lines.push(heading(format!("Agent: {}", agent.name)));
    lines.push(Line::raw(""));
    let effort = if agent.effort.is_empty() {
        "harness default"
    } else {
        agent.effort.as_str()
    };
    for (focus, label, value) in [
        (AgentSettingsFocus::AgentName, "Name", agent.name.as_str()),
        (AgentSettingsFocus::AgentMode, "Mode", agent.mode.as_str()),
        (
            AgentSettingsFocus::AgentHarness,
            "Harness",
            agent.harness.as_str(),
        ),
        (
            AgentSettingsFocus::AgentModel,
            "Model",
            agent.model.as_str(),
        ),
        (AgentSettingsFocus::AgentEffort, "Effort", effort),
        (
            AgentSettingsFocus::AgentInstructions,
            "Instructions",
            agent.instructions.as_str(),
        ),
    ] {
        push_field(lines, focused_row, width, settings, focus, label, value);
    }
}

fn home_lines(lines: &mut Vec<Line<'static>>, app: &App) {
    let config = &app.config;
    lines.push(heading("firstmate home"));
    lines.push(Line::raw(""));
    let row = |label: &str, value: String| {
        Line::from(vec![
            Span::styled(format!("{label:<16}"), Style::default().fg(MUTED_TEXT)),
            Span::styled(value, Style::default().fg(TEXT)),
        ])
    };
    lines.push(row("Home", config.fm_home.display().to_string()));
    lines.push(row(
        "Fleet ledger",
        if app.fleet.ledger_enabled {
            format!("on ({})", app.fleet.ledger.path().display())
        } else {
            "off - enable with: touch config/fleet-ledger".into()
        },
    ));
    lines.push(row("Run records", config.runs_file().display().to_string()));
    lines.push(row(
        "Agents",
        config
            .vessel_dir()
            .join("agents.json")
            .display()
            .to_string(),
    ));
    lines.push(row(
        "Settings",
        config
            .vessel_dir()
            .join("vessel.json")
            .display()
            .to_string(),
    ));
    lines.push(row(
        "Jira",
        if config.jira_enabled {
            config
                .jira_jql
                .clone()
                .unwrap_or_else(|| "on (default search)".into())
        } else {
            "off".into()
        },
    ));
    lines.push(row(
        "GitHub",
        if config.github_enabled { "on" } else { "off" }.into(),
    ));
    lines.push(row(
        "Ticket keys",
        if config.ticket_projects.is_empty() {
            "any ABC-123 key".into()
        } else {
            config.ticket_projects.join(", ")
        },
    ));
    lines.push(Line::raw(""));
    lines.push(Line::styled(
        "vessel writes only config/vessel/. Everything else here is read from firstmate.",
        Style::default().fg(MUTED_TEXT),
    ));
}

fn push_field(
    lines: &mut Vec<Line<'static>>,
    focused_row: &mut usize,
    width: u16,
    settings: &AgentSettingsState,
    focus: AgentSettingsFocus,
    label: &str,
    value: &str,
) {
    push_stacked_field(
        lines,
        focused_row,
        width,
        settings.focus == focus,
        settings.editing,
        label,
        value,
        settings.cursor,
        settings.selection_anchor,
    );
    if settings.focus == focus && !settings.editing {
        // Keep the value visible together with its label on short terminals.
        *focused_row += 1;
    }
}

fn mark_focused_row(lines: &[Line<'static>], focused_row: &mut usize, width: u16) {
    *focused_row = Paragraph::new(lines.to_vec())
        .wrap(Wrap { trim: false })
        .line_count(width);
}

fn push_list_row(
    lines: &mut Vec<Line<'static>>,
    focused_row: &mut usize,
    width: u16,
    selected: bool,
    label: String,
    detail: &str,
) {
    let mut line = Line::styled(
        format!("{} {label}", if selected { "›" } else { " " }),
        selection_style(selected),
    );
    if !detail.is_empty() {
        let used = line.width() + Line::raw(detail).width();
        if used + 3 <= usize::from(width) {
            line.push_span(Span::raw(" ".repeat(usize::from(width) - used)));
            line.push_span(Span::styled(
                detail.to_owned(),
                Style::default().fg(MUTED_TEXT),
            ));
        } else {
            lines.push(line);
            line = Line::styled(format!("  {detail}"), Style::default().fg(MUTED_TEXT));
        }
    }
    lines.push(line);
    if selected {
        mark_focused_row(lines, focused_row, width);
        *focused_row = focused_row.saturating_sub(1);
    }
}

fn agent_run_lines(
    lines: &mut Vec<Line<'static>>,
    focused_row: &mut usize,
    width: u16,
    settings: &AgentSettingsState,
    app: &App,
) {
    let Some(agent) = settings
        .agent_runs
        .and_then(|index| settings.agents.get(index))
    else {
        return;
    };
    let runs = app.agent_runs();
    lines.push(heading(format!(
        "Agent Runs: {} ({})",
        agent.name,
        runs.len()
    )));
    lines.push(Line::raw(""));
    if runs.is_empty() {
        lines.push(Line::raw("No runs for this agent."));
    }
    for (index, run) in runs.iter().enumerate() {
        let selected = index == settings.selected;
        if selected {
            mark_focused_row(lines, focused_row, width);
        }
        lines.push(recent_run_line(run, selected, usize::from(width)));
    }
}
