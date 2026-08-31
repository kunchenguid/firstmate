#!/usr/bin/env python3
"""Stable plugin-local launcher for Firstmate's single handoff mechanics owner."""

from __future__ import annotations

import os
import sys
from pathlib import Path


def main() -> None:
    plugin_root = Path(__file__).resolve().parents[1]
    firstmate_root = plugin_root.parents[1]
    core = firstmate_root / "libexec" / "fm-context-handoff.py"
    if not core.is_file():
        raise SystemExit(2)
    os.execv(sys.executable, [sys.executable, "-I", "-S", str(core), *sys.argv[1:]])


if __name__ == "__main__":
    main()
