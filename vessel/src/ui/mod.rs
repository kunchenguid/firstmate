use std::collections::BTreeMap;

use ratatui::{
    Frame,
    layout::{Alignment, Constraint, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Padding, Paragraph, Wrap},
};

use crate::{
    app::{
        AgentReviewStatus, AgentSettingsFocus, App, GitHubDetailState, GitHubOthersState,
        GitHubReviewFocus, GitHubReviewState, GitHubSection, GitHubState, JiraDetailFocus,
        JiraDetailState, JiraState, OverviewSection, PlanState, TAB_TITLES,
    },
    firstmate::runs::{Run, RunStatus},
    github::{
        PullRequest, PullRequestDetail, ReviewDecision, ReviewPullRequest, ReviewStatus,
        ticket_key_from_title,
    },
    jira::BoardStatus,
};

mod activity;
mod form;
mod github;
mod github_comments;
mod github_review;
pub(crate) use github_comments::github_comments_navigation;
mod jira;
mod overview;
mod run;
mod settings;

use github_review::{agent_review_status, markdown_lines};
use overview::{overview_scroll_offset, recent_run_line};

const BACKGROUND: Color = Color::Rgb(40, 44, 52);
const SURFACE: Color = BACKGROUND;
const MUTED_SURFACE: Color = Color::Rgb(49, 54, 63);
const BORDER: Color = Color::Rgb(82, 89, 101);
pub(crate) const TEXT: Color = Color::Rgb(226, 230, 237);
pub(crate) const MUTED_TEXT: Color = Color::Rgb(145, 151, 160);
const CORAL: Color = Color::Rgb(143, 211, 201);
pub(crate) const GREEN: Color = Color::Rgb(166, 227, 161);
pub(crate) const RED: Color = Color::Rgb(204, 103, 102);
pub(crate) const GOLD: Color = Color::Rgb(244, 231, 161);
pub(crate) const BLUE: Color = Color::Rgb(137, 180, 250);
pub(crate) const TEAL: Color = Color::Rgb(126, 193, 190);

pub(super) fn render_document(frame: &mut Frame, area: Rect, lines: Vec<Line<'_>>, scroll: u16) {
    let paragraph = Paragraph::new(lines)
        .style(Style::default().fg(MUTED_TEXT))
        .wrap(Wrap { trim: false });
    let max_scroll = paragraph
        .line_count(area.width)
        .saturating_sub(usize::from(area.height));
    frame.render_widget(
        paragraph.scroll((scroll.min(u16::try_from(max_scroll).unwrap_or(u16::MAX)), 0)),
        area,
    );
}

pub(crate) const BOARD_COLUMNS: [(BoardStatus, &str, Color); 4] = [
    (BoardStatus::ToDo, "To Do", GREEN),
    (BoardStatus::OnHold, "On Hold", RED),
    (BoardStatus::InProgress, "In Progress", GOLD),
    (BoardStatus::InReview, "In Review", BLUE),
];

/// Remy's glyph language applied to firstmate run states.
pub(crate) const fn run_status_symbol(status: RunStatus) -> &'static str {
    match status {
        RunStatus::Working => "◐",
        RunStatus::NeedsDecision => "◇",
        RunStatus::Blocked | RunStatus::Failed => "✕",
        RunStatus::Paused | RunStatus::Idle => "○",
        RunStatus::Done | RunStatus::Merged | RunStatus::Completed => "✓",
        RunStatus::Closed | RunStatus::Unknown => "●",
    }
}

pub(crate) const fn run_status_color(status: RunStatus) -> Color {
    match status {
        RunStatus::Working => GOLD,
        RunStatus::NeedsDecision => CORAL,
        RunStatus::Blocked | RunStatus::Failed => RED,
        RunStatus::Done | RunStatus::Merged | RunStatus::Completed => GREEN,
        RunStatus::Paused | RunStatus::Idle | RunStatus::Closed | RunStatus::Unknown => MUTED_TEXT,
    }
}

pub(crate) fn render(frame: &mut Frame, app: &App) {
    let area = frame.area();
    frame.render_widget(Block::new().style(Style::default().bg(BACKGROUND)), area);

    let shell = shell_areas(area);

    if let Some(notice) = app.notice.as_ref().or(app.fleet.notice.as_ref()) {
        frame.render_widget(
            Paragraph::new(notice.as_str())
                .style(Style::default().fg(CORAL))
                .alignment(Alignment::Center),
            shell[0],
        );
    }

    if app.run_view.is_some() {
        run::render_run(frame, shell[1], app);
    } else if app.activity.is_some() {
        activity::render_activity(frame, shell[1], app);
    } else if let Some(settings) = &app.agent_settings {
        settings::render_settings(frame, shell[1], settings, app);
    } else if let Some(plan) = &app.plan {
        jira::render_plan(frame, shell[1], plan);
    } else if let Some(detail) = &app.jira_detail {
        jira::render_jira_detail(frame, shell[1], detail, app.jira_detail_scroll, app);
    } else if app.github_review.is_some() {
        github_review::render_github_review(frame, shell[1], app);
    } else {
        match app.active_tab {
            0 => overview::render_overview(frame, shell[1], app),
            1 => jira::render_jira(frame, shell[1], app),
            2 => github::render_github_page(frame, shell[1], app),
            _ => render_empty_page(frame, shell[1], TAB_TITLES[app.active_tab]),
        }
    }

    render_shortcuts(frame, shell[3], app);
}

fn shell_areas(area: Rect) -> [Rect; 4] {
    Layout::vertical([
        Constraint::Length(1),
        Constraint::Min(12),
        Constraint::Length(1),
        Constraint::Length(1),
    ])
    .margin(1)
    .areas(area)
}

fn render_shortcuts(frame: &mut Frame, area: Rect, app: &App) {
    let shortcuts = if app.run_view.is_some() {
        "[Enter] Session  [Tab] Status/Brief/Report/Terminal  [↑↓/PgUp/PgDn] Scroll  [G] PR  [O] Open PR  [B] Back  [Esc] Quit"
    } else if app.activity.is_some() {
        "[↑↓/PgUp/PgDn] Scroll  [R] Refresh  [B] Back  [1-4,0] Pages  [Esc] Quit"
    } else if let Some(settings) = &app.agent_settings {
        if settings.agent_runs.is_some() {
            "[Up/Down] Select  [Enter] Session  [D] Details  [B] Back  [1-4,0] Pages  [Esc] Quit"
        } else if settings.editing {
            "[Enter] Save field  [Shift+Enter] New line  [Esc] Stop editing"
        } else {
            match settings.focus {
                AgentSettingsFocus::Sidebar => {
                    "[Up/Down] Navigate  [Enter] Open  [1-4,0] Pages  [Esc] Quit"
                }
                AgentSettingsFocus::Home => "[B] Back  [1-4,0] Pages  [Esc] Quit",
                AgentSettingsFocus::Agents => {
                    "[Enter] Edit  [R] Runs  [A] Add agent  [X] Delete agent  [↑↓] Select  [B] Back  [Esc] Quit"
                }
                AgentSettingsFocus::AgentMode
                | AgentSettingsFocus::AgentHarness
                | AgentSettingsFocus::AgentEffort => {
                    "[Arrows] Select  [Tab] Next field  [B] Back  [1-4,0] Pages  [Esc] Quit"
                }
                _ => "[Enter] Edit  [Tab] Next field  [B] Back  [1-4,0] Pages  [Esc] Quit",
            }
        }
    } else if app.plan.is_some() {
        "[Up/Down] Scroll  [PgUp/PgDn] Page  [B] Ticket  [1-4,0] Pages  [Esc] Quit"
    } else if let Some(review) = &app.github_review {
        match review.focus {
            GitHubReviewFocus::Description => {
                "[Tab] Runs  [Up/Down] Scroll  [T] Ticket  [O] Open  [B] Back  [1-4,0] Pages  [Esc] Quit"
            }
            GitHubReviewFocus::Reviews => {
                "[Tab] Comments  [↑↓] Select run  [Enter] Session  [D] Details  [T] Ticket  [O] Open  [B] Back  [Esc] Quit"
            }
            GitHubReviewFocus::Comments => {
                "[↑↓] Select  [Enter] Fold  [Space] Mark  [PgUp/Dn] Page  [R] Resolved  [Tab] Panel  [B] Back"
            }
        }
    } else if (app.active_tab == 0 || app.active_tab == 1) && app.jira_detail.is_some() {
        match app.jira_detail_focus {
            JiraDetailFocus::Ticket => {
                "[Tab] Runs  [Up/Down] Scroll  [B] Back  [1-4,0] Pages  [Esc] Quit"
            }
            JiraDetailFocus::Runs => {
                "[Tab] Plans  [Up/Down] Select run  [Enter] Session  [D] Details  [B] Back  [1-4,0] Pages  [Esc] Quit"
            }
            JiraDetailFocus::Plans => {
                "[Tab] Ticket  [Up/Down] Select plan  [Enter] Open  [B] Back  [1-4,0] Pages  [Esc] Quit"
            }
        }
    } else if app.active_tab == 1 {
        "[Up/Down] Select  [PgUp/PgDn] Page  [Enter/D] Details  [R] Refresh  [1-4,0] Pages  [Esc] Quit"
    } else if app.active_tab == 0 {
        match app.overview_section {
            OverviewSection::Crew => {
                "[1] Crew [2] Jira [3] GitHub [4] Other [0] Settings [↑↓] [Enter] Session [D] Details [A] Activity [O] PR [R] [Esc] Quit"
            }
            OverviewSection::Jira => {
                "[1] Crew [2] Jira [3] GitHub [4] Other [0] Settings [PgUp/PgDn] [↑↓] [Enter] Details [R] [Esc] Quit"
            }
            OverviewSection::GitHubMe | OverviewSection::GitHubOther => {
                "[1] Crew [2] Jira [3] GitHub [4] Other [0] Settings [PgUp/PgDn] [↑↓] [Enter/G] Open [O] Web [R] [Esc] Quit"
            }
        }
    } else if app.active_tab == 2 {
        "[Up/Down] Select  [Tab] Section  [Enter] Open  [O] Web  [R] Refresh  [1-4,0] Pages  [Esc] Quit"
    } else {
        "[1-4,0] Pages  [Esc] Quit"
    };

    frame.render_widget(
        Paragraph::new(shortcuts)
            .style(Style::default().fg(MUTED_TEXT))
            .alignment(Alignment::Left),
        area,
    );
}

fn render_empty_page(frame: &mut Frame, area: Rect, title: &str) {
    frame.render_widget(
        Paragraph::new(vec![
            Line::styled(
                title,
                Style::default().fg(TEXT).add_modifier(Modifier::BOLD),
            ),
            Line::raw(""),
            Line::styled("Nothing here yet.", Style::default().fg(MUTED_TEXT)),
        ])
        .block(card(" Workspace ", CORAL))
        .alignment(Alignment::Center),
        area,
    );
}

fn card<'a>(title: &'a str, accent: Color) -> Block<'a> {
    Block::new()
        .title(title)
        .title_style(Style::default().fg(accent).add_modifier(Modifier::BOLD))
        .borders(Borders::NONE)
        .style(Style::default().fg(TEXT).bg(SURFACE))
        .padding(Padding::new(1, 1, 0, 1))
}

fn selection_style(selected: bool) -> Style {
    if selected {
        Style::default().fg(CORAL).add_modifier(Modifier::BOLD)
    } else {
        Style::default().fg(TEXT)
    }
}

fn attention_style(selected: bool, needs_attention: bool) -> Style {
    if selected || needs_attention {
        selection_style(selected)
    } else {
        Style::default().fg(MUTED_TEXT)
    }
}

fn section_heading(title: impl Into<String>) -> Line<'static> {
    Line::styled(format!("● {}", title.into()), Style::default().fg(TEAL))
}

#[cfg(test)]
mod tests;
