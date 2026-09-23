use std::{
    collections::BTreeSet,
    sync::mpsc::{self, Receiver, TryRecvError},
    thread,
};

mod agents;
mod github;
pub(crate) use github::visible_github_feedback_indices;
mod jira;
mod overview;
mod refresh;
mod runs;
mod text;

pub(crate) use jira::{format_time, jira_content_height, jira_ticket_rows};
pub(crate) use overview::unix_now;
pub(super) use text::*;

use crate::{
    agents::{Agent, AgentStore, harness_options},
    config::Config,
    context::ContextWriter,
    firstmate::{Fleet, runs::Run},
    github::{
        PullRequest, PullRequestDetail, ReviewPullRequest, load_pull_request_detail,
        load_pull_requests, load_review_pull_requests, ticket_key_from_title,
    },
    jira::{Ticket, TicketDetail, compare_jira_keys, load_jira_ticket_detail, load_jira_tickets},
};

const GITHUB_REFRESH_INTERVAL: std::time::Duration = std::time::Duration::from_secs(5 * 60);

pub(crate) const TAB_TITLES: [&str; 4] = ["Overview", "Jira", "Github", "Settings"];
const SETTINGS_TAB: usize = TAB_TITLES.len() - 1;

#[derive(Default)]
pub(crate) struct App {
    pub(crate) config: Config,
    pub(crate) fleet: Fleet,
    pub(crate) agent_store: Option<AgentStore>,
    pub(crate) agents: Vec<Agent>,
    pub(crate) harnesses: Vec<String>,
    pub(crate) active_tab: usize,
    pub(crate) jira: JiraState,
    pub(crate) jira_rx: Option<Receiver<Result<Vec<Ticket>, String>>>,
    pub(crate) github: GitHubState,
    pub(crate) github_rx: Option<Receiver<Result<Vec<PullRequest>, String>>>,
    pub(crate) github_selected: usize,
    pub(crate) github_section: GitHubSection,
    pub(crate) github_others: GitHubOthersState,
    pub(crate) github_others_rx: Option<Receiver<Result<Vec<ReviewPullRequest>, String>>>,
    pub(crate) github_others_selected: usize,
    pub(crate) jira_scroll: usize,
    pub(crate) jira_selected: usize,
    pub(crate) jira_detail: Option<JiraDetailState>,
    pub(crate) jira_detail_rx: Option<Receiver<Result<TicketDetail, String>>>,
    pub(crate) jira_detail_scroll: u16,
    pub(crate) jira_detail_selected: usize,
    pub(crate) jira_plan_selected: usize,
    pub(crate) jira_detail_focus: JiraDetailFocus,
    pub(crate) ticket_plans: Vec<PlanOption>,
    pub(crate) plan: Option<PlanState>,
    pub(crate) github_review: Option<GitHubReviewState>,
    pub(crate) github_detail_rx: Option<Receiver<Result<PullRequestDetail, String>>>,
    pub(crate) github_ticket_rx: Option<Receiver<Result<TicketDetail, String>>>,
    pub(crate) run_view: Option<RunViewState>,
    pub(crate) activity: Option<ActivityState>,
    pub(crate) agent_settings: Option<AgentSettingsState>,
    pub(crate) notice: Option<String>,
    pub(crate) overview_selected: usize,
    pub(crate) overview_scroll: usize,
    pub(crate) overview_scroll_target: Option<OverviewSection>,
    pub(crate) overview_section: OverviewSection,
    pub(crate) github_refreshed_at: Option<std::time::Instant>,
    pub(crate) context: ContextWriter,
    /// A run whose live agent session `main` should open next.
    pub(crate) session_request: Option<(String, Option<u64>)>,
}

pub(crate) struct PlanOption {
    pub(crate) label: String,
    pub(crate) text: String,
}

pub(crate) struct PlanState {
    pub(crate) label: String,
    pub(crate) text: String,
    pub(crate) scroll: u16,
}

/// A run opened from the Crew list or a PR/ticket Runs tab.
pub(crate) struct RunViewState {
    pub(crate) task: String,
    pub(crate) created_at: Option<u64>,
    pub(crate) focus: RunViewFocus,
    pub(crate) scroll: u16,
    pub(crate) brief: Option<String>,
    pub(crate) report: Option<String>,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) enum RunViewFocus {
    #[default]
    Status,
    Brief,
    Report,
    Terminal,
}

#[derive(Default)]
pub(crate) struct ActivityState {
    pub(crate) scroll: u16,
}

#[derive(Clone)]
pub(crate) struct GitHubReviewState {
    pub(crate) repository: String,
    pub(crate) number: u64,
    pub(crate) title: String,
    pub(crate) url: String,
    pub(crate) ticket_key: Option<String>,
    pub(crate) ticket: Option<TicketDetail>,
    pub(crate) selected: usize,
    pub(crate) focus: GitHubReviewFocus,
    pub(crate) description_scroll: u16,
    pub(crate) comment_scroll: u16,
    pub(crate) comment_selected: usize,
    /// Feedback marked for a future "address feedback" request.
    pub(crate) selected_feedback: BTreeSet<String>,
    pub(crate) collapsed_feedback: BTreeSet<String>,
    pub(crate) show_resolved: bool,
    pub(crate) detail: GitHubDetailState,
}

#[derive(Clone, Copy, Eq, PartialEq)]
pub(crate) enum GitHubReviewFocus {
    Description,
    Reviews,
    Comments,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum AgentReviewStatus {
    NotReviewed,
    Unknown,
    Current,
    NewCommits,
    Running,
}

#[derive(Clone)]
pub(crate) enum GitHubDetailState {
    Loading,
    Ready(PullRequestDetail),
    Error(String),
}

fn reveal_row_range(scroll: &mut u16, (start, end): (u16, u16), viewport_height: u16) {
    let viewport_height = viewport_height.max(1);
    if start < *scroll || end.saturating_sub(start) >= viewport_height {
        *scroll = start;
    } else if end > scroll.saturating_add(viewport_height) {
        *scroll = end.saturating_sub(viewport_height);
    }
}

pub(crate) struct AgentSettingsState {
    pub(crate) sidebar_selected: usize,
    pub(crate) agents: Vec<Agent>,
    pub(crate) agent: usize,
    pub(crate) focus: AgentSettingsFocus,
    pub(crate) editing: bool,
    pub(crate) cursor: usize,
    pub(crate) selection_anchor: Option<usize>,
    pub(crate) agent_runs: Option<usize>,
    pub(crate) selected: usize,
    pub(crate) notice: Option<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum AgentSettingsFocus {
    Sidebar,
    Home,
    Agents,
    AgentName,
    AgentMode,
    AgentHarness,
    AgentModel,
    AgentEffort,
    AgentInstructions,
}

#[derive(Clone, Copy)]
pub(crate) enum JiraDirection {
    Left,
    Right,
    Up,
    Down,
}

pub(crate) enum JiraDetailState {
    Loading(String),
    Ready(TicketDetail),
    Error { key: String, message: String },
}

#[derive(Clone, Copy, Default, Eq, PartialEq)]
pub(crate) enum JiraDetailFocus {
    #[default]
    Ticket,
    Runs,
    Plans,
}

#[derive(Default)]
pub(crate) enum JiraState {
    #[default]
    Loading,
    Ready(Vec<Ticket>),
    Error(String),
    Disabled,
}

impl JiraState {
    #[cfg(test)]
    pub(crate) fn tickets(&self) -> &[Ticket] {
        match self {
            Self::Ready(tickets) => tickets,
            _ => &[],
        }
    }
}

#[derive(Default)]
pub(crate) enum GitHubState {
    #[default]
    Loading,
    Ready(Vec<PullRequest>),
    Error(String),
    Disabled,
}

#[derive(Default)]
pub(crate) enum GitHubOthersState {
    #[default]
    Loading,
    Ready(Vec<ReviewPullRequest>),
    Error(String),
    Disabled,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) enum GitHubSection {
    #[default]
    MyWork,
    OtherWork,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) enum OverviewSection {
    #[default]
    Crew,
    Jira,
    GitHubMe,
    GitHubOther,
}

impl App {
    pub(crate) fn load(config: Config) -> Self {
        crate::github::set_ticket_projects(config.ticket_projects.clone());
        if let Some(jql) = &config.jira_jql {
            crate::jira::set_jql(jql.clone());
        }
        let store = AgentStore::new(&config.fm_home, &config.fm_root);
        let mut app = Self {
            fleet: Fleet::new(&config),
            context: ContextWriter::new(config.context_file()),
            harnesses: harness_options(&config.fm_root),
            ..Self::default()
        };
        match store.load() {
            Ok(agents) => app.agents = agents,
            Err(message) => app.notice = Some(message),
        }
        app.agent_store = Some(store);
        app.config = config;
        if !app.fleet.ledger_enabled {
            app.notice = Some(
                "The fleet ledger is off, so finished runs have no history. Enable it with: touch config/fleet-ledger"
                    .into(),
            );
        }
        app.reload_jira();
        app.reload_github();
        app.reload_github_others();
        app
    }

    /// Polls every background source; called once per frame.
    pub(crate) fn update(&mut self) {
        if self.fleet.tick() {
            self.refresh_run_views();
        }
        self.update_jira();
        self.update_github();
        self.update_github_others();
        self.update_github_detail();
        self.update_github_ticket();
        self.update_jira_detail();
        self.refresh_github_if_due();
        self.overview_selected = self
            .overview_selected
            .min(self.crew_runs().len().saturating_sub(1));
        self.publish_context();
    }

    pub(crate) fn select_tab(&mut self, tab: usize) {
        self.active_tab = tab;
        self.agent_settings = None;
        self.github_review = None;
        self.github_detail_rx = None;
        self.github_ticket_rx = None;
        self.run_view = None;
        self.activity = None;
        self.fleet.close_peek();
        self.close_plan();
        self.close_jira_detail();
        if tab == SETTINGS_TAB {
            self.open_agent_settings();
        }
    }

    pub(crate) fn runs(&self) -> &[Run] {
        &self.fleet.runs
    }
}

fn receive<T>(
    receiver: &mut Option<Receiver<Result<T, String>>>,
    what: &str,
) -> Option<Result<T, String>> {
    let result = match receiver.as_ref()?.try_recv() {
        Ok(result) => result,
        Err(TryRecvError::Empty) => return None,
        Err(TryRecvError::Disconnected) => Err(format!("{what} loading stopped unexpectedly")),
    };
    *receiver = None;
    Some(result)
}

fn spawn_load<T: Send + 'static>(
    load: impl FnOnce() -> Result<T, String> + Send + 'static,
) -> Receiver<Result<T, String>> {
    let (sender, receiver) = mpsc::channel();
    thread::spawn(move || {
        let _ = sender.send(load());
    });
    receiver
}

pub(crate) fn jira_viewport_height(terminal_height: u16) -> usize {
    usize::from(terminal_height.saturating_sub(10).max(1))
}

#[cfg(test)]
mod tests;
