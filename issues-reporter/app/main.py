import os, html
from fastapi import FastAPI, Request, Form
from fastapi.responses import HTMLResponse, RedirectResponse, JSONResponse

from .store import SERVICES, SERVICE_LABELS, add_report, list_reports, counts_per_hour, recent_count
from .gatus import service_status, all_statuses
from .github_issue import try_create_github_issue

app = FastAPI(title="issues.lak.nz")

CSS = """
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:system-ui,-apple-system,sans-serif;background:#f6f7f9;color:#1a1a1a;line-height:1.5}
a{color:#0b57d0;text-decoration:none}a:hover{text-decoration:underline}
header{background:#fff;border-bottom:1px solid #e3e3e3;padding:12px 16px;position:sticky;top:0;z-index:10}
header h1{font-size:18px}header h1 a{color:inherit}
.wrap{max-width:720px;margin:0 auto;padding:16px}
.card{background:#fff;border:1px solid #e3e3e3;border-radius:12px;padding:16px;margin-bottom:12px}
.badge{display:inline-block;font-size:11px;font-weight:700;padding:2px 8px;border-radius:999px}
.badge-up{background:#d1f0d1;color:#0a5c0a}.badge-down{background:#ffd6d6;color:#8a0a0a}.badge-unk{background:#eee;color:#666}
.btn{display:inline-block;background:#0b57d0;color:#fff;border:none;border-radius:10px;padding:12px 18px;font-size:16px;font-weight:700;cursor:pointer;width:100%;text-align:center}
.btn:hover{opacity:.9;text-decoration:none}
input,select,textarea{width:100%;padding:10px 12px;border:1px solid #ccc;border-radius:10px;font-size:15px}
label{font-size:13px;font-weight:600;color:#333}
.muted{color:#666;font-size:13px}
.spark{width:100%;height:36px}
.row{display:flex;gap:12px;flex-wrap:wrap}
.row>.card{flex:1;min-width:220px}
.report{border-top:1px solid #eee;padding:10px 0}
.report:first-child{border-top:none}
.spike{color:#c00;font-weight:700;font-size:12px}
"""

def sparkline_svg(counts, w=220, h=36):
    if not counts:
        return ""
    mx = max(counts) or 1
    n = len(counts)
    pts = []
    for i, c in enumerate(counts):
        x = (i / max(n-1, 1)) * (w-4) + 2
        y = h - 4 - (c / mx) * (h - 12)
        pts.append(f"{x:.1f},{y:.1f}")
    poly = " ".join(pts)
    bars = ""
    for i, c in enumerate(counts):
        x = (i / max(n-1, 1)) * (w-4) + 2
        bh = (c / mx) * (h - 12)
        y = h - 4 - bh
        bars += f'<rect x="{x-2:.1f}" y="{y:.1f}" width="3" height="{bh:.1f}" rx="1" fill="#0b57d0" opacity="0.35"/>'
    spike = max(counts) >= 5
    spike_txt = '<text x="2" y="10" font-size="9" fill="#c00" font-weight="700">spike</text>' if spike and max(counts)==counts[-1] else ""
    return f'<svg class="spark" viewBox="0 0 {w} {h}" xmlns="http://www.w3.org/2000/svg">{bars}<polyline fill="none" stroke="#0b57d0" stroke-width="1.6" points="{poly}"/>{spike_txt}</svg>'

def status_badge(st):
    up = st.get("up")
    if up is True: return '<span class="badge badge-up">● Operational</span>'
    if up is False: return '<span class="badge badge-down">● Issues detected</span>'
    return '<span class="badge badge-unk">● Unknown</span>'

def layout(title, body):
    return f"""<!doctype html><html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{html.escape(title)} — issues.lak.nz</title>
<style>{CSS}</style></head><body>
<header><h1><a href="/">issues.lak.nz</a> <span class="muted" style="font-weight:400">— is it just me?</span></h1></header>
<div class="wrap">{body}</div>
</body></html>"""

@app.get("/health")
def health():
    return {"status": "ok"}

@app.get("/api/status")
def api_status():
    return all_statuses()

@app.get("/api/reports")
def api_reports(service: str = None):
    return list_reports(service=service)

@app.get("/api/stats")
def api_stats(service: str = None):
    s = service if service in SERVICES else None
    return {"counts_per_hour": counts_per_hour(service=s), "recent_30m": recent_count(s) if s else None}

@app.get("/", response_class=HTMLResponse)
def landing():
    statuses = all_statuses()
    cards = ""
    for svc in SERVICES:
        label = SERVICE_LABELS[svc]
        st = statuses.get(svc, {"up": None})
        badge = status_badge(st)
        counts = counts_per_hour(service=svc, hours=24)
        total = sum(counts)
        spark = sparkline_svg(counts)
        spike = " <span class='spike'>↑ spike</span>" if max(counts or [0]) >= 5 else ""
        cards += f"""<div class="card">
  <div style="display:flex;justify-content:space-between;align-items:center;gap:8px"><a href="/s/{svc}" style="font-weight:800;font-size:16px">{html.escape(label)}</a> {badge}</div>
  <div class="muted" style="margin:6px 0">{total} reports in 24h{spike} · <span class="muted">/{svc}</span></div>
  {spark}
  <div style="margin-top:10px"><a class="btn" href="/s/{svc}">View / Report issue</a></div>
</div>"""
    body = f'<p class="muted" style="margin-bottom:12px">Pick a service to see live status, report volume, and submit an issue.</p><div class="row">{cards}</div><p class="muted" style="margin-top:16px">Gatus health: <a href="https://gatus.lak.nz">gatus.lak.nz</a></p>'
    return HTMLResponse(layout("Status", body))

@app.get("/s/{service}", response_class=HTMLResponse)
def service_page(service: str, request: Request, ok: str = None, err: str = None):
    if service not in SERVICES:
        return HTMLResponse("Not found", status_code=404)
    label = SERVICE_LABELS[service]
    st = service_status(service)
    badge = status_badge(st)
    counts = counts_per_hour(service=service, hours=24)
    spark = sparkline_svg(counts, w=320, h=44)
    reports = list_reports(service=service, limit=30)
    banner = ""
    if ok: banner = '<div class="card" style="border-color:#b6e6b6;background:#eefbeE">✓ Report received — thank you.</div>'
    if err: banner = f'<div class="card" style="border-color:#f0b6b6;background:#fff0f0">{html.escape(err)}</div>'
    # spike warning
    spike_note = ""
    if max(counts or [0]) >= 5:
        spike_note = '<div class="card" style="border-color:#f0b6b6;background:#fff7f7"><b style="color:#c00">Spike detected</b> <span class="muted">— many reports in the last hour. You’re not alone.</span></div>'
    items = ""
    if not reports:
        items = '<p class="muted">No reports yet.</p>'
    else:
        for r in reports:
            import datetime as dt
            ts = dt.datetime.fromtimestamp(r["ts"]).strftime("%Y-%m-%d %H:%M")
            items += f"""<div class="report">
  <div style="font-weight:700">{html.escape(r["title"])}</div>
  <div class="muted" style="font-size:12px">{ts} · {html.escape(r["service"])}</div>
  <div style="margin-top:6px;white-space:pre-wrap">{html.escape(r["description"])}</div>
</div>"""
    body = f"""{banner}
<div class="card">
  <div style="display:flex;justify-content:space-between;align-items:center"><h2 style="font-size:18px">{html.escape(label)}</h2> {badge}</div>
  <div class="muted" style="margin:6px 0">Gatus: {html.escape(st.get("detail",""))} · {sum(counts)} reports / 24h</div>
  {spark}
  {spike_note}
  <a class="btn" href="/s/{service}/report" style="margin-top:12px">Report an issue</a>
</div>
<div class="card"><h3 style="font-size:15px;margin-bottom:8px">Recent reports</h3>{items}</div>
"""
    return HTMLResponse(layout(label, body))

@app.get("/s/{service}/report", response_class=HTMLResponse)
def report_form(service: str, err: str = None):
    if service not in SERVICES:
        return HTMLResponse("Not found", status_code=404)
    label = SERVICE_LABELS[service]
    opts = "".join(f'<option value="{s}" {"selected" if s==service else ""}>{html.escape(SERVICE_LABELS[s])}</option>' for s in SERVICES)
    e = f'<div class="card" style="border-color:#f0b6b6;background:#fff0f0">{html.escape(err)}</div>' if err else ""
    body = f"""{e}
<div class="card">
<h2 style="margin-bottom:10px">Report an issue — {html.escape(label)}</h2>
<form method="post" action="/api/report" style="display:grid;gap:12px">
  <div><label>Service</label><select name="service">{opts}</select></div>
  <div><label>Title *</label><input name="title" required maxlength="200" placeholder="e.g. Prayer bot not responding"></div>
  <div><label>Description</label><textarea name="description" rows="4" maxlength="2000" placeholder="What happened?"></textarea></div>
  <div><label>Contact (optional)</label><input name="contact" maxlength="200" placeholder="email or @handle"></div>
  <button class="btn" type="submit">Submit report</button>
</form>
<p class="muted" style="margin-top:10px">Your browser UA + timestamp are stored. Reports are public on this page.</p>
</div>"""
    return HTMLResponse(layout(f"Report — {label}", body))

@app.post("/api/report")
async def create_report(request: Request, service: str = Form(None), title: str = Form(None), description: str = Form(None), contact: str = Form(None)):
    # also support JSON
    if service is None:
        try:
            j = await request.json()
            service = j.get("service"); title = j.get("title"); description = j.get("description",""); contact = j.get("contact","")
        except Exception:
            pass
    ua = request.headers.get("user-agent", "")[:300]
    ip = request.client.host if request.client else ""
    wants_json = "application/json" in (request.headers.get("accept") or "") or (request.headers.get("content-type") or "").startswith("application/json")
    try:
        report = add_report(service or "", title or "", description or "", contact or "", ua, ip)
    except ValueError as e:
        msg = str(e)
        if wants_json:
            return JSONResponse({"error": msg}, status_code=400)
        return RedirectResponse(f"/s/{service or SERVICES[0]}/report?err={msg}", status_code=303)
    # fire-and-forget GitHub issue
    try:
        try_create_github_issue(report["service"], report["title"], report["description"], report["contact"], report["ua"], report["id"])
    except Exception:
        pass
    if wants_json:
        return JSONResponse({"ok": True, "report": report})
    return RedirectResponse(f"/s/{report['service']}?ok=1", status_code=303)

@app.get("/api/reports/{service}", response_class=JSONResponse)
def api_reports_service(service: str):
    if service not in SERVICES:
        return JSONResponse({"error": "invalid service"}, status_code=400)
    return list_reports(service=service)
