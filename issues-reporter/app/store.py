import json, os, time, threading
from pathlib import Path
from collections import defaultdict

DATA_FILE = Path(os.environ.get("DATA_FILE", "/data/reports.json"))
SERVICES = ["prayer-bot", "hawkins-radio", "docdocgo"]
SERVICE_LABELS = {
    "prayer-bot": "Prayer Bot",
    "hawkins-radio": "Hawkins Radio",
    "docdocgo": "DocDocGo",
}

_lock = threading.Lock()

def _load():
    if not DATA_FILE.exists():
        return []
    try:
        return json.loads(DATA_FILE.read_text())
    except Exception:
        return []

def _save(reports):
    DATA_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = DATA_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(reports, indent=2))
    tmp.rename(DATA_FILE)

def add_report(service, title, description, contact, ua, ip):
    if service not in SERVICES:
        raise ValueError("invalid service")
    title = (title or "").strip()[:200]
    description = (description or "").strip()[:2000]
    if not title:
        raise ValueError("title required")
    report = {
        "id": int(time.time() * 1000),
        "service": service,
        "title": title,
        "description": description,
        "contact": (contact or "").strip()[:200],
        "ua": (ua or "")[:300],
        "ip": ip,
        "ts": int(time.time()),
    }
    with _lock:
        reports = _load()
        reports.append(report)
        _save(reports)
    return report

def list_reports(service=None, limit=50):
    with _lock:
        reports = _load()
    if service:
        reports = [r for r in reports if r["service"] == service]
    reports.sort(key=lambda r: r["ts"], reverse=True)
    return reports[:limit]

def counts_per_hour(service=None, hours=24):
    now = int(time.time())
    buckets = [0]*hours  # oldest -> newest
    with _lock:
        reports = _load()
    if service:
        reports = [r for r in reports if r["service"] == service]
    for r in reports:
        age_s = now - r["ts"]
        if 0 <= age_s < hours*3600:
            idx = hours - 1 - int(age_s // 3600)  # newest at end
            buckets[idx] += 1
    return buckets

def total_counts(service=None):
    with _lock:
        reports = _load()
    if service:
        return sum(1 for r in reports if r["service"] == service)
    return len(reports)

def recent_count(service, minutes=30):
    cutoff = int(time.time()) - minutes*60
    with _lock:
        reports = _load()
    return sum(1 for r in reports if r["service"] == service and r["ts"] >= cutoff)
