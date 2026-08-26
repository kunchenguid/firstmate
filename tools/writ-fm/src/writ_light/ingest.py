"""Ingest: YAML-Regeldateien -> SQLite + FTS5 + hnswlib.

Idempotent: jeder Lauf baut komplett neu auf (Spezifikation, Abschnitt
"Ingest-Workflow"). Eine Regeldatei im Schema v2 sieht so aus:

    project: rag-digital          # optional, gilt fuer alle Regeln der Datei
    repo: ~/projects/rag-digital  # optional, fuellt die Tabelle projects
    rules:
      - id: RAG-MOCK-001
        domain: rag-digital
        severity: 2
        geltung: worker           # flotte|firstmate|secondmate|worker|projekt:<name>
        verbindlichkeit: kontext  # kern|kontext|hinweis
        anker: [L03]              # Lnn/HRn — leer nur mit `quelle`
        quelle: order:O-0018      # optional, wenn `anker` gesetzt ist
        leser: retrieval          # hook:<pfad>|tor:<pfad>|werkzeug:<pfad>|retrieval
        verfall: null             # ISO-Datum oder null
        leiter: "…"               # Stufe-4-Begruendung, optional
        status: aktiv             # aktiv|abgelaufen|hinweis-abgestuft
        trigger: ...
        statement: ...
        relations:
          - {kind: SUPPLEMENTS, dst: LEK-VERIFY-001}

Der YAML-Schluessel `quelle` traegt die HERKUNFT DES WORTLAUTS und landet in
der Spalte `nachweis`. Die Herkunftsdatei (Spalte `quelle`) ergibt sich aus dem
Dateipfad und laesst sich nur noch mit `herkunftsdatei:` ueberschreiben — bis
zum Schema v2 hiess dieser Schluessel `quelle`, und beide Bedeutungen unter
einem Namen waeren genau die zweite Wahrheit, gegen die das Regelwerk antritt.
Eine Datei im alten Format faellt deshalb LAUT durch die Nachweis-Pruefung.

Die Validierung bricht ab, statt zu warnen (L33): eine Regel, die es nicht in
den Bestand schafft, ist sichtbar; eine Regel, die stillschweigend ohne Geltung
oder ohne Anker im Bestand steht, bindet niemanden und niemand merkt es.
Einzige Ausnahme ist der Verfall — siehe `verfall_anwenden`.

KOMPATIBILITAETSVERTRAG v1 (Legacy-Modus)
-----------------------------------------
Das Schema v2 gilt JE REGEL, nicht je Bestand. Eine Regel ist v2, sobald sie
eines der Felder aus `schema.V2_MARKER` traegt oder ihre Datei `schema: v2` auf
oberster Ebene deklariert. Alles andere ist eine v1-Regel und wird ausdruecklich
weiter angenommen — bewusst, nicht aus Versehen:

  * Ohne diesen Modus muesste JEDER Bestand an einem Tag komplett umziehen.
    Bis dahin liefe kein Ingest, also auch keine Zustellung — der Umbau selbst
    wuerde die Flotte regellos machen, und das ist teurer als eine Uebergangszeit.
  * Zugestellt wird eine v1-Regel trotzdem. Sie bekommt Vorgaben, damit die
    Spalten belegt sind: geltung=flotte, verbindlichkeit=kern falls `mandatory`
    gesetzt ist sonst kontext, leser=retrieval, anker=[], quelle/nachweis=None,
    verfall=None, status=aktiv.
  * Die Vorgaben sind AUSSAGELOS, keine Behauptung. Deshalb ist eine v1-Regel
    von den v2-Pruefungen ausgenommen: Anker-Existenz, "kern verlangt einen
    benannten Leser", die Kern- und Kontext-Deckel und die CONFLICTS-Paarpruefung
    unter Kernregeln gelten nur fuer v2-Regeln. Andernfalls entschiede die
    Vorgabe `verbindlichkeit=kern` (aus einem alten `mandatory: true`) darueber,
    ob der Kerndeckel reisst — ein Deckel, der auf abgeleitete Werte reagiert,
    misst nichts.
  * `ingest --strikt-v2` (Parameter `strikt_v2=True`) schaltet den Legacy-Modus
    ab: dann ist jede v1-Regel ein Abbruch mit Datei und ID. Die Flotten-
    Regelquelle `regeln/` laeuft immer so — `bin/fm-regeln` haengt das Flag an.

Der Vertrag endet, wenn kein Bestand mehr v1-Regeln haelt; bis dahin ist er
Teil des Werkzeugs und nicht eine stille Nachsicht der Validierung.
"""

from __future__ import annotations

import datetime
import sqlite3
from pathlib import Path

import yaml

from . import anker as ankermodul
from . import embed, fmpfade, paths, schema, verfassung

VALID_KINDS = {"DEPENDS_ON", "CONFLICTS_WITH", "SUPPLEMENTS"}

# Ohne diese Felder ist eine Regel nicht zustellbar: Geltung sagt WEN sie
# bindet, Verbindlichkeit WIE sie zugestellt wird, Leser WO sie wirkt.
PFLICHTFELDER = ("geltung", "verbindlichkeit", "leser")


class IngestError(Exception):
    pass


def _clean(value) -> str:
    """Gefaltete YAML-Skalare (`>`) tragen einen Zeilenumbruch am Ende."""
    if value is None:
        return ""
    return str(value).strip()


def _heute() -> str:
    return datetime.date.today().isoformat()


def _anker_liste(roh, wo: str) -> list[str]:
    if roh is None:
        return []
    if isinstance(roh, str):
        roh = [roh]
    if not isinstance(roh, list):
        raise IngestError(f"{wo}: anker muss eine Liste sein, nicht {type(roh).__name__}")
    werte = [_clean(x) for x in roh]
    return [w for w in werte if w]


def _verfall(roh, wo: str) -> str | None:
    if roh is None or roh == "":
        return None
    if isinstance(roh, datetime.datetime):
        roh = roh.date()
    if isinstance(roh, datetime.date):
        return roh.isoformat()
    text = _clean(roh)
    try:
        datetime.date.fromisoformat(text)
    except ValueError as exc:
        raise IngestError(f"{wo}: verfall {text!r} ist kein ISO-Datum") from exc
    return text


def ist_v2(raw: dict, datei_v2: bool = False) -> bool:
    """Steht diese Regel im Schema v2? (Kompatibilitaetsvertrag im Kopf)

    Geprueft wird die ANWESENHEIT des Schluessels, nicht sein Wert: `verfall:
    null` oder `anker: []` sind Aussagen im Schema v2 und sollen als solche
    gelesen werden. Eine v1-Regel traegt keines dieser Felder ueberhaupt.
    """
    return datei_v2 or any(feld in raw for feld in schema.V2_MARKER)


def load_file(path: Path, strikt_v2: bool = False) -> tuple[list[dict], dict]:
    """Liest eine Regeldatei. Gibt (Regeln, Projekt-Metadaten) zurueck."""
    with path.open(encoding="utf-8") as fh:
        doc = yaml.safe_load(fh) or {}
    if not isinstance(doc, dict) or "rules" not in doc:
        raise IngestError(f"{path}: Schluessel 'rules' fehlt")

    project = doc.get("project")
    meta = {}
    if project:
        meta = {"id": project, "repo_path": _expand(doc.get("repo"))}

    # `schema: v2` im Dateikopf bindet ALLE Regeln der Datei — der Weg, eine
    # fertig umgestellte Datei gegen ein Zurueckfallen einzelner Regeln in den
    # Legacy-Modus zu sichern.
    datei_v2 = _clean(doc.get("schema")).lower() == "v2"

    quelle = _relative(path)
    out = []
    for raw in doc["rules"] or []:
        if not raw.get("id"):
            raise IngestError(f"{path}: Regel ohne id")
        wo = f"{path}: {raw['id']}"
        rel = []
        for r in raw.get("relations") or []:
            kind = r.get("kind")
            if kind not in VALID_KINDS:
                raise IngestError(f"{raw['id']}: unbekannte Beziehung {kind!r}")
            rel.append({"kind": kind, "dst": r["dst"]})

        fassung = "v2" if ist_v2(raw, datei_v2) else "v1"
        if fassung == "v1" and strikt_v2:
            raise IngestError(
                f"{wo}: Regel steht im alten Schema v1, --strikt-v2 verlangt v2 — "
                f"Pflichtfelder {', '.join(PFLICHTFELDER)} eintragen (oder "
                f"`schema: v2` in den Dateikopf)")

        if fassung == "v2":
            for feld in PFLICHTFELDER:
                if not _clean(raw.get(feld)):
                    raise IngestError(f"{wo}: Pflichtfeld {feld} fehlt")
            geltung = _clean(raw.get("geltung"))
            leser = _clean(raw.get("leser"))
            verbindlichkeit = _clean(raw.get("verbindlichkeit"))
            status = _clean(raw.get("status")) or "aktiv"
            anker = _anker_liste(raw.get("anker"), wo)
            nachweis = _clean(raw.get("quelle")) or None
            verfall = _verfall(raw.get("verfall"), wo)
            leiter = _clean(raw.get("leiter")) or None
            # `mandatory` ist im Schema v2 kein eigener Fakt mehr, sondern die
            # alte Schreibweise fuer verbindlichkeit=kern. Es bleibt als Spalte,
            # weil Oberflaeche und Export es lesen — aber abgeleitet, nie doppelt
            # gepflegt. Ein widersprechendes `mandatory:` ist ein Abbruch und kein
            # Vorrang, denn welcher der beiden Werte gilt, koennte man nur raten.
            mandatory = 1 if verbindlichkeit == "kern" else 0
            if "mandatory" in raw and bool(raw.get("mandatory")) != bool(mandatory):
                raise IngestError(
                    f"{wo}: mandatory={raw.get('mandatory')!r} widerspricht "
                    f"verbindlichkeit={verbindlichkeit!r} — `mandatory` ist die alte "
                    f"Schreibweise fuer verbindlichkeit: kern und wird abgeleitet")
        else:
            # Legacy-Modus. `mandatory` bleibt hier der gefuehrte Fakt und
            # verbindlichkeit die Ableitung — genau andersherum als in v2.
            mandatory = 1 if raw.get("mandatory") else 0
            geltung = schema.V1_GELTUNG
            leser = schema.V1_LESER
            verbindlichkeit = "kern" if mandatory else "kontext"
            status = schema.V1_STATUS
            anker, nachweis, verfall, leiter = [], None, None, None

        out.append({
            "id": raw["id"].strip(),
            "domain": _clean(raw.get("domain")) or "allgemein",
            "severity": int(raw.get("severity", 2)),
            "mandatory": mandatory,
            "trigger": _clean(raw.get("trigger")),
            "statement": _clean(raw.get("statement")),
            "violation": _clean(raw.get("violation")),
            "correct": _clean(raw.get("correct")),
            "tags": _clean(raw.get("tags")),
            "confidence": float(raw.get("confidence", 1.0)),
            "project": raw.get("project", project),
            # Eine Regel darf ihre Herkunftsdatei selbst mitbringen. Ohne das
            # koennte ein Export, der alle Regeln in EINE Datei schreibt, sie
            # nicht zurueckspielen: alle traegen dann diese eine Datei als
            # Quelle, und gezielte Entfernungen nach Herkunft waeren nicht mehr
            # moeglich. Der Schluessel hiess bis Schema v2 `quelle`.
            "quelle": raw.get("herkunftsdatei") or quelle,
            "geltung": geltung,
            "verbindlichkeit": verbindlichkeit,
            "anker": anker,
            "nachweis": nachweis,
            "leser": leser,
            "verfall": verfall,
            "leiter": leiter,
            "status": status,
            # Keine Datenbankspalte: die Fassung ist eine Eigenschaft der
            # QUELLE, und auf dem Rueckweg erkennt `schema.ist_v1_profil` sie
            # aus den Spalten. Eine Spalte waere ein zweiter Ort fuer denselben
            # Fakt — und der eine, der nach einem Handeingriff luegt.
            "regel_schema": fassung,
            "relations": rel,
        })
    return out, meta


def _expand(p) -> str | None:
    return str(Path(str(p)).expanduser()) if p else None


def _relative(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(paths.REPO_ROOT))
    except ValueError:
        return str(path)


# In `regeln/` liegt nicht nur Regelwerk. Die Ausnahme steht NAMENTLICH hier
# und nicht als Heuristik ("Datei ohne rules:-Schluessel ueberspringen") — sonst
# verschwindet eine echte Regeldatei mit vertipptem Schluessel lautlos aus dem
# Bestand, und niemand vermisst, was er nie gesehen hat.
KEINE_REGELDATEIEN = frozenset({"VERFASSUNG.yaml"})


def regeldateien(source: Path) -> list[Path]:
    return [p for p in sorted(source.rglob("*.yaml"))
            if p.name not in KEINE_REGELDATEIEN]


def collect(source: Path, strikt_v2: bool = False) -> tuple[list[dict], list[dict]]:
    """Alle *.yaml unter `source` einlesen (rekursiv, sortiert)."""
    files = regeldateien(source) if source.is_dir() else [source]
    if not files:
        raise IngestError(f"Keine YAML-Dateien unter {source}")
    rules: list[dict] = []
    projects: dict[str, dict] = {}
    for f in files:
        rs, meta = load_file(f, strikt_v2=strikt_v2)
        rules.extend(rs)
        if meta:
            projects[meta["id"]] = meta
    return rules, list(projects.values())


def _wo(r: dict) -> str:
    """Dateiname + Regel-ID — jede Abbruchmeldung muss beides nennen."""
    return f"{r.get('quelle') or '?'}: {r['id']}"


def legacy_auffuellen(regel: dict) -> dict:
    """Fehlende v2-Spalten mit den Legacy-Vorgaben belegen (Vertrag im Kopf).

    Noetig fuer Regeln, die NICHT aus `load_file` kommen: die Weboberflaeche
    schickt beim PUT das alte Feldset, und aus der Datenbank kommen Spalten
    ohne Herkunftsvermerk. Beide Wege landen in `validate` und muessen dort
    dieselbe Fassung erkennen wie der Ingest — sonst gilt eine Regel je nach
    Eingang unterschiedlich viel.
    """
    if regel.get("regel_schema") not in ("v1", "v2"):
        regel["regel_schema"] = "v1" if schema.ist_v1_profil(regel) else "v2"
    if regel["regel_schema"] == "v1":
        regel["geltung"] = schema.V1_GELTUNG
        regel["leser"] = schema.V1_LESER
        regel["status"] = schema.V1_STATUS
        regel["mandatory"] = 1 if regel.get("mandatory") else 0
        regel["verbindlichkeit"] = "kern" if regel["mandatory"] else "kontext"
        regel["anker"] = []
        regel["nachweis"] = regel["verfall"] = regel["leiter"] = None
    else:
        regel["status"] = regel.get("status") or "aktiv"
        regel["anker"] = schema.anker_liste(regel.get("anker"))
        for feld in ("nachweis", "verfall", "leiter"):
            regel[feld] = regel.get(feld) or None
        # Leer statt fehlend: ein halb gefuelltes v2-Feldset soll an
        # `_pruefe_felder` LAUT scheitern ("geltung '' unbekannt") und nicht
        # als KeyError irgendwo im Ingest.
        for feld in PFLICHTFELDER:
            regel[feld] = _clean(regel.get(feld))
        # Ein Eigner je Fakt: in v2 fuehrt `verbindlichkeit`, `mandatory` folgt.
        regel["mandatory"] = 1 if regel["verbindlichkeit"] == "kern" else 0
    return regel


def verfall_anwenden(rules: list[dict], heute: str | None = None) -> list[str]:
    """Abgelaufene Regeln auf status=abgelaufen setzen. WARNT, bricht nie ab.

    Der einzige Befund, der nicht abbricht — und zwar mit Absicht. Ein Verfall
    ist der geplante Normalfall (jede aus einem Einzelfall geborene Regel traegt
    eine Frist). Wuerde er den Ingest anhalten, stuende die Flotte an einem
    Stichtag ohne Regelwerk da, und der naechstliegende Ausweg waere, Fristen
    einfach hochzusetzen. Stattdessen faellt die Regel aus jeder Zustellung und
    die Warnung sagt, dass jemand entscheiden muss.
    """
    heute = heute or _heute()
    warnungen = []
    for r in rules:
        if not r.get("verfall") or r["verfall"] >= heute:
            continue
        r["status"] = "abgelaufen"
        r["mandatory"] = 0
        warnungen.append(
            f"WARNUNG: {_wo(r)} ist seit {r['verfall']} abgelaufen — status=abgelaufen, "
            f"aus jeder Zustellung genommen. Entweder erneuern (neue Frist mit "
            f"Begruendung) oder `fm-regeln streich {r['id']} --grund ...`.")
    return warnungen


def _pruefe_felder(rules: list[dict], bestand: ankermodul.Ankerbestand) -> None:
    for r in rules:
        # v1-Regeln tragen hier nur Vorgaben, keine Aussagen — sie gegen die
        # v2-Muster zu pruefen hiesse, das Werkzeug seine eigenen Defaults
        # bewerten zu lassen (Vertrag im Kopf).
        if r["regel_schema"] == "v1":
            continue
        wo = _wo(r)
        if not schema.geltung_gueltig(r["geltung"]):
            raise IngestError(
                f"{wo}: geltung {r['geltung']!r} unbekannt — erlaubt sind "
                f"{', '.join(schema.ROLLEN)} oder projekt:<name>")
        if r["verbindlichkeit"] not in schema.VERBINDLICHKEITEN:
            raise IngestError(
                f"{wo}: verbindlichkeit {r['verbindlichkeit']!r} unbekannt — erlaubt "
                f"sind {', '.join(schema.VERBINDLICHKEITEN)}")
        if r["status"] not in schema.STATUS_WERTE:
            raise IngestError(
                f"{wo}: status {r['status']!r} unbekannt — erlaubt sind "
                f"{', '.join(schema.STATUS_WERTE)}")
        if not schema.leser_gueltig(r["leser"]):
            raise IngestError(
                f"{wo}: leser {r['leser']!r} unbekannt — erlaubt sind retrieval "
                f"oder hook:<pfad> / tor:<pfad> / werkzeug:<pfad>")

        # (b) Kern ohne benannten Leser waere eine Regel, die immer zugestellt
        # wird und nirgends geprueft — genau die Prosapflicht, die das Regelwerk
        # abgeschafft hat.
        if r["verbindlichkeit"] == "kern" and r["leser"] == "retrieval":
            raise IngestError(
                f"{wo}: verbindlichkeit=kern verlangt einen benannten Leser "
                f"(hook:/tor:/werkzeug:), nicht 'retrieval'. Entweder Leser "
                f"eintragen oder auf verbindlichkeit: kontext abstufen.")

        if r["nachweis"] and not schema.NACHWEIS.match(r["nachweis"]):
            raise IngestError(
                f"{wo}: quelle {r['nachweis']!r} passt in kein Muster — erlaubt sind "
                f"grundsatz:<n>, order:O-xxxx, captain-wort:<JJJJ-MM-TT>. "
                f"(Die Herkunftsdatei heisst seit Schema v2 `herkunftsdatei:`.)")
        if not r["anker"] and not r["nachweis"]:
            raise IngestError(
                f"{wo}: weder anker noch quelle — eine Regel ohne belegten Fehlerfall "
                f"und ohne Herkunft ist eine Meinung")

        # (a) Anker gegen Ledger bzw. AGENTS.md.
        for a in r["anker"]:
            if not schema.ANKER.match(a):
                raise IngestError(
                    f"{wo}: anker {a!r} hat kein bekanntes Format — erwartet Lnn oder HRn")
            # Ein unlesbares Ledger ist kein Fehler DIESER Regel — aber der
            # Ingest bricht daran ab, und wer ihn aufruft, soll genau eine
            # Fehlerart fangen muessen. Die Regel, an der es auffiel, steht mit
            # in der Meldung: sie ist der Einstieg zum Nachsehen.
            try:
                fehler = bestand.fehlt(a)
            except ankermodul.AnkerFehler as exc:
                raise IngestError(f"{wo}: {exc}") from exc
            if fehler:
                raise IngestError(f"{wo}: {fehler}")


def _pruefe_deckel(rules: list[dict], deckel: dict) -> None:
    from .render import regel_block

    # Nur v2-Regeln zaehlen. Bei einer v1-Regel ist `verbindlichkeit` aus
    # `mandatory` ABGELEITET; ein Deckel, der darauf reagiert, misst nicht das
    # Regelwerk, sondern die Vorgaben des Legacy-Modus (Vertrag im Kopf).
    aktiv = [r for r in rules if r["status"] == "aktiv" and r["regel_schema"] == "v2"]
    kern = [r for r in aktiv if r["verbindlichkeit"] == "kern"]
    kontext = [r for r in aktiv if r["verbindlichkeit"] == "kontext"]
    ausweg = ("Herabstufung ist Pflicht, nicht Wahl: `fm-regeln streich <id> "
              "--nach hinweis --grund \"...\"` stuft eine bestehende Regel ab und "
              "traegt sie in regeln/ABGESCHAFFT.md ein.")

    if len(kern) > deckel["kern_max"]:
        raise IngestError(
            f"Kern-Deckel gerissen: {len(kern)} Kernregeln, erlaubt sind "
            f"{deckel['kern_max']} ({', '.join(sorted(r['id'] for r in kern))}). {ausweg}")

    kern_tokens = sum(verfassung.tokens_schaetzen(regel_block(r)) for r in kern)
    if kern_tokens > deckel["kern_token_max"]:
        raise IngestError(
            f"Kern-Token-Deckel gerissen: {kern_tokens} geschaetzte Tokens, erlaubt "
            f"sind {deckel['kern_token_max']}. {ausweg}")

    if len(kontext) > deckel["kontext_max_gesamt"]:
        raise IngestError(
            f"Kontext-Deckel gerissen: {len(kontext)} Kontextregeln, erlaubt sind "
            f"{deckel['kontext_max_gesamt']}. {ausweg}")

    je_geltung: dict[str, list[str]] = {}
    for r in kontext:
        je_geltung.setdefault(r["geltung"], []).append(r["id"])
    for geltung, ids in sorted(je_geltung.items()):
        if len(ids) > deckel["kontext_max_je_geltung"]:
            raise IngestError(
                f"Kontext-Deckel fuer geltung={geltung} gerissen: {len(ids)} Regeln, "
                f"erlaubt sind {deckel['kontext_max_je_geltung']} "
                f"({', '.join(sorted(ids))}). {ausweg}")


def _pruefe_kernkonflikte(rules: list[dict]) -> None:
    """(e) Zwei Kernregeln duerfen einander nicht widersprechen.

    Kernregeln werden ALLE zugestellt, ungerankt und ungekuerzt. Stehen zwei
    davon in CONFLICTS_WITH, bekommt jede Session beide und muss selbst waehlen
    — und welche gewinnt, entscheidet dann der Zufall des Kontexts. Bei
    Kontextregeln ist das anders: dort ist der Konflikt ein Hinweis fuer das
    1-Hop, weil ohnehin nicht beide erscheinen muessen.
    """
    kern = {r["id"]: r for r in rules
            if r["verbindlichkeit"] == "kern" and r["status"] == "aktiv"
            and r["regel_schema"] == "v2"}
    for r in rules:
        if r["id"] not in kern:
            continue
        for rel in r["relations"]:
            if rel["kind"] == "CONFLICTS_WITH" and rel["dst"] in kern:
                raise IngestError(
                    f"{_wo(r)}: CONFLICTS_WITH {rel['dst']} — beide sind Kernregeln und "
                    f"werden immer zusammen zugestellt. Eine von beiden muss abgestuft "
                    f"werden (`fm-regeln streich`), oder der Konflikt ist keiner.")


def validate(rules: list[dict], bestand: ankermodul.Ankerbestand | None = None,
             deckel: dict | None = None, heute: str | None = None) -> list[str]:
    """Alle Pruefungen. Gibt WARNUNGEN zurueck; alles andere bricht ab."""
    # Erst die Fassung feststellen und die Legacy-Vorgaben setzen: danach hat
    # JEDE Regel dieselben Spalten, egal ob sie aus dem YAML, aus der
    # Weboberflaeche oder aus der Datenbank kommt.
    for r in rules:
        legacy_auffuellen(r)
    ids = [r["id"] for r in rules]
    doppelt = {i for i in ids if ids.count(i) > 1}
    if doppelt:
        raise IngestError(f"Doppelte Regel-IDs: {sorted(doppelt)}")
    bekannt = set(ids)
    for r in rules:
        for rel in r["relations"]:
            if rel["dst"] not in bekannt:
                raise IngestError(
                    f"{r['id']}: Beziehung zeigt auf unbekannte Regel {rel['dst']}"
                )
        if not 1 <= r["severity"] <= 3:
            raise IngestError(f"{r['id']}: severity {r['severity']} ausserhalb 1..3")

    warnungen: list[str] = []
    if deckel is None:
        deckel, deckel_warnungen = verfassung.laden()
        warnungen += deckel_warnungen

    _pruefe_felder(rules, bestand or ankermodul.Ankerbestand())
    # Verfall VOR den Deckeln: eine abgelaufene Regel zaehlt nicht mehr gegen
    # den Kerndeckel — sonst blockiert eine laengst gegenstandslose Regel die
    # Aufnahme ihrer Nachfolgerin.
    warnungen += verfall_anwenden(rules, heute)
    _pruefe_kernkonflikte(rules)
    _pruefe_deckel(rules, deckel)
    return warnungen


def _spaltenwert(r: dict, feld: str):
    """`anker` ist im Speicher eine Liste, in der Spalte eine Zeile.

    Kommagetrennt statt eigener Tabelle: Anker werden nur gelesen (Anzeige,
    Streichungs-Eintrag), nie gejoint — eine Tabelle waere ein Join ohne Frage,
    die ihn stellt.
    """
    if feld == "anker":
        return ",".join(schema.anker_liste(r["anker"]))
    return r[feld]


def write_db(conn: sqlite3.Connection, rules: list[dict], projects: list[dict]) -> None:
    schema.reset(conn)
    conn.executemany(
        f"INSERT INTO rules ({','.join(schema.FIELDS)}) "
        f"VALUES ({','.join('?' * len(schema.FIELDS))})",
        [tuple(_spaltenwert(r, f) for f in schema.FIELDS) for r in rules],
    )
    conn.executemany(
        "INSERT INTO relations (src, dst, kind) VALUES (?,?,?)",
        [(r["id"], rel["dst"], rel["kind"]) for r in rules for rel in r["relations"]],
    )
    conn.executemany(
        "INSERT OR REPLACE INTO projects (id, repo_path) VALUES (?,?)",
        [(p["id"], p["repo_path"]) for p in projects],
    )
    conn.commit()
    schema.rebuild_fts(conn)


def build_index(conn: sqlite3.Connection, index_path: Path) -> int:
    """hnswlib-Index aus den Regeln der DB bauen. Label = rules.rowid."""
    import hnswlib

    rows = conn.execute("SELECT rowid, trigger, statement FROM rules ORDER BY rowid").fetchall()
    if not rows:
        raise IngestError("Keine Regeln in der Datenbank — Index waere leer")
    vecs = embed.shared().encode([embed.rule_text(dict(r)) for r in rows])
    index = hnswlib.Index(space="cosine", dim=embed.DIM)
    index.init_index(max_elements=max(len(rows) * 2, 64), ef_construction=200, M=16)
    index.add_items(vecs, [r["rowid"] for r in rows])
    index.set_ef(64)
    index_path.parent.mkdir(parents=True, exist_ok=True)
    index.save_index(str(index_path))
    conn.execute(
        "INSERT OR REPLACE INTO meta (key, value) VALUES ('index_count', ?)",
        (str(len(rows)),),
    )
    conn.commit()
    return len(rows)


def run(source: Path | None = None, db: Path | None = None,
        index: Path | None = None, mit_index: bool = True,
        heute: str | None = None, strikt_v2: bool = False) -> dict:
    """Regelquelle -> Datenbank (+ Vektorindex).

    `strikt_v2=True` schaltet den Legacy-Modus ab: jede Regel muss im Schema v2
    stehen, eine v1-Regel bricht mit Datei und ID ab. Gedacht fuer Bestaende,
    die den Umzug hinter sich haben — allen voran die Flotten-Regelquelle
    `regeln/`, fuer die `bin/fm-regeln` das Flag setzt.

    `mit_index=False` laesst den Vektorindex weg. Gedacht fuer Pruefungen des
    Regelwerks selbst (Validierung, Deckel, Streichung): die haengen weder am
    ONNX-Modell noch an hnswlib, und ein Ingest, der ohne beides nicht laufen
    kann, waere in genau der Lage nicht pruefbar, in der man ihn braucht — auf
    einem frisch aufgesetzten Rechner. `doctor` meldet den Verzug weiterhin.
    """
    # Die Regelquelle ist seit Schema v2 `regeln/` im Flotten-Repo, nicht mehr
    # das mitgelieferte `rules/` des Werkzeugs.
    source = source or fmpfade.regeln_dir()
    db = db or paths.db_path()
    index = index or paths.index_path()

    rules, projects = collect(source, strikt_v2=strikt_v2)
    warnungen = validate(rules, heute=heute)
    conn = schema.connect(db)
    try:
        write_db(conn, rules, projects)
        n = build_index(conn, index) if mit_index else 0
    finally:
        conn.close()
    return {
        "regeln": len(rules),
        "mandatory": sum(r["mandatory"] for r in rules),
        "kern": sum(1 for r in rules
                    if r["verbindlichkeit"] == "kern" and r["status"] == "aktiv"),
        "kontext": sum(1 for r in rules
                       if r["verbindlichkeit"] == "kontext" and r["status"] == "aktiv"),
        "abgelaufen": sum(1 for r in rules if r["status"] == "abgelaufen"),
        # Sichtbar, nicht still: solange diese Zahl nicht 0 ist, laeuft ein
        # Teil des Bestands auf Vorgaben statt auf Aussagen.
        "legacy": sum(1 for r in rules if r["regel_schema"] == "v1"),
        "beziehungen": sum(len(r["relations"]) for r in rules),
        "projekte": len(projects),
        "indexiert": n,
        "warnungen": warnungen,
        "db": db,
        "index": index,
    }
