"""Export des kompletten Regelwerks fuer eine externe Pruefung.

Erzeugt ein in sich geschlossenes Verzeichnis: ein Mensch (oder ein anderes
Modell) soll das Regelwerk beurteilen koennen, ohne dieses Repo, die Datenbank
oder writ-light zu haben.

  README.md     was das ist, Herkunft, Vorbehalte, Lesehinweise
  regeln.md     alle Regeln, nach Domain gruppiert, lesbar
  ketten.md     die Beziehungsgeflechte ("Regelketten") samt Diagrammen
  regeln.json   maschinenlesbar, volle Treue
  regeln.yaml   Gold-Format, wieder einlesbar
"""

from __future__ import annotations

import json
import re
from collections import defaultdict
from pathlib import Path

from . import paths, schema, yamlio

KIND_PFEIL = {
    "DEPENDS_ON": "setzt voraus",
    "SUPPLEMENTS": "ergaenzt",
    "CONFLICTS_WITH": "hebt auf",
}


# ── Daten holen ───────────────────────────────────────────────────────────

def bestand(db: Path | None = None) -> tuple[list[dict], list[dict]]:
    conn = schema.connect(db or paths.db_path())
    try:
        rel = [dict(r) for r in conn.execute(
            "SELECT src, dst, kind FROM relations ORDER BY src, dst")]
        nach_src = defaultdict(list)
        for r in rel:
            nach_src[r["src"]].append({"kind": r["kind"], "dst": r["dst"]})
        regeln = []
        for row in conn.execute("SELECT * FROM rules ORDER BY domain, id"):
            r = dict(row)
            r["mandatory"] = bool(r["mandatory"])
            r["relations"] = nach_src.get(r["id"], [])
            regeln.append(r)
        return regeln, rel
    finally:
        conn.close()


# ── Regelketten ───────────────────────────────────────────────────────────

def ketten(regeln: list[dict], relationen: list[dict]) -> list[list[str]]:
    """Zusammenhangskomponenten ueber alle Beziehungen, Richtung ignoriert.

    Eine Kette ist die Menge von Regeln, die ueber Beziehungen erreichbar sind —
    genau das, was man beim Pruefen am Stueck lesen will.
    """
    nachbarn = defaultdict(set)
    for r in relationen:
        nachbarn[r["src"]].add(r["dst"])
        nachbarn[r["dst"]].add(r["src"])

    gesehen: set[str] = set()
    gefunden: list[list[str]] = []
    for regel in regeln:
        start = regel["id"]
        if start in gesehen or start not in nachbarn:
            continue
        stapel, komponente = [start], []
        gesehen.add(start)
        while stapel:
            aktuell = stapel.pop()
            komponente.append(aktuell)
            for n in sorted(nachbarn[aktuell]):
                if n not in gesehen:
                    gesehen.add(n)
                    stapel.append(n)
        gefunden.append(sorted(komponente))
    gefunden.sort(key=lambda k: (-len(k), k[0]))
    return gefunden


# ── Bestandspruefungen ────────────────────────────────────────────────────
#
# Auswertungen ueber den Regelbestand, nicht ueber die Installation. `doctor`
# nutzt sie mit, der Export weist sie aus.

_DATUM = re.compile(r"\b(\d{4})-(\d{2})-(\d{2})\b|\b(\d{1,2})\.(\d{1,2})\.(\d{4})\b")

# Ein Datum ist meistens eine HERKUNFTSANGABE ("Owner-Freigabe 2026-08-01"),
# keine Frist. Nur Fristen veralten. Ohne diese Unterscheidung meldete der
# Waechter am echten Bestand 3 von 4 Funden falsch — und ein Waechter mit
# Fehlalarmen ist laut RAG-WAECHTER-001 so wertlos wie gar keiner.
HERKUNFTSMARKER = ("freigabe", "owner,", "entscheid", "gemessen", "belegt",
                   "stand", "seit", "aufgeloest", "vom", "beschluss", "anweisung")


def abgelaufene_daten(regeln: list[dict], heute: str) -> list[tuple[str, str, str]]:
    """Regeln mit einer FRIST in der Vergangenheit.

    Gibt (Regel-ID, Datum, Kontext) zurueck. Herkunftsangaben und Datteile in
    Dateinamen werden uebergangen.
    """
    raus = []
    for r in regeln:
        text = " ".join(filter(None, (r.get("trigger"), r.get("statement"),
                                      r.get("violation"), r.get("correct"))))
        for m in _DATUM.finditer(text):
            if m.group(1):
                iso = f"{m.group(1)}-{m.group(2)}-{m.group(3)}"
            else:
                iso = f"{m.group(6)}-{int(m.group(5)):02d}-{int(m.group(4)):02d}"
            vor = text[max(0, m.start() - 45):m.start()].lower()
            nach = text[m.end():m.end() + 2]
            if any(marker in vor for marker in HERKUNFTSMARKER):
                continue
            if vor.endswith("/") or nach.startswith("-"):
                continue  # Teil eines Datei- oder Pfadnamens
            if iso < heute:
                raus.append((r["id"], iso,
                             text[max(0, m.start() - 45):m.end() + 25].replace("\n", " ")))
    return raus


# ── Geheimnis-Pruefung ────────────────────────────────────────────────────

# Der Export verlaesst den Rechner. ENF-SECRET-001 erlaubt Variablennamen, keine
# Werte — das soll jeder Export selbst nachweisen, nicht jemand einmalig von Hand.
VERBOTEN = [
    ("Telegram-Bot-Token", r"\b\d{8,}:[A-Za-z0-9_-]{30,}"),
    ("Hex-Schluessel (32+ Zeichen)", r"\b[A-Fa-f0-9]{32,}\b"),
    ("OpenAI-artiger Schluessel", r"\bsk-[A-Za-z0-9]{20,}"),
    ("GitHub-Token", r"\bgh[pousr]_[A-Za-z0-9]{20,}"),
    ("Base64-Block (40+ Zeichen)", r"\b[A-Za-z0-9+/]{40,}={0,2}\b"),
]
BEMERKENSWERT = [
    ("Variablennamen (erlaubt, Werte waeren es nicht)",
     r"\b[A-Z][A-Z0-9_]{3,}(?:KEY|TOKEN|SECRET|PASS|POOL(?:_\d+)?)\b"),
    ("IP-Adressen", r"\b(?:\d{1,3}\.){3}\d{1,3}\b"),
    ("Telegram-Bot-Namen", r"@[A-Za-z0-9_]+[Bb]ot\b"),
    ("Benutzername in Pfaden", r"/home/[a-z]+"),
]


def geheimnis_pruefung(regeln: list[dict]) -> tuple[list[str], list[tuple[str, list[str]]]]:
    """Gibt (Funde verbotener Muster, bemerkenswerte Funde) zurueck."""
    text = json.dumps(regeln, ensure_ascii=False)
    treffer = [name for name, muster in VERBOTEN if re.search(muster, text)]
    bemerkt = []
    for name, muster in BEMERKENSWERT:
        gefunden = sorted(set(re.findall(muster, text)))
        if gefunden:
            bemerkt.append((name, gefunden))
    return treffer, bemerkt


def _mermaid(kette: list[str], relationen: list[dict]) -> str:
    knoten = set(kette)
    zeilen = ["```mermaid", "graph LR"]
    for r in relationen:
        if r["src"] in knoten and r["dst"] in knoten:
            a, b = r["src"].replace("-", "_"), r["dst"].replace("-", "_")
            zeilen.append(f'  {a}["{r["src"]}"] -->|{KIND_PFEIL[r["kind"]]}| {b}["{r["dst"]}"]')
    zeilen.append("```")
    return "\n".join(zeilen)


# ── Textbausteine ─────────────────────────────────────────────────────────

def _regel_md(r: dict) -> str:
    kopf = f"### `{r['id']}`"
    if r["mandatory"]:
        kopf += "  ·  **VERBINDLICH**"
    zeilen = [kopf, ""]
    merkmale = [f"Schwere {r['severity']}/3"]
    if r["project"]:
        merkmale.append(f"nur im Projekt `{r['project']}`")
    if r["tags"]:
        merkmale.append(f"Schlagworte: {r['tags']}")
    zeilen.append("*" + " · ".join(merkmale) + "*")
    zeilen += ["", f"**WENN** {r['trigger']}", "", f"**DANN** {r['statement']}"]
    if r["violation"]:
        zeilen += ["", f"- Falsch: {r['violation']}"]
    if r["correct"]:
        zeilen += ["", f"- Richtig: {r['correct']}"] if not r["violation"] else [f"- Richtig: {r['correct']}"]
    if r["relations"]:
        zeilen += ["", "Beziehungen: " + ", ".join(
            f"{KIND_PFEIL[x['kind']]} `{x['dst']}`" for x in r["relations"])]
    zeilen += ["", f"<sub>Quelle: `{r['quelle']}`</sub>", ""]
    return "\n".join(zeilen)


def regeln_md(regeln: list[dict]) -> str:
    nach_domain = defaultdict(list)
    for r in regeln:
        nach_domain[r["domain"]].append(r)

    teile = ["# Alle Regeln", "",
             f"{len(regeln)} Regeln in {len(nach_domain)} Domains, "
             f"davon {sum(1 for r in regeln if r['mandatory'])} verbindlich.", "",
             "Verbindliche Regeln werden jeder Session ungerankt vorangestellt. Alle",
             "uebrigen liefert die Suche nur, wenn sie zum jeweiligen Prompt passen.", "",
             "## Inhalt", ""]
    for domain in sorted(nach_domain):
        n = len(nach_domain[domain])
        m = sum(1 for r in nach_domain[domain] if r["mandatory"])
        teile.append(f"- [{domain}](#{domain.replace('_', '-')}) — {n} Regeln"
                     + (f", {m} verbindlich" if m else ""))
    teile.append("")

    for domain in sorted(nach_domain):
        teile += ["---", "", f"## {domain}", ""]
        projekte = {r["project"] for r in nach_domain[domain] if r["project"]}
        if projekte:
            teile += [f"*Projektgebunden: {', '.join(sorted(projekte))}. Diese Regeln "
                      f"erscheinen nur in Sessions, die in diesem Repo arbeiten.*", ""]
        for r in sorted(nach_domain[domain], key=lambda x: x["id"]):
            teile.append(_regel_md(r))
    return "\n".join(teile)


def ketten_md(regeln: list[dict], relationen: list[dict]) -> str:
    nach_id = {r["id"]: r for r in regeln}
    gruppen = ketten(regeln, relationen)
    verbunden = {i for g in gruppen for i in g}
    allein = [r["id"] for r in regeln if r["id"] not in verbunden]

    zaehler = defaultdict(int)
    for r in relationen:
        zaehler[r["kind"]] += 1

    teile = [
        "# Regelketten", "",
        "Eine Kette ist eine Gruppe von Regeln, die ueber Beziehungen zusammenhaengen —",
        "das, was man beim Pruefen am Stueck lesen will. Die Richtung ist hier bewusst",
        "ignoriert: fuer die Beurteilung zaehlt der Zusammenhang, nicht die Pfeilrichtung.", "",
        f"{len(relationen)} Beziehungen verbinden {len(verbunden)} von {len(regeln)} Regeln",
        f"zu {len(gruppen)} Ketten. {len(allein)} Regeln stehen fuer sich.", "",
        "| Art | Bedeutung | Anzahl |", "|---|---|---:|",
        f"| `DEPENDS_ON` | setzt voraus — die Zielregel muss mitgelesen werden | {zaehler['DEPENDS_ON']} |",
        f"| `SUPPLEMENTS` | ergaenzt — praezisiert oder erweitert die Zielregel | {zaehler['SUPPLEMENTS']} |",
        f"| `CONFLICTS_WITH` | hebt auf — gilt statt der Zielregel im engeren Fall | {zaehler['CONFLICTS_WITH']} |",
        "",
        "Nur `DEPENDS_ON` wirkt im Retrieval: die Nachbarn der drei bestplatzierten",
        "Treffer werden angehaengt. `SUPPLEMENTS` und `CONFLICTS_WITH` sind Wissen fuer",
        "den Leser, kein Ranking-Signal.", "",
    ]

    for nr, kette in enumerate(gruppen, 1):
        mand = [i for i in kette if nach_id[i]["mandatory"]]
        domains = sorted({nach_id[i]["domain"] for i in kette})
        teile += ["---", "", f"## Kette {nr} — {len(kette)} Regeln", "",
                  f"*Domains: {', '.join(domains)}"
                  + (f" · verbindlich darin: {', '.join(mand)}" if mand else "") + "*", "",
                  _mermaid(kette, relationen), ""]
        for i in kette:
            r = nach_id[i]
            marke = " **[VERBINDLICH]**" if r["mandatory"] else ""
            teile.append(f"- `{i}`{marke} — {r['trigger'][:100]}")
        teile.append("")

    teile += ["---", "", f"## Ohne Beziehungen ({len(allein)})", "",
              "Nicht zwangslaeufig ein Mangel — viele Regeln stehen sachlich fuer sich.",
              "Beim Pruefen aber die Stelle, an der eine fehlende Verknuepfung auffaellt.", ""]
    for i in allein:
        teile.append(f"- `{i}` ({nach_id[i]['domain']}) — {nach_id[i]['trigger'][:90]}")
    return "\n".join(teile) + "\n"


def _geheimnis_abschnitt(regeln: list[dict]) -> str:
    verboten, bemerkt = geheimnis_pruefung(regeln)
    zeilen = []
    if verboten:
        zeilen += ["> **ACHTUNG — moegliche Zugangsdaten im Export gefunden:**", ""]
        zeilen += [f"> - {name}" for name in verboten]
        zeilen += ["", "> Vor der Weitergabe pruefen und die betroffene Regel bereinigen.", ""]
    else:
        zeilen += ["Automatisch geprueft, **keine Treffer**: keine Bot-Tokens, keine "
                   "Hex- oder Base64-Schluessel, keine API-Schluessel-Muster.", ""]
    if bemerkt:
        zeilen += ["Enthalten sind dagegen — bewusst, weil die Regeln ohne sie nutzlos "
                   "waeren:", "", "| Art | Vorkommen |", "|---|---|"]
        for name, funde in bemerkt:
            gekuerzt = ", ".join(f"`{f}`" for f in funde[:8])
            if len(funde) > 8:
                gekuerzt += f" … (+{len(funde) - 8})"
            zeilen.append(f"| {name} | {gekuerzt} |")
        zeilen += ["", "Variablen**namen** sind erlaubt, ihre Werte waeren es nicht — so "
                   "verlangt es die Regel `ENF-SECRET-001` des Regelwerks selbst."]
    return "\n".join(zeilen)


def _fristen_abschnitt(regeln: list[dict], stand: str) -> str:
    abgelaufen = abgelaufene_daten(regeln, stand)
    if not abgelaufen:
        return ("Automatisch geprueft, **keine abgelaufenen Fristen** zum Stand oben.\n\n"
                "Datumsangaben, die eine Herkunft benennen (\"Owner-Freigabe 2026-08-01\"),\n"
                "gelten dabei nicht als Frist — nur Regeln, deren Gegenstand mit einem\n"
                "Termin verfaellt. `writ-light doctor` prueft dasselbe bei jedem Lauf.")
    zeilen = ["Diese Regeln nennen eine Frist, die zum Stand oben bereits vergangen ist —",
              "sie koennten gegenstandslos geworden sein:", ""]
    for rid, datum, kontext in abgelaufen:
        zeilen.append(f"- `{rid}` ({datum}) — …{kontext.strip()}…")
    return "\n".join(zeilen)


def readme_md(regeln: list[dict], relationen: list[dict], stand: str) -> str:
    nach_domain = defaultdict(int)
    for r in regeln:
        nach_domain[r["domain"]] += 1
    projekte = sorted({r["project"] for r in regeln if r["project"]})
    mand = [r["id"] for r in regeln if r["mandatory"]]
    geheimnisse = _geheimnis_abschnitt(regeln)
    fristen = _fristen_abschnitt(regeln, stand)

    return f"""# Regelwerk — Export zur externen Pruefung

Stand: **{stand}**. Erzeugt mit `writ-light export` auf dem Laptop des Owners.

## Worum es geht

Dieses Regelwerk steuert KI-Programmiersessions auf einem Entwickler-Laptop. Statt
alle Regeln in jede Sitzung zu kopieren, sucht ein Werkzeug (`writ-light`) pro
Eingabe die passenden heraus: Volltextsuche und Vektorsuche, zusammengefuehrt, dazu
die direkten Nachbarn der besten Treffer. Eine kleine Menge Regeln ist als
**verbindlich** markiert und wird immer mitgeliefert, ungerankt.

Die Regeln stammen aus gewachsenen Arbeitsdokumenten (Arbeitsregeln, ein
Erfahrungsbuch, Projekt-Dossiers) und wurden am 2026-08-02 in dieses strukturierte
Format ueberfuehrt.

## Zahlen

| | |
|---|---:|
| Regeln | {len(regeln)} |
| davon verbindlich | {len(mand)} |
| Beziehungen | {len(relationen)} |
| Domains | {len(nach_domain)} |
| projektgebundene Regeln | {sum(1 for r in regeln if r['project'])} |

Verbindlich sind: {', '.join(f'`{i}`' for i in sorted(mand))}.

Projektgebundene Regeln gibt es fuer: {', '.join(f'`{p}`' for p in projekte)}.
Sie erscheinen ausschliesslich in Sitzungen, die im jeweiligen Repo arbeiten —
das soll verhindern, dass Wissen ueber ein Projekt in ein anderes einsickert.

## Die Dateien

| Datei | Inhalt |
|---|---|
| `regeln.md` | Alle Regeln, nach Domain gruppiert, zum Lesen |
| `ketten.md` | Die Beziehungsgeflechte samt Diagrammen |
| `regeln.json` | Maschinenlesbar, volle Treue |
| `regeln.yaml` | Quellformat, wieder einlesbar |

## Aufbau einer Regel

Jede Regel hat einen **Ausloeser** (wann sie gilt) und eine **Aussage** (was dann zu
tun ist), dazu meist ein Negativ- und ein Positivbeispiel. Der Ausloeser ist nicht
Deko: er ist der Text, gegen den gesucht wird. Eine Regel mit vagem Ausloeser wird
schlecht gefunden, egal wie gut ihre Aussage ist.

Die Schwere (1–3) ist ein schwaches Ranking-Signal, keine Rangordnung der
Wichtigkeit. Verbindlichkeit ist die eigentliche Aussage darueber.

## Wonach eine Pruefung sinnvollerweise sucht

- **Widersprueche**, die nicht als `CONFLICTS_WITH` modelliert sind.
- **Ausloeser, die zu vage sind**, um die Regel zur richtigen Zeit zu finden — oder
  so eng, dass sie den eigentlichen Fall verfehlen.
- **Regeln, die dasselbe zweimal sagen**, in verschiedenen Domains.
- **Verbindliche Regeln, die es nicht sein muessten** (jede kostet Platz in jeder
  Sitzung) — und umgekehrt Regeln, deren stilles Wegfallen echten Schaden anrichtet.
- **Fehlende Beziehungen**: Regeln, die einander voraussetzen, ohne es zu sagen.
- **Zeitgebundenes**, das als Dauerregel formuliert ist.

## Was an Betriebsdaten drinsteht

Dieser Abschnitt wird bei jedem Export neu erzeugt, nicht von Hand gepflegt.

{geheimnisse}

## Zeitgebundene Regeln

{fristen}

## Vorbehalte

- Der Export ist eine Momentaufnahme. Er wird nicht automatisch aktualisiert;
  `writ-light export` erzeugt ihn neu.
- Die deutschen Umlaute sind uneinheitlich: teils `ae/oe/ue`, teils echte Umlaute.
  Das ist gewachsen und kein inhaltlicher Unterschied.
- Der Regelbestand ist gewachsen, nicht am Reissbrett entworfen. Manche Regeln sind
  Niederschlaege einzelner Vorfaelle und entsprechend eng formuliert.
"""


# ── Schreiben ─────────────────────────────────────────────────────────────

def _yaml_gesamt(regeln: list[dict], stand: str) -> str:
    kopf = (f"# Regelwerk-Export, Stand {stand}\n"
            f"# {len(regeln)} Regeln. Wieder einlesbar mit `writ-light ingest`.\n"
            f"#\n"
            f"# Hier stehen alle Regeln in EINER Datei; im Repo liegen sie nach Herkunft\n"
            f"# getrennt. Deshalb tragen sie hier `project` und `quelle` ausdruecklich —\n"
            f"# in den Herkunftsdateien ist beides implizit. Ohne diese zwei Felder wuerde\n"
            f"# ein Rueckspielen saemtliche Projektbindungen aufloesen.\n\n")
    return kopf + "rules:\n\n" + "\n\n".join(
        yamlio.regel_block(r, mit_herkunft=True) for r in regeln) + "\n"


def schreiben(ziel: Path, db: Path | None = None, stand: str = "") -> dict:
    regeln, relationen = bestand(db)
    if not regeln:
        raise ValueError("Keine Regeln in der Datenbank — erst `writ-light ingest`")
    ziel.mkdir(parents=True, exist_ok=True)

    dateien = {
        "README.md": readme_md(regeln, relationen, stand),
        "regeln.md": regeln_md(regeln),
        "ketten.md": ketten_md(regeln, relationen),
        "regeln.json": json.dumps(regeln, ensure_ascii=False, indent=2) + "\n",
        "regeln.yaml": _yaml_gesamt(regeln, stand),
    }
    for name, inhalt in dateien.items():
        (ziel / name).write_text(inhalt, encoding="utf-8")

    return {
        "ziel": ziel,
        "regeln": len(regeln),
        "beziehungen": len(relationen),
        "ketten": len(ketten(regeln, relationen)),
        "dateien": sorted(dateien),
    }
