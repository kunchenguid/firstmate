use super::*;
use crate::firstmate::runs::RunStatus;

/// Ticket indexes and text rows, shared by rendering and keyboard navigation.
pub(crate) fn jira_ticket_rows(tickets: &[Ticket]) -> Vec<(usize, usize)> {
    let mut indexes = (0..tickets.len()).collect::<Vec<_>>();
    indexes.sort_by(|&left, &right| {
        tickets[left]
            .feature
            .cmp(&tickets[right].feature)
            .then_with(|| compare_jira_keys(&tickets[left].key, &tickets[right].key))
    });
    let mut previous_feature = None;
    let mut row = 0;
    indexes
        .into_iter()
        .map(|index| {
            let feature = tickets[index].feature.as_str();
            if previous_feature != Some(feature) {
                row += if previous_feature.is_some() { 2 } else { 1 };
                previous_feature = Some(feature);
            }
            let position = (index, row);
            row += 1;
            position
        })
        .collect()
}

pub(crate) fn jira_content_height(tickets: &[Ticket]) -> usize {
    jira_ticket_rows(tickets)
        .last()
        .map_or(0, |(_, row)| row + 1)
}

impl App {
    pub(super) fn reset_jira_detail_navigation(&mut self) {
        self.jira_detail_scroll = 0;
        self.jira_detail_selected = 0;
        self.jira_plan_selected = 0;
        self.jira_detail_focus = JiraDetailFocus::Ticket;
    }

    pub(crate) fn toggle_jira_detail_focus(&mut self) {
        self.jira_detail_focus = match self.jira_detail_focus {
            JiraDetailFocus::Ticket => JiraDetailFocus::Runs,
            JiraDetailFocus::Runs => JiraDetailFocus::Plans,
            JiraDetailFocus::Plans => JiraDetailFocus::Ticket,
        };
    }

    pub(crate) fn move_jira_run_selection(&mut self, offset: isize) {
        let count = self.current_ticket_runs().len();
        if self.jira_detail_focus == JiraDetailFocus::Runs {
            self.jira_detail_selected = self
                .jira_detail_selected
                .saturating_add_signed(offset)
                .min(count.saturating_sub(1));
        }
    }

    pub(crate) fn open_selected_jira_run(&mut self, details: bool) {
        if self.jira_detail_focus != JiraDetailFocus::Runs {
            return;
        }
        let Some((task, created_at)) = self
            .current_ticket_runs()
            .get(self.jira_detail_selected)
            .map(|run| (run.task.clone(), run.created_at))
        else {
            return;
        };
        self.enter_run(task, created_at, details);
    }

    pub(crate) fn move_jira_plan_selection(&mut self, offset: isize) {
        let count = self.ticket_plans.len();
        if self.jira_detail_focus == JiraDetailFocus::Plans {
            self.jira_plan_selected = self
                .jira_plan_selected
                .saturating_add_signed(offset)
                .min(count.saturating_sub(1));
        }
    }

    pub(crate) fn open_selected_jira_plan(&mut self) {
        if self.jira_detail_focus != JiraDetailFocus::Plans {
            return;
        }
        let Some(plan) = self.ticket_plans.get(self.jira_plan_selected) else {
            return;
        };
        self.plan = Some(PlanState {
            label: plan.label.clone(),
            text: plan.text.clone(),
            scroll: 0,
        });
    }

    pub(crate) fn scroll_plan(&mut self, offset: i16) {
        if let Some(plan) = &mut self.plan {
            plan.scroll = plan.scroll.saturating_add_signed(offset);
        }
    }

    pub(crate) fn close_plan(&mut self) {
        self.plan = None;
    }

    fn current_ticket_key(&self) -> Option<&str> {
        match &self.jira_detail {
            Some(JiraDetailState::Ready(detail)) => Some(detail.key.as_str()),
            _ => None,
        }
    }

    pub(crate) fn current_ticket_runs(&self) -> Vec<&Run> {
        let Some(key) = self.current_ticket_key() else {
            return Vec::new();
        };
        self.runs()
            .iter()
            .filter(|run| {
                run.ticket_key
                    .as_deref()
                    .is_some_and(|ticket| ticket.eq_ignore_ascii_case(key))
            })
            .collect()
    }

    /// Plans are the reports of finished `plan` runs for the open ticket.
    pub(crate) fn refresh_ticket_plans(&mut self) {
        let plans = self
            .current_ticket_runs()
            .into_iter()
            .filter(|run| run.workflow.as_deref() == Some("plan"))
            .filter(|run| !matches!(run.status, RunStatus::Failed))
            .filter_map(|run| {
                let text = self.fleet.document(&run.task, "report.md")?;
                (!text.trim().is_empty()).then(|| PlanOption {
                    label: format!(
                        "{} - {}",
                        run.agent().unwrap_or("Planner"),
                        format_time(run.created_at)
                    ),
                    text,
                })
            })
            .collect();
        self.ticket_plans = plans;
        self.jira_plan_selected = self
            .jira_plan_selected
            .min(self.ticket_plans.len().saturating_sub(1));
    }

    pub(crate) fn open_selected_jira_detail(&mut self) {
        let JiraState::Ready(tickets) = &self.jira else {
            return;
        };
        let Some(ticket) = tickets.get(self.jira_selected) else {
            return;
        };
        let key = ticket.key.clone();
        let feature = ticket.feature.clone();
        self.start_jira_ticket_detail(key, feature);
    }

    pub(super) fn start_jira_ticket_detail(&mut self, key: String, feature: String) {
        self.jira_detail = Some(JiraDetailState::Loading(key.clone()));
        self.reset_jira_detail_navigation();
        self.ticket_plans.clear();
        self.jira_detail_rx = Some(spawn_load(move || load_jira_ticket_detail(&key, feature)));
    }

    pub(crate) fn update_jira_detail(&mut self) {
        let Some(result) = receive(&mut self.jira_detail_rx, "Jira ticket") else {
            return;
        };
        let key = match &self.jira_detail {
            Some(JiraDetailState::Loading(key)) => key.clone(),
            _ => "Jira ticket".into(),
        };
        self.jira_detail = Some(match result {
            Ok(detail) => JiraDetailState::Ready(detail),
            Err(message) => JiraDetailState::Error { key, message },
        });
        self.refresh_ticket_plans();
    }

    pub(crate) fn close_jira_detail(&mut self) {
        self.jira_detail = None;
        self.jira_detail_rx = None;
        self.ticket_plans.clear();
        self.reset_jira_detail_navigation();
    }

    pub(crate) fn scroll_jira(&mut self, offset: isize, viewport_height: usize) {
        let JiraState::Ready(tickets) = &self.jira else {
            return;
        };
        let max_scroll = jira_content_height(tickets).saturating_sub(viewport_height.max(1));
        self.jira_scroll = if offset.is_negative() {
            self.jira_scroll.saturating_sub(offset.unsigned_abs())
        } else {
            self.jira_scroll.saturating_add(offset as usize)
        }
        .min(max_scroll);
    }

    pub(crate) fn move_jira_selection(&mut self, direction: JiraDirection, viewport_height: usize) {
        let JiraState::Ready(tickets) = &self.jira else {
            return;
        };
        let positions = jira_ticket_rows(tickets);
        let Some(current) = positions
            .iter()
            .position(|(index, _)| *index == self.jira_selected)
        else {
            return;
        };
        let offset = match direction {
            JiraDirection::Up | JiraDirection::Left => -1,
            JiraDirection::Down | JiraDirection::Right => 1,
        };
        let target = current
            .saturating_add_signed(offset)
            .min(positions.len() - 1);
        let (index, row) = positions[target];
        self.jira_selected = index;

        let viewport_height = viewport_height.max(1);
        let max_scroll = positions
            .last()
            .map_or(0, |(_, row)| row + 1)
            .saturating_sub(viewport_height);
        if row < self.jira_scroll {
            self.jira_scroll = row;
        } else if row >= self.jira_scroll.saturating_add(viewport_height) {
            self.jira_scroll = (row + 1).saturating_sub(viewport_height);
        }
        self.jira_scroll = self.jira_scroll.min(max_scroll);
    }

    /// Tickets with a run in flight get a crew marker in lists.
    pub(crate) fn active_run_for_ticket(&self, key: &str) -> Option<&Run> {
        self.runs().iter().find(|run| {
            run.is_active()
                && run
                    .ticket_key
                    .as_deref()
                    .is_some_and(|ticket| ticket.eq_ignore_ascii_case(key))
        })
    }
}

pub(crate) fn format_time(timestamp: Option<u64>) -> String {
    timestamp
        .and_then(|timestamp| {
            chrono::Local
                .timestamp_opt(i64::try_from(timestamp).ok()?, 0)
                .single()
        })
        .map(|time| time.format("%Y-%m-%d %H:%M").to_string())
        .unwrap_or_else(|| "unknown time".into())
}

use chrono::TimeZone;
