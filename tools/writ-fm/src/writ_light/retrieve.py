"""Retrieval-Pipeline nach regel-retrieval-light.md.

    1. BM25 ueber FTS5           (Top 20)
    2. Vektorsuche ueber hnswlib (Top 20)
    3. RRF-Merge k=60, gewichtet Vektor 0.6 / BM25 0.2 / severity 0.1 / confidence 0.1
    4. 1-Hop-Expansion: DEPENDS_ON-Nachbarn der Top-3
    5. mandatory-Regeln ungerankt vorangestellt
    6. Budget

Vier Filter liegen darueber (Begruendung in schema.py):
    * Projekt   — nur globale Regeln plus die des gebundenen Projekts
    * claw-rolle — standardmaessig ausgeschlossen, die Rolle Claw ist nicht
      die Rolle der Claude-Code-Session
    * Geltung   — flotte plus die eigene Rolle plus das eigene Projekt
    * Verbindlichkeit/Status — kern wird gesetzt zugestellt, kontext gerankt,
      hinweis NIE (nur auf ausdrueckliche Nachfrage), abgelaufen NIE
"""

from __future__ import annotations

import os
import re
import sqlite3
import sys
from dataclasses import dataclass, field
from pathlib import Path

from . import embed, paths, schema, verfassung

# Deutsche und englische Funktionswoerter. FTS5 bringt keine Stoppwortliste mit;
# ohne sie besteht ein Prompt wie "wie sage ich dem Owner Bescheid?" fuer BM25
# ueberwiegend aus Rauschen. Gemessen am Akzeptanz-Satz (146 Regeln): Top-5
# steigt von 9/10 auf 10/10.
_STOPP_ROH = """
aber alle allem allen aller alles als also am an ander andere anderem anderen anderer anderes
auch auf aus bei beim bin bis bist da damit dann das dass dasselbe dazu dein deine dem den denn
der derer des dessen dich die dies diese diesem diesen dieser dieses dir doch dort du durch ein
eine einem einen einer eines einig einige er es etwas euch euer eure fuer für gegen gewesen hab
habe haben hat hatte hatten hier hin hinter ich ihm ihn ihnen ihr ihre ihrem ihren ihrer ihres im
in indem ins ist jede jedem jeden jeder jedes jene jetzt kann kein keine man mein meine mich mir
mit muss musste nach nicht nichts noch nun nur ob oder ohne schon sehr sein seine selbst sich sie
sind so solche soll sollte sonst über um und uns unser unsere unter viel vom von vor war waren
warum was weg weil weiter welche wenn wer werde werden wie wieder will wir wird wirst wo wollen
woll würde würden zu zum zur zwar zwischen
and are but for from has have how not that the this was what when where which will with you your
"""

# Auch die Stoppwoerter muessen durch dieselbe Vereinheitlichung: sonst rutscht
# "ueber" als vermeintlich bedeutungstragend durch, waehrend "über" gefiltert wird.
STOPPWOERTER = frozenset(schema.normalisieren(_STOPP_ROH).split())

RRF_K = 60
GEWICHTE = {"bm25": 0.2, "vektor": 0.6, "severity": 0.1, "confidence": 0.1}
# Wie viele Kandidaten jede der beiden Suchen liefert, BEVOR gemischt wird.
#
# Stand bis 2026-08-07 auf 20 — gesetzt, als der Korpus klein war. Bei 169
# Regeln sind 20 Kandidaten 12 % des Bestands, und der Schnitt ist eine
# KLIPPE, keine Steigung: eine Regel knapp dahinter verliert ihren
# Vektorbeitrag VOLLSTAENDIG und faellt auf das BM25-Gewicht von 0,2 zurueck.
#
# Gemessen an DB-SICHERUNG-001 und der Frage "Darf ich die Tabelle droppen?" —
# deren Trigger die Woerter woertlich enthaelt. Sie lag auf gefiltertem
# Vektorrang 20, also genau auf der Kante. Die fuenf Regeln aus
# rules/arbeitsweise.yaml schoben sie auf 23:
#
#   Pool 20:  Platz 21 von 21   score 0.4000   bm25 1, vektor —
#   Pool 30:  Platz  2 von 31   score 0.8410   bm25 1, vektor 23
#
# Drei Plaetze Verschiebung, 19 Plaetze Absturz. Damit kann das Hinzufuegen
# beliebiger, voellig unverwandter Regeln eine bestehende lautlos
# unauffindbar machen — genau die Sorte Ausfall, die niemand bemerkt.
#
# 60 statt der gerade noch reichenden 30: der Wert soll Luft haben, nicht
# passen. Kosten sind flach — 17 ms je Query bei 20, 30, 40, 60 und 100
# (belege/t4-kandidatenschnitt.md); die teure Arbeit ist das Einbetten der
# Frage, nicht das Ranken von vierzig zusaetzlichen Zeilen. Was hinten zu
# schwach ist, schneidet ohnehin das Token-Budget ab.
KANDIDATEN = 60
CLAW_DOMAIN = "claw-rolle"
STANDARD_BUDGET = 2000


@dataclass
class Treffer:
    regel: dict
    score: float = 0.0
    rang_bm25: int | None = None
    rang_vektor: int | None = None
    herkunft: str = "ranking"          # ranking | 1-hop | mandatory


@dataclass
class Ergebnis:
    # Der Kern-Block: verbindlichkeit=kern, status=aktiv. Das Feld heisst
    # weiter `mandatory`, weil die gleichnamige Spalte genau diese Menge
    # bezeichnet (sie wird aus verbindlichkeit abgeleitet) — und weil ein
    # Umbenennen hier nur Aufrufer beruehrt, ohne einen Fakt zu klaeren.
    mandatory: list[Treffer] = field(default_factory=list)
    gerankt: list[Treffer] = field(default_factory=list)
    projekt: str | None = None
    geltung: str | None = None
    weggelassen: int = 0               # aus Budgetgruenden gestrichen
    tokens: int = 0

    @property
    def alle(self) -> list[Treffer]:
        return self.mandatory + self.gerankt

    def ids(self) -> list[str]:
        return [t.regel["id"] for t in self.alle]

    def gerankte_ids(self) -> list[str]:
        return [t.regel["id"] for t in self.gerankt]


# ── Projektbindung ────────────────────────────────────────────────────────

def aktives_projekt(conn: sqlite3.Connection, explizit: str | None = None,
                    cwd: str | Path | None = None) -> str | None:
    """Projekt aus Argument, Umgebung oder Arbeitsverzeichnis bestimmen."""
    if explizit:
        return explizit
    aus_env = os.environ.get("WRIT_PROJECT")
    if aus_env:
        return aus_env
    pfad = Path(cwd or Path.cwd()).resolve()
    treffer, laenge = None, -1
    for row in conn.execute("SELECT id, repo_path FROM projects WHERE repo_path IS NOT NULL"):
        repo = Path(row["repo_path"]).resolve()
        if pfad == repo or repo in pfad.parents:
            if len(str(repo)) > laenge:
                treffer, laenge = row["id"], len(str(repo))
    return treffer


class ZustellFehler(Exception):
    """Unbekannte Rolle o.ae. — lauter Abbruch statt stiller Vollauslieferung.

    Der stille Weg waere hier besonders teuer: eine unbekannte Rolle als "kein
    Filter" zu lesen liefert JEDER Session JEDE Regel, und das faellt niemandem
    auf, weil mehr Regeln nach mehr Sorgfalt aussehen.
    """


def erlaubte_geltungen(rolle: str | None, projekt: str | None) -> list[str] | None:
    """Welche `geltung`-Werte diese Zustellung sehen darf. None = kein Filter.

    `flotte` gilt immer mit: die Flotte ist die Obermenge jeder Rolle. Das
    Projekt kommt nur dazu, wenn eines benannt ist — sonst saehe ein Worker
    ohne Projektbindung die Regeln aller Projekte.
    """
    if rolle is None:
        return None
    if rolle not in schema.ROLLEN:
        raise ZustellFehler(
            f"Unbekannte Geltung {rolle!r} — erlaubt sind {', '.join(schema.ROLLEN)}")
    werte = {"flotte", rolle}
    if projekt:
        werte.add(f"projekt:{projekt}")
    return sorted(werte)


def _filter_sql(projekt: str | None, mit_claw: bool,
                geltungen: list[str] | None = None,
                stufen: tuple[str, ...] = (),
                status: tuple[str, ...] = ("aktiv",)) -> tuple[str, list]:
    bedingungen, werte = [], []
    if projekt:
        bedingungen.append("(r.project IS NULL OR r.project = ?)")
        werte.append(projekt)
    else:
        bedingungen.append("r.project IS NULL")
    if not mit_claw:
        bedingungen.append("r.domain != ?")
        werte.append(CLAW_DOMAIN)
    if geltungen:
        bedingungen.append(f"r.geltung IN ({','.join('?' * len(geltungen))})")
        werte.extend(geltungen)
    if stufen:
        bedingungen.append(f"r.verbindlichkeit IN ({','.join('?' * len(stufen))})")
        werte.extend(stufen)
    if status:
        bedingungen.append(f"r.status IN ({','.join('?' * len(status))})")
        werte.extend(status)
    return " AND ".join(bedingungen), werte


# ── Signale ───────────────────────────────────────────────────────────────

def fts_escape(prompt: str) -> str:
    """Freitext in eine FTS5-Query uebersetzen.

    Einzelne Woerter als ODER-Verknuepfung: FTS5 verbindet mehrere Terme
    sonst mit UND, und ein ganzer Prompt findet dann nie etwas.

    Mindestlaenge 2, nicht 3: Kuerzel wie `tg`, `ui` oder `qa` sind oft der
    unterscheidende Term. Funktionswoerter fliegen ueber STOPPWOERTER raus.

    Die Schreibweise wird vereinheitlicht wie beim Indexieren — sonst findet
    eine Suche nach "Loesung" die Regel nicht, die "Lösung" schreibt.
    """
    worte = re.findall(r"\w+", schema.normalisieren(prompt), flags=re.UNICODE)
    worte = [w for w in worte if len(w) >= 2 and w not in STOPPWOERTER]
    if not worte:
        return ""
    return " OR ".join(f'"{w}"' for w in dict.fromkeys(worte))


def bm25_treffer(conn, prompt: str, projekt, mit_claw: bool, limit=KANDIDATEN,
                 geltungen=None, stufen=("kontext",), status=("aktiv",)) -> list[int]:
    ausdruck = fts_escape(prompt)
    if not ausdruck:
        return []
    filt, werte = _filter_sql(projekt, mit_claw, geltungen, stufen, status)
    sql = (
        "SELECT r.rowid AS rid FROM rules_fts f "
        "JOIN rules r ON r.rowid = f.rowid "
        f"WHERE rules_fts MATCH ? AND {filt} "
        "ORDER BY rank LIMIT ?"
    )
    try:
        rows = conn.execute(sql, [ausdruck, *werte, limit]).fetchall()
    except sqlite3.OperationalError:
        return []
    return [r["rid"] for r in rows]


def vektor_treffer(conn, prompt: str, projekt, mit_claw: bool, limit=KANDIDATEN,
                   geltungen=None, stufen=("kontext",), status=("aktiv",)) -> list[int]:
    # Erst die Datei, dann der Import: ohne Index gibt es nichts zu laden, und
    # ein `ingest --ohne-index` (Pruefung des Regelwerks) soll ohne hnswlib
    # auskommen. LIEGT ein Index, bleibt der ImportError laut — dann fehlt eine
    # Abhaengigkeit, die dieser Bestand braucht, und stilles Weiterlaufen waere
    # eine halbierte Suche, die niemand sieht.
    if not paths.index_path().exists():
        return []
    gesamt = conn.execute("SELECT count(*) FROM rules").fetchone()[0]
    if not gesamt:
        return []

    import hnswlib
    index = hnswlib.Index(space="cosine", dim=embed.DIM)
    index.load_index(str(paths.index_path()), max_elements=max(gesamt * 2, 64))
    index.set_ef(max(64, limit * 4))
    # Grosszuegig suchen, danach filtern — sonst fressen ausgefilterte
    # Regeln die Plaetze der zulaessigen weg.
    #
    # k wird auch am INDEX gedeckelt, nicht nur an der Regelzahl. Bleibt der
    # Index hinter der Datenbank zurueck — `ingest` schreibt erst die DB und
    # baut danach den Index, ohne umspannende Transaktion —, wirft hnswlib
    # sonst "Cannot return the results in a contiguous 2D array". Der Hook
    # `prompt-regeln.sh` beendet sich bei jedem Fehler mit 0, also faellt der
    # GANZE Regelblock still aus, obwohl die BM25-Seite noch liefern koennte.
    # Mit dem Deckel bleibt der Ausfall auf die fehlenden Vektoren begrenzt.
    # `doctor` meldet den Verzug weiterhin ("n indiziert gegen m Regeln").
    vorhanden = index.get_current_count()
    if not vorhanden:
        return []
    k = min(gesamt, vorhanden, max(limit * 3, 50))
    labels, _ = index.knn_query(embed.shared().encode_one(prompt), k=k)

    filt, werte = _filter_sql(projekt, mit_claw, geltungen, stufen, status)
    erlaubt = {
        r["rowid"] for r in conn.execute(
            f"SELECT r.rowid FROM rules r WHERE {filt}", werte)
    }
    return [int(l) for l in labels[0] if int(l) in erlaubt][:limit]


def _rrf(rang: int | None) -> float:
    """Auf [0,1] normiert: Rang 1 -> 1.0, nicht enthalten -> 0.0.

    Ohne die Normierung laege RRF bei ~0.016 und die Zuschlaege fuer
    severity/confidence (bis 0.1) wuerden die Suchsignale ueberstimmen.
    """
    if rang is None:
        return 0.0
    return (RRF_K + 1) / (RRF_K + rang)


def rrf_merge(conn, bm25: list[int], vektor: list[int]) -> list[Treffer]:
    r_bm = {rid: i + 1 for i, rid in enumerate(bm25)}
    r_vec = {rid: i + 1 for i, rid in enumerate(vektor)}
    rids = list(dict.fromkeys([*bm25, *vektor]))
    if not rids:
        return []
    platzhalter = ",".join("?" * len(rids))
    regeln = {
        r["rowid"]: dict(r)
        for r in conn.execute(
            f"SELECT rowid, * FROM rules WHERE rowid IN ({platzhalter})", rids)
    }
    treffer = []
    for rid in rids:
        regel = regeln[rid]
        score = (
            GEWICHTE["bm25"] * _rrf(r_bm.get(rid))
            + GEWICHTE["vektor"] * _rrf(r_vec.get(rid))
            + GEWICHTE["severity"] * ((regel["severity"] or 1) - 1) / 2
            + GEWICHTE["confidence"] * (regel["confidence"] if regel["confidence"] is not None else 1.0)
        )
        treffer.append(Treffer(regel=regel, score=score,
                               rang_bm25=r_bm.get(rid), rang_vektor=r_vec.get(rid)))
    treffer.sort(key=lambda t: (-t.score, t.regel["id"]))
    return treffer


def ein_hop(conn, top: list[Treffer], projekt, mit_claw: bool,
            bekannt: set[str], geltungen=None, stufen=("kontext",),
            status=("aktiv",)) -> list[Treffer]:
    """Nachbarn der Top-3 anhaengen (Spezifikation, Schritt 4).

    `DEPENDS_ON` laeuft wie spezifiziert nur vorwaerts: die Regel setzt die
    andere voraus, nicht umgekehrt.

    `CONFLICTS_WITH` laeuft in BEIDE Richtungen — Abweichung von der Spec, mit
    Grund. Ein Konflikt ist symmetrisch, gespeichert wird er aber nur einmal.
    Konkreter Fall aus dem Bestand: CLID-BOT-001 hebt COMM-BOT-001 fuer das
    CLI-Dashboard auf. Ohne die Rueckrichtung faende eine Session, die
    COMM-BOT-001 trifft ("kein Bot in bots.conf, also claw-bot-request"), die
    Ausnahme nie — ausgerechnet in dem Projekt, wo genau das verboten ist.
    Eine aufhebende Regel darf nicht davon abhaengen, welche der beiden das
    Ranking zufaellig zuerst findet.
    """
    if not top:
        return []
    quellen = [t.regel["id"] for t in top[:3]]
    platzhalter = ",".join("?" * len(quellen))
    filt, werte = _filter_sql(projekt, mit_claw, geltungen, stufen, status)
    rows = conn.execute(
        f"SELECT DISTINCT r.rowid, r.* FROM rules r WHERE {filt} "
        f"AND (r.id IN (SELECT dst FROM relations WHERE src IN ({platzhalter}) "
        f"              AND kind IN ('DEPENDS_ON','CONFLICTS_WITH')) "
        f"  OR r.id IN (SELECT src FROM relations WHERE dst IN ({platzhalter}) "
        f"              AND kind = 'CONFLICTS_WITH'))",
        [*werte, *quellen, *quellen],
    ).fetchall()
    return [Treffer(regel=dict(r), score=0.0, herkunft="1-hop")
            for r in rows if r["id"] not in bekannt]


def kern_regeln(conn, projekt, mit_claw: bool, geltungen=None) -> list[Treffer]:
    """Die gesetzten Regeln: verbindlichkeit=kern und status=aktiv.

    Hiess bis Schema v2 `mandatory_regeln` und las die Spalte `mandatory`. Die
    Spalte bleibt (Oberflaeche, Export lesen sie), ist aber nur noch abgeleitet
    — gelesen wird der Fakt, nicht seine alte Schreibweise.
    """
    filt, werte = _filter_sql(projekt, mit_claw, geltungen, ("kern",))
    rows = conn.execute(
        f"SELECT rowid, * FROM rules r WHERE {filt} "
        f"ORDER BY r.severity DESC, r.id", werte).fetchall()
    return [Treffer(regel=dict(r), herkunft="kern") for r in rows]


# ── Budget ────────────────────────────────────────────────────────────────

_schaetzung_gemeldet = False


def _tokens(treffer: Treffer) -> int:
    """Tokenzahl eines Regelblocks — echter Tokenizer, sonst Schaetzung.

    Der Rueckfall ist eng gefasst (nur ImportError) und meldet sich EINMAL auf
    stderr. Er existiert, weil die Alternative schlimmer waere: auf einem
    Rechner ohne `tokenizers` fiele sonst die komplette Regelzustellung aus —
    eine Session ganz ohne Regeln, wegen einer Budgetrechnung, die um ein
    Fuenftel danebenliegen darf. Die Schaetzformel ist dieselbe wie beim
    Verfassungs-Deckel, damit nicht zwei Massstaebe nebeneinander gelten.
    """
    global _schaetzung_gemeldet
    from .render import regel_block

    text = regel_block(treffer.regel)
    try:
        return embed.count_tokens(text)
    except ImportError:
        if not _schaetzung_gemeldet:
            _schaetzung_gemeldet = True
            print("WARNUNG: `tokenizers` fehlt — Token-Budget wird geschaetzt "
                  "(Woerter * 1,3). `writ-light doctor` zeigt, was fehlt.",
                  file=sys.stderr)
        return verfassung.tokens_schaetzen(text)


def budget_anwenden(ergebnis: Ergebnis, budget: int) -> Ergebnis:
    """Das Budget gilt fuer die GERANKTEN Regeln.

    Die Spezifikation reicht `mandatory + ranked` durch apply_budget. Ein
    knappes Budget wuerde dabei verbindliche Regeln abschneiden — genau das,
    was `mandatory: true` ausschliessen soll. Gekuerzt wird deshalb nur die
    gerankte Liste; die Ausgabe weist aus, wie viel weggefallen ist.

    Bis 2026-08-07 startete `verbraucht` trotzdem mit der Summe der
    verbindlichen Regeln. Abgeschnitten wurden sie damit nie — aber sie
    zahlten aus demselben Topf und verdraengten die gerankten: 918 von 2000
    Tokens, 6 bis 8 statt 13 bis 15 Regeln (belege/e1-budget-messung.md).
    Das ist die falsche Buchhaltung. Verbindliche Regeln sind GESETZT, nicht
    gerankt; sie konkurrieren nicht um Plaetze, sie haben keine.

    `ergebnis.tokens` weist weiterhin BEIDE Teile aus — die Kopfzeile darf
    nicht behaupten, der Block sei billiger als er ist.
    """
    verbraucht = 0
    behalten = []
    for t in ergebnis.gerankt:
        kosten = _tokens(t)
        if verbraucht + kosten > budget:
            break
        behalten.append(t)
        verbraucht += kosten
    ergebnis.weggelassen = len(ergebnis.gerankt) - len(behalten)
    ergebnis.gerankt = behalten
    ergebnis.tokens = verbraucht + sum(_tokens(t) for t in ergebnis.mandatory)
    return ergebnis


# ── Einstiegspunkt ────────────────────────────────────────────────────────

def nur_kern(projekt: str | None = None, cwd: str | Path | None = None,
             db: Path | None = None, geltung: str | None = None) -> Ergebnis:
    """Ausschliesslich die Kernregeln — fuer den Session-Start.

    Nicht ueber query("") loesbar: ein leerer Prompt schaltet zwar BM25 ab,
    die Vektorsuche liefert aber trotzdem Nachbarn.
    """
    conn = schema.connect(db or paths.db_path())
    try:
        aktiv = aktives_projekt(conn, projekt, cwd)
        geltungen = erlaubte_geltungen(geltung, aktiv)
        ergebnis = Ergebnis(mandatory=kern_regeln(conn, aktiv, False, geltungen),
                            projekt=aktiv, geltung=geltung)
        ergebnis.tokens = sum(_tokens(t) for t in ergebnis.mandatory)
        return ergebnis
    finally:
        conn.close()


def query(prompt: str, budget_tokens: int = STANDARD_BUDGET,
          projekt: str | None = None, mit_claw: bool = False,
          cwd: str | Path | None = None, db: Path | None = None,
          limit: int | None = None, geltung: str | None = None,
          auch_hinweise: bool = False, deckel: dict | None = None) -> Ergebnis:
    """Gerankte Kontextregeln plus den gesetzten Kern-Block.

    `limit` kommt normalerweise NICHT vom Aufrufer, sondern als `topk` aus der
    Verfassung: wie viele Kontextregeln eine Session vertraegt, ist eine
    Entscheidung des Regelwerks und keine des Werkzeugs, das gerade fragt.

    `auch_hinweise` ist der einzige Weg, an abgestufte Regeln zu kommen. In
    keiner Zustellung tauchen sie auf — genau das ist der Unterschied zwischen
    "abgestuft" und "geloescht": nachschlagbar, aber nicht mehr im Weg.
    """
    if deckel is None:
        deckel, _ = verfassung.laden()
    stufen = ("kontext", "hinweis") if auch_hinweise else ("kontext",)
    status = ("aktiv", "hinweis-abgestuft") if auch_hinweise else ("aktiv",)
    conn = schema.connect(db or paths.db_path())
    try:
        aktiv = aktives_projekt(conn, projekt, cwd)
        geltungen = erlaubte_geltungen(geltung, aktiv)
        bm25 = bm25_treffer(conn, prompt, aktiv, mit_claw, geltungen=geltungen,
                            stufen=stufen, status=status)
        vektor = vektor_treffer(conn, prompt, aktiv, mit_claw, geltungen=geltungen,
                                stufen=stufen, status=status)
        gerankt = rrf_merge(conn, bm25, vektor)
        bekannt = {t.regel["id"] for t in gerankt}
        gerankt += ein_hop(conn, gerankt, aktiv, mit_claw, bekannt,
                           geltungen=geltungen, stufen=stufen, status=status)
        # Verfassungs-topk klemmt nur den Flottenpfad (Geltungs-Abfrage oder
        # real vorhandene VERFASSUNG.yaml). Standalone-/v1-Betrieb behaelt die
        # Budget-Mechanik der Vorlage - die Vendor-Suite pinnt sie.
        from . import fmpfade
        flottenpfad = geltung is not None or fmpfade.verfassung_datei().exists()
        if limit is not None:
            gerankt = gerankt[:limit]
        elif flottenpfad:
            gerankt = gerankt[:deckel["topk"]]
        ergebnis = Ergebnis(
            mandatory=kern_regeln(conn, aktiv, mit_claw, geltungen),
            gerankt=gerankt,
            projekt=aktiv,
            geltung=geltung,
        )
        return budget_anwenden(ergebnis, budget_tokens)
    finally:
        conn.close()
