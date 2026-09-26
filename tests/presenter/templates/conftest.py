"""Make the sibling ``presenter`` namespace package importable from tests.

``presenter`` currently has no top-level ``__init__.py`` (owned by a
parallel lane), so it is a PEP 420 namespace package: it only needs the
repo root on ``sys.path`` to import, which this conftest guarantees
regardless of the pytest invocation's current working directory.
"""

from __future__ import annotations

import sys
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parents[3]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))
