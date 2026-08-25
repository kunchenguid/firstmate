"""Gemeinsames Testwerkzeug: isolierte Datenverzeichnisse, echtes Modell."""

from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
ECHTES_MODELL = Path.home() / ".local/share/writ-light/model"


class TempDatenTest(unittest.TestCase):
    """Legt DB und Index in ein Wegwerf-Verzeichnis, nutzt aber das echte Modell."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self._alt = {k: os.environ.get(k) for k in ("WRIT_DATA_DIR", "WRIT_MODEL_DIR")}
        os.environ["WRIT_DATA_DIR"] = self._tmp.name
        os.environ["WRIT_MODEL_DIR"] = str(ECHTES_MODELL)
        self.tmp = Path(self._tmp.name)

    def tearDown(self) -> None:
        for k, v in self._alt.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self._tmp.cleanup()

    def schreibe_regeln(self, text: str, name: str = "test.yaml") -> Path:
        d = self.tmp / "rules"
        d.mkdir(exist_ok=True)
        p = d / name
        p.write_text(text, encoding="utf-8")
        return d


MINI = """
rules:
  - id: A-EINS-001
    domain: alpha
    severity: 2
    trigger: Ein Commit steht an und die Suite ist rot.
    statement: Nicht committen, erst die Testsuite gruen machen.
    tags: commit, tests
  - id: A-ZWEI-001
    domain: alpha
    severity: 1
    mandatory: true
    trigger: Der Owner soll ueber einen Meilenstein informiert werden.
    statement: Meldung per claw-notify absetzen.
    tags: meldung, telegram
    relations:
      - {kind: SUPPLEMENTS, dst: A-EINS-001}
"""
