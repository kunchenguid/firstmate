#!/usr/bin/env python3
"""Read unresolved bot-manager Notion issues and emit newly observed rows."""
import argparse
import json
import os
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

API = "https://api.notion.com/v1/databases/{}/query"
VERSION = "2022-06-28"  # Keep in step with IMAC's established reader.
UNRESOLVED = {"신규", "관찰", "승인 대기", "재실행 중"}
POLL_SECONDS = 300


def rich_text(prop):
    return "".join(x.get("plain_text", "") for x in prop.get("rich_text", []))


def title(prop):
    return "".join(x.get("plain_text", "") for x in prop.get("title", []))


def text_prop(props, key):
    prop = props.get(key, {})
    return title(prop) if prop.get("type") == "title" else rich_text(prop)


def row(page):
    p = page.get("properties", {})
    status = (p.get("상태", {}).get("select") or {}).get("name", "")
    name = title(p.get("이름", {}))
    job = text_prop(p, "잡 이름") or name.split(":", 1)[0].strip()
    severity = (p.get("심각도", {}).get("select") or {}).get("name", "")
    count = p.get("발생 횟수", {}).get("number") or 1
    return {
        "page_id": page.get("id", ""),
        "url": page.get("url", ""),
        "name": name,
        "status": status,
        "severity": severity,
        "job_name": job,
        "error_fingerprint": text_prop(p, "오류 지문"),
        "result_summary": text_prop(p, "결과 요약"),
        "occurrence_count": count,
        "discord_url": (p.get("Discord 원문", {}).get("url") or ""),
    }


def fetch(database, token):
    rows, cursor = [], None
    while True:
        payload = {"page_size": 100}
        if cursor:
            payload["start_cursor"] = cursor
        req = urllib.request.Request(
            API.format(database),
            data=json.dumps(payload).encode(),
            headers={"Authorization": f"Bearer {token}", "Notion-Version": VERSION,
                     "Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=30) as res:
            body = json.load(res)
        rows.extend(row(x) for x in body.get("results", []))
        if not body.get("has_more"):
            break
        cursor = body.get("next_cursor")
        if not cursor:
            raise RuntimeError("Notion pagination omitted next_cursor")
    return [r for r in rows if r["status"] in UNRESOLVED]


def read_state(path):
    try:
        data = json.loads(path.read_text())
        return set(data.get("snapshot_ids", []))
    except FileNotFoundError:
        return None


def atomic_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".bot-manager-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, ensure_ascii=False, sort_keys=True)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def poll(database, state_path):
    state_path = Path(state_path)
    known = read_state(state_path)
    while True:
        try:
            rows = fetch(database, os.environ["NOTION_TOKEN"])
        except (OSError, ValueError, urllib.error.URLError, RuntimeError):
            # Keep the standing listener alive through transient API/network
            # outages; the next bounded poll retries without duplicating wakes.
            time.sleep(POLL_SECONDS)
            continue
        ids = {r["page_id"] for r in rows}
        if known is None:
            # Establish a baseline without creating a burst of historic tasks.
            atomic_json(state_path, {"snapshot_ids": sorted(ids)})
            known = ids
        else:
            new = [r for r in rows if r["page_id"] not in known]
            if new:
                print(json.dumps({"kind": "issues", "snapshot_ids": sorted(ids),
                                  "issues": new}, ensure_ascii=False))
                return
            if ids != known:
                atomic_json(state_path, {"snapshot_ids": sorted(ids)})
                known = ids
        time.sleep(POLL_SECONDS)


def acknowledge(state_path, result_path):
    result = json.loads(Path(result_path).read_text())
    atomic_json(Path(state_path), {"snapshot_ids": sorted(set(result["snapshot_ids"]))})


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("poll")
    p.add_argument("--database", required=True)
    p.add_argument("--state", required=True)
    a = sub.add_parser("acknowledge")
    a.add_argument("--state", required=True)
    a.add_argument("--result", required=True)
    args = parser.parse_args()
    try:
        if args.cmd == "poll":
            poll(args.database, args.state)
        else:
            acknowledge(args.state, args.result)
    except (KeyError, OSError, ValueError, urllib.error.URLError, RuntimeError) as e:
        print(f"bot-manager poll failed: {type(e).__name__}: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
