use super::*;

impl App {
    pub(crate) fn open_run(&mut self, task: String, created_at: Option<u64>) {
        let brief = self.fleet.document(&task, "brief.md");
        let report = self.fleet.document(&task, "report.md");
        self.fleet.open_peek(&task);
        self.run_view = Some(RunViewState {
            task,
            created_at,
            focus: RunViewFocus::Status,
            scroll: 0,
            brief,
            report,
        });
    }

    /// Enter on a run: its live agent session when it has one, else (or with
    /// `details`) the run view. `main` opens the session, since that may need
    /// the terminal.
    pub(crate) fn enter_run(&mut self, task: String, created_at: Option<u64>, details: bool) {
        let has_session = self.runs().iter().any(|run| {
            run.task == task
                && run.created_at == created_at
                && run.live
                && run.endpoint_exists != Some(false)
        });
        if has_session && !details {
            self.session_request = Some((task, created_at));
        } else {
            self.open_run(task, created_at);
        }
    }

    /// Enter inside the run view.
    pub(crate) fn open_viewed_run_session(&mut self) {
        if let Some(run) = self.viewed_run() {
            if run.live && run.endpoint_exists != Some(false) {
                self.session_request = Some((run.task.clone(), run.created_at));
            } else {
                self.notice = Some(format!("{} has no live session", run.task));
            }
        }
    }

    pub(crate) fn close_run(&mut self) {
        self.run_view = None;
        self.fleet.close_peek();
    }

    /// The run shown in the run view, matched by task id and dispatch time.
    pub(crate) fn viewed_run(&self) -> Option<&Run> {
        let view = self.run_view.as_ref()?;
        self.runs()
            .iter()
            .find(|run| run.task == view.task && run.created_at == view.created_at)
            .or_else(|| self.fleet.run(&view.task))
    }

    pub(crate) fn toggle_run_view_focus(&mut self, offset: isize) {
        const ORDER: [RunViewFocus; 4] = [
            RunViewFocus::Status,
            RunViewFocus::Brief,
            RunViewFocus::Report,
            RunViewFocus::Terminal,
        ];
        if let Some(view) = &mut self.run_view {
            let current = ORDER
                .iter()
                .position(|focus| *focus == view.focus)
                .unwrap_or_default();
            view.focus =
                ORDER[(current as isize + offset).rem_euclid(ORDER.len() as isize) as usize];
            view.scroll = 0;
        }
    }

    pub(crate) fn scroll_run_view(&mut self, offset: i16) {
        if let Some(view) = &mut self.run_view {
            view.scroll = view.scroll.saturating_add_signed(offset);
        }
    }

    /// Re-reads documents shown on screen after the fleet changed.
    pub(super) fn refresh_run_views(&mut self) {
        if let Some(view) = &mut self.run_view {
            view.brief = self.fleet.document(&view.task, "brief.md");
            view.report = self.fleet.document(&view.task, "report.md");
        }
        if matches!(self.jira_detail, Some(JiraDetailState::Ready(_))) {
            self.refresh_ticket_plans();
        }
    }
}
