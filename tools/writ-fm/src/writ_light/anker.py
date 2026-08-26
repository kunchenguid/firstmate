"""Anker pruefen: gibt es den belegten Fehlerfall, den die Regel behauptet?

Jede Regel nennt entweder einen Anker (Lnn im Lehren-Ledger, HRn in AGENTS.md)
oder eine Quelle (Grundsatz, Order, Captain-Wort). Ohne das eine oder das
andere ist sie eine Meinung.

Die Pruefung ist bewusst textuell und nicht semantisch: sie beantwortet
"existiert L42 ueberhaupt", nicht "passt L42 inhaltlich". Das Erste kann eine
Maschine, das Zweite nicht — und ein Anker, der auf nichts zeigt, ist der
haeufigere Fehler (Tippfehler, umnummeriertes Ledger, kopierte Regel).

Beide Dateien werden je Lauf EINMAL gelesen und gecacht. Ein Ingest prueft
hunderte Anker; ohne Cache liest er das Ledger hunderte Male.
"""

from __future__ import annotations

import re
from pathlib import Path

from . import fmpfade


class AnkerFehler(Exception):
    pass


class Ankerbestand:
    """Welche Anker es gibt — aus Ledger und AGENTS.md, faul gelesen.

    Faul, weil ein Regelwerk ohne Lnn-Anker (alles ueber `quelle` belegt) das
    Ledger gar nicht braucht: dann darf sein Fehlen den Ingest auch nicht
    aufhalten.
    """

    def __init__(self, ledger: Path | None = None, agents: Path | None = None) -> None:
        self.ledger = ledger or fmpfade.ledger_datei()
        self.agents = agents or fmpfade.agents_datei()
        self._lehren: set[str] | None = None
        self._hr: set[str] | None = None

    def _text(self, pfad: Path, wofuer: str) -> str:
        try:
            return pfad.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            raise AnkerFehler(
                f"{wofuer} nicht lesbar ({pfad}): {exc} — ohne sie laesst sich kein "
                f"Anker pruefen. Pfad setzbar ueber WRIT_LEDGER_PATH bzw. WRIT_AGENTS_PATH."
            ) from exc

    def lehren(self) -> set[str]:
        if self._lehren is None:
            self._lehren = set(re.findall(
                r"^### (L\d{2}) ", self._text(self.ledger, "Lehren-Ledger"),
                flags=re.MULTILINE))
        return self._lehren

    def hardening(self) -> set[str]:
        if self._hr is None:
            self._hr = set(re.findall(
                r"HR(\d+)", self._text(self.agents, "AGENTS.md")))
        return self._hr

    def fehlt(self, wert: str) -> str | None:
        """Fehlermeldung, falls der Anker nirgends steht — sonst None."""
        if wert.startswith("L"):
            if wert not in self.lehren():
                return (f"Anker {wert} steht nicht als '### {wert} ' in {self.ledger}")
            return None
        if wert.removeprefix("HR") not in self.hardening():
            return f"Anker {wert} kommt in {self.agents} nicht vor"
        return None
