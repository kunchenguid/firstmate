#!/usr/bin/env python3
"""Textual pilot test for bin/fm-bridge-console.py.

Skips cleanly (exit 0, "skip: ...") when Textual is not importable, so this
never breaks a CI environment that has no Textual installed - the plain
unittest coverage in tests/fm-bridge-console-lib.test.py is what CI relies on.
When Textual IS available (for example run through `uv run --with textual`,
as the colocated tests/fm-bridge-console.test.sh does), this drives the app
headless against the fixture snapshot with every external command stubbed,
asserts the main screen and the peek modal render, and saves an SVG
screenshot of each as PR evidence.

The queued-key flows (U, s, /, f) are each driven to completion, not just
opened: every dialog in the chain is pressed to Confirm by mouse click and
again by keyboard (Tab/Enter), and to Cancel by mouse click and again by
keyboard, asserting the fake --inbox-cmd stub only ever receives a note on
the completed paths. A scratch FM_HOME and the fake inbox stub keep every
queued note from ever reaching a real inbox.
"""

from __future__ import annotations

import asyncio
import importlib.util
import os
import sys
import tempfile
from pathlib import Path

if importlib.util.find_spec("textual") is None:
    print("skip: textual not installed")
    sys.exit(0)

REPO_ROOT = Path(__file__).parents[1]
BIN_DIR = REPO_ROOT / "bin"
FIXTURE = Path(__file__).parent / "fixtures" / "fm-bridge-console" / "fm-bridge-snapshot.sample.json"
# Scratch by default so an ordinary test run never dirties the tracked tree.
# Set FM_BRIDGE_SCREENSHOT_DIR to a real path to (re)generate committed PR
# evidence, e.g. docs/verification/fm-bridge-console/.
SCREENSHOT_DIR = Path(os.environ.get("FM_BRIDGE_SCREENSHOT_DIR") or tempfile.mkdtemp(prefix="fm-bridge-pilot-"))

_spec = importlib.util.spec_from_file_location("fm_bridge_console", BIN_DIR / "fm-bridge-console.py")
console = importlib.util.module_from_spec(_spec)
sys.modules["fm_bridge_console"] = console
_spec.loader.exec_module(console)


class InboxLog:
    """Tracks what the fake --inbox-cmd stub has been told to queue.

    `new_text()` returns only what landed since the last call, so each
    assertion checks exactly the action that was just performed instead of
    the whole run's history.
    """

    def __init__(self, path: Path) -> None:
        self.path = path
        self._pos = 0

    def _read(self) -> str:
        return self.path.read_text() if self.path.exists() else ""

    def new_text(self) -> str:
        text = self._read()
        added = text[self._pos :]
        self._pos = len(text)
        return added

    async def wait_for(self, expected: str, timeout: float = 2.0) -> str:
        """Poll for `expected` to land, since queueing runs in a worker thread.

        `_queue_note` shells out to the fake --inbox-cmd stub from a
        `run_worker(thread=True, ...)` background thread, so the write can
        land a few event-loop turns after the confirming click/keypress
        returns. Cancel paths never start that worker at all, so callers
        checking "nothing was queued" can read `new_text()` directly with no
        wait.
        """
        loop = asyncio.get_event_loop()
        deadline = loop.time() + timeout
        collected = ""
        while True:
            collected += self.new_text()
            if expected in collected or loop.time() >= deadline:
                return collected
            await asyncio.sleep(0.02)


async def _type(pilot, text: str) -> None:
    for ch in text:
        await pilot.press("space" if ch == " " else ch)


def _screen_name(app) -> str:
    return app.screen.__class__.__name__


async def _settle(pilot) -> None:
    """Pause for pending messages, then again after a beat.

    Queueing a note and dismissing a modal both hop through a background
    worker thread (`_queue_note`, `push_screen` callbacks), so a single
    `pilot.pause()` right after the triggering key/click can race ahead of
    the work it is meant to wait for.
    """
    await pilot.pause()
    await asyncio.sleep(0.05)
    await pilot.pause()


async def _run(fake_peek: Path, fake_inbox: Path, inbox: InboxLog) -> None:
    SCREENSHOT_DIR.mkdir(parents=True, exist_ok=True)
    args = console.parse_args(
        [
            "--snapshot-file",
            str(FIXTURE),
            "--interval",
            "999",
            "--peek-cmd",
            str(fake_peek),
            "--inbox-cmd",
            str(fake_inbox),
        ]
    )
    app = console.BridgeConsole(args)
    async with app.run_test(size=(120, 40)) as pilot:
        await _settle(pilot)
        await asyncio.sleep(0.3)
        await _settle(pilot)

        table = app.query_one("#fleet-table")
        assert table.row_count == 4, f"expected 4 fleet rows, got {table.row_count}"

        header = app.query_one("#header-bar")
        assert "landons-mac-mini" in str(header.content), header.content

        quota = app.query_one("#quota-strip")
        assert "claude" in str(quota.content), quota.content
        assert "attention" in str(quota.content), quota.content

        app.save_screenshot(str(SCREENSHOT_DIR / "main-screen.svg"))

        await pilot.press("p")
        await asyncio.sleep(0.2)
        await _settle(pilot)
        assert _screen_name(app) == "MessageModal", app.screen
        app.save_screenshot(str(SCREENSHOT_DIR / "peek-modal.svg"))
        await pilot.press("escape")
        await _settle(pilot)

        # -- U: take_upstream -> ConfirmModal directly ------------------------
        expected_u = console.lib.queue_note_text("take_upstream")

        await pilot.press("U")
        await _settle(pilot)
        assert _screen_name(app) == "ConfirmModal", app.screen
        hint = app.screen.query_one(".modal-hint")
        assert "Tab" in str(hint.content) and "Enter" in str(hint.content), hint.content
        app.save_screenshot(str(SCREENSHOT_DIR / "confirm-modal.svg"))
        await pilot.click("#confirm-yes")
        await _settle(pilot)
        assert len(app.screen_stack) == 1, "ConfirmModal should be dismissed after clicking Queue it"
        assert expected_u in await inbox.wait_for(expected_u), "U + click Queue it must queue the take-upstream note"

        await pilot.press("U")
        await _settle(pilot)
        assert _screen_name(app) == "ConfirmModal", app.screen
        await pilot.press("enter")  # confirm-yes is auto-focused
        await _settle(pilot)
        assert len(app.screen_stack) == 1, "ConfirmModal should be dismissed after Enter on Queue it"
        assert expected_u in await inbox.wait_for(expected_u), "U + keyboard Enter must queue the take-upstream note"

        await pilot.press("U")
        await _settle(pilot)
        assert _screen_name(app) == "ConfirmModal", app.screen
        await pilot.click("#confirm-no")
        await _settle(pilot)
        assert len(app.screen_stack) == 1, "ConfirmModal should be dismissed after clicking Cancel"
        assert inbox.new_text() == "", "U + click Cancel must not queue anything"

        await pilot.press("U")
        await _settle(pilot)
        assert _screen_name(app) == "ConfirmModal", app.screen
        await pilot.press("tab")  # confirm-yes -> confirm-no
        await pilot.press("enter")
        await _settle(pilot)
        assert len(app.screen_stack) == 1, "ConfirmModal should be dismissed after Tab+Enter on Cancel"
        assert inbox.new_text() == "", "U + keyboard Tab+Enter Cancel must not queue anything"

        # -- s: ask_firstmate -> TextInputModal -> ConfirmModal ---------------
        await pilot.press("s")
        await _settle(pilot)
        assert _screen_name(app) == "TextInputModal", app.screen
        await _type(pilot, "click ask")
        await pilot.click("#text-ok")
        await _settle(pilot)
        assert _screen_name(app) == "ConfirmModal", app.screen
        expected_s_click = console.lib.queue_note_text("ask_firstmate", text="click ask")
        await pilot.click("#confirm-yes")
        await _settle(pilot)
        assert len(app.screen_stack) == 1
        assert expected_s_click in await inbox.wait_for(expected_s_click), "s completed by click must queue the typed ask"

        await pilot.press("s")
        await _settle(pilot)
        assert _screen_name(app) == "TextInputModal", app.screen
        await _type(pilot, "kbd ask")
        await pilot.press("enter")  # Input.Submitted -> next modal
        await _settle(pilot)
        assert _screen_name(app) == "ConfirmModal", app.screen
        expected_s_kbd = console.lib.queue_note_text("ask_firstmate", text="kbd ask")
        await pilot.press("enter")  # confirm-yes auto-focused
        await _settle(pilot)
        assert len(app.screen_stack) == 1
        assert expected_s_kbd in await inbox.wait_for(expected_s_kbd), "s completed by keyboard must queue the typed ask"

        await pilot.press("s")
        await _settle(pilot)
        assert _screen_name(app) == "TextInputModal", app.screen
        await _type(pilot, "should not queue")
        await pilot.click("#text-cancel")
        await _settle(pilot)
        assert len(app.screen_stack) == 1, "TextInputModal should be dismissed after clicking Cancel"
        assert inbox.new_text() == "", "s + click Cancel must not queue anything"

        await pilot.press("s")
        await _settle(pilot)
        assert _screen_name(app) == "TextInputModal", app.screen
        await _type(pilot, "should not queue either")
        await pilot.press("tab")  # input -> text-ok
        await pilot.press("tab")  # text-ok -> text-cancel
        await pilot.press("enter")
        await _settle(pilot)
        assert len(app.screen_stack) == 1, "TextInputModal should be dismissed after Tab+Tab+Enter on Cancel"
        assert inbox.new_text() == "", "s + keyboard Cancel must not queue anything"

        # -- /: route -> SelectModal -> TextInputModal -> ConfirmModal --------
        await pilot.press("slash")
        await _settle(pilot)
        assert _screen_name(app) == "SelectModal", app.screen
        select_list = app.screen.query_one("#select-list")
        assert [item.name for item in select_list.children] == ["main", "fleet-secondmate"]
        await pilot.click(select_list.children[0])  # "main"
        await _settle(pilot)
        assert _screen_name(app) == "TextInputModal", app.screen
        await _type(pilot, "click route")
        await pilot.click("#text-ok")
        await _settle(pilot)
        assert _screen_name(app) == "ConfirmModal", app.screen
        expected_route_click = console.lib.queue_note_text("route", target="main", text="click route")
        await pilot.click("#confirm-yes")
        await _settle(pilot)
        assert len(app.screen_stack) == 1
        assert expected_route_click in await inbox.wait_for(expected_route_click), "/ completed by click must queue the routed note"

        await pilot.press("slash")
        await _settle(pilot)
        assert _screen_name(app) == "SelectModal", app.screen
        select_list = app.screen.query_one("#select-list")
        await pilot.press("down")  # main -> fleet-secondmate
        await pilot.press("enter")  # select highlighted item
        await _settle(pilot)
        assert _screen_name(app) == "TextInputModal", app.screen
        await _type(pilot, "kbd route")
        await pilot.press("enter")
        await _settle(pilot)
        assert _screen_name(app) == "ConfirmModal", app.screen
        expected_route_kbd = console.lib.queue_note_text("route", target="fleet-secondmate", text="kbd route")
        await pilot.press("enter")
        await _settle(pilot)
        assert len(app.screen_stack) == 1
        assert expected_route_kbd in await inbox.wait_for(expected_route_kbd), "/ completed by keyboard must queue the routed note"

        await pilot.press("slash")
        await _settle(pilot)
        assert _screen_name(app) == "SelectModal", app.screen
        await pilot.click("#select-cancel")
        await _settle(pilot)
        assert len(app.screen_stack) == 1, "SelectModal should be dismissed after clicking Cancel"
        assert inbox.new_text() == "", "/ + click Cancel must not queue anything"

        await pilot.press("slash")
        await _settle(pilot)
        assert _screen_name(app) == "SelectModal", app.screen
        await pilot.press("tab")  # list -> select-cancel
        await pilot.press("enter")
        await _settle(pilot)
        assert len(app.screen_stack) == 1, "SelectModal should be dismissed after Tab+Enter on Cancel"
        assert inbox.new_text() == "", "/ + keyboard Cancel must not queue anything"

        # -- f: propose_restart on the selected fleet row -> ConfirmModal -----
        table.cursor_coordinate = (0, 0)  # "cim-signal" per the fixture's row order
        await _settle(pilot)
        expected_f = console.lib.queue_note_text("propose_restart", target="cim-signal")

        await pilot.press("f")
        await _settle(pilot)
        assert _screen_name(app) == "ConfirmModal", app.screen
        await pilot.click("#confirm-yes")
        await _settle(pilot)
        assert len(app.screen_stack) == 1
        assert expected_f in await inbox.wait_for(expected_f), "f completed by click must queue the restart proposal"

        await pilot.press("f")
        await _settle(pilot)
        assert _screen_name(app) == "ConfirmModal", app.screen
        await pilot.press("enter")
        await _settle(pilot)
        assert len(app.screen_stack) == 1
        assert expected_f in await inbox.wait_for(expected_f), "f completed by keyboard must queue the restart proposal"

        await pilot.press("f")
        await _settle(pilot)
        assert _screen_name(app) == "ConfirmModal", app.screen
        await pilot.click("#confirm-no")
        await _settle(pilot)
        assert len(app.screen_stack) == 1
        assert inbox.new_text() == "", "f + click Cancel must not queue anything"

        await pilot.press("f")
        await _settle(pilot)
        assert _screen_name(app) == "ConfirmModal", app.screen
        await pilot.press("tab")
        await pilot.press("enter")
        await _settle(pilot)
        assert len(app.screen_stack) == 1
        assert inbox.new_text() == "", "f + keyboard Cancel must not queue anything"


def main() -> int:
    scratch = Path(tempfile.mkdtemp(prefix="fm-bridge-pilot-fakebin-"))
    os.environ["FM_HOME"] = str(scratch / "fm-home")  # never touch a real fleet home

    fake_peek = scratch / "fake-peek.sh"
    fake_peek.write_text("#!/usr/bin/env bash\necho \"fake pane tail for $1\"\n")
    fake_peek.chmod(0o755)

    inbox_log = scratch / "inbox.log"
    fake_inbox = scratch / "fake-inbox.sh"
    fake_inbox.write_text(f'#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "{inbox_log}"\n')
    fake_inbox.chmod(0o755)
    inbox = InboxLog(inbox_log)

    asyncio.run(_run(fake_peek, fake_inbox, inbox))
    print(
        "ok - fm-bridge-console pilot: main screen and peek modal render; "
        "U/s//f dialog chains complete and cancel by click and by keyboard, "
        "queueing exactly the expected note and nothing on cancel"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
