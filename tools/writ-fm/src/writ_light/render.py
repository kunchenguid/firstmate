"""Ausgabeformat der Regelblöcke — analog Writ (Spezifikation, Abschnitt
"Claude-Code-Integration").
"""

from __future__ import annotations

from .retrieve import Ergebnis

KOPF = "--- REGELN ({treffer} Treffer + {mandatory} mandatory) ---"
FUSS = "--- ENDE REGELN ---"


def regel_block(regel: dict) -> str:
    zeilen = [f"[{regel['id']}]" + (" MANDATORY" if regel.get("mandatory") else "")]
    if regel.get("trigger"):
        zeilen.append(f"WENN: {regel['trigger']}")
    zeilen.append(f"RULE: {regel['statement']}")
    if regel.get("violation"):
        zeilen.append(f"FALSCH: {regel['violation']}")
    if regel.get("correct"):
        zeilen.append(f"RICHTIG: {regel['correct']}")
    return "\n".join(zeilen)


def block(ergebnis: Ergebnis, hinweis: str | None = None,
          mandatory_als_ids: bool = False) -> str:
    """Regelblock. `mandatory_als_ids` gibt die verbindlichen nur als IDs aus.

    Der Schalter ist fuer den UserPromptSubmit-Block da: dort steht ihr
    Wortlaut schon im Session-Start-Block, und ihn je Eingabe zu wiederholen
    kostete 918 von 2000 Tokens (belege/e1-budget-messung.md).

    Die Kopfzeile zaehlt sie trotzdem mit. Sie gelten ja — nur eben nicht
    noch einmal ausgeschrieben. Wuerde dort "0 mandatory" stehen, laese sich
    das als "es gibt keine verbindlichen Regeln", und das waere die
    gefaehrlichste Auskunft, die dieses Werkzeug geben kann.
    """
    teile = [KOPF.format(treffer=len(ergebnis.gerankt), mandatory=len(ergebnis.mandatory))]
    if ergebnis.projekt:
        teile.append(f"Projektbindung: {ergebnis.projekt}")
    if hinweis:
        teile.append(hinweis)
    teile.append("")
    if mandatory_als_ids and ergebnis.mandatory:
        ids = ", ".join(t.regel["id"] for t in ergebnis.mandatory)
        teile.append(f"Verbindlich, unveraendert in Kraft: {ids}")
        teile.append("(Wortlaut steht im Session-Start-Block; erneut holen mit "
                     "`writ-light session-start`)")
        teile.append("")
    sichtbar = ergebnis.gerankt if mandatory_als_ids else ergebnis.alle
    for t in sichtbar:
        teile.append(regel_block(t.regel))
        teile.append("")
    if ergebnis.weggelassen:
        teile.append(f"({ergebnis.weggelassen} weitere Regeln wegen Token-Budget weggelassen)")
    teile.append(FUSS)
    return "\n".join(teile)


def erklaerung(ergebnis: Ergebnis) -> str:
    """Ranking-Diagnose fuer `writ-light query --erklaeren`."""
    zeilen = [f"Projekt: {ergebnis.projekt or '—'}   "
              f"Tokens: {ergebnis.tokens}   weggelassen: {ergebnis.weggelassen}", ""]
    zeilen.append(f"{'#':>2}  {'ID':<22} {'score':>7}  {'bm25':>4} {'vek':>4}  herkunft")
    for i, t in enumerate(ergebnis.mandatory, 1):
        zeilen.append(f"{'M':>2}  {t.regel['id']:<22} {'—':>7}  {'—':>4} {'—':>4}  mandatory")
    for i, t in enumerate(ergebnis.gerankt, 1):
        zeilen.append(
            f"{i:>2}  {t.regel['id']:<22} {t.score:7.4f}  "
            f"{t.rang_bm25 or '—':>4} {t.rang_vektor or '—':>4}  {t.herkunft}")
    return "\n".join(zeilen)
