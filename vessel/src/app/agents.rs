//! Settings: the agent editor (the only thing vessel writes) and a read-only home summary.

use super::*;
use crate::agents::{EFFORTS, MODES};

pub(crate) fn agent_settings_text(state: &AgentSettingsState) -> Option<&str> {
    let agent = state.agents.get(state.agent)?;
    Some(match state.focus {
        AgentSettingsFocus::AgentName => &agent.name,
        AgentSettingsFocus::AgentModel => &agent.model,
        AgentSettingsFocus::AgentInstructions => &agent.instructions,
        _ => return None,
    })
}

fn agent_text_mut(
    state: &mut AgentSettingsState,
) -> Option<(&mut String, &mut usize, &mut Option<usize>)> {
    let focus = state.focus;
    let agent = state.agents.get_mut(state.agent)?;
    let text = match focus {
        AgentSettingsFocus::AgentName => &mut agent.name,
        AgentSettingsFocus::AgentModel => &mut agent.model,
        AgentSettingsFocus::AgentInstructions => &mut agent.instructions,
        _ => return None,
    };
    Some((text, &mut state.cursor, &mut state.selection_anchor))
}

impl App {
    pub(crate) fn open_agent_settings(&mut self) {
        self.active_tab = SETTINGS_TAB;
        self.agent_settings = Some(AgentSettingsState {
            sidebar_selected: 0,
            agents: self.agents.clone(),
            agent: 0,
            focus: AgentSettingsFocus::Sidebar,
            editing: false,
            cursor: 0,
            selection_anchor: None,
            agent_runs: None,
            selected: 0,
            notice: None,
        });
    }

    pub(crate) fn move_settings_sidebar(&mut self, offset: isize) {
        if let Some(state) = &mut self.agent_settings {
            state.sidebar_selected = state.sidebar_selected.saturating_add_signed(offset).min(1);
        }
    }

    pub(crate) fn open_selected_settings_section(&mut self) {
        if let Some(state) = &mut self.agent_settings {
            state.focus = if state.sidebar_selected == 0 {
                AgentSettingsFocus::Agents
            } else {
                AgentSettingsFocus::Home
            };
            state.editing = false;
        }
    }

    pub(crate) fn back_to_settings_sidebar(&mut self) {
        if let Some(state) = &mut self.agent_settings {
            state.focus = AgentSettingsFocus::Sidebar;
            state.editing = false;
            state.selection_anchor = None;
        }
    }

    pub(crate) fn back_to_agent_selector(&mut self) {
        if let Some(state) = &mut self.agent_settings {
            state.focus = AgentSettingsFocus::Agents;
            state.editing = false;
            state.selection_anchor = None;
        }
    }

    pub(crate) fn open_selected_agent(&mut self) {
        if let Some(state) = &mut self.agent_settings
            && state.focus == AgentSettingsFocus::Agents
            && !state.agents.is_empty()
        {
            state.focus = AgentSettingsFocus::AgentName;
            state.editing = false;
        }
    }

    pub(crate) fn open_selected_agent_runs(&mut self) {
        if let Some(state) = &mut self.agent_settings
            && state.focus == AgentSettingsFocus::Agents
            && !state.agents.is_empty()
        {
            state.agent_runs = Some(state.agent);
            state.selected = 0;
        }
    }

    pub(crate) fn close_agent_runs(&mut self) {
        if let Some(state) = &mut self.agent_settings
            && state.agent_runs.take().is_some()
        {
            state.selected = 0;
        }
    }

    pub(crate) fn agent_runs(&self) -> Vec<&Run> {
        let Some(name) = self.agent_settings.as_ref().and_then(|state| {
            state
                .agent_runs
                .and_then(|index| state.agents.get(index))
                .map(|agent| agent.name.clone())
        }) else {
            return Vec::new();
        };
        self.runs()
            .iter()
            .filter(|run| {
                run.agent()
                    .is_some_and(|agent| agent.eq_ignore_ascii_case(&name))
            })
            .collect()
    }

    pub(crate) fn open_selected_agent_run(&mut self, details: bool) {
        let Some(selected) = self
            .agent_settings
            .as_ref()
            .and_then(|state| state.agent_runs.map(|_| state.selected))
        else {
            return;
        };
        let Some((task, created_at)) = self
            .agent_runs()
            .get(selected)
            .map(|run| (run.task.clone(), run.created_at))
        else {
            return;
        };
        self.enter_run(task, created_at, details);
    }

    pub(crate) fn toggle_agent_settings_focus(&mut self) {
        let Some(state) = &mut self.agent_settings else {
            return;
        };
        state.focus = match state.focus {
            AgentSettingsFocus::AgentName => AgentSettingsFocus::AgentMode,
            AgentSettingsFocus::AgentMode => AgentSettingsFocus::AgentHarness,
            AgentSettingsFocus::AgentHarness => AgentSettingsFocus::AgentModel,
            AgentSettingsFocus::AgentModel => AgentSettingsFocus::AgentEffort,
            AgentSettingsFocus::AgentEffort => AgentSettingsFocus::AgentInstructions,
            AgentSettingsFocus::AgentInstructions => AgentSettingsFocus::AgentName,
            other => other,
        };
        state.editing = false;
        state.selection_anchor = None;
    }

    pub(crate) fn start_agent_settings_edit(&mut self) {
        let Some(state) = &mut self.agent_settings else {
            return;
        };
        state.editing = matches!(
            state.focus,
            AgentSettingsFocus::AgentName
                | AgentSettingsFocus::AgentModel
                | AgentSettingsFocus::AgentInstructions
        );
        state.cursor = agent_settings_text(state)
            .map(|text| text.chars().count())
            .unwrap_or(0);
        state.selection_anchor = None;
    }

    pub(crate) fn commit_agent_settings_edit(&mut self) {
        if let Some(state) = &mut self.agent_settings {
            state.editing = false;
            state.selection_anchor = None;
        }
        self.save_agents();
    }

    pub(crate) fn cancel_agent_settings_edit(&mut self) {
        if let Some(state) = &mut self.agent_settings {
            state.editing = false;
        }
        self.save_agents();
    }

    pub(crate) fn move_agent_selection(&mut self, offset: isize) {
        let run_count = self.agent_runs().len();
        let Some(state) = &mut self.agent_settings else {
            return;
        };
        if state.agent_runs.is_some() {
            state.selected = state
                .selected
                .saturating_add_signed(offset)
                .min(run_count.saturating_sub(1));
        } else if state.focus == AgentSettingsFocus::Agents {
            state.agent = state
                .agent
                .saturating_add_signed(offset)
                .min(state.agents.len().saturating_sub(1));
        }
    }

    pub(crate) fn add_agent(&mut self) {
        let harness = self
            .harnesses
            .iter()
            .find(|harness| *harness == "pi")
            .or_else(|| self.harnesses.first())
            .cloned()
            .unwrap_or_default();
        let Some(state) = &mut self.agent_settings else {
            return;
        };
        state.agents.push(Agent {
            name: "New agent".into(),
            mode: "Implement".into(),
            harness,
            model: String::new(),
            effort: "high".into(),
            instructions: String::new(),
            instructions_file: None,
        });
        state.agent = state.agents.len() - 1;
        state.focus = AgentSettingsFocus::AgentName;
        state.editing = false;
        self.save_agents();
    }

    pub(crate) fn delete_agent(&mut self) {
        let Some(state) = &mut self.agent_settings else {
            return;
        };
        if state.focus == AgentSettingsFocus::Agents && !state.agents.is_empty() {
            state.agents.remove(state.agent);
            state.agent = state.agent.min(state.agents.len().saturating_sub(1));
            self.save_agents();
        }
    }

    pub(crate) fn edit_agent_text(&mut self, character: char) {
        let Some(state) = &mut self.agent_settings else {
            return;
        };
        if !state.editing {
            return;
        }
        if let Some((text, cursor, anchor)) = agent_text_mut(state) {
            insert_text(text, cursor, anchor, character);
        }
    }

    pub(crate) fn backspace_agent_text(&mut self) {
        let Some(state) = &mut self.agent_settings else {
            return;
        };
        if !state.editing {
            return;
        }
        if let Some((text, cursor, anchor)) = agent_text_mut(state) {
            backspace_text(text, cursor, anchor);
        }
    }

    pub(crate) fn delete_agent_text(&mut self) {
        let Some(state) = &mut self.agent_settings else {
            return;
        };
        if !state.editing {
            return;
        }
        if let Some((text, cursor, anchor)) = agent_text_mut(state) {
            delete_text(text, cursor, anchor);
        }
    }

    pub(crate) fn move_agent_cursor(&mut self, offset: isize, selecting: bool) {
        let Some(state) = &mut self.agent_settings else {
            return;
        };
        if !state.editing {
            return;
        }
        let length = agent_settings_text(state)
            .map(|text| text.chars().count())
            .unwrap_or(0);
        move_cursor(
            &mut state.cursor,
            &mut state.selection_anchor,
            length,
            offset,
            selecting,
        );
    }

    pub(crate) fn select_all_agent_text(&mut self) {
        let Some(state) = &mut self.agent_settings else {
            return;
        };
        if state.editing {
            state.selection_anchor = Some(0);
            state.cursor = agent_settings_text(state)
                .map(|text| text.chars().count())
                .unwrap_or(0);
        }
    }

    pub(crate) fn move_agent_option(&mut self, offset: isize) {
        let harnesses = self
            .harnesses
            .iter()
            .map(String::as_str)
            .collect::<Vec<_>>();
        let Some(state) = &mut self.agent_settings else {
            return;
        };
        let focus = state.focus;
        let Some(agent) = state.agents.get_mut(state.agent) else {
            return;
        };
        match focus {
            AgentSettingsFocus::AgentMode => cycle_option(&mut agent.mode, &MODES, offset),
            AgentSettingsFocus::AgentHarness if !harnesses.is_empty() => {
                cycle_option(&mut agent.harness, &harnesses, offset)
            }
            AgentSettingsFocus::AgentEffort => cycle_option(&mut agent.effort, &EFFORTS, offset),
            _ => return,
        }
        self.save_agents();
    }

    fn save_agents(&mut self) {
        let Some(state) = &mut self.agent_settings else {
            return;
        };
        if state
            .agents
            .iter()
            .any(|agent| agent.name.trim().is_empty())
        {
            state.notice = Some("Agent names cannot be empty".into());
            return;
        }
        let mut names = BTreeSet::new();
        if let Some(duplicate) = state
            .agents
            .iter()
            .find(|agent| !names.insert(agent.name.trim().to_lowercase()))
        {
            state.notice = Some(format!("Two agents are named {}", duplicate.name.trim()));
            return;
        }
        let result = match &self.agent_store {
            Some(store) => store.save(&state.agents),
            None => Ok(()),
        };
        match result {
            Ok(()) => {
                // Newly written agents get their instructions file name back from disk.
                if let Some(store) = &self.agent_store
                    && let Ok(agents) = store.load()
                {
                    state.agents = agents;
                }
                self.agents = state.agents.clone();
                state.notice = None;
            }
            Err(message) => state.notice = Some(message),
        }
    }
}
