//! Keyboard handling. vessel only navigates and edits its own agents: no key
//! starts, steers, stops, merges, or moves anything.
//!
//! Remy's action letters are deliberately left unbound so future hotkeys can
//! reuse them: Jira `I`/`P`/`N`, PR `N`/`F`/`C`/`A`/`U`, plan `I`. Those
//! hotkeys will send a `[vessel]` request through `bin/fm-inbox.sh` (see
//! `vessel/docs/requests.md`) rather than launching anything themselves.

use std::io;

use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use ratatui::{Terminal, backend::Backend};

use crate::{app::*, ui::github_comments_navigation};

pub(super) fn handle_mouse_scroll(app: &mut App, delta: isize, area: ratatui::layout::Rect) {
    if app.run_view.is_some() {
        app.scroll_run_view(delta.clamp(-100, 100) as i16);
    } else if app.activity.is_some() {
        app.scroll_activity(delta.clamp(-100, 100) as i16);
    } else if app
        .github_review
        .as_ref()
        .is_some_and(|review| review.focus == GitHubReviewFocus::Comments)
    {
        let (ranges, height) = github_comments_navigation(app, area);
        app.scroll_github_comments(
            delta.clamp(i32::MIN as isize, i32::MAX as isize) as i32,
            &ranges,
            height,
        );
    } else if app.active_tab == 0 && app.jira_detail.is_none() {
        app.scroll_overview(delta);
    }
}

/// Returns `Ok(true)` when vessel should exit.
pub(super) fn handle_key<B: Backend>(
    terminal: &mut Terminal<B>,
    app: &mut App,
    key: KeyEvent,
) -> io::Result<bool>
where
    B::Error: Into<io::Error>,
{
    if key.kind != KeyEventKind::Press {
        return Ok(false);
    }
    if !is_text_editing(app) {
        if key.code == KeyCode::Esc || key.code == KeyCode::Char('q') {
            return Ok(true);
        }
        if key.code == KeyCode::Char('0') {
            app.select_tab(3);
            return Ok(false);
        }
        if let Some(section) = overview_section_key(key.code) {
            app.select_overview_section(section);
            return Ok(false);
        }
        if matches!(key.code, KeyCode::Char('b' | 'B')) {
            go_back(app);
            return Ok(false);
        }
        if key.code == KeyCode::Char('o') {
            if let Some(url) = selected_url(app) {
                open_url(app, &url);
            }
            return Ok(false);
        }
    }

    if app.run_view.is_some() {
        match key.code {
            KeyCode::Tab => app.toggle_run_view_focus(1),
            KeyCode::BackTab => app.toggle_run_view_focus(-1),
            KeyCode::Char('g' | 'G') => app.open_run_pull_request(),
            KeyCode::Enter => app.open_viewed_run_session(),
            code if scroll_delta(code).is_some() => {
                app.scroll_run_view(scroll_delta(code).unwrap())
            }
            _ => {}
        }
        return Ok(false);
    }

    if app.activity.is_some() {
        if let Some(delta) = scroll_delta(key.code) {
            app.scroll_activity(delta);
        } else if matches!(key.code, KeyCode::Char('r' | 'R')) {
            app.fleet.request_refresh();
        }
        return Ok(false);
    }

    if app.agent_settings.is_some() {
        handle_settings_key(app, key);
        return Ok(false);
    }

    if app.plan.is_some() {
        if let Some(delta) = scroll_delta(key.code) {
            app.scroll_plan(delta);
        }
        return Ok(false);
    }

    if app.github_review.is_some() {
        let focus = app.github_review.as_ref().unwrap().focus;
        match key.code {
            KeyCode::Char('t' | 'T') => app.open_github_ticket(),
            KeyCode::Char('r' | 'R') if focus == GitHubReviewFocus::Comments => {
                app.toggle_github_resolved()
            }
            KeyCode::Tab | KeyCode::BackTab => app.toggle_github_review_focus(),
            KeyCode::Up if focus == GitHubReviewFocus::Description => {
                app.scroll_github_description(-1)
            }
            KeyCode::Down if focus == GitHubReviewFocus::Description => {
                app.scroll_github_description(1)
            }
            code if focus == GitHubReviewFocus::Comments
                && matches!(
                    code,
                    KeyCode::Up
                        | KeyCode::Down
                        | KeyCode::PageUp
                        | KeyCode::PageDown
                        | KeyCode::Home
                        | KeyCode::End
                        | KeyCode::Enter
                        | KeyCode::Char(' ')
                ) =>
            {
                let size = terminal.size().map_err(Into::into)?;
                handle_github_comments_key(
                    app,
                    code,
                    ratatui::layout::Rect::new(0, 0, size.width, size.height),
                );
            }
            KeyCode::Up => app.move_review_selection(-1),
            KeyCode::Down => app.move_review_selection(1),
            KeyCode::Enter if focus == GitHubReviewFocus::Reviews => {
                app.open_selected_review_run(false)
            }
            KeyCode::Char('d' | 'D') if focus == GitHubReviewFocus::Reviews => {
                app.open_selected_review_run(true)
            }
            _ => {}
        }
        return Ok(false);
    }

    let jira_detail_active =
        (app.active_tab == 0 || app.active_tab == 1) && app.jira_detail.is_some();
    let overview_jira_active = app.active_tab == 0
        && app.jira_detail.is_none()
        && app.overview_section == OverviewSection::Jira;
    let jira_page_active =
        (app.active_tab == 1 || overview_jira_active) && app.jira_detail.is_none();

    if app.active_tab == 0 && app.jira_detail.is_none() {
        if matches!(key.code, KeyCode::PageUp | KeyCode::PageDown)
            && app.overview_section != OverviewSection::Crew
        {
            app.scroll_overview(if key.code == KeyCode::PageUp { -5 } else { 5 });
            return Ok(false);
        }
        if matches!(key.code, KeyCode::Tab | KeyCode::BackTab) {
            app.move_overview_section(if key.code == KeyCode::Tab { 1 } else { -1 });
            return Ok(false);
        }
        if matches!(key.code, KeyCode::Char('a' | 'A')) {
            app.open_activity();
            return Ok(false);
        }
        if matches!(key.code, KeyCode::Char('r' | 'R') | KeyCode::F(5)) {
            app.refresh_all();
            return Ok(false);
        }
        match app.overview_section {
            OverviewSection::Crew => match key.code {
                KeyCode::Up | KeyCode::Char('k') => app.move_overview_selection(-1),
                KeyCode::Down | KeyCode::Char('j') => app.move_overview_selection(1),
                KeyCode::PageUp => app.move_overview_selection(-5),
                KeyCode::PageDown => app.move_overview_selection(5),
                KeyCode::Enter => app.open_selected_overview_run(false),
                KeyCode::Char('d' | 'D') => app.open_selected_overview_run(true),
                _ => {}
            },
            OverviewSection::GitHubMe | OverviewSection::GitHubOther => match key.code {
                KeyCode::Up | KeyCode::Char('k') => app.move_github_selection(-1),
                KeyCode::Down | KeyCode::Char('j') => app.move_github_selection(1),
                KeyCode::PageUp => app.move_github_selection(-5),
                KeyCode::PageDown => app.move_github_selection(5),
                KeyCode::Enter | KeyCode::Char('g' | 'G') => app.open_github_review(),
                _ => {}
            },
            OverviewSection::Jira => {}
        }
    }

    let jira_page_height = jira_viewport_height(terminal.size().map_err(Into::into)?.height);
    match key.code {
        KeyCode::Char('d' | 'D') if jira_page_active => app.open_selected_jira_detail(),
        KeyCode::Enter if jira_page_active => app.open_selected_jira_detail(),
        KeyCode::Tab | KeyCode::BackTab if jira_detail_active => app.toggle_jira_detail_focus(),
        KeyCode::Up if jira_detail_active && app.jira_detail_focus == JiraDetailFocus::Plans => {
            app.move_jira_plan_selection(-1)
        }
        KeyCode::Down if jira_detail_active && app.jira_detail_focus == JiraDetailFocus::Plans => {
            app.move_jira_plan_selection(1)
        }
        KeyCode::Up if jira_detail_active && app.jira_detail_focus == JiraDetailFocus::Runs => {
            app.move_jira_run_selection(-1)
        }
        KeyCode::Down if jira_detail_active && app.jira_detail_focus == JiraDetailFocus::Runs => {
            app.move_jira_run_selection(1)
        }
        KeyCode::Enter if jira_detail_active && app.jira_detail_focus == JiraDetailFocus::Plans => {
            app.open_selected_jira_plan()
        }
        KeyCode::Enter if jira_detail_active && app.jira_detail_focus == JiraDetailFocus::Runs => {
            app.open_selected_jira_run(false)
        }
        KeyCode::Char('d' | 'D')
            if jira_detail_active && app.jira_detail_focus == JiraDetailFocus::Runs =>
        {
            app.open_selected_jira_run(true)
        }
        KeyCode::Up if jira_detail_active => {
            app.jira_detail_scroll = app.jira_detail_scroll.saturating_sub(1)
        }
        KeyCode::Down if jira_detail_active => {
            app.jira_detail_scroll = app.jira_detail_scroll.saturating_add(1)
        }
        KeyCode::PageUp if app.active_tab == 1 && jira_page_active => {
            app.scroll_jira(-(jira_page_height as isize), jira_page_height)
        }
        KeyCode::PageDown if app.active_tab == 1 && jira_page_active => {
            app.scroll_jira(jira_page_height as isize, jira_page_height)
        }
        KeyCode::Right if jira_page_active => {
            app.move_jira_selection(JiraDirection::Right, jira_page_height)
        }
        KeyCode::Left if jira_page_active => {
            app.move_jira_selection(JiraDirection::Left, jira_page_height)
        }
        KeyCode::Up | KeyCode::Char('k') if jira_page_active => {
            app.move_jira_selection(JiraDirection::Up, jira_page_height)
        }
        KeyCode::Down | KeyCode::Char('j') if jira_page_active => {
            app.move_jira_selection(JiraDirection::Down, jira_page_height)
        }
        KeyCode::Char('r' | 'R') if app.active_tab == 1 => app.reload_jira(),
        KeyCode::Up | KeyCode::Char('k') if app.active_tab == 2 => app.move_github_selection(-1),
        KeyCode::Down | KeyCode::Char('j') if app.active_tab == 2 => app.move_github_selection(1),
        KeyCode::Tab | KeyCode::BackTab if app.active_tab == 2 => app.toggle_github_section(),
        KeyCode::Enter if app.active_tab == 2 => app.open_github_review(),
        KeyCode::Char('r' | 'R') | KeyCode::F(5) if app.active_tab == 2 => {
            app.reload_github();
            app.reload_github_others();
        }
        _ => {}
    }
    Ok(false)
}

fn handle_settings_key(app: &mut App, key: KeyEvent) {
    let Some(settings) = &app.agent_settings else {
        return;
    };
    let focus = settings.focus;
    if settings.agent_runs.is_some() {
        match key.code {
            KeyCode::Up => app.move_agent_selection(-1),
            KeyCode::Down => app.move_agent_selection(1),
            KeyCode::Enter => app.open_selected_agent_run(false),
            KeyCode::Char('d' | 'D') => app.open_selected_agent_run(true),
            _ => {}
        }
        return;
    }
    if settings.editing {
        let shift = key.modifiers.contains(KeyModifiers::SHIFT);
        match key.code {
            KeyCode::Esc => app.cancel_agent_settings_edit(),
            KeyCode::Char('a') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                app.select_all_agent_text()
            }
            KeyCode::Left => app.move_agent_cursor(-1, shift),
            KeyCode::Right => app.move_agent_cursor(1, shift),
            KeyCode::Home => app.move_agent_cursor(isize::MIN, shift),
            KeyCode::End => app.move_agent_cursor(isize::MAX, shift),
            KeyCode::Delete => app.delete_agent_text(),
            KeyCode::Enter if focus == AgentSettingsFocus::AgentInstructions && shift => {
                app.edit_agent_text('\n')
            }
            KeyCode::Enter => app.commit_agent_settings_edit(),
            KeyCode::Backspace => app.backspace_agent_text(),
            KeyCode::Char(character) => {
                app.edit_agent_text(shifted_text_character(character, key.modifiers))
            }
            _ => {}
        }
        return;
    }
    let option_field = matches!(
        focus,
        AgentSettingsFocus::AgentMode
            | AgentSettingsFocus::AgentHarness
            | AgentSettingsFocus::AgentEffort
    );
    let text_field = matches!(
        focus,
        AgentSettingsFocus::AgentName
            | AgentSettingsFocus::AgentModel
            | AgentSettingsFocus::AgentInstructions
    );
    match (focus, key.code) {
        (AgentSettingsFocus::Sidebar, KeyCode::Up | KeyCode::Left) => app.move_settings_sidebar(-1),
        (AgentSettingsFocus::Sidebar, KeyCode::Down | KeyCode::Right) => {
            app.move_settings_sidebar(1)
        }
        (AgentSettingsFocus::Sidebar, KeyCode::Enter) => app.open_selected_settings_section(),
        (AgentSettingsFocus::Agents, KeyCode::Up) => app.move_agent_selection(-1),
        (AgentSettingsFocus::Agents, KeyCode::Down) => app.move_agent_selection(1),
        (AgentSettingsFocus::Agents, KeyCode::Enter) => app.open_selected_agent(),
        (AgentSettingsFocus::Agents, KeyCode::Char('a' | 'A')) => app.add_agent(),
        (AgentSettingsFocus::Agents, KeyCode::Char('x' | 'X')) => app.delete_agent(),
        (AgentSettingsFocus::Agents, KeyCode::Char('r' | 'R')) => app.open_selected_agent_runs(),
        (_, KeyCode::Tab | KeyCode::BackTab) if option_field || text_field => {
            app.toggle_agent_settings_focus()
        }
        (_, KeyCode::Left | KeyCode::Up) if option_field => app.move_agent_option(-1),
        (_, KeyCode::Right | KeyCode::Down) if option_field => app.move_agent_option(1),
        (_, KeyCode::Enter) if text_field => app.start_agent_settings_edit(),
        _ => {}
    }
}

pub(super) fn is_text_editing(app: &App) -> bool {
    app.agent_settings
        .as_ref()
        .is_some_and(|settings| settings.editing)
}

pub(super) fn go_back(app: &mut App) {
    if app.run_view.is_some() {
        app.close_run();
    } else if app.plan.is_some() {
        app.close_plan();
    } else if app.activity.is_some() {
        app.close_activity();
    } else if app
        .agent_settings
        .as_ref()
        .is_some_and(|settings| settings.agent_runs.is_some())
    {
        app.close_agent_runs();
    } else if app.agent_settings.as_ref().is_some_and(|settings| {
        !matches!(
            settings.focus,
            AgentSettingsFocus::Sidebar | AgentSettingsFocus::Agents | AgentSettingsFocus::Home
        )
    }) {
        app.back_to_agent_selector();
    } else if app.agent_settings.is_some() {
        app.back_to_settings_sidebar();
    } else if app.github_review.is_some() {
        app.close_github_review();
    } else if (app.active_tab == 0 || app.active_tab == 1) && app.jira_detail.is_some() {
        app.close_jira_detail();
    }
}

pub(super) fn overview_section_key(code: KeyCode) -> Option<OverviewSection> {
    match code {
        KeyCode::Char('1') => Some(OverviewSection::Crew),
        KeyCode::Char('2') => Some(OverviewSection::Jira),
        KeyCode::Char('3') => Some(OverviewSection::GitHubMe),
        KeyCode::Char('4') => Some(OverviewSection::GitHubOther),
        _ => None,
    }
}

pub(super) fn scroll_delta(code: KeyCode) -> Option<i16> {
    match code {
        KeyCode::Up | KeyCode::Char('k') => Some(-1),
        KeyCode::Down | KeyCode::Char('j') => Some(1),
        KeyCode::PageUp => Some(-10),
        KeyCode::PageDown => Some(10),
        _ => None,
    }
}

/// The URL `o` opens for whatever is selected.
fn selected_url(app: &App) -> Option<String> {
    if let Some(run) = app.viewed_run() {
        return run.pr_url.clone();
    }
    if let Some(review) = &app.github_review {
        return Some(review.url.clone());
    }
    let on_github = app.active_tab == 2
        || (app.active_tab == 0
            && matches!(
                app.overview_section,
                OverviewSection::GitHubMe | OverviewSection::GitHubOther
            ));
    if on_github {
        return app.selected_pull_request_url();
    }
    if app.active_tab == 0 && app.overview_section == OverviewSection::Crew {
        return app
            .crew_runs()
            .get(app.overview_selected)
            .and_then(|run| run.pr_url.clone());
    }
    None
}

fn open_url(app: &mut App, url: &str) {
    let opener = if cfg!(target_os = "macos") {
        "open"
    } else {
        "xdg-open"
    };
    if let Err(error) = std::process::Command::new(opener)
        .arg(url)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
    {
        app.notice = Some(format!("Could not open {url}: {error}"));
    }
}

pub(super) fn shifted_text_character(character: char, modifiers: KeyModifiers) -> char {
    if !modifiers.contains(KeyModifiers::SHIFT) {
        return character;
    }
    match character {
        'a'..='z' => character.to_ascii_uppercase(),
        '`' => '~',
        '1' => '!',
        '2' => '@',
        '3' => '#',
        '4' => '$',
        '5' => '%',
        '6' => '^',
        '7' => '&',
        '8' => '*',
        '9' => '(',
        '0' => ')',
        '-' => '_',
        '=' => '+',
        '[' => '{',
        ']' => '}',
        '\\' => '|',
        ';' => ':',
        '\'' => '"',
        ',' => '<',
        '.' => '>',
        '/' => '?',
        _ => character,
    }
}

pub(super) fn handle_github_comments_key(
    app: &mut App,
    code: KeyCode,
    area: ratatui::layout::Rect,
) {
    if code == KeyCode::Char(' ') {
        app.toggle_selected_github_feedback();
        return;
    }
    if code == KeyCode::Enter {
        app.toggle_github_feedback_expanded();
    }
    let (ranges, height) = github_comments_navigation(app, area);
    match code {
        KeyCode::Up => app.move_github_comment_selection(-1, &ranges, height),
        KeyCode::Down => app.move_github_comment_selection(1, &ranges, height),
        KeyCode::PageUp => app.scroll_github_comments(-i32::from(height.max(1)), &ranges, height),
        KeyCode::PageDown => app.scroll_github_comments(i32::from(height.max(1)), &ranges, height),
        KeyCode::Home => app.scroll_github_comments(-i32::from(u16::MAX), &ranges, height),
        KeyCode::End => {
            app.scroll_github_comments(i32::from(u16::MAX), &ranges, height);
            if let Some(review) = &mut app.github_review {
                review.comment_selected = ranges.len().saturating_sub(1);
            }
        }
        KeyCode::Enter => app.reveal_github_comment(&ranges, height),
        _ => {}
    }
}
