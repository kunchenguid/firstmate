//! Opening a crewmate's live agent session.
//!
//! vessel asks firstmate's own backend library where a task runs
//! (`fm_backend_of_meta` and `fm_backend_target_of_meta` in `bin/fm-backend.sh`)
//! and attaches through a throwaway tmux session grouped with firstmate's, so
//! the firstmate session's own current window never moves and the view is gone
//! once its terminal closes. Typing there is the captain's direct intervention,
//! exactly like `tmux attach -t firstmate` (docs/tmux-backend.md).

use std::{
    env,
    path::Path,
    process::Command,
    time::{SystemTime, UNIX_EPOCH},
};

use crate::config::Config;

/// The shell script that attaches to `task`'s session, or why it cannot.
pub(crate) fn attach_script(config: &Config, task: &str) -> Result<String, String> {
    let (backend, target) = endpoint(config, task)?;
    if backend != "tmux" {
        return Err(format!(
            "vessel can only open tmux sessions; {task} runs on {backend}"
        ));
    }
    // tmux resolves both `session:window` and a bare legacy window name, and
    // fails when the window is gone.
    let tmux = tmux_executable();
    let resolved = Command::new(&tmux)
        .args([
            "display-message",
            "-p",
            "-t",
            &target,
            "#{session_name}\t#{window_name}",
        ])
        .output()
        .map_err(|error| format!("Could not run tmux: {error}"))?;
    let resolved = String::from_utf8_lossy(&resolved.stdout);
    let Some((session, window)) = resolved
        .trim_end()
        .split_once('\t')
        .filter(|(session, window)| !session.is_empty() && !window.is_empty())
    else {
        return Err(format!("The session of {task} is gone"));
    };
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.subsec_nanos());
    Ok(script(
        &tmux,
        session,
        window,
        &format!("vessel-{task}-{nonce}"),
    ))
}

/// Creates the grouped view, selects the task's window, then attaches; the
/// view destroys itself when its last client leaves.
pub(crate) fn script(tmux: &str, session: &str, window: &str, view: &str) -> String {
    let tmux = shell_quote(tmux);
    let target = shell_quote(&format!("{view}:={window}"));
    let (session, view) = (shell_quote(session), shell_quote(view));
    format!(
        "{tmux} new-session -d -t {session} -s {view} && \
         {tmux} select-window -t {target} && \
         exec {tmux} attach-session -t {view} \\; set-option -t {view} destroy-unattached on"
    )
}

/// Whether to open sessions in a new Ghostty tab (as Remy does) rather than
/// in vessel's own terminal.
pub(crate) fn use_ghostty() -> bool {
    cfg!(target_os = "macos") && env::var("TERM_PROGRAM").is_ok_and(|name| name == "ghostty")
}

pub(crate) fn open_in_ghostty(script: &str, directory: &Path) -> Result<(), String> {
    let command = format!("/usr/bin/env -u TMUX /bin/sh -c {}", shell_quote(script));
    let output = Command::new("osascript")
        .args(["-e", &ghostty_tab_script(directory, &command)])
        .output()
        .map_err(|error| format!("Could not open a Ghostty tab: {error}"))?;
    if output.status.success() {
        return Ok(());
    }
    let message = String::from_utf8_lossy(&output.stderr).trim().to_owned();
    Err(if message.is_empty() {
        "Could not open a Ghostty tab".into()
    } else {
        format!("Could not open a Ghostty tab: {message}")
    })
}

fn endpoint(config: &Config, task: &str) -> Result<(String, String), String> {
    let meta = config.state_dir().join(format!("{task}.meta"));
    if !meta.is_file() {
        return Err(format!("{task} has no live session"));
    }
    let output = Command::new("bash")
        .args([
            "-c",
            r#". "$1/bin/fm-backend.sh" && fm_backend_of_meta "$2" && printf '\n' && fm_backend_target_of_meta "$2""#,
            "vessel",
        ])
        .arg(&config.fm_root)
        .arg(&meta)
        .output()
        .map_err(|error| format!("Could not read the session of {task}: {error}"))?;
    let text = String::from_utf8_lossy(&output.stdout);
    let mut lines = text.lines();
    match (output.status.success(), lines.next(), lines.next()) {
        (true, Some(backend), Some(target)) if !backend.is_empty() && !target.is_empty() => {
            Ok((backend.to_owned(), target.to_owned()))
        }
        _ => Err(format!("Could not find the session of {task}")),
    }
}

/// Ghostty launches commands without the login shell's PATH, so name tmux fully.
fn tmux_executable() -> String {
    env::var_os("PATH")
        .and_then(|paths| {
            env::split_paths(&paths)
                .map(|directory| directory.join("tmux"))
                .find(|path| path.is_file())
        })
        .map_or_else(|| "tmux".into(), |path| path.to_string_lossy().into_owned())
}

fn ghostty_tab_script(directory: &Path, command: &str) -> String {
    format!(
        "tell application \"Ghostty\"\n\
         set configuration to new surface configuration\n\
         set initial working directory of configuration to {}\n\
         set command of configuration to {}\n\
         activate\n\
         if (count of windows) = 0 then\n\
             new window with configuration configuration\n\
         else\n\
             new tab in front window with configuration configuration\n\
         end if\n\
         end tell",
        applescript_quote(&directory.to_string_lossy()),
        applescript_quote(command),
    )
}

fn applescript_quote(value: &str) -> String {
    let mut escaped = String::from("\"");
    for character in value.chars() {
        match character {
            '\\' => escaped.push_str("\\\\"),
            '"' => escaped.push_str("\\\""),
            '\n' => escaped.push_str("\\n"),
            '\r' => escaped.push_str("\\r"),
            '\t' => escaped.push_str("\\t"),
            _ => escaped.push(character),
        }
    }
    escaped.push('"');
    escaped
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn script_attaches_through_a_grouped_view_on_the_task_window() {
        let script = script(
            "/opt/homebrew/bin/tmux",
            "firstmate",
            "fm-review-webapp-42",
            "vessel-review-webapp-42-1",
        );
        assert_eq!(
            script,
            "'/opt/homebrew/bin/tmux' new-session -d -t 'firstmate' -s 'vessel-review-webapp-42-1' && \
             '/opt/homebrew/bin/tmux' select-window -t 'vessel-review-webapp-42-1:=fm-review-webapp-42' && \
             exec '/opt/homebrew/bin/tmux' attach-session -t 'vessel-review-webapp-42-1' \\; \
             set-option -t 'vessel-review-webapp-42-1' destroy-unattached on"
        );
    }

    #[test]
    fn ghostty_command_is_quoted_for_applescript() {
        let script = ghostty_tab_script(Path::new("/home"), "sh -c 'a \"b\"'");
        assert!(script.contains(r#"set command of configuration to "sh -c 'a \"b\"'""#));
    }

    #[test]
    fn resolves_the_endpoint_through_firstmate() {
        let home = std::env::temp_dir().join(format!("vessel-session-{}", std::process::id()));
        std::fs::create_dir_all(home.join("state")).unwrap();
        std::fs::write(
            home.join("state/review-webapp-42.meta"),
            "window=firstmate:fm-review-webapp-42\nkind=scout\n",
        )
        .unwrap();
        let config = Config {
            fm_home: home.clone(),
            fm_root: Path::new(env!("CARGO_MANIFEST_DIR"))
                .parent()
                .unwrap()
                .to_path_buf(),
            ..Config::default()
        };
        assert_eq!(
            endpoint(&config, "review-webapp-42").unwrap(),
            ("tmux".into(), "firstmate:fm-review-webapp-42".into())
        );
        assert!(endpoint(&config, "missing").is_err());
        std::fs::remove_dir_all(home).ok();
    }
}
