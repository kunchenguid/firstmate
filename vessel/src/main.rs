//! vessel: a Remy-style, read-only view of a firstmate fleet, plus Jira and GitHub.

use std::{io, path::PathBuf, time::Duration};

use crossterm::{
    event::{self, DisableMouseCapture, EnableMouseCapture, Event, MouseEventKind},
    execute,
    terminal::{EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode},
};
use ratatui::{Terminal, backend::CrosstermBackend};

mod agents;
mod app;
mod config;
mod context;
mod firstmate;
mod github;
mod input;
mod jira;
mod radar;
mod ui;

use app::{App, GitHubReviewFocus};

const USAGE: &str = "usage: vessel [--home <firstmate-home>]
       vessel radar check|arm|disarm|ack [--home <firstmate-home>]

A read-only view of what firstmate is doing, with Jira and GitHub alongside.
The firstmate home is --home, $VESSEL_FM_HOME, $FM_HOME, or the nearest
firstmate checkout above the current directory.

vessel radar monitors GitHub and Jira for events that need attention.
Run `vessel radar arm` once to keep firstmate monitoring all day.";

fn main() -> io::Result<()> {
    let all_args: Vec<String> = std::env::args().skip(1).collect();

    if all_args.first().map(String::as_str) == Some("radar") {
        return radar::run(&all_args[1..]);
    }

    let mut explicit_home = None;
    let mut arguments = all_args.into_iter();
    while let Some(argument) = arguments.next() {
        match argument.as_str() {
            "--home" => explicit_home = arguments.next().map(PathBuf::from),
            "-h" | "--help" => {
                println!("{USAGE}");
                return Ok(());
            }
            other => {
                eprintln!("vessel: unknown argument {other}\n\n{USAGE}");
                std::process::exit(2);
            }
        }
    }
    let config = match config::resolve_fm_home(explicit_home).and_then(config::load_config) {
        Ok(config) => config,
        Err(message) => {
            eprintln!("vessel: {message}");
            std::process::exit(1);
        }
    };

    let app = App::load(config);
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen, EnableMouseCapture)?;
    let mut terminal = Terminal::new(CrosstermBackend::new(stdout))?;
    let result = run(&mut terminal, app);

    disable_raw_mode()?;
    execute!(
        terminal.backend_mut(),
        LeaveAlternateScreen,
        DisableMouseCapture
    )?;
    terminal.show_cursor()?;
    result
}

/// Opens a run's live agent session: in a new Ghostty tab when vessel runs in
/// Ghostty (as Remy does), else in this terminal until the captain detaches.
/// When the session cannot be opened, the run view explains what is there.
fn open_session(
    terminal: &mut Terminal<CrosstermBackend<io::Stdout>>,
    app: &mut App,
    task: String,
    created_at: Option<u64>,
) -> io::Result<()> {
    let opened = firstmate::session::attach_script(&app.config, &task).and_then(|script| {
        if firstmate::session::use_ghostty() {
            return firstmate::session::open_in_ghostty(&script, &app.config.fm_home);
        }
        disable_raw_mode()
            .and_then(|()| execute!(io::stdout(), LeaveAlternateScreen, DisableMouseCapture))
            .map_err(|error| format!("Could not hand the terminal to tmux: {error}"))?;
        // Inside tmux this attach is nested, so the prefix must reach the inner tmux.
        let detach = if std::env::var_os("TMUX").is_some() {
            "your tmux prefix twice, then d"
        } else {
            "your tmux prefix, then d"
        };
        println!("Attaching to {task}. Detach with {detach} to return to vessel.");
        let status = std::process::Command::new("/bin/sh")
            .args(["-c", &script])
            .env_remove("TMUX")
            .status();
        enable_raw_mode()
            .and_then(|()| execute!(io::stdout(), EnterAlternateScreen, EnableMouseCapture))
            .and_then(|()| terminal.clear())
            .map_err(|error| format!("Could not restore vessel's screen: {error}"))?;
        match status {
            Ok(status) if status.success() => Ok(()),
            Ok(_) => Err(format!("tmux could not attach to {task}")),
            Err(error) => Err(format!("Could not run tmux: {error}")),
        }
    });
    if let Err(message) = opened {
        app.notice = Some(message);
        app.open_run(task, created_at);
    }
    Ok(())
}

fn run(terminal: &mut Terminal<CrosstermBackend<io::Stdout>>, mut app: App) -> io::Result<()> {
    loop {
        app.update();
        terminal.draw(|frame| ui::render(frame, &app))?;

        if event::poll(Duration::from_millis(100))? {
            match event::read()? {
                Event::Key(key) => {
                    if input::handle_key(terminal, &mut app, key)? {
                        app.publish_context_on_exit();
                        return Ok(());
                    }
                    if let Some((task, created_at)) = app.session_request.take() {
                        open_session(terminal, &mut app, task, created_at)?;
                    }
                }
                Event::Resize(width, height)
                    if app
                        .github_review
                        .as_ref()
                        .is_some_and(|review| review.focus == GitHubReviewFocus::Comments) =>
                {
                    let (ranges, height) = ui::github_comments_navigation(
                        &app,
                        ratatui::layout::Rect::new(0, 0, width, height),
                    );
                    app.reveal_github_comment(&ranges, height);
                }
                Event::Mouse(mouse) => match mouse.kind {
                    MouseEventKind::ScrollUp => {
                        input::handle_mouse_scroll(&mut app, -3, terminal.get_frame().area())
                    }
                    MouseEventKind::ScrollDown => {
                        input::handle_mouse_scroll(&mut app, 3, terminal.get_frame().area())
                    }
                    _ => {}
                },
                _ => {}
            }
        }
    }
}
