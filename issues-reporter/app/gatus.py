import os, time
import urllib.request, json

GATUS_URL = os.environ.get("GATUS_URL", "http://gatus:8080")
# map service -> gatus key(s) that determine up/down
GATUS_KEYS = {
    "prayer-bot": ["prayer_prayer-bot-health", "prayer_prayer-bot-dashboard"],
    "hawkins-radio": ["core_hawkins-radio-login"],
    "docdocgo": ["core_docdocgo-lak-nz"],
}

_cache = {}
_cache_ts = 0
TTL = 30  # seconds

def _fetch():
    global _cache, _cache_ts
    now = time.time()
    if now - _cache_ts < TTL and _cache:
        return _cache
    try:
        with urllib.request.urlopen(f"{GATUS_URL}/api/v1/endpoints/statuses", timeout=5) as r:
            data = json.loads(r.read().decode())
        m = {}
        for ep in data:
            key = ep.get("key", "")
            results = ep.get("results") or []
            # last result determines status
            last = results[-1] if results else {}
            m[key] = {
                "success": bool(last.get("success", False)),
                "status": last.get("status"),
            }
        _cache = m
        _cache_ts = now
    except Exception:
        pass  # keep stale cache
    return _cache

def service_status(service):
    keys = GATUS_KEYS.get(service, [])
    if not keys:
        return {"up": None, "detail": "no gatus mapping"}
    m = _fetch()
    # up only if ALL mapped keys are success
    ups = []
    for k in keys:
        v = m.get(k)
        if v is None:
            ups.append(None)
        else:
            ups.append(v["success"])
    if any(v is False for v in ups):
        return {"up": False, "detail": ", ".join(f"{k}={m.get(k,{}).get('success')}" for k in keys)}
    if all(v is True for v in ups):
        return {"up": True, "detail": "ok"}
    return {"up": None, "detail": "unknown — gatus not yet polled"}

def all_statuses():
    return {s: service_status(s) for s in GATUS_KEYS}
