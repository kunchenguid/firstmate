"""Filter one GitHub JSON response for bin/fm-tracker-notify.sh.

Reads the response body on stdin and prints, on stdout:

    CURSOR\t<newest updated_at seen, or the incoming cursor>
    <owner/repo>\t<issue number>      (zero or more, newest-first order preserved)

Only entries strictly newer than FM_PARSE_SINCE are printed, so a thread is
reported once and an already-seen comment never wakes firstmate twice. The
CURSOR line is printed even when nothing is new, so the caller can advance
position on a quiet poll.

Environment:
    FM_PARSE_MODE   "notifications" or "comments"
    FM_PARSE_SINCE  ISO 8601 cursor, or empty on the seeding run
    FM_PARSE_REPOS  comma-separated owner/repo allowlist (notifications mode)
    FM_PARSE_SLUG   owner/repo the body belongs to (comments mode)

Any malformed input exits quietly with no output lines beyond the cursor: this
feeds a watcher poll that must never read a failure as an event.
"""

import json
import os
import sys


def issue_number(url):
    tail = url.rsplit("/", 1)[-1] if url else ""
    return tail if tail.isdigit() else ""


def main():
    mode = os.environ.get("FM_PARSE_MODE", "")
    since = os.environ.get("FM_PARSE_SINCE", "")
    slug_arg = os.environ.get("FM_PARSE_SLUG", "")
    watched = set(x for x in os.environ.get("FM_PARSE_REPOS", "").split(",") if x)

    try:
        data = json.load(sys.stdin)
    except Exception:
        print("CURSOR\t%s" % since)
        return
    if not isinstance(data, list):
        print("CURSOR\t%s" % since)
        return

    newest = since
    hits = []
    for item in data:
        if not isinstance(item, dict):
            continue
        if mode == "notifications":
            subject = item.get("subject") or {}
            if subject.get("type") != "Issue":
                continue
            slug = (item.get("repository") or {}).get("full_name") or ""
            if slug not in watched:
                continue
            number = issue_number(subject.get("latest_comment_url") or subject.get("url") or "")
            updated = item.get("updated_at") or ""
        elif mode == "comments":
            slug = slug_arg
            number = issue_number(item.get("issue_url") or "")
            updated = item.get("updated_at") or item.get("created_at") or ""
        else:
            continue
        if not number or not updated or not slug:
            continue
        if updated > newest:
            newest = updated
        if since and updated <= since:
            continue
        hits.append("%s\t%s" % (slug, number))

    print("CURSOR\t%s" % newest)
    for line in hits:
        print(line)


if __name__ == "__main__":
    main()
