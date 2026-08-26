#!/usr/bin/env bash
# fm-streichliste.sh - the day-close strike-candidate list (drift brake, single
# owner). AGENTS.md: "gate decisions log to state/tor-log/ and feed the
# Tagesschluss strike list (fm-regeln streich demotes, never deletes
# knowledge; ABGESCHAFFT.md keeps things dead and is never injected)." This
# script is that reader: it never demotes or deletes anything itself, it only
# names candidates and the exact command to act on them.
#
# Usage:
#   fm-streichliste.sh          print the strike-candidate list to stdout
#   fm-streichliste.sh --help
#
# Reads (never writes, never demotes):
#   $FM_HOME/state/tor-log/*.jsonl   one gate decision per line (fm-tor-log-lib.sh
#                                    contract: ts, tor, regel, verdikt, ausweg,
#                                    kontext - "ausweg" is "-" for no escape
#                                    taken, any other value names the exit the
#                                    caller actually took)
#   $FM_ROOT/regeln/*.yaml           the rule source; `status:` and `verfall:`
#                                    are read as ingest last wrote them
#   $FM_ROOT/tests/regel-retrieval-golden.tsv   golden retrieval rows
#                                    (prompt<TAB>expected-rule-id)
#   $FM_HOME/state/writ-fm/.delivered-*   bin/fm-prompt-regeln.sh's own record
#                                    of rule ids actually delivered as full
#                                    text in a live session (its file contract
#                                    is the single owner of this format) - the
#                                    only real evidence a kontext rule was ever
#                                    handed to a prompt, not merely retrievable
#
# Four candidate classes, one line each, always naming the exact next command:
#   (a) a Tor (gate) with zero verdikt=rot in the last 45 days
#   (b) a Tor with a pure false-alarm profile: at least one rot ever, and
#       EVERY rot has a non-"-" ausweg (every alarm was escaped, none ever
#       actually caught/blocked anything - "kein Fang")
#   (c) a rule whose status is abgelaufen (ingest already marked the expiry)
#   (d) a kontext rule with neither a golden-retrieval row naming it nor a
#       delivery-hit in any .delivered-* file - never proven reachable
# A Tor whose log is younger than 45 days (from its earliest line, or with no
# lines at all) is reported as "zu jung fuer ein Urteil", never as (a) or (b):
# there is not yet enough log to judge it either way.
#
# The remedy line differs by class: Tor candidates get the shadow-mode step
# ("remove state/.tor-<name>-scharf, then watch the log for 30 days" - a Tor
# demotes itself back to report-only, nothing is deleted); rule candidates get
# the one command that owns rule demotion/removal, `fm-regeln streich <id>`.
#
# This is a report, not a gate: it never fails on what it finds, and it always
# exits 0 except for a bad invocation (--help excepted). A missing python3
# (needed for JSON and YAML parsing) or missing PyYAML degrades to a note in
# the printed report rather than a failure, so a bare environment still gets
# whatever this script can determine.
#
# Env (all optional):
#   FM_ROOT_OVERRIDE            repo root (default: this script's own repo)
#   FM_HOME                     home whose state/ is read (default: FM_ROOT)
#   FM_STATE_OVERRIDE           state/ dir override (default: $FM_HOME/state)
#   FM_STREICHLISTE_REGELN      regeln/ dir override (default: $FM_ROOT/regeln)
#   FM_STREICHLISTE_GOLDEN      golden tsv override
#                                (default: $FM_ROOT/tests/regel-retrieval-golden.tsv)
#   FM_STREICHLISTE_FENSTER_TAGE  the lookback window in days (default: 45)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
TOR_LOG_DIR="$STATE/tor-log"
DELIVERED_DIR="$STATE/writ-fm"
REGELN_DIR="${FM_STREICHLISTE_REGELN:-$FM_ROOT/regeln}"
GOLDEN_TSV="${FM_STREICHLISTE_GOLDEN:-$FM_ROOT/tests/regel-retrieval-golden.tsv}"
FENSTER_TAGE="${FM_STREICHLISTE_FENSTER_TAGE:-45}"

usage() { sed -n '2,44p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
if [ "$#" -gt 0 ]; then
  printf 'fm-streichliste.sh: unexpected argument: %s\n' "$1" >&2
  usage >&2
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  printf '# Streichliste\n'
  printf 'fm-streichliste.sh: python3 not found - cannot analyze tor-log or regeln (Ausweg: install python3)\n'
  exit 0
fi

python3 - "$TOR_LOG_DIR" "$REGELN_DIR" "$GOLDEN_TSV" "$DELIVERED_DIR" "$FENSTER_TAGE" <<'PY'
import datetime
import glob
import json
import os
import sys

tor_log_dir, regeln_dir, golden_tsv, delivered_dir, fenster_tage_raw = sys.argv[1:6]
try:
    fenster_tage = int(fenster_tage_raw)
except ValueError:
    fenster_tage = 45

heute = datetime.datetime.now(datetime.timezone.utc).date()


def parse_ts(ts):
    try:
        return datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").date()
    except (TypeError, ValueError):
        return None


# --- 1. Tor-Log: state/tor-log/*.jsonl --------------------------------------
tor_zeilen = {}
for pfad in sorted(glob.glob(os.path.join(tor_log_dir, "*.jsonl"))):
    name = os.path.basename(pfad)[: -len(".jsonl")]
    zeilen = []
    try:
        with open(pfad, encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except ValueError:
                    continue
                datum = parse_ts(obj.get("ts", ""))
                if datum is None:
                    continue
                zeilen.append((datum, obj.get("verdikt", ""), obj.get("ausweg", "-")))
    except OSError:
        continue
    zeilen.sort(key=lambda z: z[0])
    tor_zeilen[name] = zeilen

jung = []
kandidaten_tore = []
fenster_start = heute - datetime.timedelta(days=fenster_tage)
for name in sorted(tor_zeilen):
    zeilen = tor_zeilen[name]
    if not zeilen:
        jung.append((name, None))
        continue
    aeltest = zeilen[0][0]
    alter_tage = (heute - aeltest).days
    if alter_tage < fenster_tage:
        jung.append((name, aeltest))
        continue
    rot_kuerzlich = [z for z in zeilen if z[1] == "rot" and z[0] >= fenster_start]
    rot_alle = [z for z in zeilen if z[1] == "rot"]
    if not rot_kuerzlich:
        kandidaten_tore.append(
            (name, "keine Verweigerung (rot) in den letzten %d Tagen" % fenster_tage))
    if rot_alle and all(z[2] not in ("-", "") for z in rot_alle):
        kandidaten_tore.append(
            (name, "reines Fehlalarm-Profil (jede Verweigerung endete in "
                   "ausweg-genutzt, nie ein Fang)"))

# --- 2. regeln/*.yaml --------------------------------------------------------
regel_hinweis = None
regeln = []
try:
    import yaml
except ImportError:
    regel_hinweis = "PyYAML fehlt - Regel-Auswertung (c)/(d) ausgelassen (Ausweg: pyyaml installieren)"
else:
    if not os.path.isdir(regeln_dir):
        regel_hinweis = "regeln/ nicht gefunden unter %s" % regeln_dir
    else:
        for pfad in sorted(glob.glob(os.path.join(regeln_dir, "*.yaml"))):
            dateiname = os.path.basename(pfad)
            try:
                with open(pfad, encoding="utf-8") as handle:
                    doc = yaml.safe_load(handle)
            except yaml.YAMLError:
                continue
            if not isinstance(doc, dict) or "rules" not in doc:
                continue
            eintraege = doc.get("rules")
            if not isinstance(eintraege, list):
                continue
            for entry in eintraege:
                if not isinstance(entry, dict) or not entry.get("id"):
                    continue
                regeln.append({
                    "id": str(entry["id"]),
                    "datei": dateiname,
                    "verbindlichkeit": entry.get("verbindlichkeit"),
                    "status": entry.get("status"),
                })

# --- 3. golden-retrieval rows -------------------------------------------------
golden_ids = set()
if os.path.isfile(golden_tsv):
    with open(golden_tsv, encoding="utf-8") as handle:
        for line in handle:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            teile = line.split("\t")
            if len(teile) >= 2 and teile[1].strip():
                golden_ids.add(teile[1].strip())

# --- 4. delivery-hit evidence: state/writ-fm/.delivered-* -------------------
delivered_ids = set()
if os.path.isdir(delivered_dir):
    for pfad in glob.glob(os.path.join(delivered_dir, ".delivered-*")):
        try:
            with open(pfad, encoding="utf-8") as handle:
                for line in handle:
                    line = line.strip()
                    if line:
                        delivered_ids.add(line)
        except OSError:
            continue

kandidaten_regeln = []
for regel in regeln:
    rid = regel["id"]
    if regel.get("status") == "abgelaufen":
        kandidaten_regeln.append((rid, regel["datei"], "status=abgelaufen"))
    if (regel.get("verbindlichkeit") == "kontext"
            and rid not in golden_ids and rid not in delivered_ids):
        kandidaten_regeln.append(
            (rid, regel["datei"],
             "kontext ohne Golden-Row und ohne Zustell-Treffer-Beleg"))

# --- Ausgabe ------------------------------------------------------------------
aus = []
aus.append("# Streichliste %s" % heute.isoformat())
aus.append("")
aus.append("## Tore")
for name, datum in sorted(jung, key=lambda x: x[0]):
    if datum is None:
        aus.append("jung: Tor %s zu jung fuer ein Urteil (keine Eintraege)" % name)
    else:
        aus.append("jung: Tor %s zu jung fuer ein Urteil (seit %s)" % (name, datum.isoformat()))
for name, grund in kandidaten_tore:
    aus.append(
        "streichkandidat: Tor %s - %s. Schattenmodus: Flag state/.tor-%s-scharf "
        "entfernen + 30 Tage Log beobachten" % (name, grund, name))
if not jung and not kandidaten_tore:
    aus.append("keine Tor-Kandidaten")

aus.append("")
aus.append("## Regeln")
if regel_hinweis:
    aus.append("hinweis: %s" % regel_hinweis)
for rid, datei, grund in kandidaten_regeln:
    aus.append(
        "streichkandidat: Regel %s (regeln/%s) - %s. fm-regeln streich %s"
        % (rid, datei, grund, rid))
if not kandidaten_regeln and not regel_hinweis:
    aus.append("keine Regel-Kandidaten")

print("\n".join(aus))
PY
