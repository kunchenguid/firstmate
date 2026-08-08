import os, urllib.request, urllib.error, json

REPO_MAP = {
    "prayer-bot": os.environ.get("PRAYER_BOT_REPO", "lakshaysethi2/discord-prayer-bot"),
    "hawkins-radio": os.environ.get("HAWKINS_RADIO_REPO", "lakshaysethi2/discord-radio"),
    "docdocgo": os.environ.get("DOCDOCGO_REPO", ""),  # GitLab, skip by default
}

def try_create_github_issue(service, title, description, contact, ua, report_id):
    token = os.environ.get("GITHUB_TOKEN", "").strip()
    if not token:
        return None
    repo = REPO_MAP.get(service, "")
    if not repo or "/" not in repo:
        return None
    # Only GitHub repos (no dot in host needed, but GitLab check)
    if "gitlab" in repo.lower():
        return None
    # don't fail the report if GitHub fails
    try:
        body = f"{description}\n\n---\nService: {service}\nReport ID: {report_id}\nContact: {contact or '—'}\nUA: {ua or '—'}"
        payload = json.dumps({"title": f"[issue-report] {title}", "body": body, "labels": ["issue-report"]}).encode()
        req = urllib.request.Request(
            f"https://api.github.com/repos/{repo}/issues",
            data=payload,
            headers={
                "Authorization": f"Bearer {token}",
                "Accept": "application/vnd.github+json",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=10) as r:
            data = json.loads(r.read().decode())
            return data.get("html_url")
    except Exception:
        return None
