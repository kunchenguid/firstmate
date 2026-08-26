"""Testisolation der Vendor-Suite (Firstmate-Portierung).

Die Suite lief auf dem Alt-Laptop gegen einen exklusiven XDG-Store. Im
Firstmate-Repo teilt sich derselbe Unix-User einen Live-Store
(state/writ-fm via bin/fm-regeln) und den XDG-Pfad - ohne Isolation
vergiften sich Volllauf-Tests gegenseitig (leere rules.db, fremde
Korpora). Dieses conftest pinnt jede Testsession auf ein frisches
Datenverzeichnis und entfernt Flotten-Umgebung, sofern ein Test nicht
selbst WRIT_DATA_DIR setzt (die Fixtures tun das weiterhin und gewinnen).
"""

import os
import tempfile

import pytest


@pytest.fixture(autouse=True)
def _writ_isolation(request, monkeypatch, tmp_path_factory):
    # test_schema_v2 baut sich seine Flotte selbst (eigene Env-Fixtures,
    # standalone beweisbar hermetisch) - die Pauschal-Isolation wuerde
    # seine Fixture-Verdrahtung ueberdecken.
    if "test_schema_v2" in str(request.node.fspath):
        yield
        return
    if "WRIT_DATA_DIR" not in os.environ:
        monkeypatch.setenv(
            "WRIT_DATA_DIR", str(tmp_path_factory.mktemp("writ-data"))
        )
    monkeypatch.delenv("FM_HOME", raising=False)
    # Pinnen statt loeschen: geloescht griffe die Modulpfad-Ableitung und
    # faende das ECHTE Flotten-Repo (VERFASSUNG.yaml, Ledger) - Tests
    # liefen dann gegen den Live-Bestand. Ein leeres Temp-Root haelt die
    # Flottenseite nachweislich abwesend; Fixtures, die eine Flotte bauen,
    # setzen die Variable selbst und gewinnen (monkeypatch je Test).
    if "WRIT_FLOTTE_ROOT" not in os.environ:
        monkeypatch.setenv(
            "WRIT_FLOTTE_ROOT", str(tmp_path_factory.mktemp("flotte-leer"))
        )
    yield
