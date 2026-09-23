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
mod firstmate;
mod github;
mod input;
mod jira;
mod ui;

use app::{App, GitHubReviewFocus};

const USAGE: &str = "usage: vessel [--home <firstmate-home>]

A read-only view of what firstmate is doing, with Jira and GitHub alongside.
The firstmate home is --home, $VESSEL_FM_HOME, $FM_HOME, or the nearest
firstmate checkout above the current directory.";

fn main() -> io::Result<()> {
    let mut explicit_home = None;
    let mut arguments = std::env::args().skip(1);
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

fn run(terminal: &mut Terminal<CrosstermBackend<io::Stdout>>, mut app: App) -> io::Result<()> {
    loop {
        app.update();
        terminal.draw(|frame| ui::render(frame, &app))?;

        if event::poll(Duration::from_millis(100))? {
            match event::read()? {
                Event::Key(key) => {
                    if input::handle_key(terminal, &mut app, key)? {
                        return Ok(());
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
