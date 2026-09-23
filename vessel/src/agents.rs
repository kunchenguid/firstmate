//! The captain's vessel agents: `config/vessel/agents.json` plus one
//! instructions file per agent in `config/vessel/agents/`.
//!
//! The `vessel-workflows` firstmate skill reads the same files when it
//! dispatches a workflow, so an edit here changes the next run's profile.

use std::{
    fs,
    path::{Path, PathBuf},
};

use serde_json::{Value, json};

use crate::config::write_atomic;

pub(crate) const MODES: [&str; 7] = [
    "Implement",
    "Plan",
    "Review",
    "Address",
    "Conflicts",
    "Ticket",
    "Description",
];
pub(crate) const EFFORTS: [&str; 7] = ["", "low", "medium", "high", "xhigh", "max", "ultra"];
/// Used when the firstmate home's adapter references cannot be read.
const FALLBACK_HARNESSES: [&str; 3] = ["claude", "codex", "pi"];

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct Agent {
    pub(crate) name: String,
    pub(crate) mode: String,
    pub(crate) harness: String,
    pub(crate) model: String,
    pub(crate) effort: String,
    pub(crate) instructions: String,
    pub(crate) instructions_file: Option<String>,
}

pub(crate) struct AgentStore {
    directory: PathBuf,
    defaults: PathBuf,
}

impl AgentStore {
    pub(crate) fn new(fm_home: &Path, fm_root: &Path) -> Self {
        Self {
            directory: fm_home.join("config/vessel"),
            defaults: fm_root.join("vessel/defaults"),
        }
    }

    #[cfg(test)]
    pub(crate) fn at(directory: PathBuf, defaults: PathBuf) -> Self {
        Self {
            directory,
            defaults,
        }
    }

    fn file(&self) -> PathBuf {
        self.directory.join("agents.json")
    }

    /// Loads the captain's agents, seeding them from `vessel/defaults` on first use.
    pub(crate) fn load(&self) -> Result<Vec<Agent>, String> {
        if !self.file().exists() {
            let agents = read_agents(
                &self.defaults.join("agents.json"),
                &self.defaults.join("agents"),
            )?;
            self.save(&agents)?;
            return Ok(agents);
        }
        read_agents(&self.file(), &self.directory.join("agents"))
    }

    pub(crate) fn save(&self, agents: &[Agent]) -> Result<(), String> {
        let instructions_dir = self.directory.join("agents");
        fs::create_dir_all(&instructions_dir)
            .map_err(|error| format!("Could not create {}: {error}", instructions_dir.display()))?;
        let mut entries = Vec::with_capacity(agents.len());
        for (index, agent) in agents.iter().enumerate() {
            let file = agent
                .instructions_file
                .clone()
                .unwrap_or_else(|| format!("{}.md", slug(&agent.name, index)));
            write_atomic(&instructions_dir.join(&file), &agent.instructions)?;
            entries.push(json!({
                "name": agent.name,
                "mode": agent.mode,
                "harness": agent.harness,
                "model": agent.model,
                "effort": agent.effort,
                "instructions_file": file,
            }));
        }
        let document = json!({"version": 1, "agents": entries});
        let text = serde_json::to_string_pretty(&document)
            .map_err(|error| format!("Could not encode agents: {error}"))?;
        write_atomic(&self.file(), &format!("{text}\n"))
    }
}

fn read_agents(file: &Path, instructions_dir: &Path) -> Result<Vec<Agent>, String> {
    let text = fs::read_to_string(file)
        .map_err(|error| format!("Could not read {}: {error}", file.display()))?;
    let value: Value = serde_json::from_str(&text)
        .map_err(|error| format!("Could not parse {}: {error}", file.display()))?;
    let agents = value
        .get("agents")
        .and_then(Value::as_array)
        .ok_or_else(|| format!("{} has no agents list", file.display()))?;
    Ok(agents
        .iter()
        .filter_map(|agent| {
            let text = |field: &str| {
                agent
                    .get(field)
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .unwrap_or_default()
                    .to_owned()
            };
            let name = text("name");
            if name.is_empty() {
                return None;
            }
            let instructions_file = Some(text("instructions_file")).filter(|file| !file.is_empty());
            let instructions = instructions_file
                .as_ref()
                .and_then(|file| fs::read_to_string(instructions_dir.join(file)).ok())
                .unwrap_or_default();
            Some(Agent {
                mode: Some(text("mode"))
                    .filter(|mode| !mode.is_empty())
                    .unwrap_or_else(|| "Implement".into()),
                harness: text("harness"),
                model: text("model"),
                effort: text("effort"),
                name,
                instructions,
                instructions_file,
            })
        })
        .collect())
}

fn slug(name: &str, index: usize) -> String {
    let slug = name
        .to_lowercase()
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() {
                character
            } else {
                '-'
            }
        })
        .collect::<String>()
        .split('-')
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join("-");
    if slug.is_empty() {
        format!("agent-{}", index + 1)
    } else {
        slug
    }
}

/// firstmate's verified harness adapters, from its adapter reference files.
pub(crate) fn harness_options(fm_home: &Path) -> Vec<String> {
    let directory = fm_home.join(".agents/skills/harness-adapters/references/harness");
    let mut harnesses = fs::read_dir(directory)
        .map(|entries| {
            entries
                .filter_map(Result::ok)
                .filter_map(|entry| {
                    entry
                        .path()
                        .file_stem()
                        .and_then(|stem| stem.to_str())
                        .map(str::to_owned)
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    if harnesses.is_empty() {
        harnesses = FALLBACK_HARNESSES.map(str::to_owned).to_vec();
    }
    harnesses.sort();
    harnesses
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> PathBuf {
        let path =
            std::env::temp_dir().join(format!("vessel-agents-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&path);
        path
    }

    fn defaults() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("defaults")
    }

    #[test]
    fn first_load_seeds_the_role_agents() {
        let directory = temp("seed");
        let store = AgentStore::at(directory.clone(), defaults());

        let agents = store.load().unwrap();

        assert_eq!(agents.len(), 7);
        assert_eq!(agents[0].name, "Snoop");
        assert_eq!(agents[0].mode, "Review");
        assert_eq!(agents[0].harness, "pi");
        let stringer = agents
            .iter()
            .find(|agent| agent.name == "Stringer")
            .unwrap();
        assert!(stringer.instructions.contains("implementation plans"));
        assert!(directory.join("agents.json").is_file());
        assert!(directory.join("agents/stringer.md").is_file());
        fs::remove_dir_all(directory).ok();
    }

    #[test]
    fn edits_round_trip() {
        let directory = temp("roundtrip");
        let store = AgentStore::at(directory.clone(), defaults());
        let mut agents = store.load().unwrap();

        agents[0].model = "claude-opus-5".into();
        agents.push(Agent {
            name: "Bunk Moreland".into(),
            mode: "Implement".into(),
            harness: "claude".into(),
            model: String::new(),
            effort: "max".into(),
            instructions: "Work the case.".into(),
            instructions_file: None,
        });
        store.save(&agents).unwrap();
        let reloaded = store.load().unwrap();

        assert_eq!(reloaded[0].model, "claude-opus-5");
        assert_eq!(reloaded[7].name, "Bunk Moreland");
        assert_eq!(reloaded[7].instructions, "Work the case.");
        assert_eq!(
            reloaded[7].instructions_file.as_deref(),
            Some("bunk-moreland.md")
        );
        fs::remove_dir_all(directory).ok();
    }

    #[test]
    fn every_default_agent_uses_a_known_mode_and_verified_harness() {
        let home = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
        let harnesses = harness_options(home);
        let agents =
            read_agents(&defaults().join("agents.json"), &defaults().join("agents")).unwrap();

        for agent in agents {
            assert!(MODES.contains(&agent.mode.as_str()), "{}", agent.name);
            assert!(harnesses.contains(&agent.harness), "{}", agent.name);
            assert!(EFFORTS.contains(&agent.effort.as_str()), "{}", agent.name);
        }
    }
}
