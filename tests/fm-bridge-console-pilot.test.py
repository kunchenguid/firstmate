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


async def _run(fake_peek: Path) -> None:
    SCREENSHOT_DIR.mkdir(parents=True, exist_ok=True)
    args = console.parse_args(
        [
            "--snapshot-file",
            str(FIXTURE),
            "--interval",
            "999",
            "--peek-cmd",
            str(fake_peek),
        ]
    )
    app = console.BridgeConsole(args)
    async with app.run_test(size=(120, 40)) as pilot:
        await pilot.pause()
        await asyncio.sleep(0.3)
        await pilot.pause()

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
        await pilot.pause()
        assert app.screen.__class__.__name__ == "MessageModal", app.screen
        app.save_screenshot(str(SCREENSHOT_DIR / "peek-modal.svg"))
        await pilot.press("escape")
        await pilot.pause()

        # A queued key must confirm before anything is sent.
        await pilot.press("U")
        await pilot.pause()
        assert app.screen.__class__.__name__ == "ConfirmModal", app.screen


def main() -> int:
    scratch = Path(tempfile.mkdtemp(prefix="fm-bridge-pilot-fakebin-"))
    fake_peek = scratch / "fake-peek.sh"
    fake_peek.write_text("#!/usr/bin/env bash\necho \"fake pane tail for $1\"\n")
    fake_peek.chmod(0o755)

    asyncio.run(_run(fake_peek))
    print("ok - fm-bridge-console pilot: main screen and peek modal render, U key confirms before queueing")
    return 0


if __name__ == "__main__":
    sys.exit(main())
