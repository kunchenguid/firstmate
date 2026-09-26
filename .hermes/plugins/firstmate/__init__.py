"""Firstmate plugin loader for Hermes Agent.

This file is deliberately tiny and stable. It is the only Firstmate file Hermes
discovers, and it may live in two places:

  * ``<firstmate-root>/.hermes/plugins/firstmate/`` - the tracked copy, found by
    Hermes as a project plugin when ``HERMES_ENABLE_PROJECT_PLUGINS=1`` and the
    session runs with the Firstmate home as its working directory;
  * ``$HERMES_HOME/plugins/firstmate/`` - a byte-identical copy installed by
    ``bin/fm-hermes-plugin.sh install``, which is what lets a Hermes worker in
    a project worktree (where the project, not Firstmate, owns ``.hermes/``)
    load Firstmate at all.

Either way the loader only resolves WHICH Firstmate checkout to load, then
imports that checkout's tracked implementation from
``<root>/.hermes/firstmate/plugin.py``. The implementation therefore always
matches the checkout it supervises and updates with ``/updatefirstmate``; an
installed loader never needs reinstalling for a behaviour change.

Root resolution, first match wins, and nothing is ever inferred from a
directory NAME:
  1. this file itself sits inside a Firstmate-shaped root (project mode);
  2. ``FM_HERMES_ROOT`` names a Firstmate-shaped root (set by ``bin/fm-spawn.sh``
     for every Hermes worker and secondmate it launches);
  3. the current working directory is exactly one of the roots registered in
     the ``roots`` file beside the installed loader (``bin/fm-hermes-plugin.sh
     install`` registers the checkout it ran from). Exact equality, never an
     ancestor match, so a Hermes session started inside ``projects/<clone>``
     never loads the home's primary hooks.

No match leaves the plugin inert: Hermes keeps running exactly as without it.
Every failure is logged and swallowed, because a broken supervisor plugin must
never break the agent session it rides in.
"""

from __future__ import annotations

import importlib.util
import logging
import os
import sys
from pathlib import Path

LOADER_VERSION = 1

logger = logging.getLogger("hermes_plugins.firstmate")


def _firstmate_root(candidate: Path) -> bool:
    try:
        return (
            (candidate / ".hermes" / "firstmate" / "plugin.py").is_file()
            and (candidate / "bin" / "fm-session-start.sh").is_file()
            and (candidate / "AGENTS.md").is_file()
        )
    except OSError:
        return False


def _real(path: str | os.PathLike) -> Path:
    try:
        return Path(path).resolve()
    except OSError:
        return Path(os.path.abspath(path))


def _registered_roots() -> list[Path]:
    registry = Path(__file__).resolve().parent / "roots"
    try:
        lines = registry.read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    roots = []
    for line in lines:
        line = line.strip()
        if line and not line.startswith("#") and os.path.isabs(line):
            roots.append(_real(line))
    return roots


def resolve_root() -> Path | None:
    here = Path(__file__).resolve().parent
    # <root>/.hermes/plugins/firstmate/__init__.py
    if here.name == "firstmate" and here.parent.name == "plugins" and here.parent.parent.name == ".hermes":
        candidate = here.parent.parent.parent
        if _firstmate_root(candidate):
            return candidate
    env_root = os.environ.get("FM_HERMES_ROOT", "").strip()
    if env_root and os.path.isabs(env_root):
        candidate = _real(env_root)
        if _firstmate_root(candidate):
            return candidate
    try:
        cwd = _real(os.getcwd())
    except OSError:
        return None
    for candidate in _registered_roots():
        if candidate == cwd and _firstmate_root(candidate):
            return candidate
    return None


def _load_implementation(root: Path):
    source = root / ".hermes" / "firstmate" / "plugin.py"
    name = "firstmate_hermes_impl"
    package_dir = str(source.parent)
    if package_dir not in sys.path:
        sys.path.insert(0, package_dir)
    spec = importlib.util.spec_from_file_location(name, source)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load {source}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def register(ctx) -> None:
    try:
        root = resolve_root()
        if root is None:
            return
        impl = _load_implementation(root)
        impl.register(ctx, root=root, loader_version=LOADER_VERSION)
    except Exception:  # noqa: BLE001 - never break the host session
        logger.warning("firstmate: plugin registration failed; Hermes continues without Firstmate hooks",
                       exc_info=True)
