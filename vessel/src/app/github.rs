use super::*;
use crate::firstmate::runs::RunStatus;

pub(crate) fn visible_github_feedback_indices(
    detail: &PullRequestDetail,
    show_resolved: bool,
) -> Vec<usize> {
    detail
        .comments
        .iter()
        .enumerate()
        .filter(|(index, comment)| {
            (show_resolved || !comment.resolved)
                && (comment.thread.is_none()
                    || *index == 0
                    || detail.comments[*index - 1].thread.as_deref() != comment.thread.as_deref())
        })
        .map(|(index, _)| index)
        .collect()
}

fn review_state(repository: &str, number: u64, title: &str, url: &str) -> GitHubReviewState {
    GitHubReviewState {
        repository: repository.to_owned(),
        number,
        title: title.to_owned(),
        url: url.to_owned(),
        ticket_key: ticket_key_from_title(title),
        ticket: None,
        selected: 0,
        focus: GitHubReviewFocus::Description,
        description_scroll: 0,
        comment_scroll: 0,
        comment_selected: 0,
        selected_feedback: BTreeSet::new(),
        collapsed_feedback: BTreeSet::new(),
        show_resolved: true,
        detail: GitHubDetailState::Loading,
    }
}

fn is_review_run(run: &Run) -> bool {
    run.workflow.as_deref() == Some("review")
}

fn is_finished_review(run: &Run) -> bool {
    is_review_run(run)
        && !run.is_active()
        && matches!(
            run.status,
            RunStatus::Completed | RunStatus::Done | RunStatus::Merged
        )
}

impl App {
    pub(crate) fn move_github_selection(&mut self, offset: isize) {
        let (selected, count) = match self.github_section {
            GitHubSection::MyWork => {
                let count = match &self.github {
                    GitHubState::Ready(pull_requests) => pull_requests.len(),
                    _ => 0,
                };
                (&mut self.github_selected, count)
            }
            GitHubSection::OtherWork => {
                let count = match &self.github_others {
                    GitHubOthersState::Ready(pull_requests) => pull_requests.len(),
                    _ => 0,
                };
                (&mut self.github_others_selected, count)
            }
        };
        *selected = selected
            .saturating_add_signed(offset)
            .min(count.saturating_sub(1));
    }

    pub(crate) fn toggle_github_section(&mut self) {
        self.github_section = match self.github_section {
            GitHubSection::MyWork => GitHubSection::OtherWork,
            GitHubSection::OtherWork => GitHubSection::MyWork,
        };
    }

    pub(crate) fn selected_pull_request_url(&self) -> Option<String> {
        match self.github_section {
            GitHubSection::MyWork => match &self.github {
                GitHubState::Ready(pull_requests) => pull_requests
                    .get(self.github_selected)
                    .map(|pull_request| pull_request.url.clone()),
                _ => None,
            },
            GitHubSection::OtherWork => match &self.github_others {
                GitHubOthersState::Ready(pull_requests) => pull_requests
                    .get(self.github_others_selected)
                    .map(|pull_request| pull_request.url.clone()),
                _ => None,
            },
        }
    }

    pub(crate) fn open_github_review(&mut self) {
        let target = match self.github_section {
            GitHubSection::MyWork => match &self.github {
                GitHubState::Ready(pull_requests) => {
                    pull_requests.get(self.github_selected).map(|pull_request| {
                        review_state(
                            &pull_request.repository,
                            pull_request.number,
                            &pull_request.title,
                            &pull_request.url,
                        )
                    })
                }
                _ => None,
            },
            GitHubSection::OtherWork => match &self.github_others {
                GitHubOthersState::Ready(pull_requests) => pull_requests
                    .get(self.github_others_selected)
                    .map(|pull_request| {
                        review_state(
                            &pull_request.repository,
                            pull_request.number,
                            &pull_request.title,
                            &pull_request.url,
                        )
                    }),
                _ => None,
            },
        };
        self.show_github_review(target);
    }

    /// Opens a pull request that a run worked on, even when it is not in My/Other Work.
    pub(crate) fn open_run_pull_request(&mut self) {
        let Some(run) = self.viewed_run() else {
            return;
        };
        let (Some(repository), Some(number)) = (run.repo.clone(), run.pr_number) else {
            self.notice = Some("This run has no pull request".into());
            return;
        };
        let url = run
            .pr_url
            .clone()
            .unwrap_or_else(|| format!("https://github.com/{repository}/pull/{number}"));
        let title = run.title.clone();
        self.run_view = None;
        self.fleet.close_peek();
        self.show_github_review(Some(review_state(&repository, number, &title, &url)));
    }

    fn show_github_review(&mut self, review: Option<GitHubReviewState>) {
        self.github_review = review;
        let Some(review) = &self.github_review else {
            return;
        };
        let ticket_key = review.ticket_key.clone();
        self.reload_github_detail();
        if let Some(key) = ticket_key
            && self.config.jira_enabled
        {
            self.github_ticket_rx = Some(spawn_load(move || {
                load_jira_ticket_detail(&key, String::new())
            }));
        }
        self.notice = None;
    }

    pub(super) fn reload_github_detail(&mut self) {
        let Some(review) = &self.github_review else {
            return;
        };
        let repository = review.repository.clone();
        let number = review.number;
        self.github_detail_rx = Some(spawn_load(move || {
            load_pull_request_detail(&repository, number)
        }));
    }

    pub(crate) fn update_github_detail(&mut self) {
        let Some(result) = receive(&mut self.github_detail_rx, "GitHub pull request") else {
            return;
        };
        if let Some(review) = &mut self.github_review {
            review.detail = result.map_or_else(GitHubDetailState::Error, |detail| {
                let keys = visible_github_feedback_indices(&detail, true)
                    .into_iter()
                    .map(|index| detail.comments[index].feedback_key(index))
                    .collect::<BTreeSet<_>>();
                review.collapsed_feedback.retain(|key| keys.contains(key));
                review.selected_feedback.retain(|key| keys.contains(key));
                review.comment_selected = review.comment_selected.min(
                    visible_github_feedback_indices(&detail, review.show_resolved)
                        .len()
                        .saturating_sub(1),
                );
                GitHubDetailState::Ready(detail)
            });
        }
    }

    pub(crate) fn close_github_review(&mut self) {
        self.github_review = None;
        self.github_detail_rx = None;
        self.github_ticket_rx = None;
    }

    pub(crate) fn update_github_ticket(&mut self) {
        if let Some(result) = receive(&mut self.github_ticket_rx, "Jira ticket")
            && let Some(review) = &mut self.github_review
        {
            review.ticket = result.ok();
        }
    }

    pub(crate) fn open_github_ticket(&mut self) {
        let Some(review) = &self.github_review else {
            return;
        };
        let Some(key) = review.ticket_key.clone() else {
            self.notice = Some("No Jira ticket found in this pull request title".into());
            return;
        };
        let ticket = review.ticket.clone();
        self.select_tab(1);
        if let Some(ticket) = ticket {
            self.jira_detail = Some(JiraDetailState::Ready(ticket));
            self.jira_detail_rx = None;
            self.reset_jira_detail_navigation();
            self.refresh_ticket_plans();
        } else {
            self.start_jira_ticket_detail(key, String::new());
        }
    }

    pub(crate) fn current_review_runs(&self) -> Vec<&Run> {
        let Some(review) = &self.github_review else {
            return Vec::new();
        };
        self.runs()
            .iter()
            .filter(|run| run.matches_pull_request(&review.repository, review.number))
            .collect()
    }

    pub(crate) fn agent_review_status(
        &self,
        repository: &str,
        number: u64,
        current_head_commit: &str,
    ) -> AgentReviewStatus {
        if self.runs().iter().any(|run| {
            run.matches_pull_request(repository, number) && is_review_run(run) && run.is_active()
        }) {
            return AgentReviewStatus::Running;
        }
        self.completed_agent_review_status(repository, number, current_head_commit)
    }

    pub(crate) fn completed_agent_review_status(
        &self,
        repository: &str,
        number: u64,
        current_head_commit: &str,
    ) -> AgentReviewStatus {
        let Some(run) = self.latest_completed_review_run(repository, number) else {
            return AgentReviewStatus::NotReviewed;
        };
        let Some(reviewed_commit) = run.pr_head().filter(|commit| !commit.is_empty()) else {
            return AgentReviewStatus::Unknown;
        };
        if current_head_commit.is_empty() {
            AgentReviewStatus::Unknown
        } else if reviewed_commit == current_head_commit {
            AgentReviewStatus::Current
        } else {
            AgentReviewStatus::NewCommits
        }
    }

    pub(crate) fn latest_completed_review_run(
        &self,
        repository: &str,
        number: u64,
    ) -> Option<&Run> {
        self.runs()
            .iter()
            .filter(|run| run.matches_pull_request(repository, number) && is_finished_review(run))
            .max_by_key(|run| run.created_at)
    }

    pub(crate) fn active_run_for_pull_request(
        &self,
        repository: &str,
        number: u64,
    ) -> Option<&Run> {
        self.runs()
            .iter()
            .find(|run| run.is_active() && run.matches_pull_request(repository, number))
    }

    pub(crate) fn move_review_selection(&mut self, offset: isize) {
        let count = self.current_review_runs().len();
        if let Some(review) = &mut self.github_review {
            review.selected = review
                .selected
                .saturating_add_signed(offset)
                .min(count.saturating_sub(1));
        }
    }

    pub(crate) fn toggle_github_review_focus(&mut self) {
        if let Some(review) = &mut self.github_review {
            review.focus = match review.focus {
                GitHubReviewFocus::Description => GitHubReviewFocus::Reviews,
                GitHubReviewFocus::Reviews => GitHubReviewFocus::Comments,
                GitHubReviewFocus::Comments => GitHubReviewFocus::Description,
            };
        }
    }

    pub(crate) fn scroll_github_description(&mut self, offset: i16) {
        if let Some(review) = &mut self.github_review
            && review.focus == GitHubReviewFocus::Description
        {
            review.description_scroll = review.description_scroll.saturating_add_signed(offset);
        }
    }

    pub(crate) fn move_github_comment_selection(
        &mut self,
        offset: isize,
        ranges: &[(u16, u16)],
        viewport_height: u16,
    ) {
        if let Some(review) = &mut self.github_review {
            review.comment_selected = review
                .comment_selected
                .saturating_add_signed(offset)
                .min(ranges.len().saturating_sub(1));
        }
        self.reveal_github_comment(ranges, viewport_height);
    }

    pub(crate) fn reveal_github_comment(&mut self, ranges: &[(u16, u16)], viewport_height: u16) {
        if let Some(review) = &mut self.github_review {
            if let Some(&range) = ranges.get(review.comment_selected) {
                reveal_row_range(&mut review.comment_scroll, range, viewport_height);
            }
            let maximum = ranges
                .last()
                .map_or(0, |(_, end)| end.saturating_sub(viewport_height));
            review.comment_scroll = review.comment_scroll.min(maximum);
        }
    }

    pub(crate) fn scroll_github_comments(
        &mut self,
        offset: i32,
        ranges: &[(u16, u16)],
        viewport_height: u16,
    ) {
        if let Some(review) = &mut self.github_review {
            let maximum = ranges
                .last()
                .map_or(0, |(_, end)| end.saturating_sub(viewport_height));
            review.comment_scroll = (i32::from(review.comment_scroll.min(maximum)) + offset)
                .clamp(0, i32::from(maximum)) as u16;
            if let Some(index) = ranges.iter().position(|&(start, end)| {
                start <= review.comment_scroll && end > review.comment_scroll
            }) {
                review.comment_selected = index;
            }
        }
    }

    /// Marks feedback locally; a future "address feedback" request will send the marked items.
    pub(crate) fn toggle_selected_github_feedback(&mut self) {
        let Some(review) = &mut self.github_review else {
            return;
        };
        let GitHubDetailState::Ready(detail) = &review.detail else {
            return;
        };
        let Some(index) = visible_github_feedback_indices(detail, review.show_resolved)
            .get(review.comment_selected)
            .copied()
        else {
            return;
        };
        let Some(comment) = detail.comments.get(index) else {
            return;
        };
        let key = comment.feedback_key(index);
        if !review.selected_feedback.insert(key.clone()) {
            review.selected_feedback.remove(&key);
        }
    }

    pub(crate) fn toggle_github_feedback_expanded(&mut self) {
        let Some(review) = &mut self.github_review else {
            return;
        };
        let GitHubDetailState::Ready(detail) = &review.detail else {
            return;
        };
        let Some(index) = visible_github_feedback_indices(detail, review.show_resolved)
            .get(review.comment_selected)
            .copied()
        else {
            return;
        };
        let Some(comment) = detail.comments.get(index) else {
            return;
        };
        let key = comment.feedback_key(index);
        if !review.collapsed_feedback.insert(key.clone()) {
            review.collapsed_feedback.remove(&key);
        }
    }

    pub(crate) fn toggle_github_resolved(&mut self) {
        if let Some(review) = &mut self.github_review {
            review.show_resolved = !review.show_resolved;
            review.comment_scroll = 0;
            review.comment_selected = 0;
        }
    }

    pub(crate) fn open_selected_review_run(&mut self, details: bool) {
        let Some(selected) = self.github_review.as_ref().map(|review| review.selected) else {
            return;
        };
        let Some((task, created_at)) = self
            .current_review_runs()
            .get(selected)
            .map(|run| (run.task.clone(), run.created_at))
        else {
            return;
        };
        self.enter_run(task, created_at, details);
    }
}
