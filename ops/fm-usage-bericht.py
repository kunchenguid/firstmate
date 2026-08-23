#!/usr/bin/env python3
# fm-usage-bericht.py — Stündlicher Nutzungsbericht per Telegram (Hauptbot).
# Nachfolger des alten claw_quota_watch.py vom Laptop: Kimi raus, beide
# Claude-Konten rein, dazu FAL- und OpenRouter-Guthaben.
#
# Quellen:
#   Konto 1: https://api.anthropic.com/api/oauth/usage, Token aus
#            ~/.claude/.credentials.json (kein eigener Refresh — macht Claude Code)
#   Konto 2: derselbe Endpunkt, Token aus ~/.claude2/.credentials.json,
#            IMMER über den eigenen Proxy 127.0.0.1:1080 (tailscaled2/Hetzner);
#            ist der Proxy tot, wird NICHT direkt gefragt (Netz-Identitäten
#            bleiben getrennt), der Bericht zeigt dann "nicht abrufbar".
#   Konto 3: derselbe Endpunkt, Token aus ~/.claude3/.credentials.json
#            (claude3-Wrapper, ehemaliges Hauptkonto; direkt, ohne Proxy).
#            Seit 2026-08-16 ist ~/.claude das NEUE Hauptkonto (kontakt@lensclash.de).
#   FAL:     https://rest.fal.ai/billing/user_balance (nackte Zahl, USD)
#   OpenRouter: https://openrouter.ai/api/v1/credits (credits - usage, USD)
#   Schlüssel aus ~/.config/claw/env (FAL_API_KEY, OPENROUTER_API_KEY).
#   Sessions: pgrep -x claude + /proc/<pid>/cwd (beide Instanzen laufen als
#             Binary "claude").
#
# Kadenz: systemd-Timer alle 15 min (fm-usage.timer). Voller Bericht 1x/h
# (unbedingt, der Captain will den Stundentakt). Dazwischen nur Band-Logik:
# >=90% Band-Eintritt (warn), >=95% Warnung max. 1x/h (kritisch).
# Lineare Hochrechnung "reicht bis Reset" je Fenster aus eigener Historie.
#
# RECHECK (23.08.2026, Captain-Auftrag): Liest sich ein Konto nicht mehr,
# startet der Bericht EINEN automatischen Auth-Refresh-Versuch
# (~/.local/bin/fm-konto-auth-refresh --konto N; derselbe Mechanismus wie im
# 6h-Timer fm-konto-auth.timer) und liest einmal nach. Nur wenn auch das
# scheitert und der Refresh-Token nachweislich tot ist (Marker des Refresh-
# Skripts), erscheint die handlungsableitende Meldung
#   "Konto N: Neu-Anmeldung noetig (claudeN oeffnen)"
# statt "nicht abrufbar" - eine Warnung ohne moegliche Aktion gibt es hier
# nicht mehr. Der Uebergang zu "Neu-Anmeldung noetig" wird zusaetzlich EINMAL
# gesondert gemeldet, nicht stuendlich wiederholt (Einmal-pro-Verfall).
# --dry-run: Bericht nur ausgeben, nichts senden/schreiben.
import json
import os
import subprocess
import sys
import time
import urllib.request
from datetime import datetime, timezone

FM_KONTO_REFRESH = os.path.expanduser("~/.local/bin/fm-konto-auth-refresh")
FM_KONTO_STATE = os.path.expanduser("~/.local/state/fm-konto-auth")

CLAUDE_USAGE_API = "https://api.anthropic.com/api/oauth/usage"
# KORRIGIERT 16.08.2026, zwei Fehler auf einmal:
#
# 1. Konto 1 zeigte auf ~/.claude/.credentials.json - einen SEPARATEN, veralteten
#    Namensraum. Seit dem Umzug an diesem Tag lebt Konto 1 in ~/.claude1/.
#    Der Bericht meldete deshalb dauerhaft "nicht abrufbar - Anmeldung pruefen",
#    obwohl das Konto einwandfrei laeuft. Der Owner hat das gemeldet.
# 2. Konto 2 lief ueber den Proxy 127.0.0.1:1080 (tailscaled). Der liefert nur
#    zwischengespeicherte und teils erfundene Werte - nachgemessen am selben Tag:
#    einmal die Zahlen von Konto 1, einmal ein Fenster ohne Wochenanteil, das es
#    nicht gibt. Ohne Proxy antwortet dasselbe Konto sauber.
#
# Die Namen tragen jetzt die Mailadresse statt "Haupt"/"ehem. Haupt" - wer Haupt
# ist, hat sich heute einmal geaendert und wird sich wieder aendern.
KONTEN = [
    ("Konto 1 · kontakt@lensclash.de", os.path.expanduser("~/.claude1/.credentials.json"), None),
    ("Konto 2 · fridjofs@gmail.com", os.path.expanduser("~/.claude2/.credentials.json"), None),
    ("Konto 3 · ronja.krueger@web.de", os.path.expanduser("~/.claude3/.credentials.json"), None),
    ("Konto 4 · kontakt@fotett.de", os.path.expanduser("~/.claude4/.credentials.json"), None),
]
CLAW_ENV = os.path.expanduser("~/.config/claw/env")
DIR = os.path.expanduser("~/.local/share/fm-usage")
HIST = f"{DIR}/history.jsonl"
STATE = f"{DIR}/state.json"
BERICHT_INTERVALL = 3600        # voller Bericht 1x/h, unbedingt
WARN_BAND = 95.0
POLL_BAND = 90.0
WARN_WIEDERHOLUNG = 3600
DRY_RUN = "--dry-run" in sys.argv


def jetzt():
    return time.time()


def kurzdatum(iso_s):
    try:
        return (datetime.fromisoformat(iso_s.replace("Z", "+00:00"))
                .astimezone().strftime("%d.%m. %H:%M"))
    except (AttributeError, ValueError, TypeError):
        return "?"


def lade_json(pfad, default):
    try:
        return json.load(open(pfad, encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return default


def claw_env():
    werte = {}
    try:
        for zeile in open(CLAW_ENV, encoding="utf-8"):
            zeile = zeile.strip()
            if zeile and not zeile.startswith("#") and "=" in zeile:
                k, _, v = zeile.partition("=")
                werte[k] = v
    except OSError:
        pass
    return werte


def notify(text, prio="info"):
    if DRY_RUN:
        return
    subprocess.run([os.path.expanduser("~/.local/bin/claw-notify"), text,
                    "--html", "--prio", prio, "--projekt", "default"],
                   capture_output=True, timeout=60)


def balken(prozent, voll="🟩", breite=8):
    if prozent is None:
        return "⬜" * breite
    n = max(0, min(breite, round(prozent / 100 * breite)))
    if prozent > 0:
        n = max(n, 1)
    return voll * n + "⬜" * (breite - n)


def hole(url, headers=None, proxy=None, timeout=20):
    handler = []
    if proxy:
        handler.append(urllib.request.ProxyHandler({"http": proxy, "https": proxy}))
    opener = urllib.request.build_opener(*handler)
    req = urllib.request.Request(url, headers=headers or {})
    with opener.open(req, timeout=timeout) as r:
        return r.read().decode("utf-8")


def konto_quota(creds_pfad, proxy):
    """5h/Weekly + modell-gebundene Limits eines Kontos, oder None.
    Weekly darf fehlen (Konto-1-Anomalie: kein allgemeines Wochenfenster)."""
    try:
        token = lade_json(creds_pfad, {})["claudeAiOauth"]["accessToken"]
        d = json.loads(hole(CLAUDE_USAGE_API, headers={
            "Authorization": f"Bearer {token}",
            "anthropic-beta": "oauth-2025-04-20",
        }, proxy=proxy))
        scoped = []
        for lim in d.get("limits") or []:
            modell = ((lim.get("scope") or {}).get("model") or {}).get("display_name")
            if lim.get("kind") == "weekly_scoped" and modell and lim.get("percent") is not None:
                scoped.append((modell, float(lim["percent"])))
        return {"c5": (d.get("five_hour") or {}).get("utilization"),
                "c5_reset": (d.get("five_hour") or {}).get("resets_at"),
                "cw": (d.get("seven_day") or {}).get("utilization"),
                "cw_reset": (d.get("seven_day") or {}).get("resets_at"),
                "scoped": scoped}
    except Exception:
        return None


def konto_recheck(nr):
    """EIN Auth-Refresh-Versuch fuer Konto nr (1-basiert) ueber das gemeinsame
    Refresh-Skript. Das Skript entscheidet selbst: laufende Sessions bleiben
    unberuehrt, gesunde Konten kosten nichts, tote Refresh-Tokens werden als
    "needs-relogin" gemeldet. Rueckgabe ist der Ergebnis-Tag."""
    try:
        r = subprocess.run([FM_KONTO_REFRESH, "--konto", str(nr)],
                           capture_output=True, text=True, timeout=120)
        for zeile in reversed((r.stdout or "").splitlines()):
            if zeile.startswith("RESULT: ") and "overall=" not in zeile:
                return zeile[len("RESULT: "):].strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return "unbekannt"


def konto_tot(nr):
    """Gilt das Konto nachweislich als neu-anmeldungsbeduerftig?"""
    return os.path.exists(f"{FM_KONTO_STATE}/konto{nr}.tot")


def guthaben_daten(env):
    """(fal_usd, openrouter_usd) — je None wenn nicht abrufbar."""
    fal = openrouter = None
    if env.get("FAL_API_KEY"):
        try:
            fal = float(hole("https://rest.fal.ai/billing/user_balance",
                             headers={"Authorization": f"Key {env['FAL_API_KEY']}"}))
        except Exception:
            pass
    if env.get("OPENROUTER_API_KEY"):
        try:
            d = json.loads(hole("https://openrouter.ai/api/v1/credits",
                                headers={"Authorization": f"Bearer {env['OPENROUTER_API_KEY']}"}))
            openrouter = float(d["data"]["total_credits"]) - float(d["data"]["total_usage"])
        except Exception:
            pass
    return fal, openrouter


def sessions_daten():
    """Aktive Claude-Sessions (beide Instanzen), lesbar benannt aus cwd:
    ~/.treehouse/<proj>-hash/N/<proj> -> Projektname, ~/.no-mistakes/... ->
    Validierungslauf, Home -> (Home). Mehrfachnennung wird gezaehlt."""
    home = os.path.expanduser("~")
    zaehler = {}
    try:
        pids = subprocess.run(["pgrep", "-x", "claude"], capture_output=True,
                              text=True, timeout=5).stdout.split()
    except (OSError, subprocess.SubprocessError):
        return []
    for pid in pids:
        try:
            cwd = os.readlink(f"/proc/{pid}/cwd").rstrip("/")
        except OSError:
            continue
        if cwd == home:
            name = "(Home)"
        elif f"{home}/.no-mistakes/" in cwd + "/":
            name = "Validierung"
        else:
            name = os.path.basename(cwd) or cwd
        # Konto aus CLAUDE_CONFIG_DIR des Prozesses (~/.claude2 -> K2, ~/.claude3 -> K3)
        try:
            with open(f"/proc/{pid}/environ", "rb") as f:
                env = dict(e.split(b"=", 1) for e in f.read().split(b"\0") if b"=" in e)
            cfg = env.get(b"CLAUDE_CONFIG_DIR", b"").decode(errors="replace")
        except OSError:
            cfg = ""
        if cfg.rstrip("/").endswith("/.claude2"):
            name += " [K2]"
        elif cfg.rstrip("/").endswith("/.claude3"):
            name += " [K3]"
        zaehler[name] = zaehler.get(name, 0) + 1
    return sorted(f"{n} ×{c}" if c > 1 else n for n, c in zaehler.items())


def pr_daten():
    """PRs, die auf das Go des Captains warten: pr=-Eintraege aus den
    Firstmate-Task-Aufzeichnungen (bis zum Aufraeumen nach dem Merge)."""
    urls = []
    statedir = os.path.expanduser("~/firstmate/state")
    try:
        metas = [f for f in os.listdir(statedir) if f.endswith(".meta")]
    except OSError:
        return []
    for f in sorted(metas):
        try:
            for zeile in open(os.path.join(statedir, f), encoding="utf-8"):
                if zeile.startswith("pr="):
                    url = zeile[3:].strip()
                    if url:
                        urls.append(url)
        except OSError:
            continue
    return urls


def flotten_daten():
    """Flottenstand aus dem Firstmate-Backlog: (laufende Auftraege,
    wartende Captain-Entscheidungen) oder None wenn nicht lesbar."""
    try:
        out = subprocess.run(["tasks-axi", "list"], capture_output=True,
                             text=True, timeout=20,
                             cwd=os.path.expanduser("~/firstmate"))
        if out.returncode != 0:
            return None
        laufend = entscheidungen = 0
        for zeile in out.stdout.splitlines():
            if not zeile.startswith("  "):
                continue
            teile = zeile.strip().split(",")
            if len(teile) < 3:
                continue
            zustand, art = teile[1], teile[2]
            if zustand == "in_flight":
                laufend += 1
            elif zustand == "queued" and art == "captain":
                entscheidungen += 1
        return (laufend, entscheidungen)
    except (OSError, subprocess.SubprocessError):
        return None


def hochrechnung(history, name, used_jetzt, reset_iso, fenster):
    """Lineare Regression der Samples des AKTUELLEN Fensters -> 100%-Zeitpunkt.
    Fenster-Resets (Saegezahn) bleiben draussen, sonst kippt die Steigung."""
    try:
        reset_ts = datetime.fromisoformat(reset_iso.replace("Z", "+00:00")).timestamp()
    except (AttributeError, ValueError, TypeError):
        reset_ts = None
    pts = [(h["ts"], h[name]) for h in history
           if h.get(name) is not None and jetzt() - h["ts"] < 36 * 3600]
    pts.append((jetzt(), used_jetzt))
    if reset_ts and fenster:
        start = reset_ts - fenster
        pts = [p for p in pts if p[0] > start]
    else:
        letzter_abfall = 0
        for i in range(1, len(pts)):
            if pts[i][1] < pts[i - 1][1]:
                letzter_abfall = i
        pts = pts[letzter_abfall:]
    if len(pts) < 3:
        return None
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    n = len(pts)
    xm, ym = sum(xs) / n, sum(ys) / n
    den = sum((x - xm) ** 2 for x in xs)
    if den == 0:
        return None
    steigung = sum((x - xm) * (y - ym) for x, y in pts) / den
    reset_kurz = datetime.fromtimestamp(reset_ts).strftime("%d.%m. %H:%M") if reset_ts else None
    if steigung <= 0:
        return {"ok": True, "wenn": None, "reset": reset_kurz}
    t100 = xm + (100.0 - ym) / steigung
    try:
        wenn = datetime.fromtimestamp(t100).strftime("%d.%m. %H:%M")
    except (OverflowError, OSError, ValueError):
        return {"ok": True, "wenn": None, "reset": reset_kurz}
    if reset_ts and t100 > reset_ts:
        return {"ok": True, "wenn": wenn, "reset": reset_kurz}
    return {"ok": False, "wenn": wenn, "reset": reset_kurz}


def main():
    os.makedirs(DIR, exist_ok=True)
    state = lade_json(STATE, {"band": {}, "letzter_bericht": 0, "letzte_warnung": 0})
    history = ([json.loads(z) for z in open(HIST, encoding="utf-8").readlines()[-200:]]
               if os.path.exists(HIST) else [])
    env = claw_env()

    konten = []          # (label, prefix, quota|None)
    nachlese_tags = {}   # prefix -> Ergebnis-Tag des Recheck-Versuchs
    for i, (label, creds, proxy) in enumerate(KONTEN, 1):
        q = konto_quota(creds, proxy)
        if q is None:
            # Recheck: EIN Refresh-Versuch, dann EIN Nachlesen - bevor das
            # Konto in irgendeiner Form als unlesbar gemeldet wird.
            tag = konto_recheck(i)
            nachlese_tags[f"k{i}"] = tag
            if tag not in ("needs-relogin",):
                q = konto_quota(creds, proxy)
        cache_key = f"k{i}_cache"
        if q is not None:
            state[cache_key] = {**q, "ts": jetzt()}
        else:
            cache = state.get(cache_key) or {}
            if jetzt() - cache.get("ts", 0) < 2 * 3600 and not konto_tot(i):
                q = {k: v for k, v in cache.items() if k != "ts"}
                q["stand"] = cache["ts"]
        konten.append((label, f"k{i}", q))

    # Uebergang zu "Neu-Anmeldung noetig" EINMAL je Verfall gesondert melden,
    # nicht bei jedem Stundentakt wiederholen (Einmal-pro-Verfall-Regel).
    # Im Probelauf (--dry-run) wird nichts gesetzt: eine Warnung darf nicht
    # verbraucht werden, ohne gesendet worden zu sein.
    if not DRY_RUN:
        for i, (label, prefix, q) in enumerate(konten, 1):
            schluessel = f"relogin_gemeldet_{prefix}"
            if q is None and konto_tot(i):
                if not state.get(schluessel):
                    notify(f"🔐 Konto {i}: Auth laesst sich nicht mehr automatisch "
                           f"erneuern — Neu-Anmeldung noetig (claude{i} oeffnen)",
                           prio="warn")
                    state[schluessel] = True
            else:
                state[schluessel] = False

    fal, openrouter = guthaben_daten(env)
    sessions = sessions_daten()
    flotte = flotten_daten()
    prs = pr_daten()

    # Tagesbasis fuer "heute verbraucht": erster Lauf des Tages setzt sie
    heute = datetime.now().strftime("%Y-%m-%d")
    tb = state.get("tages_basis") or {}
    if tb.get("datum") != heute:
        tb = {"datum": heute, "FAL": fal, "OpenRouter": openrouter}
    for name, wert in (("FAL", fal), ("OpenRouter", openrouter)):
        if tb.get(name) is None:
            tb[name] = wert
    state["tages_basis"] = tb

    # Sample fuer die Hochrechnung sichern (frische Werte, kein Cache)
    if not DRY_RUN:
        sample = {"ts": jetzt()}
        for label, prefix, q in konten:
            frisch = q is not None and "stand" not in q
            sample[f"{prefix}_5h"] = q["c5"] if frisch else None
            sample[f"{prefix}_w"] = q["cw"] if frisch else None
            if frisch:
                for mname, p in q["scoped"]:
                    sample[f"{prefix}_m_{mname}"] = p
        with open(HIST, "a", encoding="utf-8") as f:
            f.write(json.dumps(sample) + "\n")

    def prognosen(prefix, q):
        if not q:
            return []
        erg = []
        if q.get("c5") is not None:
            erg.append(("5h", hochrechnung(history, f"{prefix}_5h", q["c5"],
                                           q.get("c5_reset"), 5 * 3600), q["c5"]))
        if q.get("cw") is not None:
            erg.append(("Woche", hochrechnung(history, f"{prefix}_w", q["cw"],
                                              q.get("cw_reset"), 7 * 86400), q["cw"]))
        for mname, p in q.get("scoped") or []:
            erg.append((mname, hochrechnung(history, f"{prefix}_m_{mname}", p,
                                            q.get("cw_reset"), 7 * 86400), p))
        return erg

    alle_prognosen = {prefix: prognosen(prefix, q) for _, prefix, q in konten}
    werte = [w for pl in alle_prognosen.values() for _, _, w in pl if w is not None]
    maxband = max(werte) if werte else 0

    def metrik(label, prozent, voll="🟩"):
        wert = f"{prozent:>3.0f}%" if prozent is not None else " n/a"
        return f"<code>{label:<8}</code>{balken(prozent, voll)}<code> {wert}</code>"

    def status_zeilen(eintraege):
        rot, daten = [], False
        for label, hr, _wert in eintraege:
            if hr is None:
                continue
            daten = True
            if not hr["ok"]:
                rot.append(f"<b>{label} reicht nicht!</b>")
                rot.append(f"    100% ~{hr['wenn']}")
                if hr["reset"]:
                    rot.append(f"    Reset am {hr['reset']}")
        if rot:
            return rot
        hoechster = max((w for _, _, w in eintraege if w is not None), default=0)
        if daten or hoechster < POLL_BAND:
            return ["reicht bis Reset"]
        return ["hoher Stand — Prognose folgt"]

    def konto_block(label, prefix, q):
        nr = int(prefix[1:])
        if not q:
            # Handlungsableitend statt warnung-ohne-weg: Nur wenn der Refresh-
            # Token nachweislich tot ist, sonst neutrale Netz-/Konto-Formulierung.
            if konto_tot(nr):
                return [f"<b>Konto {nr}:</b> Neu-Anmeldung noetig "
                        f"(claude{nr} oeffnen)"]
            creds = next((c for l, c, _ in KONTEN if l == label), "")
            if creds and not os.path.exists(creds):
                grund = "noch nicht angemeldet"
            elif nachlese_tags.get(prefix) == "unbekannt":
                grund = "Refresh-Werkzeug unerreichbar - Anmeldung prüfen"
            else:
                grund = "Netz oder Konto unklar - Anmeldung prüfen"
            return [f"<b>{label}</b>: nicht abrufbar — {grund}"]
        hrs = {l: hr for l, hr, _ in alle_prognosen[prefix]}

        def farbe(l, wert):
            hr = hrs.get(l)
            if (hr and not hr["ok"]) or (wert or 0) >= WARN_BAND:
                return "🟥"
            if (wert or 0) >= POLL_BAND:
                return "🟨"
            return "🟩"

        kopf = f"<b>{label}</b> (Reset {kurzdatum(q.get('cw_reset') or q.get('c5_reset'))})"
        if q.get("stand"):
            kopf += " — Stand " + datetime.fromtimestamp(q["stand"]).strftime("%H:%M")
        block = [kopf, metrik("5h", q.get("c5"), farbe("5h", q.get("c5")))]
        if q.get("cw") is not None:
            block.append(metrik("Woche", q["cw"], farbe("Woche", q["cw"])))
        else:
            block.append("Woche: kein allgemeines Limit gemeldet")
        for mname, p in q.get("scoped") or []:
            block.append(metrik(mname[:8], p, farbe(mname, p)))
        block += status_zeilen(alle_prognosen[prefix])
        return block

    def geld(betrag):
        return f"{betrag:.2f} $" if betrag is not None else "n/a"

    def delta_abschnitt():
        zeilen = []
        gb = state.get("guthaben_basis") or {}
        for name, wert in (("FAL", fal), ("OpenRouter", openrouter)):
            alt = gb.get(name)
            if wert is not None and alt is not None and abs(wert - alt) >= 0.01:
                zeilen.append(f"{name} {wert - alt:+.2f} $")
        vorher = set(state.get("sessions_basis") or [])
        neu = sorted(set(sessions) - vorher)
        weg = sorted(vorher - set(sessions))
        if neu:
            zeilen.append("Session neu: " + ", ".join(neu))
        if weg:
            zeilen.append("Session beendet: " + ", ".join(weg))
        if not zeilen:
            zeilen = ["keine Änderungen"]
        return ["<b>Seit letztem Bericht:</b>"] + zeilen

    def guthaben_zeile(name, wert):
        zeile = f"{name} {geld(wert)}"
        basis = (state.get("tages_basis") or {}).get(name)
        if wert is not None and basis is not None and basis - wert >= 0.01:
            zeile += f" (heute −{basis - wert:.2f})"
        return zeile

    def meldung():
        zeilen = [f"<b>Nutzungsbericht</b> {datetime.now().strftime('%H:%M')}"]
        for label, prefix, q in konten:
            zeilen += konto_block(label, prefix, q)
        zeilen.append("<b>Guthaben:</b>")
        zeilen.append(guthaben_zeile("FAL", fal))
        zeilen.append(guthaben_zeile("OpenRouter", openrouter))
        if flotte:
            laufend, entscheidungen = flotte
            zeilen.append(f"<b>Flotte:</b> {laufend} Aufträge laufen · "
                          f"{entscheidungen} Entscheidungen warten auf dich")
        if prs:
            zeilen.append(f"<b>PRs warten auf dein Go ({len(prs)}):</b>")
            zeilen += prs
        zeilen += delta_abschnitt()
        if sessions:
            zeilen.append("<b>Sessions:</b>")
            zeilen += sessions
        return "\n".join(zeilen)

    if DRY_RUN:
        print(meldung())
        return

    def merke_basis():
        state["letzter_bericht"] = jetzt()
        state["guthaben_basis"] = {"FAL": fal, "OpenRouter": openrouter}
        state["sessions_basis"] = sessions

    warnen = maxband >= WARN_BAND
    band = POLL_BAND <= maxband < WARN_BAND
    vorher = state["band"].get("zustand", "ok")

    if warnen and (vorher != "95" or jetzt() - state["letzte_warnung"] > WARN_WIEDERHOLUNG):
        notify("🚨🚨🚨 QUOTA-WARNUNG 🚨🚨🚨\n" + meldung() +
               "\n⚠️ Über 95% — Verbrauch prüfen/drosseln!", prio="kritisch")
        state["letzte_warnung"] = jetzt()
        merke_basis()
    elif band and vorher == "ok":
        notify("⚠️ Quota über 90% — Band-Überwachung aktiv "
               "(15-min-Prüfung, Meldung bei Zustandswechsel):\n" + meldung(),
               prio="warn")
        merke_basis()
    elif jetzt() - state["letzter_bericht"] >= BERICHT_INTERVALL:
        # Nachtmodus 0-7 Uhr: keine Routineberichte, Warnungen (oben) laufen
        # weiter; der erste Tick ab 7 Uhr liefert den Morgenbericht sofort.
        if not 0 <= datetime.now().hour < 7:
            notify(meldung())
            merke_basis()

    state["band"]["zustand"] = "95" if warnen else ("90" if band else "ok")
    json.dump(state, open(STATE, "w"))


if __name__ == "__main__":
    main()
