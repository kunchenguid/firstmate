#!/usr/bin/env python3
"""Authenticate one native MAIN input and append it to the canonical task brief.

This is a purpose-specific intent transaction owner.  It writes no task state,
progress mirror, lifecycle record, authority ledger, or scheduling record.  The
native session remains the authority store; the task brief is the sole result.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time

MAX_BYTES = 262144
MAX_INT = 9007199254740991
SESSION_INDEX_SCHEMA = "fm-task-session-index.v1"
SESSION_SCAN_BYTES = 33554432
SESSION_RECORD_BYTES = 16777216
SESSION_INDEX_BYTES = 16777216
SESSION_INDEX_ENTRIES = 50000


class Refusal(Exception):
    pass


def require(ok, reason):
    if not ok:
        raise Refusal(reason)


def atom(value):
    return isinstance(value, str) and bool(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,159}", value))


def integer(value, minimum=0):
    return type(value) is int and minimum <= value <= MAX_INT


def text(value, maximum=8192):
    return isinstance(value, str) and bool(value) and len(value) <= maximum and "\0" not in value


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def regular(path):
    st = path.lstat()
    require(stat.S_ISREG(st.st_mode) and st.st_nlink == 1, "unsafe file: " + str(path))
    require(st.st_uid == os.getuid() and st.st_size <= MAX_BYTES, "unsafe owner or size: " + str(path))
    return path.read_bytes()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON key: " + key)
        result[key] = value
    return result


def native_session(path, index_directory, selected_entry, input_id):
    """Incrementally index bounded native-session deltas and return one route chain."""
    require(path.is_absolute(), "native session path must be absolute")
    started = time.monotonic()
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as stream:
        st = os.fstat(stream.fileno())
        require(stat.S_ISREG(st.st_mode) and st.st_nlink == 1 and st.st_uid == os.getuid(),
                "unsafe native input session file identity")
        index_directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        index_st = index_directory.lstat()
        require(stat.S_ISDIR(index_st.st_mode) and index_st.st_uid == os.getuid() and
                not index_directory.is_symlink(), "unsafe native session index directory")
        index_path = index_directory / (digest(str(path).encode()) + ".json")
        cached = None
        if index_path.exists() or index_path.is_symlink():
            index_file_st = index_path.lstat()
            require(stat.S_ISREG(index_file_st.st_mode) and index_file_st.st_nlink == 1 and
                    index_file_st.st_uid == os.getuid() and index_file_st.st_size <= SESSION_INDEX_BYTES,
                    "unsafe native session index")
            try:
                candidate = json.loads(index_path.read_bytes(), object_pairs_hook=unique_object)
                entries = candidate.get("entries")
                require(candidate.get("schema") == SESSION_INDEX_SCHEMA and candidate.get("path") == str(path) and
                        candidate.get("device") == st.st_dev and candidate.get("inode") == st.st_ino and
                        integer(candidate.get("indexed_size")) and candidate["indexed_size"] <= st.st_size and
                        isinstance(entries, list) and len(entries) <= SESSION_INDEX_ENTRIES,
                        "stale native session index")
                offsets = {}
                for item in entries:
                    require(isinstance(item, dict) and text(item.get("id"), 512) and
                            (item.get("parentId") is None or text(item.get("parentId"), 512)) and
                            integer(item.get("offset")) and integer(item.get("length"), 1) and
                            bool(re.fullmatch(r"[a-f0-9]{64}", str(item.get("sha256", "")))),
                            "invalid native session index entry")
                    require(item["id"] not in offsets, "duplicate native session index identity")
                    offsets[item["id"]] = item
                boundary_length = min(4096, candidate["indexed_size"])
                boundary = os.pread(stream.fileno(), boundary_length,
                                    candidate["indexed_size"] - boundary_length)
                require(digest(boundary) == candidate.get("boundary_sha256"),
                        "native session index boundary changed")
                if candidate["indexed_size"] == st.st_size:
                    require(candidate.get("mtime_ns") == st.st_mtime_ns,
                            "native session changed without append")
                cached = candidate
            except (Refusal, ValueError, TypeError, KeyError, AttributeError):
                cached = None
        index = cached or {"schema": SESSION_INDEX_SCHEMA, "path": str(path), "device": st.st_dev,
                           "inode": st.st_ino, "indexed_size": 0, "header": None, "entries": [],
                           "leaf_id": None}
        offsets = {item["id"]: item for item in index["entries"]}
        starting_offset = index["indexed_size"]
        checkpoint = starting_offset
        stream.seek(starting_offset)
        scanned_bytes = 0
        while stream.tell() < st.st_size and time.monotonic() - started < 10:
            offset = stream.tell()
            remaining = min(SESSION_SCAN_BYTES - scanned_bytes, st.st_size - offset)
            if remaining <= 0:
                break
            raw = stream.readline(min(SESSION_RECORD_BYTES + 1, remaining))
            if not raw:
                break
            scanned_bytes += len(raw)
            require(len(raw) <= SESSION_RECORD_BYTES, "native session record exceeds bounded readback")
            if not raw.endswith(b"\n") and stream.tell() < st.st_size:
                stream.seek(offset)
                break
            checkpoint = stream.tell()
            if not raw.strip():
                continue
            entry = json.loads(raw, object_pairs_hook=unique_object)
            if index["header"] is None:
                require(entry.get("type") == "session", "missing session identity")
                index["header"] = {"offset": offset, "length": len(raw), "sha256": digest(raw)}
                continue
            require(len(index["entries"]) < SESSION_INDEX_ENTRIES,
                    "native session index exceeds entry bound")
            entry_id = entry.get("id")
            parent_id = entry.get("parentId")
            require(text(entry_id, 512) and (parent_id is None or text(parent_id, 512)),
                    "invalid native session ancestry")
            require(entry_id not in offsets, "duplicate session entry identity")
            item = {"id": entry_id, "parentId": parent_id, "type": entry.get("type"),
                    "offset": offset, "length": len(raw), "sha256": digest(raw)}
            if entry.get("type") == "custom" and entry.get("customType") == "fm-continuation-input":
                item.update({"customType": "fm-continuation-input",
                             "input_id": entry.get("data", {}).get("id")})
            index["entries"].append(item)
            offsets[entry_id] = item
            index["leaf_id"] = entry_id
        require(index["header"] is not None, "missing session identity")
        index["indexed_size"] = checkpoint
        index["mtime_ns"] = st.st_mtime_ns
        boundary_length = min(4096, checkpoint)
        index["boundary_sha256"] = digest(os.pread(stream.fileno(), boundary_length,
                                                   checkpoint - boundary_length))

        def persist_index():
            raw_index = (json.dumps(index, ensure_ascii=False, separators=(",", ":")) + "\n").encode()
            require(len(raw_index) <= SESSION_INDEX_BYTES, "native session index exceeds byte bound")
            temporary_fd, temporary = tempfile.mkstemp(prefix=".session-index.", dir=index_directory)
            try:
                with os.fdopen(temporary_fd, "wb") as output:
                    output.write(raw_index)
                    output.flush()
                    os.fsync(output.fileno())
                os.replace(temporary, index_path)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)

        after_scan = os.fstat(stream.fileno())
        require((st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns) ==
                (after_scan.st_dev, after_scan.st_ino, after_scan.st_size, after_scan.st_mtime_ns),
                "native session changed during readback")
        if checkpoint < st.st_size:
            require(checkpoint > starting_offset,
                    "native session bounded readback made no complete-record progress")
            persist_index()
            raise Refusal("native session index catch-up incomplete; retry the same operation")
        if scanned_bytes or cached is None:
            persist_index()

        chain = []
        seen = set()
        entry_id = index["leaf_id"]
        while entry_id is not None:
            require(entry_id not in seen, "invalid session ancestry")
            seen.add(entry_id)
            item = offsets.get(entry_id)
            require(item is not None, "incomplete session ancestry")
            chain.append(item)
            entry_id = item["parentId"]
        chain.reverse()
        require(selected_entry in seen, "route receipt is outside the current session branch")

        def read_indexed(item):
            raw = os.pread(stream.fileno(), item["length"], item["offset"])
            require(len(raw) == item["length"] and digest(raw) == item["sha256"],
                    "native session indexed entry changed")
            return json.loads(raw, object_pairs_hook=unique_object)

        header = read_indexed(index["header"])
        route = read_indexed(offsets[selected_entry])
        full = {selected_entry}
        source_id = route.get("data", {}).get("source_entry_id")
        if source_id is not None:
            require(source_id in seen, "original message is outside the current session branch")
            full.add(source_id)
        entries = [header]
        retained_bytes = 0
        for item in chain:
            receipt = item.get("customType") == "fm-continuation-input"
            keep = item["id"] in full or receipt and item.get("input_id") == input_id
            if keep:
                entry = route if item["id"] == selected_entry else read_indexed(item)
                retained_bytes += item["length"]
                require(retained_bytes <= SESSION_RECORD_BYTES,
                        "native task receipts exceed bounded readback")
                entries.append(entry)
            else:
                entries.append({key: item[key] for key in ("id", "parentId", "type") if key in item})
        final = os.fstat(stream.fileno())
        require((st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns) ==
                (final.st_dev, final.st_ino, final.st_size, final.st_mtime_ns),
                "native session changed during readback")
        return entries


class Intent:
    def __init__(self, task):
        require(atom(task), "invalid task id")
        require(os.environ.get("FM_SUPERVISION_ACTOR", "main") == "main",
                "intent updates belong to MAIN")
        require(bool(os.environ.get("FM_HOME")), "FM_HOME must be explicit")
        self.id = task
        self.home = Path(os.environ["FM_HOME"]).resolve(strict=True)
        self.data = Path(os.environ.get("FM_DATA_OVERRIDE", self.home / "data")).resolve(strict=True)
        self.state = Path(os.environ.get("FM_STATE_OVERRIDE", self.home / "state")).resolve(strict=True)
        self.directory = self.data / task
        require(self.directory.is_dir() and not self.directory.is_symlink(),
                "missing or unsafe task data directory")

    def native_input(self, args):
        pid = regular(self.state / ".lock").decode().strip()
        require(pid.isdigit() and int(pid) > 1, "missing native owner")
        parent = os.getpid()
        for _ in range(32):
            if str(parent) == pid:
                break
            result = subprocess.run(["ps", "-o", "ppid=", "-p", str(parent)],
                                    capture_output=True, text=True, check=False)
            require(result.returncode == 0 and result.stdout.strip().isdigit(),
                    "cannot verify native input owner")
            parent = int(result.stdout.strip())
            require(parent > 1, "input caller is outside owning session")
        require(str(parent) == pid, "input owner ancestry exceeded")
        path = Path(args.session_file)
        entries = native_session(path, self.state / "task-session-index", args.entry_id, args.input)
        by_id = {entry["id"]: entry for entry in entries[1:] if "id" in entry}
        route = by_id.get(args.entry_id)
        require(route is not None, "unread native route receipt")
        require(route.get("customType") == "fm-continuation-input" and
                route.get("data", {}).get("task") == self.id and
                route.get("data", {}).get("update_brief") is True and
                route.get("data", {}).get("id") == args.input,
                "not an explicit intent route receipt")
        value = route["data"]
        source_id = value.get("source_entry_id")
        if source_id:
            require(source_id == args.input and source_id in by_id,
                    "original message is outside the current session branch")
            source = by_id[source_id]
            content = (source.get("message", {}).get("content")
                       if source.get("type") == "message" else source.get("content"))
            original = content if isinstance(content, str) else "".join(
                part.get("text", "") for part in content
                if isinstance(part, dict) and part.get("type") == "text") if isinstance(content, list) else ""
            require(text(original) and value.get("text") == original,
                    "intent words differ from original message")
            if source.get("type") == "message":
                require(source.get("message", {}).get("role") == "user",
                        "source is not an original user message")
            else:
                script = Path(__file__).with_name("fm-feishu-state.mjs").resolve().as_uri()
                check = subprocess.run(["node", "--input-type=module", "-e",
                    "import {verifyFeishuSessionMessage as verify} from " + json.dumps(script) +
                    "; let raw=''; for await (const part of process.stdin) raw+=part; " +
                    "process.stdout.write(verify(process.argv[1],JSON.parse(raw))?'verified':'refused');",
                    str(self.home)], input=json.dumps(source), capture_output=True,
                    text=True, check=False, timeout=10)
                require(check.returncode == 0 and check.stdout == "verified",
                        "missing immutable Feishu delivery proof")
            operational = subprocess.run([str(Path(__file__).with_name("fm-operational-input.sh")), "classify"],
                                         input=original, capture_output=True, text=True,
                                         check=False, timeout=10)
            require(operational.returncode == 1 and not operational.stdout.strip(),
                    "operational input is not task intent")
        else:
            # Retain interrupted task-assigned transactions created before
            # source-entry binding. Unassigned historical chat cannot newly
            # become task intent through this compatibility path.
            values = [entry.get("data", {}) for entry in reversed(entries)
                      if entry.get("type") == "custom" and
                      entry.get("customType") == "fm-continuation-input" and
                      entry.get("data", {}).get("id") == args.input]
            require(len(values) >= 2 and text(values[0].get("text")) and
                    not values[0].get("task") and not values[0].get("answer"),
                    "missing original authenticated input")
            require(all(item.get("text") == value["text"] and
                        item.get("task", self.id) == self.id and not item.get("answer")
                        for item in values), "input authority was rerouted or answered")
        return value

    @staticmethod
    def intent_body(raw, value):
        body = raw.decode()
        heading = "## Captain's intent\n"
        require(body.count(heading) == 1, "brief needs one canonical Captain intent subsection")
        start = body.index(heading) + len(heading)
        end = re.search(r"^#{1,2} ", body[start:], flags=re.M)
        position = start + end.start() if end else len(body)
        body = body[:position].rstrip("\n") + "\n\n" + value["text"] + "\n\n" + body[position:]
        pipeline = "## Captain intent authorized for --intent\n"
        if pipeline in body:
            require(body.count(pipeline) == 1, "ambiguous pipeline intent subsection")
            body = body.rstrip("\n") + "\n\n" + value["text"] + "\n"
        result = body.encode()
        require(len(result) <= MAX_BYTES, "updated brief too large")
        return result

    def plan(self, args):
        value = self.native_input(args)
        raw = regular(self.directory / "brief.md")
        return {"task_id": self.id, "mode": "compact", "before_sha256": digest(raw),
                "after_sha256": digest(self.intent_body(raw, value))}

    def update(self, args):
        value = self.native_input(args)
        before = value.get("brief_before_sha256")
        after = value.get("brief_after_sha256")
        require(isinstance(before, str) and re.fullmatch(r"[a-f0-9]{64}", before) and
                isinstance(after, str) and re.fullmatch(r"[a-f0-9]{64}", after),
                "compact intent update requires its persisted brief plan")
        brief = self.directory / "brief.md"
        raw = regular(brief)
        if digest(raw) == after:
            return {"task_id": self.id, "mode": "compact", "brief_sha256": after}
        require(digest(raw) == before, "brief changed during compact intent append")
        updated = self.intent_body(raw, value)
        require(digest(updated) == after, "compact intent plan changed")
        fd, name = tempfile.mkstemp(prefix=".brief.", dir=self.directory)
        try:
            with os.fdopen(fd, "wb") as stream:
                stream.write(updated)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(name, brief)
            directory_fd = os.open(self.directory, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        finally:
            if os.path.exists(name):
                os.unlink(name)
        return {"task_id": self.id, "mode": "compact", "brief_sha256": after}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("intent-plan", "update-brief"))
    parser.add_argument("task")
    parser.add_argument("--session-file", required=True)
    parser.add_argument("--entry-id", required=True)
    parser.add_argument("--input", required=True)
    args = parser.parse_args()
    intent = Intent(args.task)
    result = intent.plan(args) if args.operation == "intent-plan" else intent.update(args)
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (Refusal, OSError, ValueError, TypeError, KeyError,
            subprocess.TimeoutExpired) as error:
        print("REFUSED: " + str(error), file=sys.stderr)
        sys.exit(6)
