//! Locating the firstmate home and reading vessel's own settings.
//!
//! vessel keeps everything it owns under `<fm_home>/config/vessel/`, which is
//! local and gitignored in firstmate. The TUI never writes anywhere else.

use std::{
    collections::BTreeMap,
    env, fs,
    path::{Path, PathBuf},
};

use serde_json::Value;

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct Config {
    /// Operational home: `state/`, `data/`, `config/`.
    pub(crate) fm_home: PathBuf,
    /// firstmate checkout whose `bin/` scripts vessel runs (usually the home itself).
    pub(crate) fm_root: PathBuf,
    pub(crate) jira_jql: Option<String>,
    pub(crate) ticket_projects: Vec<String>,
    pub(crate) feature_projects: BTreeMap<String, String>,
    pub(crate) repo_projects: BTreeMap<String, String>,
    pub(crate) github_enabled: bool,
    pub(crate) jira_enabled: bool,
}

impl Config {
    pub(crate) fn vessel_dir(&self) -> PathBuf {
        self.fm_home.join("config/vessel")
    }

    pub(crate) fn state_dir(&self) -> PathBuf {
        env::var_os("FM_STATE_OVERRIDE")
            .map(PathBuf::from)
            .unwrap_or_else(|| self.fm_home.join("state"))
    }

    pub(crate) fn data_dir(&self) -> PathBuf {
        self.fm_home.join("data")
    }

    pub(crate) fn runs_file(&self) -> PathBuf {
        self.data_dir().join("vessel/runs.jsonl")
    }

    /// What the captain sees in vessel, for firstmate (see `context.rs`).
    pub(crate) fn context_file(&self) -> PathBuf {
        self.data_dir().join("vessel/context.json")
    }

    pub(crate) fn ledger_file(&self) -> PathBuf {
        self.state_dir().join("fleet-ledger.jsonl")
    }

    pub(crate) fn ledger_enabled(&self) -> bool {
        self.fm_home.join("config/fleet-ledger").exists()
    }
}

/// Finds the firstmate home (`--home`, `$VESSEL_FM_HOME`, `$FM_HOME`, or the
/// nearest checkout above the working directory or the binary) and the
/// checkout whose scripts serve it. Returns `(home, root)`.
pub(crate) fn resolve_fm_home(explicit: Option<PathBuf>) -> Result<(PathBuf, PathBuf), String> {
    let candidate = explicit
        .or_else(|| env::var_os("VESSEL_FM_HOME").map(PathBuf::from))
        .or_else(|| env::var_os("FM_HOME").map(PathBuf::from));
    let nearest_checkout = || {
        env::current_dir()
            .ok()
            .into_iter()
            .chain(env::current_exe().ok())
            .find_map(|start| {
                start
                    .ancestors()
                    .find(|path| is_checkout(path))
                    .map(Path::to_path_buf)
            })
    };
    match candidate {
        Some(home) if is_checkout(&home) => Ok((home.clone(), home)),
        // A home without scripts (a fixture or data-only copy) is served by the
        // checkout vessel runs from, exactly like firstmate's FM_HOME override.
        Some(home) if home.join("state").is_dir() => nearest_checkout()
            .map(|root| (home.clone(), root))
            .ok_or_else(|| {
                format!(
                    "{} has no bin/ scripts and vessel is not inside a firstmate checkout",
                    home.display()
                )
            }),
        Some(home) => Err(format!(
            "{} is not a firstmate home (no bin/fm-fleet-snapshot.sh or state/)",
            home.display()
        )),
        None => nearest_checkout()
            .map(|root| (root.clone(), root))
            .ok_or_else(|| {
                "Could not find a firstmate home. Run vessel inside your firstmate checkout, or pass --home <dir>.".into()
            }),
    }
}

/// Writes `path` through a sibling temporary file, so readers never see half a file.
pub(crate) fn write_atomic(path: &Path, contents: &str) -> Result<(), String> {
    let temporary = path.with_extension("tmp");
    fs::write(&temporary, contents)
        .and_then(|()| fs::rename(&temporary, path))
        .map_err(|error| format!("Could not write {}: {error}", path.display()))
}

fn is_checkout(path: &Path) -> bool {
    path.join("bin/fm-fleet-snapshot.sh").is_file()
}

pub(crate) fn load_config((fm_home, fm_root): (PathBuf, PathBuf)) -> Result<Config, String> {
    let mut config = Config {
        fm_home,
        fm_root,
        github_enabled: true,
        jira_enabled: true,
        ..Config::default()
    };
    let path = config.vessel_dir().join("vessel.json");
    let text = match fs::read_to_string(&path) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(config),
        Err(error) => return Err(format!("Could not read {}: {error}", path.display())),
    };
    let value: Value = serde_json::from_str(&text)
        .map_err(|error| format!("Could not parse {}: {error}", path.display()))?;
    apply_config(&mut config, &value);
    Ok(config)
}

fn apply_config(config: &mut Config, value: &Value) {
    config.jira_jql = value
        .get("jira_jql")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|jql| !jql.is_empty())
        .map(str::to_owned);
    config.ticket_projects = value
        .get("ticket_projects")
        .and_then(Value::as_array)
        .map(|projects| {
            projects
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_default();
    config.feature_projects = string_map(value.get("feature_projects"));
    config.repo_projects = string_map(value.get("repo_projects"));
    if let Some(enabled) = value.get("github_enabled").and_then(Value::as_bool) {
        config.github_enabled = enabled;
    }
    if let Some(enabled) = value.get("jira_enabled").and_then(Value::as_bool) {
        config.jira_enabled = enabled;
    }
}

fn string_map(value: Option<&Value>) -> BTreeMap<String, String> {
    value
        .and_then(Value::as_object)
        .map(|entries| {
            entries
                .iter()
                .filter_map(|(key, value)| Some((key.clone(), value.as_str()?.to_owned())))
                .collect()
        })
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_defaults_enable_integrations() {
        let home = env::temp_dir().join(format!("vessel-config-{}", std::process::id()));
        let config = load_config((home.clone(), home.clone())).unwrap();

        assert_eq!(config.fm_home, home);
        assert!(config.github_enabled && config.jira_enabled);
        assert_eq!(config.runs_file(), home.join("data/vessel/runs.jsonl"));
    }

    #[test]
    fn config_reads_optional_keys() {
        let mut config = Config {
            github_enabled: true,
            jira_enabled: true,
            ..Config::default()
        };
        apply_config(
            &mut config,
            &serde_json::json!({
                "jira_jql": " project = KAN ",
                "ticket_projects": ["KAN"],
                "feature_projects": {"KAN-1": "webapp"},
                "repo_projects": {"acme/api": "api"},
                "github_enabled": false
            }),
        );

        assert_eq!(config.jira_jql.as_deref(), Some("project = KAN"));
        assert_eq!(config.ticket_projects, ["KAN"]);
        assert_eq!(config.feature_projects["KAN-1"], "webapp");
        assert_eq!(config.repo_projects["acme/api"], "api");
        assert!(!config.github_enabled);
        assert!(config.jira_enabled);
    }
}
