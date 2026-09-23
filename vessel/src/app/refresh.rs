use super::*;

impl App {
    pub(crate) fn reload_jira(&mut self) {
        self.jira_scroll = 0;
        self.jira_selected = 0;
        self.jira_detail = None;
        self.jira_detail_rx = None;
        self.reset_jira_detail_navigation();
        if !self.config.jira_enabled {
            self.jira = JiraState::Disabled;
            return;
        }
        self.jira = JiraState::Loading;
        self.start_jira_load();
    }

    fn start_jira_load(&mut self) {
        if self.config.jira_enabled {
            self.jira_rx = Some(spawn_load(load_jira_tickets));
        }
    }

    pub(crate) fn update_jira(&mut self) {
        if let Some(result) = receive(&mut self.jira_rx, "Jira") {
            self.jira = match result {
                Ok(mut tickets) => {
                    tickets.sort_by(|left, right| compare_jira_keys(&left.key, &right.key));
                    self.jira_selected = self.jira_selected.min(tickets.len().saturating_sub(1));
                    JiraState::Ready(tickets)
                }
                Err(message) => JiraState::Error(message),
            };
        }
    }

    pub(crate) fn reload_github(&mut self) {
        if !self.config.github_enabled {
            self.github = GitHubState::Disabled;
            return;
        }
        self.github = GitHubState::Loading;
        self.start_github_load();
        self.github_refreshed_at = Some(std::time::Instant::now());
    }

    fn start_github_load(&mut self) {
        if self.config.github_enabled {
            self.github_rx = Some(spawn_load(load_pull_requests));
        }
    }

    pub(crate) fn update_github(&mut self) {
        if let Some(result) = receive(&mut self.github_rx, "GitHub") {
            self.github = match result {
                Ok(pull_requests) => {
                    self.github_selected = self
                        .github_selected
                        .min(pull_requests.len().saturating_sub(1));
                    GitHubState::Ready(pull_requests)
                }
                Err(message) => GitHubState::Error(message),
            };
        }
    }

    pub(crate) fn reload_github_others(&mut self) {
        if !self.config.github_enabled {
            self.github_others = GitHubOthersState::Disabled;
            return;
        }
        self.github_others = GitHubOthersState::Loading;
        self.start_github_others_load();
        self.github_refreshed_at = Some(std::time::Instant::now());
    }

    fn start_github_others_load(&mut self) {
        if self.config.github_enabled {
            self.github_others_rx = Some(spawn_load(load_review_pull_requests));
        }
    }

    pub(crate) fn update_github_others(&mut self) {
        if let Some(result) = receive(&mut self.github_others_rx, "GitHub review") {
            self.github_others = match result {
                Ok(pull_requests) => {
                    self.github_others_selected = self
                        .github_others_selected
                        .min(pull_requests.len().saturating_sub(1));
                    GitHubOthersState::Ready(pull_requests)
                }
                Err(message) => GitHubOthersState::Error(message),
            };
        }
    }

    /// Refreshes everything: the fleet now, Jira and GitHub in the background.
    pub(crate) fn refresh_all(&mut self) {
        self.fleet.request_refresh();
        self.reload_jira();
        self.reload_github();
        self.reload_github_others();
    }

    pub(crate) fn refresh_github_if_due(&mut self) {
        if self.github_rx.is_none()
            && self.github_others_rx.is_none()
            && self.jira_rx.is_none()
            && self
                .github_refreshed_at
                .is_some_and(|refreshed| refreshed.elapsed() >= GITHUB_REFRESH_INTERVAL)
        {
            self.start_jira_load();
            self.start_github_load();
            self.start_github_others_load();
            if self.github_review.is_some() && self.github_detail_rx.is_none() {
                self.reload_github_detail();
            }
            self.github_refreshed_at = Some(std::time::Instant::now());
        }
    }
}
