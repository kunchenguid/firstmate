"""Die Deckel aus `regeln/VERFASSUNG.yaml` — und die Token-Schaetzung.

Ein Regelwerk waechst; niemand streicht freiwillig. Die Verfassung ist die
Gegenkraft: sie sagt, wie viele Kern- und Kontextregeln ueberhaupt existieren
duerfen. Wer eine neue Kernregel will, muss eine alte abstufen — das erzwingt
der Ingest, nicht die Selbstdisziplin.

Dieses Modul ist der EINZIGE Eigner der Deckelwerte und ihrer Standardwerte.
Fehlt die Datei, gelten die Standardwerte UND es gibt eine Warnung: stillschweigend
mit Standardwerten weiterzurechnen hiesse, einen Deckel zu behaupten, den
niemand beschlossen hat.
"""

from __future__ import annotations

import re
from pathlib import Path

import yaml

from . import fmpfade

# Standardwerte, falls regeln/VERFASSUNG.yaml (noch) fehlt.
STANDARD = {
    "kern_max": 8,
    "kern_token_max": 1200,
    "kontext_max_je_geltung": 12,
    "kontext_max_gesamt": 40,
    "topk": 3,
    "brief_token_max": 600,
    "nogo_zeilen_max_je_brief": 5,
}


class VerfassungsFehler(Exception):
    """Die Verfassung ist da, aber unlesbar oder unsinnig — lauter Abbruch.

    Bewusst KEIN Rueckfall auf die Standardwerte: eine kaputte Verfassung ist
    etwas anderes als eine fehlende. Bei einer fehlenden hat niemand etwas
    beschlossen; bei einer kaputten hat jemand etwas beschlossen, das wir nicht
    verstehen — und dann still den Standardwert zu nehmen hiesse, den Beschluss
    zu ueberschreiben.
    """


def laden(pfad: Path | None = None) -> tuple[dict, list[str]]:
    """(Deckelwerte, Warnungen). Fehlende Datei = Standardwerte + Warnung."""
    pfad = pfad or fmpfade.verfassung_datei()
    if not pfad.exists():
        return dict(STANDARD), [
            f"WARNUNG: {pfad} fehlt — es gelten die Standarddeckel "
            + ", ".join(f"{k}={v}" for k, v in STANDARD.items())
        ]
    try:
        doc = yaml.safe_load(pfad.read_text(encoding="utf-8")) or {}
    except yaml.YAMLError as exc:
        raise VerfassungsFehler(f"{pfad}: nicht lesbar — {exc}") from exc
    if not isinstance(doc, dict):
        raise VerfassungsFehler(f"{pfad}: erwartet wird eine Zuordnung Schluessel -> Zahl")

    werte, warnungen = dict(STANDARD), []
    for schluessel, standard in STANDARD.items():
        if schluessel not in doc:
            warnungen.append(
                f"WARNUNG: {pfad} nennt {schluessel} nicht — Standard {standard} gilt")
            continue
        roh = doc[schluessel]
        if isinstance(roh, bool) or not isinstance(roh, int) or roh < 1:
            raise VerfassungsFehler(
                f"{pfad}: {schluessel}={roh!r} ist keine positive ganze Zahl")
        werte[schluessel] = roh
    unbekannt = sorted(set(doc) - set(STANDARD))
    if unbekannt:
        # Lauter Hinweis statt Abbruch: ein unbekannter Schluessel bindet
        # nichts, aber er sieht so aus, als taete er es — genau die Sorte
        # Deckel, auf die sich jemand verlaesst, obwohl ihn niemand liest.
        warnungen.append(
            f"WARNUNG: {pfad} nennt Schluessel, die kein Deckel sind und nichts "
            f"bewirken: {', '.join(unbekannt)}")
    return werte, warnungen


_WORT = re.compile(r"\S+")


def tokens_schaetzen(text: str) -> int:
    """Token-Schaetzung ohne Tokenizer: Woerter * 1,3, aufgerundet.

    Der echte Tokenizer haengt am ONNX-Modell und damit an einem 90-MB-Download.
    Fuer einen DECKEL reicht die Schaetzung: sie muss reproduzierbar und
    monoton sein, nicht exakt. Wichtig ist nur, dass Ingest und Brief dieselbe
    Formel benutzen — sonst kappt der eine, was der andere gerade durchgelassen
    hat.
    """
    worte = len(_WORT.findall(text or ""))
    return int(worte * 1.3 + 0.999) if worte else 0
