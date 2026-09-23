use std::path::{Path, PathBuf};

use super::*;

fn temp_dir(name: &str) -> PathBuf {
    let path = std::env::temp_dir().join(format!("vessel-app-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&path);
    path
}

fn app_with_store(directory: &Path) -> App {
    let defaults = Path::new(env!("CARGO_MANIFEST_DIR")).join("defaults");
    let store = AgentStore::at(directory.to_path_buf(), defaults);
    let agents = store.load().unwrap();
    App {
        agent_store: Some(store),
        agents,
        harnesses: vec!["claude".into(), "codex".into(), "pi".into()],
        ..App::default()
    }
}

fn open_first_agent(app: &mut App) {
    app.select_tab(3);
    app.open_selected_settings_section();
    app.open_selected_agent();
}

#[test]
fn editing_an_agent_saves_it_for_firstmate() {
    let directory = temp_dir("edit");
    let mut app = app_with_store(&directory);
    open_first_agent(&mut app);

    // Name -> Mode -> Harness -> Model
    for _ in 0..3 {
        app.toggle_agent_settings_focus();
    }
    app.start_agent_settings_edit();
    app.select_all_agent_text();
    for character in "claude-opus-5".chars() {
        app.edit_agent_text(character);
    }
    app.commit_agent_settings_edit();

    let saved = std::fs::read_to_string(directory.join("agents.json")).unwrap();
    assert!(saved.contains("\"model\": \"claude-opus-5\""), "{saved}");
    assert_eq!(app.agents[0].model, "claude-opus-5");
    std::fs::remove_dir_all(directory).ok();
}

#[test]
fn invalid_agent_lists_are_not_saved() {
    let directory = temp_dir("invalid");
    let mut app = app_with_store(&directory);
    open_first_agent(&mut app);
    let before = std::fs::read_to_string(directory.join("agents.json")).unwrap();

    app.start_agent_settings_edit();
    app.select_all_agent_text();
    app.edit_agent_text('S');
    app.backspace_agent_text();
    app.commit_agent_settings_edit();
    assert_eq!(
        app.agent_settings.as_ref().unwrap().notice.as_deref(),
        Some("Agent names cannot be empty")
    );

    app.start_agent_settings_edit();
    for character in "Stringer".chars() {
        app.edit_agent_text(character);
    }
    app.commit_agent_settings_edit();
    assert_eq!(
        app.agent_settings.as_ref().unwrap().notice.as_deref(),
        Some("Two agents are named Stringer")
    );
    assert_eq!(
        std::fs::read_to_string(directory.join("agents.json")).unwrap(),
        before
    );
    std::fs::remove_dir_all(directory).ok();
}

#[test]
fn harness_and_mode_pickers_cycle_known_values() {
    let directory = temp_dir("pickers");
    let mut app = app_with_store(&directory);
    open_first_agent(&mut app);

    app.toggle_agent_settings_focus(); // Mode
    app.move_agent_option(1);
    assert_eq!(app.agents[0].mode, "Address");
    app.toggle_agent_settings_focus(); // Harness
    app.move_agent_option(-1);
    assert_eq!(app.agents[0].harness, "codex");
    std::fs::remove_dir_all(directory).ok();
}

#[test]
fn browsing_writes_nothing() {
    let directory = temp_dir("browse");
    let mut app = app_with_store(&directory);
    let modified = std::fs::metadata(directory.join("agents.json"))
        .unwrap()
        .modified()
        .unwrap();

    open_first_agent(&mut app);
    for _ in 0..6 {
        app.toggle_agent_settings_focus();
    }
    app.select_tab(0);
    app.open_activity();

    assert_eq!(
        std::fs::metadata(directory.join("agents.json"))
            .unwrap()
            .modified()
            .unwrap(),
        modified
    );
    std::fs::remove_dir_all(directory).ok();
}
