#!/usr/bin/env python3
"""Deterministic executable-boundary tests for curated context handoff."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "bin" / "fm-context-handoff.py"
PLUGIN = ROOT / "integrations" / "claude-context-handoff"
FIXTURE_CORE = ROOT / "tests" / "fixtures" / "context-handoff-transaction-core.py"
FIXED_NOW = "2026-08-30T20:00:00Z"


class Failure(RuntimeError):
    pass


def check(condition: bool, message: str) -> None:
    if not condition:
        raise Failure(message)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def session_hash(harness: str, value: str) -> str:
    return hashlib.sha256(f"firstmate-context-handoff-v1\0{harness}\0{value}".encode()).hexdigest()


class Environment:
    def __init__(self, root: Path, name: str, *, exact_core: bool = False) -> None:
        self.root = root / name
        self.home = self.root / "home"
        self.source = self.root / "source"
        self.vault = self.root / "vault"
        self.home.joinpath("config").mkdir(parents=True)
        self.home.joinpath("state").mkdir()
        self.source.mkdir()
        self.vault.joinpath(".obsidian").mkdir(parents=True)
        self.vault.joinpath(".raw").mkdir()
        self.vault.joinpath("wiki", "concepts").mkdir(parents=True)
        self.vault.joinpath("wiki", "decisions").mkdir()
        self.vault.joinpath("wiki", "projects").mkdir()
        for name_, text in (
            ("index.md", "# Index\n"),
            ("log.md", "# Log\n"),
            ("hot.md", "# Hot\n"),
        ):
            self.vault.joinpath("wiki", name_).write_text(text, encoding="utf-8")
        self.source_file = self.source / "facts.md"
        self.source_file.write_text("Curated durable facts.\n", encoding="utf-8")
        self.claude_session = "claude-session-generation-1"
        self.herdr_mode = self.root / "herdr-mode"
        self.herdr_mode.write_text("ready\n", encoding="utf-8")
        self.herdr_log = self.root / "herdr-log.jsonl"
        self.fake_herdr = self.root / "fake-herdr.py"
        self.fake_herdr.write_text(
            """#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args=sys.argv[1:]
log=Path(os.environ['FAKE_HERDR_LOG'])
with log.open('a', encoding='utf-8') as h: h.write(json.dumps(args,separators=(',',':'))+'\\n')
mode=Path(os.environ['FAKE_HERDR_MODE_FILE']).read_text().strip()
if args[:2] == ['agent','get']:
    session_value=os.environ['FAKE_CLAUDE_SESSION'] if mode != 'mismatch' else 'other-session'
    status='working' if mode == 'busy' else 'idle'
    if mode == 'unavailable': raise SystemExit(1)
    print(json.dumps({'result':{'agent':{'pane_id':'pane-1','workspace_id':'workspace-1','tab_id':'tab-1','agent':'claude','agent_status':status,'cwd':os.environ['FAKE_VAULT'],'foreground_cwd':os.environ['FAKE_VAULT'],'agent_session':{'source':'claude','agent':'claude','kind':'id','value':session_value}}}},separators=(',',':')))
elif args[:2] == ['agent','prompt']:
    if mode == 'prompt-fail': raise SystemExit(1)
    print('{}')
else:
    raise SystemExit(64)
""",
            encoding="utf-8",
        )
        self.fake_herdr.chmod(0o755)
        installed_root = Path(os.environ.get("FM_CONTEXT_HANDOFF_TRANSACTION_ROOT", str(Path.home() / "claude-obsidian"))).resolve()
        installed_core = installed_root / "scripts" / "claude-obsidian.py"
        installed_module = installed_root / "claude_obsidian" / "transaction.py"
        if exact_core and installed_core.is_file() and installed_module.is_file():
            self.core = installed_core
            self.module = installed_module
            self.exact_core = True
        else:
            self.core = FIXTURE_CORE
            self.module = FIXTURE_CORE
            self.exact_core = False
        self.python = Path(sys.executable).resolve()
        self.flags = {
            "registration_enabled": True,
            "sealing_enabled": True,
            "delivery_enabled": False,
            "consumer_enabled": False,
        }
        self.write_config()

    def base_env(self) -> dict[str, str]:
        env = os.environ.copy()
        env.update(
            {
                "FM_HOME": str(self.home),
                "HOME": str(self.root / "synthetic-home"),
                "FM_HANDOFF_TESTING": "1",
                "FM_HANDOFF_TEST_NOW": FIXED_NOW,
                "FAKE_HERDR_LOG": str(self.herdr_log),
                "FAKE_HERDR_MODE_FILE": str(self.herdr_mode),
                "FAKE_CLAUDE_SESSION": self.claude_session,
                "FAKE_VAULT": str(self.vault),
                "HERDR_SESSION": "lab",
                "HERDR_WORKSPACE_ID": "workspace-1",
                "HERDR_TAB_ID": "tab-1",
                "HERDR_PANE_ID": "pane-1",
            }
        )
        return env

    def write_config(self) -> None:
        info = self.vault.stat()
        value = {
            "schema": "firstmate.context-handoff.config.v1",
            **self.flags,
            "approved_source_roots": [str(self.source)],
            "allowed_provider_classes": ["anthropic-claude-obsidian"],
            "vault": {"path": str(self.vault), "device": info.st_dev, "inode": info.st_ino},
            "recipient": {
                "herdr_cli_path": str(self.fake_herdr),
                "herdr_cli_sha256": digest(self.fake_herdr),
                "session": "lab",
                "workspace_id": "workspace-1",
                "tab_id": "tab-1",
                "pane_id": "pane-1",
                "agent": "claude",
                "agent_session_sha256": session_hash("claude", self.claude_session),
            },
            "transaction": {
                "python_path": str(self.python),
                "core_path": str(self.core),
                "core_sha256": digest(self.core),
                "module_path": str(self.module),
                "module_sha256": digest(self.module),
            },
            "consumer": {
                "create_prefix_allowlist": ["wiki/concepts/", "wiki/decisions/", "wiki/projects/"],
                "replace_path_allowlist": ["wiki/hot.md", "wiki/index.md", "wiki/log.md"],
                "required_coupled_paths": ["wiki/hot.md", "wiki/index.md", "wiki/log.md"],
            },
        }
        path = self.home / "config" / "context-handoff.json"
        path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
        path.chmod(0o600)

    def enable(self, **flags: bool) -> None:
        self.flags.update(flags)
        self.write_config()

    def run(self, *args: str, input_value=None, expect: int = 0, extra_env=None, cwd: Path | None = None):
        env = self.base_env()
        if extra_env:
            env.update(extra_env)
        data = None
        if input_value is not None:
            data = json.dumps(input_value, separators=(",", ":"))
        completed = subprocess.run(
            [str(CLI), *args],
            input=data,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=cwd or ROOT,
            env=env,
            check=False,
            timeout=45,
        )
        check(completed.returncode == expect, f"command {args} returned {completed.returncode}, expected {expect}: {completed.stderr}")
        if completed.stdout.strip():
            return json.loads(completed.stdout)
        return None

    def register(self, statement: str, *, harness: str = "pi", kind: str = "gotcha", source: Path | None = None, source_sha: str | None = None, provider: str = "anthropic-claude-obsidian", expect: int = 0):
        source = source or self.source_file
        return self.run(
            "register",
            "--source-harness",
            harness,
            "--kind",
            kind,
            "--statement",
            statement,
            "--source-record",
            str(source),
            "--source-sha256",
            source_sha or digest(source),
            "--confidence",
            "verified",
            "--sphere",
            "privat",
            "--provider-class",
            provider,
            expect=expect,
            extra_env={"PI_SESSION_ID": "pi-session-1"},
        )

    def seal_pi(self, session: str = "pi-session-1", trigger: str = "threshold", *, expect: int = 0, extra_env=None):
        return self.run("seal", "--source-harness", "pi", "--trigger", trigger, input_value={"session_id": session}, expect=expect, extra_env=extra_env)

    def complete(self, seal, outcome: str = "success"):
        return self.run(
            "compaction-outcome",
            outcome,
            input_value={
                "record_id": seal["record_id"],
                "envelope_sha256": seal["envelope_sha256"],
                "trigger": "threshold",
                "reason": "synthetic-compaction-result",
            },
        )

    def bind_claude(self, source: str = "startup", session: str | None = None):
        return self.run(
            "claude-hook",
            input_value={"hook_event_name": "SessionStart", "session_id": session or self.claude_session, "source": source},
            cwd=self.vault,
        )

    def hook(self, payload):
        payload = {"session_id": self.claude_session, **payload}
        return self.run("claude-hook", input_value=payload, cwd=self.vault)

    def mcp(self, name: str, arguments: dict):
        request = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": name, "arguments": arguments}}
        completed = subprocess.run(
            [str(CLI), "mcp-server"],
            input=json.dumps(request, separators=(",", ":")) + "\n",
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=self.vault,
            env=self.base_env(),
            check=False,
            timeout=45,
        )
        check(completed.returncode == 0, f"MCP server failed: {completed.stderr}")
        response = json.loads(completed.stdout)
        content = json.loads(response["result"]["content"][0]["text"])
        return content, response["result"].get("isError", False)

    def make_ready_record(self, statement: str = "Keep retries bounded after a lock conflict."):
        self.register(statement)
        seal = self.seal_pi()
        check(seal["status"] == "sealed", "Pi record did not seal")
        self.complete(seal)
        return seal

    def bundle(self, record_id: str, suffix: str = "", *, expected_override=None):
        operation_id = "handoff-" + hashlib.sha256(record_id.encode()).hexdigest()[:32]
        expected = {
            "wiki/concepts/Bounded retry.md": None,
            "wiki/index.md": digest(self.vault / "wiki" / "index.md"),
            "wiki/log.md": digest(self.vault / "wiki" / "log.md"),
            "wiki/hot.md": digest(self.vault / "wiki" / "hot.md"),
        }
        if expected_override:
            expected.update(expected_override)
        return {
            "schema": "claude-obsidian.transaction.v1",
            "operation_id": operation_id,
            "operation_type": "save",
            "expected_hashes": expected,
            "writes": [
                {"path": "wiki/concepts/Bounded retry.md", "mode": "create", "content": f"# Bounded retry\n\nKeep retries bounded after a lock conflict.{suffix}\n"},
                {"path": "wiki/index.md", "mode": "replace", "content": f"# Index\n- [[concepts/Bounded retry]]{suffix}\n"},
                {"path": "wiki/log.md", "mode": "replace", "content": f"# Log\n- Added bounded retry guidance.{suffix}\n"},
                {"path": "wiki/hot.md", "mode": "replace", "content": f"# Hot\n- Bounded retry guidance.{suffix}\n"},
            ],
            "address_requests": [],
            "source_manifest_updates": {},
        }

    def prepare(self, record_id: str, bundle=None):
        value, error = self.mcp(
            "prepare_handoff_save",
            {
                "record_id": record_id,
                "duplicate_check": {"result": "no-match", "searched_paths": ["wiki/index.md"]},
                "bundle": bundle or self.bundle(record_id),
            },
        )
        check(not error, f"Save preparation failed: {value}")
        return value

    def commit(self, record_id: str, approval: str):
        return self.mcp("commit_handoff_save", {"record_id": record_id, "approval_sha256": approval})


def test_registration_sealing_and_rejections(tmp: Path) -> None:
    env = Environment(tmp, "register")
    env.enable(registration_enabled=False)
    env.register("This durable fact is disabled.", expect=2)
    env.enable(registration_enabled=True)
    accepted = env.register("Keep retries bounded after a lock conflict.")
    duplicate = env.register("Keep retries bounded after a lock conflict.")
    check(accepted == duplicate, "identical candidate registration was not idempotent")
    candidate_path = env.home / "state" / "context-handoff" / "candidates" / f"{accepted['candidate_id']}.json"
    check(stat.S_IMODE(candidate_path.stat().st_mode) == 0o600, "candidate mode is not 0600")
    for statement in (
        "User: copy this raw chat transcript.",
        "The api key should be retained.",
        "Contact somebody@example.com for the customer record.",
        "Keep this local-only message body.",
    ):
        env.register(statement, expect=2)
    env.register("Provider-class refusal is durable.", provider="openai-ok", expect=2)
    env.register("A changed source hash must fail.", source_sha="0" * 64, expect=2)
    symlink = env.root / "source-link.md"
    symlink.symlink_to(env.source_file)
    env.register("A symlink source must fail.", source=symlink, expect=2)
    seal = env.seal_pi()
    check(seal["status"] == "sealed", "registered candidate did not seal")
    record = env.home / "state" / "context-handoff" / "records" / f"{seal['record_id']}.json"
    data = record.read_bytes()
    value = json.loads(data)
    check(len(data) <= 32768 and len(value["items"]) == 1, "sealed envelope violated bounds")
    check(hashlib.sha256(data).hexdigest() == seal["envelope_sha256"], "sealed envelope hash is not exact")
    check(stat.S_IMODE(record.stat().st_mode) == 0o600, "sealed envelope mode is not 0600")
    check(env.seal_pi()["status"] == "already-sealed", "crash/retry seal binding was not idempotent")
    claim_path = env.home / "state" / "context-handoff" / "claims" / f"{accepted['candidate_id']}.json"
    queue_path = env.home / "state" / "context-handoff" / "queue" / f"{seal['record_id']}.json"
    claim_path.unlink()
    queue_path.unlink()
    recovered_after_publication = env.seal_pi()
    check(recovered_after_publication["record_id"] == seal["record_id"] and claim_path.exists() and queue_path.exists(), "crash after envelope publication did not recover claims and queue")
    check(env.seal_pi("another-pi-session")["status"] == "empty", "empty unrelated register was not a no-op")
    failed = env.run("compaction-outcome", "failure", input_value={"record_id": seal["record_id"], "envelope_sha256": seal["envelope_sha256"], "trigger": "threshold", "reason": "provider-failure"})
    check(failed["status"] == "compaction-failed", "compaction failure did not remain durable")
    retry = env.seal_pi()
    check(retry["record_id"] == seal["record_id"], "failed compaction did not retain its exact sealed record for retry")
    env.complete(retry)
    status = env.run("status")
    check(status["counts"]["pending"] == 1, "successful compaction did not leave a queue-first pending record")


def test_caps_atomicity_and_failure_receipts(tmp: Path) -> None:
    overlap_env = Environment(tmp, "state-vault-overlap")
    overlapping_vault = overlap_env.home / "state" / "context-handoff" / "vault"
    overlapping_vault.joinpath(".obsidian").mkdir(parents=True)
    config_path = overlap_env.home / "config" / "context-handoff.json"
    config_value = json.loads(config_path.read_text())
    overlap_info = overlapping_vault.stat()
    config_value["vault"] = {"path": str(overlapping_vault), "device": overlap_info.st_dev, "inode": overlap_info.st_ino}
    config_path.write_text(json.dumps(config_value, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
    overlap_env.register("State must remain outside the selected Vault.", expect=2)
    state_symlink_env = Environment(tmp, "state-symlink")
    outside_state = state_symlink_env.root / "outside-state"
    outside_state.mkdir()
    (state_symlink_env.home / "state" / "context-handoff").symlink_to(outside_state, target_is_directory=True)
    state_symlink_env.register("A symlinked state root must be refused.", expect=2)
    check(not list(outside_state.iterdir()), "symlinked state root received handoff records")
    item_env = Environment(tmp, "item-cap")
    for index in range(33):
        item_env.register(f"Durable bounded item number {index} remains current.")
    result = item_env.seal_pi()
    check(result == {"status": "seal-failed", "had_candidates": True, "reason": "item-cap-exceeded"}, "item cap did not fail the whole seal")
    check(not list((item_env.home / "state" / "context-handoff" / "records").glob("*.json")), "item-cap failure partially sealed a record")
    byte_env = Environment(tmp, "byte-cap")
    for index in range(20):
        byte_env.register(f"Durable item {index}: " + ("x" * 1800))
    byte_result = byte_env.seal_pi()
    check(byte_result["reason"] == "byte-cap-exceeded", "byte cap did not fail the whole seal")
    stale_source_env = Environment(tmp, "stale-source-before-seal")
    stale_source_env.register("A source hash change before seal must stop compaction.")
    stale_source_env.source_file.write_text("Changed before seal.\n", encoding="utf-8")
    stale_source = stale_source_env.seal_pi()
    check(stale_source["status"] == "seal-failed" and stale_source["had_candidates"], "non-empty candidate with a changed source hash did not fail sealing")
    fsync_env = Environment(tmp, "fsync-failure")
    fsync_env.register("A durable fsync failure probe remains current.")
    result = fsync_env.seal_pi(extra_env={"FM_HANDOFF_TEST_FAILPOINT": "before-file-fsync"})
    check(result["status"] == "seal-failed" and result["had_candidates"], "fsync failure did not surface as non-empty seal failure")
    receipts = [json.loads(path.read_text()) for path in (fsync_env.home / "state" / "context-handoff" / "receipts").glob("*.json")]
    check(any(item.get("reason") == "atomic-seal-failed" for item in receipts), "fsync failure left no durable failure receipt")
    check(not list((fsync_env.home / "state" / "context-handoff" / "records").glob("*.json")), "fsync failure published a partial envelope")


def test_exact_delivery_and_no_launch(tmp: Path) -> None:
    env = Environment(tmp, "delivery")
    env.enable(consumer_enabled=True)
    seal = env.make_ready_record()
    env.enable(delivery_enabled=True)
    env.herdr_mode.write_text("mismatch\n")
    pending = env.run("deliver")
    check(pending["status"] == "pending" and pending["reason"] == "recipient-identity-mismatch", "session-generation mismatch did not retain pending")
    env.herdr_mode.write_text("busy\n")
    busy = env.run("deliver")
    check(busy["reason"] == "recipient-not-idle", "busy exact recipient was notified")
    env.herdr_mode.write_text("ready\n")
    delivered = env.run("deliver")
    check(delivered["status"] == "notified", "exact ready recipient was not notified")
    again = env.run("deliver")
    check(again["status"] == "nothing-pending", "successful notification replayed")
    calls = [json.loads(line) for line in env.herdr_log.read_text().splitlines()]
    prompts = [call for call in calls if call[:2] == ["agent", "prompt"]]
    check(len(prompts) == 1 and prompts[0][3] == "/firstmate-context-handoff:consume", "delivery did not use one constant prompt")
    log_text = env.herdr_log.read_text()
    check(seal["record_id"] not in log_text and "Keep retries" not in log_text, "delivery exposed record identity or content")
    check(not any(any(word in part for word in ("start", "restart", "respawn")) for call in calls for part in call), "delivery attempted to launch or restart a process")


def test_claude_hooks_guard_and_compaction(tmp: Path) -> None:
    env = Environment(tmp, "claude-hooks")
    env.enable(consumer_enabled=True)
    wrong = env.bind_claude(session="another-session")
    check(wrong is None, "wrong Claude session generation was bound")
    env.bind_claude()
    registered, error = env.mcp(
        "register_curated_candidate",
        {
            "kind": "decision",
            "statement": "Use one bounded Save transaction for this durable fact.",
            "source_record": str(env.source_file),
            "source_sha256": digest(env.source_file),
            "confidence": "verified",
            "sphere": "privat",
            "provider_class": "anthropic-claude-obsidian",
            "supersedes": [],
        },
    )
    check(not error and registered["status"] == "registered", "Claude candidate register was not separately maintained")
    pre = env.hook({"hook_event_name": "PreCompact", "trigger": "manual", "custom_instructions": None, "transcript_path": "/forbidden/transcript"})
    check(pre is None, "successful Claude PreCompact emitted content")
    marker = "COMPACT_SUMMARY_MUST_NOT_PERSIST"
    post = env.hook({"hook_event_name": "PostCompact", "trigger": "manual", "compact_summary": marker, "transcript_path": "/forbidden/transcript"})
    check(post is None, "Claude PostCompact emitted content")
    registered_auto, error = env.mcp(
        "register_curated_candidate",
        {
            "kind": "next-step",
            "statement": "Review the next bounded handoff after automatic compaction.",
            "source_record": str(env.source_file),
            "source_sha256": digest(env.source_file),
            "confidence": "verified",
            "sphere": "privat",
            "provider_class": "anthropic-claude-obsidian",
            "supersedes": [],
        },
    )
    check(not error and registered_auto["status"] == "registered", "second Claude candidate registration failed")
    check(env.hook({"hook_event_name": "PreCompact", "trigger": "auto", "custom_instructions": None}) is None, "automatic Claude PreCompact emitted content")
    check(env.hook({"hook_event_name": "PostCompact", "trigger": "auto", "compact_summary": marker}) is None, "automatic Claude PostCompact emitted content")
    state_bytes = b"".join(path.read_bytes() for path in (env.home / "state" / "context-handoff").rglob("*.json"))
    check(marker.encode() not in state_bytes and b"/forbidden/transcript" not in state_bytes, "Claude lifecycle serialized a compact summary or transcript path")
    outside = env.root / "outside.txt"
    write_deny = env.hook({"hook_event_name": "PreToolUse", "tool_name": "Write", "tool_input": {"file_path": str(outside), "content": "x"}})
    check(write_deny["hookSpecificOutput"]["permissionDecision"] == "deny", "outside Write was not denied")
    obsidian_deny = env.hook({"hook_event_name": "PreToolUse", "tool_name": "Edit", "tool_input": {"file_path": str(env.vault / ".obsidian" / "app.json")}})
    check(obsidian_deny["hookSpecificOutput"]["permissionDecision"] == "deny", ".obsidian Edit was not denied")
    for command in ("git add .", "rm -rf wiki", "pip install package", "echo secret > /tmp/value"):
        decision = env.hook({"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": command}})
        check(decision["hookSpecificOutput"]["permissionDecision"] == "deny", f"unsafe shell command was not denied: {command}")
    malformed = env.hook({"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": f"{env.python} {env.core} transaction apply /tmp/bundle --vault {env.vault} --approved-plan-sha256 {'0'*64}"}})
    check(malformed["hookSpecificOutput"]["permissionDecision"] == "deny", "unbound transaction command was allowed")

    failure_env = Environment(tmp, "claude-seal-failure")
    failure_env.enable(consumer_enabled=True)
    failure_env.bind_claude()
    value, error = failure_env.mcp(
        "register_curated_candidate",
        {
            "kind": "gotcha",
            "statement": "Stop compaction when this curated candidate cannot be sealed.",
            "source_record": str(failure_env.source_file),
            "source_sha256": digest(failure_env.source_file),
            "confidence": "verified",
            "sphere": "privat",
            "provider_class": "anthropic-claude-obsidian",
            "supersedes": [],
        },
    )
    check(not error and value["status"] == "registered", "Claude failure candidate registration failed")
    blocked = failure_env.run(
        "claude-hook",
        input_value={"hook_event_name": "PreCompact", "session_id": failure_env.claude_session, "trigger": "manual", "custom_instructions": None},
        cwd=failure_env.vault,
        extra_env={"FM_HANDOFF_TEST_FAILPOINT": "before-file-fsync"},
    )
    check(blocked["decision"] == "block", "Claude non-empty seal failure did not block compaction")


def test_transaction_apply_replay_conflict_and_ack(tmp: Path) -> None:
    env = Environment(tmp, "transaction", exact_core=True)
    env.enable(consumer_enabled=True)
    seal = env.make_ready_record()
    env.bind_claude()
    next_value, error = env.mcp("next_curated_handoff", {})
    check(not error and next_value["record_id"] == seal["record_id"], "consumer did not validate and return the queued record")
    traversal_env = Environment(tmp, "transaction-traversal")
    traversal_env.enable(consumer_enabled=True)
    traversal_seal = traversal_env.make_ready_record("Quarantine an out-of-contract traversal proposal.")
    traversal_env.bind_claude()
    traversal = traversal_env.bundle(traversal_seal["record_id"])
    traversal["expected_hashes"]["../escape.md"] = traversal["expected_hashes"].pop("wiki/concepts/Bounded retry.md")
    traversal["writes"][0]["path"] = "../escape.md"
    rejected, error = traversal_env.mcp("prepare_handoff_save", {"record_id": traversal_seal["record_id"], "duplicate_check": {"result": "no-match", "searched_paths": ["wiki/index.md"]}, "bundle": traversal})
    check(error and rejected["code"] == "TRANSACTION_PATH", "transaction path traversal was not refused")
    traversal_queue = json.loads((traversal_env.home / "state" / "context-handoff" / "queue" / f"{traversal_seal['record_id']}.json").read_text())
    check(traversal_queue["status"] == "quarantined", "out-of-contract traversal was not quarantined")

    symlink_env = Environment(tmp, "transaction-symlink")
    symlink_env.enable(consumer_enabled=True)
    symlink_seal = symlink_env.make_ready_record("Quarantine a symlink escape proposal.")
    symlink_env.bind_claude()
    outside_target = symlink_env.root / "outside-target.md"
    outside_target.write_text("outside\n", encoding="utf-8")
    symlink_target = symlink_env.vault / "wiki" / "concepts" / "escape.md"
    symlink_target.symlink_to(outside_target)
    symlink_bundle = symlink_env.bundle(symlink_seal["record_id"])
    symlink_bundle["expected_hashes"]["wiki/concepts/escape.md"] = symlink_bundle["expected_hashes"].pop("wiki/concepts/Bounded retry.md")
    symlink_bundle["writes"][0]["path"] = "wiki/concepts/escape.md"
    rejected, error = symlink_env.mcp("prepare_handoff_save", {"record_id": symlink_seal["record_id"], "duplicate_check": {"result": "no-match", "searched_paths": ["wiki/index.md"]}, "bundle": symlink_bundle})
    check(error and rejected["code"] == "TRANSACTION_SYMLINK", "transaction symlink escape was not refused")
    symlink_queue = json.loads((symlink_env.home / "state" / "context-handoff" / "queue" / f"{symlink_seal['record_id']}.json").read_text())
    check(symlink_queue["status"] == "quarantined", "symlink escape was not quarantined")

    sensitive_env = Environment(tmp, "transaction-sensitive")
    sensitive_env.enable(consumer_enabled=True)
    sensitive_seal = sensitive_env.make_ready_record("Quarantine sensitive Save content.")
    sensitive_env.bind_claude()
    sensitive_bundle = sensitive_env.bundle(sensitive_seal["record_id"])
    sensitive_bundle["writes"][0]["content"] = "# Contact\n\nEmail body somebody@example.com\n"
    rejected, error = sensitive_env.mcp("prepare_handoff_save", {"record_id": sensitive_seal["record_id"], "duplicate_check": {"result": "no-match", "searched_paths": ["wiki/index.md"]}, "bundle": sensitive_bundle})
    check(error and rejected["code"] == "BUNDLE_CONTENT", "sensitive Save content was not refused")
    sensitive_queue = json.loads((sensitive_env.home / "state" / "context-handoff" / "queue" / f"{sensitive_seal['record_id']}.json").read_text())
    check(sensitive_queue["status"] == "quarantined", "sensitive Save content was not quarantined")

    prepared = env.prepare(seal["record_id"])
    ack_path = env.home / "state" / "context-handoff" / "acks" / f"{seal['record_id']}.json"
    check(not ack_path.exists(), "source was acknowledged before apply completed")
    bundle_path = env.home / "state" / "context-handoff" / "bundles" / seal["record_id"] / f"{prepared['bundle_sha256']}.json"
    exact_command = f"{env.python} {env.core} transaction apply {bundle_path} --vault {env.vault} --approved-plan-sha256 {prepared['approval_sha256']}"
    allow = env.hook({"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": exact_command}})
    check(allow["hookSpecificOutput"]["permissionDecision"] == "allow", "exact reviewed transaction command was not allowed")
    committed, error = env.commit(seal["record_id"], prepared["approval_sha256"])
    check(not error and committed["status"] == "acknowledged" and ack_path.is_file(), "transaction did not verify and acknowledge")
    check(not (env.vault / ".vault-meta" / "mutation.lock").exists(), "transaction lock remained after acknowledgement")
    replay, error = env.commit(seal["record_id"], prepared["approval_sha256"])
    check(not error and replay["status"] == "acknowledged", "identical transaction replay was not idempotent")
    result_path = env.vault / ".vault-meta" / "transactions" / prepared["operation_id"] / "changed-paths.json"
    journal_path = result_path.with_name("journal.json")
    check(stat.S_IMODE(result_path.stat().st_mode) == 0o600 and stat.S_IMODE(journal_path.stat().st_mode) == 0o600, "transaction result or journal mode is not 0600")
    result = json.loads(result_path.read_text())
    for relative, expected in result["hashes"].items():
        check(digest(env.vault / relative) == expected, f"changed path hash did not verify: {relative}")

    crash_env = Environment(tmp, "apply-before-ack")
    crash_env.enable(consumer_enabled=True)
    crash_seal = crash_env.make_ready_record("Use a verified result to heal apply-complete-before-ack.")
    crash_env.bind_claude()
    crash_prepared = crash_env.prepare(crash_seal["record_id"])
    crash_bundle = crash_env.home / "state" / "context-handoff" / "bundles" / crash_seal["record_id"] / f"{crash_prepared['bundle_sha256']}.json"
    direct = subprocess.run(
        [str(crash_env.python), str(crash_env.core), "transaction", "apply", str(crash_bundle), "--vault", str(crash_env.vault), "--approved-plan-sha256", crash_prepared["approval_sha256"]],
        env=crash_env.base_env(),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
        timeout=45,
    )
    check(direct.returncode == 0, f"synthetic direct apply failed: {direct.stderr}")
    crash_ack = crash_env.home / "state" / "context-handoff" / "acks" / f"{crash_seal['record_id']}.json"
    check(not crash_ack.exists(), "direct apply unexpectedly wrote the source acknowledgement")
    healed, error = crash_env.commit(crash_seal["record_id"], crash_prepared["approval_sha256"])
    check(not error and healed["status"] == "acknowledged" and crash_ack.exists(), "apply-complete-before-ack did not heal")

    conflict_env = Environment(tmp, "conflict")
    conflict_env.enable(consumer_enabled=True)
    conflict_seal = conflict_env.make_ready_record("Re-read coupled files after an expected hash conflict.")
    conflict_env.bind_claude()
    conflict_prepared = conflict_env.prepare(conflict_seal["record_id"])
    conflict_env.vault.joinpath("wiki", "index.md").write_text("# External edit\n", encoding="utf-8")
    conflict, error = conflict_env.commit(conflict_seal["record_id"], conflict_prepared["approval_sha256"])
    check(not error and conflict["status"] == "pending" and not (conflict_env.home / "state" / "context-handoff" / "acks" / f"{conflict_seal['record_id']}.json").exists(), "expected-hash conflict acknowledged or mutated source state")
    rebuilt = conflict_env.bundle(conflict_seal["record_id"], suffix=" Updated")
    rebuilt["expected_hashes"]["wiki/index.md"] = digest(conflict_env.vault / "wiki" / "index.md")
    conflict_prepared_2 = conflict_env.prepare(conflict_seal["record_id"], rebuilt)
    recovered, error = conflict_env.commit(conflict_seal["record_id"], conflict_prepared_2["approval_sha256"])
    check(not error and recovered["status"] == "acknowledged", "fresh inspect after expected-hash conflict did not recover")

    lock_env = Environment(tmp, "held-lock")
    lock_env.enable(consumer_enabled=True)
    lock_seal = lock_env.make_ready_record("Preserve a pending record while the mutation lock is held.")
    lock_env.bind_claude()
    lock_prepared = lock_env.prepare(lock_seal["record_id"])
    lock_path = lock_env.vault / ".vault-meta" / "mutation.lock"
    lock_path.parent.mkdir(exist_ok=True)
    lock_path.write_text("held\n", encoding="utf-8")
    held, error = lock_env.commit(lock_seal["record_id"], lock_prepared["approval_sha256"])
    check(not error and held["status"] == "pending" and not (lock_env.home / "state" / "context-handoff" / "acks" / f"{lock_seal['record_id']}.json").exists(), "held lock did not preserve an unacknowledged pending record")
    lock_path.unlink()
    unlocked, error = lock_env.commit(lock_seal["record_id"], lock_prepared["approval_sha256"])
    check(not error and unlocked["status"] == "acknowledged", "held-lock retry did not recover")

    rollback_env = Environment(tmp, "transaction-crash")
    rollback_env.enable(consumer_enabled=True)
    rollback_seal = rollback_env.make_ready_record("Recover a rolled-back transaction before source acknowledgement.")
    rollback_env.bind_claude()
    rollback_prepared = rollback_env.prepare(rollback_seal["record_id"])
    rollback_bundle = rollback_env.home / "state" / "context-handoff" / "bundles" / rollback_seal["record_id"] / f"{rollback_prepared['bundle_sha256']}.json"
    crash = subprocess.run(
        [str(rollback_env.python), str(rollback_env.core), "transaction", "apply", str(rollback_bundle), "--vault", str(rollback_env.vault), "--approved-plan-sha256", rollback_prepared["approval_sha256"]],
        env={**rollback_env.base_env(), "FM_FIXTURE_FAIL_AFTER": "1"},
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
        timeout=45,
    )
    check(crash.returncode != 0 and not (rollback_env.home / "state" / "context-handoff" / "acks" / f"{rollback_seal['record_id']}.json").exists(), "crash during transaction incorrectly acknowledged the source")
    after_crash, error = rollback_env.commit(rollback_seal["record_id"], rollback_prepared["approval_sha256"])
    check(not error and after_crash["status"] == "acknowledged", "rolled-back transaction did not recover on retry")


def test_payload_mismatch_disable_and_dispositions(tmp: Path) -> None:
    source_changed = Environment(tmp, "consumer-source-changed")
    source_changed.enable(consumer_enabled=True)
    source_seal = source_changed.make_ready_record("Revalidate every exact source hash before curation.")
    source_changed.bind_claude()
    source_changed.source_file.write_text("Changed after registration.\n", encoding="utf-8")
    value, error = source_changed.mcp("next_curated_handoff", {})
    check(error and value["code"] == "SOURCE_HASH_MISMATCH", "consumer accepted a changed source hash")
    source_queue = json.loads((source_changed.home / "state" / "context-handoff" / "queue" / f"{source_seal['record_id']}.json").read_text())
    check(source_queue["status"] == "quarantined", "consumer did not quarantine a changed source hash")

    provider_changed = Environment(tmp, "consumer-provider-changed")
    provider_changed.enable(consumer_enabled=True)
    provider_seal = provider_changed.make_ready_record("Revalidate the destination provider class before curation.")
    provider_changed.bind_claude()
    config_path = provider_changed.home / "config" / "context-handoff.json"
    config_value = json.loads(config_path.read_text())
    config_value["allowed_provider_classes"] = ["different-approved-provider"]
    config_path.write_text(json.dumps(config_value, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
    value, error = provider_changed.mcp("next_curated_handoff", {})
    check(error and value["code"] == "PROVIDER_CLASS", "consumer accepted a refused provider class")
    provider_queue = json.loads((provider_changed.home / "state" / "context-handoff" / "queue" / f"{provider_seal['record_id']}.json").read_text())
    check(provider_queue["status"] == "quarantined", "consumer did not quarantine a refused provider class")

    mismatch = Environment(tmp, "payload-mismatch")
    mismatch.enable(consumer_enabled=True)
    seal = mismatch.make_ready_record()
    mismatch.bind_claude()
    record_path = mismatch.home / "state" / "context-handoff" / "records" / f"{seal['record_id']}.json"
    value = json.loads(record_path.read_text())
    value["items"][0]["statement"] = "Changed payload under the same stable record ID."
    record_path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
    record_path.chmod(0o600)
    next_value, error = mismatch.mcp("next_curated_handoff", {})
    check(error and next_value["code"] in {"ENVELOPE_BINDING", "PAYLOAD_MISMATCH"}, "changed payload under one ID was not refused")
    queue = json.loads((mismatch.home / "state" / "context-handoff" / "queue" / f"{seal['record_id']}.json").read_text())
    check(queue["status"] == "quarantined", "changed payload was not quarantined")

    disabled = Environment(tmp, "disable")
    disabled.enable(consumer_enabled=True)
    pending = disabled.make_ready_record("Preserve pending records across disable and re-enable.")
    disabled.bind_claude()
    records_before = sorted(path.read_bytes() for path in (disabled.home / "state" / "context-handoff" / "records").glob("*.json"))
    disabled.enable(sealing_enabled=False, delivery_enabled=False, consumer_enabled=False)
    value, error = disabled.mcp("next_curated_handoff", {})
    check(error and value["code"] == "CONSUMER_DISABLED", "disabled consumer continued")
    check(records_before == sorted(path.read_bytes() for path in (disabled.home / "state" / "context-handoff" / "records").glob("*.json")), "disable removed pending records")
    disabled.enable(consumer_enabled=True)
    disabled.bind_claude()
    value, error = disabled.mcp("next_curated_handoff", {})
    check(not error and value["record_id"] == pending["record_id"], "re-enable did not resume preserved pending record")
    disposed, error = disabled.mcp("record_curation_disposition", {"record_id": pending["record_id"], "disposition": "duplicate", "rationale": "The durable fact already exists in an authoritative note."})
    check(not error and disposed["status"] == "acknowledged", "duplicate disposition was not durably acknowledged")


def test_pi_extension_handlers_and_model_free_discovery(tmp: Path) -> None:
    env = Environment(tmp, "pi-extension")
    env.register("Cancel compaction only when this non-empty register cannot seal.")
    script = r'''
import { pathToFileURL } from "node:url";
const handlers = new Map();
const pi = { on(name, handler) { handlers.set(name, handler); } };
const mod = await import(pathToFileURL(process.env.EXT).href + `?v=${Date.now()}`);
mod.registerContextHandoff(pi, process.env.ROOT, process.env.FM_HOME);
for (const name of ["session_before_compact","session_compact","session_compact_failed"]) {
  if (!handlers.has(name)) throw new Error(`missing ${name}`);
}
const ctx = { sessionManager: { getSessionId() { return "pi-session-1"; } } };
process.env.FM_HANDOFF_TEST_FAILPOINT = "before-file-fsync";
const blocked = await handlers.get("session_before_compact")({ reason:"threshold" }, ctx);
if (!blocked?.cancel) throw new Error("non-empty seal failure did not cancel compaction");
delete process.env.FM_HANDOFF_TEST_FAILPOINT;
const allowed = await handlers.get("session_before_compact")({ reason:"overflow" }, ctx);
if (allowed?.cancel) throw new Error("durably sealed candidate cancelled compaction");
await handlers.get("session_compact_failed")({ reason:"overflow" }, ctx);
const retry = await handlers.get("session_before_compact")({ reason:"overflow" }, ctx);
if (retry?.cancel) throw new Error("failed compaction did not retain retryable seal");
await handlers.get("session_compact")({ reason:"overflow" }, ctx);
'''
    node_env = env.base_env()
    node_env.update({"EXT": str(ROOT / ".pi" / "extensions" / "lib" / "fm-context-handoff.ts"), "ROOT": str(ROOT), "PI_SESSION_ID": "pi-session-1"})
    completed = subprocess.run(["node", "--input-type=module"], input=script, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=ROOT, env=node_env, check=False, timeout=45)
    check(completed.returncode == 0, f"Pi extension model-free lifecycle smoke failed: {completed.stderr}")
    check(completed.stdout == "", "Pi extension smoke exposed output")
    validate = subprocess.run(["claude", "plugin", "validate", str(PLUGIN)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, cwd=ROOT, env={**os.environ, "HOME": str(env.root / "claude-home")}, check=False, timeout=45)
    check(validate.returncode == 0, f"Claude plugin model-free validation failed: {validate.stdout}{validate.stderr}")


def main() -> int:
    tests = [
        test_registration_sealing_and_rejections,
        test_caps_atomicity_and_failure_receipts,
        test_exact_delivery_and_no_launch,
        test_claude_hooks_guard_and_compaction,
        test_transaction_apply_replay_conflict_and_ack,
        test_payload_mismatch_disable_and_dispositions,
        test_pi_extension_handlers_and_model_free_discovery,
    ]
    with tempfile.TemporaryDirectory(prefix="fm-context-handoff-") as directory:
        root = Path(directory)
        for test in tests:
            try:
                test(root)
            except BaseException as exc:
                print(f"not ok - {test.__name__}: {exc}", file=sys.stderr)
                return 1
            print(f"ok - {test.__name__}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
