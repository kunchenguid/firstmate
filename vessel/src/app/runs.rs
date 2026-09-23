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
