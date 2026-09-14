# /// script
# requires-python = ">=3.11"
# dependencies = ["textual"]
# ///
"""fm-bridge-console.py - the terminal console piece of the captain's bridge.

Reads the fm-bridge-snapshot.v1 JSON produced by bin/fm-bridge-snapshot.sh
(the collector, built alongside this in a separate task) and renders it as a
Textual app: quota strip, fleet table, backlog counts, upstream status, and
unrecorded-process warnings. Direct keys (r/q/u/p/o/t) run immediately and only
ever read; `t` renders the selected task's time and token timeline from the
durable record bin/fm_task_timeline.py owns (data/<id>/timeline.json) plus, for
a live task, the same sources the collector reads. Queued keys (s, /, f, U)
always show what will be sent, ask for
confirmation, then hand the text to `bin/fm-inbox.sh note` - this console
never calls fm-send.sh, fm-spawn.sh, fm-control.sh, fm-pr-merge.sh, `git push`,
or any merge; that is firstmate's job once it drains the note.

Run via bin/fm-bridge.sh, which resolves `uv` and executes this script so PEP
723's inline dependency list installs Textual into a throwaway environment
without a global install. All formatting/parsing/threshold logic lives in the
colocated fm_bridge_lib.py so it can be unit tested without Textual.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path
from typing import Any

BIN_DIR = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("fm_bridge_lib", BIN_DIR / "fm_bridge_lib.py")
lib = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(lib)
_tl_spec = importlib.util.spec_from_file_location("fm_task_timeline", BIN_DIR / "fm_task_timeline.py")
timeline = importlib.util.module_from_spec(_tl_spec)
_tl_spec.loader.exec_module(timeline)

from rich.text import Text  # noqa: E402
from textual.app import App, ComposeResult  # noqa: E402
from textual.binding import Binding  # noqa: E402
from textual.containers import Vertical, VerticalScroll  # noqa: E402
from textual.screen import ModalScreen  # noqa: E402
from textual.widgets import Button, DataTable, Footer, Input, Label, ListItem, ListView, Static  # noqa: E402

DEFAULT_INTERVAL = 15.0
MODAL_KEY_HINT = "Tab: switch buttons  Enter: activate  Escape: cancel"


def default_snapshot_cmd() -> list[str]:
    return [str(BIN_DIR / "fm-bridge-snapshot.sh"), "--json"]


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Firstmate bridge terminal console")
    p.add_argument("--snapshot-file", help="read snapshot JSON from this file instead of the collector")
    p.add_argument(
        "--snapshot-cmd",
        help="override collector command (space-split); default runs fm-bridge-snapshot.sh --json",
    )
    p.add_argument("--interval", type=float, default=DEFAULT_INTERVAL, help="seconds between refreshes")
    p.add_argument("--peek-cmd", default=str(BIN_DIR / "fm-peek.sh"))
    p.add_argument("--upstream-cmd", default=str(BIN_DIR / "fm-upstream-sync.sh"))
    p.add_argument("--inbox-cmd", default=str(BIN_DIR / "fm-inbox.sh"))
    p.add_argument("--quota-cmd", default="quota-axi")
    p.add_argument("--lavish-cmd", default="lavish-axi")
    p.add_argument("--fm-home", default=None, help="home whose data/<id>/timeline.json the t key reads (default: the snapshot's fm_home)")
    return p.parse_args(argv)


# --- modal screens -----------------------------------------------------------


class MessageModal(ModalScreen[None]):
    """A dismissable read-only message (peek output, open links, errors)."""

    BINDINGS = [Binding("escape", "dismiss_modal", "Close")]

    def __init__(self, title: str, body: str | Text) -> None:
        super().__init__()
        self._title = title
        self._body = body

    def compose(self) -> ComposeResult:
        with Vertical(id="modal-box"):
            yield Label(self._title, id="modal-title")
            with VerticalScroll(id="modal-body-scroll"):
                yield Static(self._body, id="modal-body")
            yield Button("Close", id="close-btn")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "close-btn":
            self.dismiss(None)

    def action_dismiss_modal(self) -> None:
        self.dismiss(None)


class ConfirmModal(ModalScreen[bool]):
    """Show the exact text that will be queued and ask yes/no."""

    BINDINGS = [Binding("escape", "cancel_modal", "Cancel")]

    def __init__(self, prompt: str, note_text: str) -> None:
        super().__init__()
        self._prompt = prompt
        self._note_text = note_text

    def compose(self) -> ComposeResult:
        with Vertical(id="modal-box"):
            yield Label(self._prompt, id="modal-title")
            yield Static(f'"{self._note_text}"', id="modal-body")
            yield Label("This is queued for firstmate; nothing runs until firstmate acts on it.")
            yield Label(MODAL_KEY_HINT, classes="modal-hint")
            with Vertical(id="confirm-buttons"):
                yield Button("Queue it", id="confirm-yes", variant="primary")
                yield Button("Cancel", id="confirm-no")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        self.dismiss(event.button.id == "confirm-yes")

    def action_cancel_modal(self) -> None:
        self.dismiss(False)


class TextInputModal(ModalScreen[str | None]):
    """Free-text entry, used by the 's' (ask) and '/' (route) queued keys."""

    BINDINGS = [Binding("escape", "cancel_modal", "Cancel")]

    def __init__(self, prompt: str) -> None:
        super().__init__()
        self._prompt = prompt

    def compose(self) -> ComposeResult:
        with Vertical(id="modal-box"):
            yield Label(self._prompt, id="modal-title")
            yield Input(placeholder="type your message, enter to continue", id="text-input")
            yield Label(MODAL_KEY_HINT, classes="modal-hint")
            with Vertical(id="confirm-buttons"):
                yield Button("Continue", id="text-ok", variant="primary")
                yield Button("Cancel", id="text-cancel")

    def on_mount(self) -> None:
        self.query_one("#text-input", Input).focus()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        self.dismiss(event.value)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "text-ok":
            self.dismiss(self.query_one("#text-input", Input).value)
        else:
            self.dismiss(None)

    def action_cancel_modal(self) -> None:
        self.dismiss(None)


class SelectModal(ModalScreen[str | None]):
    """Pick one target from a short list, used by the '/' route key."""

    BINDINGS = [Binding("escape", "cancel_modal", "Cancel")]

    def __init__(self, prompt: str, options: list[str]) -> None:
        super().__init__()
        self._prompt = prompt
        self._options = options

    def compose(self) -> ComposeResult:
        with Vertical(id="modal-box"):
            yield Label(self._prompt, id="modal-title")
            yield ListView(*[ListItem(Label(opt), name=opt) for opt in self._options], id="select-list")
            yield Label(MODAL_KEY_HINT, classes="modal-hint")
            yield Button("Cancel", id="select-cancel")

    def on_list_view_selected(self, event: ListView.Selected) -> None:
        self.dismiss(event.item.name)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        self.dismiss(None)

    def action_cancel_modal(self) -> None:
        self.dismiss(None)


# --- main app ------------------------------------------------------------


class BridgeConsole(App[None]):
    CSS = """
    #modal-box {
        width: 70%;
        max-width: 100;
        height: auto;
        max-height: 80%;
        border: thick $accent;
        background: $surface;
        padding: 1 2;
    }
    #modal-body-scroll { height: auto; max-height: 20; }
    #confirm-buttons { height: auto; align: right middle; }
    .modal-hint { color: $text-muted; }
    #header-bar, #quota-strip, #backlog-bar, #upstream-bar, #warnings-bar { height: auto; padding: 0 1; }
    .band-normal { color: $text; }
    .band-amber { color: $warning; }
    .band-red { color: $error; text-style: bold; }
    .band-unknown { color: $text-muted; }
    """

    BINDINGS = [
        Binding("r", "refresh", "Refresh"),
        Binding("q", "refresh_quota", "Quota"),
        Binding("u", "check_upstream", "Upstream"),
        Binding("p", "peek", "Peek"),
        Binding("o", "open_links", "Open"),
        Binding("s", "ask_firstmate", "Ask"),
        Binding("slash", "route", "Route"),
        Binding("f", "propose_restart", "Restart"),
        Binding("U", "take_upstream", "Take upstream"),
        Binding("t", "timeline", "Timeline"),
        Binding("ctrl+q", "quit", "Quit"),
    ]

    def __init__(self, args: argparse.Namespace) -> None:
        super().__init__()
        self.args = args
        self.snapshot: dict[str, Any] | None = None
        self.snapshot_error: str | None = None

    # -- layout ------------------------------------------------------------

    def compose(self) -> ComposeResult:
        yield Static("firstmate bridge - starting up...", id="header-bar")
        yield Static("", id="quota-strip")
        table = DataTable(id="fleet-table")
        table.cursor_type = "row"
        table.add_columns("id", "kind", "status", "context", "step", "elapsed")
        yield table
        yield Static("", id="backlog-bar")
        yield Static("", id="upstream-bar")
        yield Static("", id="warnings-bar")
        yield Footer()

    def on_mount(self) -> None:
        self.set_interval(max(self.args.interval, 1.0), self.action_refresh)
        self.action_refresh()

    # -- snapshot fetch (off the UI thread) --------------------------------

    def action_refresh(self) -> None:
        self.run_worker(self._fetch_snapshot, thread=True, exclusive=True, group="snapshot")

    def _fetch_snapshot(self) -> None:
        if self.args.snapshot_file:
            try:
                text = Path(self.args.snapshot_file).read_text()
            except OSError as exc:
                self.call_from_thread(self._apply_snapshot, None, f"could not read {self.args.snapshot_file}: {exc}")
                return
        else:
            cmd = self.args.snapshot_cmd.split() if self.args.snapshot_cmd else default_snapshot_cmd()
            rc, out, err = lib.run_command(cmd, timeout=30.0)
            if rc != 0:
                self.call_from_thread(
                    self._apply_snapshot,
                    None,
                    f"bridge snapshot collector not available: {(err or out or 'no output').strip()}",
                )
                return
            text = out
        try:
            data = lib.parse_snapshot(text)
        except lib.SnapshotError as exc:
            self.call_from_thread(self._apply_snapshot, None, str(exc))
            return
        self.call_from_thread(self._apply_snapshot, data, None)

    def _apply_snapshot(self, data: dict[str, Any] | None, error: str | None) -> None:
        if data is not None:
            self.snapshot = data
            self.snapshot_error = None
        else:
            self.snapshot_error = error
        self._render_all()

    # -- rendering -----------------------------------------------------------

    def _render_all(self) -> None:
        self._render_header()
        self._render_quota()
        self._render_fleet()
        self._render_backlog()
        self._render_upstream()
        self._render_warnings()

    def _render_header(self) -> None:
        bar = self.query_one("#header-bar", Static)
        if self.snapshot_error and not self.snapshot:
            bar.update(f"firstmate bridge - {self.snapshot_error}")
            return
        snap = self.snapshot or {}
        host = snap.get("host", "?")
        age = lib.format_age(snap.get("generated"))
        bar.update(f"firstmate bridge - {host} - refreshed {age}")

    def _render_quota(self) -> None:
        widget = self.query_one("#quota-strip", Static)
        snap = self.snapshot or {}
        quota = snap.get("quota") or {}
        if not quota:
            widget.update("quota: not measured")
            return
        lines = [lib.format_quota_provider(p) for p in quota.get("providers", [])]
        attention = quota.get("attention") or []
        if attention:
            lines.append(f"attention ({len(attention)}): " + "; ".join(f"{a['provider']} {a['kind']}" for a in attention))
        widget.update("\n".join(lines) if lines else "quota: no providers reported")

    def _render_fleet(self) -> None:
        table = self.query_one("#fleet-table", DataTable)
        table.clear()
        for agent in (self.snapshot or {}).get("agents", []):
            aid = agent.get("id", "?")
            status_note = (agent.get("last_status") or {}).get("note") or (agent.get("current_state") or "?")
            ctx_text, _band = lib.format_context(agent.get("context"))
            step = (agent.get("validation") or {}).get("current_step") if agent.get("validation") else None
            step_text = step or "-"
            elapsed_text = lib.format_elapsed(agent.get("elapsed_seconds"))
            table.add_row(aid, agent.get("kind", "?"), status_note, ctx_text, step_text, elapsed_text, key=aid)

    def _render_backlog(self) -> None:
        widget = self.query_one("#backlog-bar", Static)
        backlog = (self.snapshot or {}).get("backlog")
        if not backlog:
            widget.update("backlog: not measured")
            return
        widget.update(
            "backlog: {in_flight} in flight, {held} held, {ready} ready, {blocked} blocked".format(
                in_flight=backlog.get("in_flight", "?"),
                held=backlog.get("held", "?"),
                ready=backlog.get("ready", "?"),
                blocked=backlog.get("blocked", "?"),
            )
        )

    def _render_upstream(self) -> None:
        widget = self.query_one("#upstream-bar", Static)
        upstream = (self.snapshot or {}).get("upstream")
        if not upstream:
            widget.update("upstream: not measured")
            return
        status = upstream.get("status", "?")
        n = upstream.get("new_commits")
        age = lib.format_age(upstream.get("checked_at"))
        widget.update(f"upstream: {status} ({n if n is not None else '?'} new commits), checked {age}")

    def _render_warnings(self) -> None:
        widget = self.query_one("#warnings-bar", Static)
        lines = lib.warnings_for_unrecorded((self.snapshot or {}).get("unrecorded_agents"))
        widget.update("\n".join(lines))

    # -- selection helper -----------------------------------------------------

    def _selected_agent_id(self) -> str | None:
        table = self.query_one("#fleet-table", DataTable)
        if table.row_count == 0:
            return None
        try:
            row_key, _column_key = table.coordinate_to_cell_key(table.cursor_coordinate)
        except Exception:
            return None
        return row_key.value if row_key is not None else None

    def _selected_agent(self) -> dict[str, Any] | None:
        aid = self._selected_agent_id()
        if aid is None:
            return None
        for agent in (self.snapshot or {}).get("agents", []):
            if agent.get("id") == aid:
                return agent
        return None

    # -- direct keys (read-only) ----------------------------------------------

    def action_refresh_quota(self) -> None:
        self.run_worker(self._fetch_quota_only, thread=True, exclusive=True, group="quota")

    def _fetch_quota_only(self) -> None:
        cmd = self.args.quota_cmd.split() + ["--json"]
        rc, out, err = lib.run_command(cmd, timeout=20.0)
        if rc != 0:
            self.call_from_thread(self.notify, f"quota refresh failed: {(err or out or '').strip()}", severity="error")
            return
        try:
            raw = json.loads(out)
        except ValueError as exc:
            self.call_from_thread(self.notify, f"quota-axi returned invalid JSON: {exc}", severity="error")
            return
        adapted = lib.quota_from_quota_axi_json(raw)
        self.call_from_thread(self._apply_quota_only, adapted)

    def _apply_quota_only(self, quota: dict[str, Any]) -> None:
        if self.snapshot is None:
            self.snapshot = {"quota": quota, "agents": []}
        else:
            self.snapshot["quota"] = quota
        self._render_quota()
        self.notify("quota refreshed")

    def action_check_upstream(self) -> None:
        self.run_worker(self._check_upstream, thread=True, exclusive=True, group="upstream")

    def _check_upstream(self) -> None:
        rc, out, err = lib.run_command([self.args.upstream_cmd, "--check"], timeout=30.0)
        line = out.strip() or ("up to date" if rc == 0 else (err or "").strip() or "unknown result")
        self.call_from_thread(self.notify, f"upstream check: {line}")

    def action_peek(self) -> None:
        agent = self._selected_agent_id()
        if agent is None:
            self.notify("select an agent in the fleet table first", severity="warning")
            return
        self.run_worker(lambda: self._peek(agent), thread=True, exclusive=True, group="peek")

    def _peek(self, agent_id: str) -> None:
        rc, out, err = lib.run_command([self.args.peek_cmd, agent_id, "40"], timeout=15.0)
        body = out if rc == 0 else f"peek failed ({rc}): {err or out}"
        self.call_from_thread(self.push_screen, MessageModal(f"peek: {agent_id}", body or "(empty)"))

    def action_open_links(self) -> None:
        self.run_worker(self._open_links, thread=True, exclusive=True, group="open")

    def _open_links(self) -> None:
        agent = self._selected_agent()
        rc, out, _err = lib.run_command([self.args.lavish_cmd], timeout=15.0)
        lavish_rows = lib.parse_lavish_sessions(out) if rc == 0 else []
        pr_entry = (agent.get("id"), agent["pr"]) if agent and agent.get("pr") else None
        body = self._build_open_links_text(pr_entry, lavish_rows)
        self.call_from_thread(self.push_screen, MessageModal("open", body))

    @staticmethod
    def _build_open_links_text(pr_entry: tuple[str, str] | None, lavish_rows: list[dict[str, str]]) -> Text:
        text = Text()
        if pr_entry:
            agent_id, url = pr_entry
            text.append(f"PR ({agent_id}): ")
            text.append("open PR", style=f"link {url}")
            text.append(f"  {url}\n")
        for row in lavish_rows:
            text.append(f"lavish [{row['status']}]: ")
            text.append(row["file"], style=f"link {row['url']}")
            text.append(f"  {row['url']}\n")
        if not pr_entry and not lavish_rows:
            text.append("no PR on the selected agent and no open Lavish sessions")
        return text

    def action_timeline(self) -> None:
        agent = self._selected_agent_id()
        if agent is None:
            self.notify("select an agent in the fleet table first", severity="warning")
            return
        self.run_worker(lambda: self._timeline(agent), thread=True, exclusive=True, group="timeline")

    def _timeline(self, agent_id: str) -> None:
        """Read-only: the durable record under data/<id>/, plus the live sources
        for a task that is still running (bin/fm_task_timeline.py owns both)."""
        fm_home = self.args.fm_home or (self.snapshot or {}).get("fm_home") or None
        try:
            body = timeline.format_timeline(timeline.build_timeline(fm_home, agent_id))
        except Exception as exc:  # noqa: BLE001 - one broken source must not take the console down.
            body = f"timeline failed: {exc}"
        self.call_from_thread(self.push_screen, MessageModal(f"timeline: {agent_id}", body or "(empty)"))

    # -- queued keys (confirm, then fm-inbox.sh note) -------------------------

    def _queue_note(self, note_text: str) -> None:
        def worker() -> None:
            rc, out, err = lib.run_command([self.args.inbox_cmd, "note", note_text], timeout=15.0)
            if rc == 0:
                self.call_from_thread(self.notify, "Queued for firstmate")
            else:
                self.call_from_thread(self.notify, f"queue failed: {(err or out or '').strip()}", severity="error")

        self.run_worker(worker, thread=True, exclusive=False, group="queue")

    def _confirm_and_queue(self, prompt: str, note_text: str) -> None:
        def on_result(confirmed: bool | None) -> None:
            if confirmed:
                self._queue_note(note_text)

        self.push_screen(ConfirmModal(prompt, note_text), on_result)

    def action_ask_firstmate(self) -> None:
        def on_text(text: str | None) -> None:
            if not text:
                return
            note = lib.queue_note_text("ask_firstmate", text=text)
            self._confirm_and_queue("Ask firstmate", note)

        self.push_screen(TextInputModal("Ask firstmate (free text):"), on_text)

    def action_route(self) -> None:
        options = ["main"] + [
            a.get("id") for a in (self.snapshot or {}).get("agents", []) if a.get("kind") == "secondmate"
        ]

        def on_target(target: str | None) -> None:
            if target is None:
                return

            def on_text(text: str | None) -> None:
                if not text:
                    return
                note = lib.queue_note_text("route", target=target, text=text)
                self._confirm_and_queue(f"Route to {target}", note)

            self.push_screen(TextInputModal(f"Route to {target} (free text):"), on_text)

        self.push_screen(SelectModal("Route to:", options), on_target)

    def action_propose_restart(self) -> None:
        agent = self._selected_agent_id()
        if agent is None:
            self.notify("select an agent in the fleet table first", severity="warning")
            return
        note = lib.queue_note_text("propose_restart", target=agent)
        self._confirm_and_queue(f"Propose a fresh restart of {agent}", note)

    def action_take_upstream(self) -> None:
        note = lib.queue_note_text("take_upstream")
        self._confirm_and_queue("Take upstream", note)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    app = BridgeConsole(args)
    app.run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
