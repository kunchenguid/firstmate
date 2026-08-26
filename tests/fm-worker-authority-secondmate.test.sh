#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# Hermetic coverage for the secondmate compartment evidence mode of
# bin/fm-worker-authority.py (R2/R3 PR 6, design B.7): the same
# fm.worker-release/v2 bundle with the same five receipt names, whose report,
# landing, and worktree receipts prove compartment closeout evidence when the
# ordinary task metadata records kind=secondmate - and whose bundle still
# passes the lifecycle's UNMODIFIED release_receipt and
# verify_release_against_worker, exercised here through the real release CLI.
#
# Durable-shape coupling, named: the terminal status file
# (state/<task>.cloud-secondmate-status: closed|idle|ttl-exhausted), the
# durable monitor state (state/<task>.cloud-secondmate-state.json with
# last_summary/landed_bundles/kept_bundles), and the collected mailbox
# (state/<task>.cloud-mailbox with <seq8>-<sha256>.json leg summaries,
# bundle-<seq8>-<sha256>.bundle files, and the sticky .chain-break marker)
# are the shapes bin/fm-secondmate-cloud-monitor.{sh,py} writes on branch
# fm/secondmate-cloud-monitor; these fixtures pin that contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AUTHORITY="$ROOT/bin/fm-worker-authority.py"
CONTROLLER="$ROOT/bin/fm-worker-lifecycle.py"
WRAPPER="$ROOT/bin/fm-worker-lifecycle.sh"
SUB=11111111-1111-4111-8111-111111111111

# One shared fixture builder: a primary home with the compartment evidence a
# closed-out secondmate leaves behind, plus the secondmate home worktree.
# <home> <task> <home-worktree> [unlanded]
# Builds a REAL git bundle from the home worktree, because the landing receipt
# now proves reachability from the bundle's own tip commit rather than trusting
# landed_bundles. With "unlanded", the home is rewound after bundling so the
# bundle's commit is genuinely absent from the home - the shape L0/L1 need.
write_compartment_fixture() {
  python3 - "$1" "$2" "$3" "${4:-landed}" <<'PY'
import hashlib
import json
from pathlib import Path
import subprocess
import sys

home = Path(sys.argv[1])
task = sys.argv[2]
worktree = Path(sys.argv[3])
mode = sys.argv[4]
state = home / "state"
state.mkdir(parents=True, exist_ok=True)

def git(*args):
    return subprocess.run(
        ["git", "-C", str(worktree), *args], text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout.strip()

base = git("rev-parse", "HEAD")
(worktree / "compartment-work.txt").write_text("work from the compartment\n")
git("add", "compartment-work.txt")
git("commit", "--quiet", "-m", "compartment leg work")
tip_commit = git("rev-parse", "HEAD")
bundle_path = state / "fixture.bundle"
git("bundle", "create", str(bundle_path), "{}..HEAD".format(base))
bundle_body = bundle_path.read_bytes()
bundle_path.unlink()
if mode == "unlanded":
    # The commits exist only in the bundle now, never in the home.
    git("reset", "--hard", base)
    git("clean", "-fd")
bundle_digest = hashlib.sha256(bundle_body).hexdigest()

(state / (task + ".cloud-secondmate-status")).write_text("closed\n")

mailbox = state / (task + ".cloud-mailbox")
mailbox.mkdir(exist_ok=True)
# A REAL collected chain: sequences 1..N with no gaps, each entry content
# addressed and chained onto the previous, exactly as the monitor collects
# them. delivered_sequence/verified_tip below must agree with what is here -
# the authority now refuses a mailbox holding fewer entries than the durable
# state claims, which is the rewound-outbox rule the monitor itself applies.
chain = "0" * 64
for sequence, body in enumerate((
    {"kind": "fm.secondmate-message/v1", "text": "checking in"},
    {
        "kind": "fm.secondmate-leg-summary/v1",
        "reason": "close",
        "legs_completed": 2,
        "bundles": [{
            "name": "session/out/bundle-00000001-{}.bundle".format(bundle_digest),
            "sha256": bundle_digest, "bytes": len(bundle_body), "commits": 1,
        }],
    },
), 1):
    message = dict(body, sequence=sequence)
    unsigned = json.dumps(message, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    content = hashlib.sha256(unsigned).hexdigest()
    chain = hashlib.sha256((chain + content).encode()).hexdigest()
    message["content_sha256"] = content
    message["chain_digest"] = chain
    (mailbox / "{:08d}-{}.json".format(sequence, content)).write_text(
        json.dumps(message, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
(mailbox / "bundle-00000001-{}.bundle".format(bundle_digest)).write_bytes(bundle_body)

# The durable state is written from the chain that was actually built, so the
# verified tip carries the REAL recomputed chain digest - the authority now
# re-derives the chain by content and requires it to reproduce this tip.
(state / (task + ".cloud-secondmate-state.json")).write_text(json.dumps({
    "delivered_sequence": 2,
    "landed_bundles": [bundle_digest],
    "kept_bundles": [],
    "last_summary": {"reason": "close", "legs_completed": 2},
    "verified_tip": {"sequence": 2, "chain_digest": chain},
}, sort_keys=True, separators=(",", ":")) + "\n")

report = home / "data" / task
report.mkdir(parents=True, exist_ok=True)
(report / "completion.md").write_text(
    "## Summary\nclosed\n## What changed\nx\n## Verification\nx\n"
    "## Visual evidence\nnone\n## Artifacts\nnone\n## Follow-ups\nnone\n")
print(bundle_digest)
print(chain)
print(tip_commit)
PY
}

write_home_worktree() {  # <path>
  git init --quiet -b main "$1"
  git -C "$1" config user.name Test
  git -C "$1" config user.email test@example.invalid
  printf 'charter\n' >"$1/charter.md"
  git -C "$1" add charter.md
  git -C "$1" commit --quiet -m charter
}

secondmate_evidence_refusal_matrix() {
  local tmp
  fm_test_tmproot_into tmp fm-authority-secondmate-matrix
  mkdir -p "$tmp/home"
  write_home_worktree "$tmp/subhome"
  fixture_out=$(write_compartment_fixture "$tmp/home" smc-1 "$tmp/subhome") || fail "compartment fixture build failed"
  bundle_digest=$(printf '%s\n' "$fixture_out" | sed -n 1p)
  honest_tip=$(printf '%s\n' "$fixture_out" | sed -n 2p)
  python3 - "$AUTHORITY" "$tmp/home" "$tmp/subhome" "$bundle_digest" "$honest_tip" <<'PY' || fail "a secondmate evidence leg refusal is missing or indistinct"
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location("worker_authority", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
home = Path(sys.argv[2])
subhome = Path(sys.argv[3])
bundle_digest = sys.argv[4]
task = "smc-1"
state = home / "state"
status_path = state / (task + ".cloud-secondmate-status")
state_path = state / (task + ".cloud-secondmate-state.json")
mailbox = state / (task + ".cloud-mailbox")
values = {"worktree": [str(subhome)]}

def monitor_state():
    return json.loads(state_path.read_text())

def put_state(value):
    state_path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")

def expect(callable_, fragment):
    try:
        callable_()
    except module.AuthorityError as exc:
        assert fragment in str(exc), (fragment, str(exc))
    else:
        raise AssertionError("no refusal: {}".format(fragment))

HEAD = module.git(subhome, "rev-parse", "HEAD")
HONEST_TIP = {"sequence": 2, "chain_digest": sys.argv[5]}

ABSENT = object()

def controller_worker(tip=None):
    """A worker record as the CONTROLLER hands it to the authority. The
    verified chain tip lives HERE, not in the monitor-local state file, which
    is what stops a forged chain from carrying its own matching anchor.
    tip=ABSENT models a compartment whose monitor has not recorded one."""
    if tip is ABSENT:
        return {}
    return {"verified_chain_tip": json.loads(json.dumps(HONEST_TIP)) if tip is None else tip}

def landing(generation=None, tip=None):
    return module.secondmate_landing_evidence(
        home, task, controller_worker(tip), subhome,
        generation if generation is not None else HEAD)

# The good fixture proves all three compartment legs.
report = module.secondmate_report_evidence(home, task)
assert report.startswith(b"closed\0close\x002\0"), report[:40]
assert b"## Summary" in report
landing_bytes = landing()
assert bundle_digest.encode() in landing_bytes
worktree_info, worktree = module.secondmate_worktree_evidence(home, task, values, controller_worker())
assert worktree == subhome.resolve()

# The ack mapping binds every terminal reason the monitor writes.
saved = monitor_state()
for terminal, ack in (("idle", "idle"), ("ttl-exhausted", "wall")):
    status_path.write_text(terminal + "\n")
    value = monitor_state()
    value["last_summary"]["reason"] = ack
    put_state(value)
    assert module.secondmate_report_evidence(home, task).startswith(
        "{}\0{}\x002\0".format(terminal, ack).encode())
status_path.write_text("closed\n")
put_state(saved)

# report: missing terminal status.
status_path.unlink()
expect(lambda: module.secondmate_report_evidence(home, task),
       "lacks the terminal session status")
# report: unrecognized terminal value.
status_path.write_text("done\n")
expect(lambda: module.secondmate_report_evidence(home, task),
       "terminal status is unrecognized")
status_path.write_text("closed\n")
# report: the chained close ack must MATCH the terminal reason.
value = monitor_state()
value["last_summary"]["reason"] = "idle"
put_state(value)
expect(lambda: module.secondmate_report_evidence(home, task),
       "lacks the chained close ack")
put_state(saved)
# report: no durable monitor state at all.
state_path.rename(str(state_path) + ".away")
expect(lambda: module.secondmate_report_evidence(home, task),
       "no durable monitor state")
expect(lambda: landing(),
       "no durable monitor state")
Path(str(state_path) + ".away").rename(state_path)
# landing: a bundle the monitor kept instead of landing.
value = monitor_state()
value["kept_bundles"] = [bundle_digest]
put_state(value)
expect(lambda: landing(),
       "kept unlanded")
put_state(saved)
# landed_bundles is ADVISORY: this home genuinely contains the bundle's
# commits, so emptying the monitor-local claim changes nothing. Landing is
# decided by reachability, not by what the file asserts. (The converse - a
# LYING claim over work that is genuinely absent - is L1 in its own unit.)
value = monitor_state()
value["landed_bundles"] = []
put_state(value)
landing()
module.secondmate_worktree_evidence(home, task, values, controller_worker())
# A collected bundle whose file is removed can no longer be proven landed:
# nothing names the commits it carried, so it refuses rather than assuming.
stashed = {}
for entry in list(mailbox.iterdir()):
    if entry.name.startswith("bundle-"):
        stashed[entry.name] = entry.read_bytes()
        entry.unlink()
expect(lambda: landing(), "its collected file is absent")
for name, body in stashed.items():
    (mailbox / name).write_bytes(body)
put_state(saved)
# landing: a collected-but-undeclared bundle FILE must also be landed.
# A collected-but-undeclared bundle file must ALSO be proven landed, so a
# planted one refuses - here at its own digest, before any git call.
stray = mailbox / ("bundle-00000009-" + "a" * 64 + ".bundle")
stray.write_bytes(b"stray")
expect(lambda: landing(), "differs from its digest")
stray.unlink()
# landing: a recorded chain break freezes the receipt...
(mailbox / ".chain-break").write_text("{}")
expect(lambda: landing(),
       "frozen by a recorded outbox chain break")
(mailbox / ".chain-break").unlink()
# ... and a DANGLING SYMLINK named .chain-break is still a marker: exists()
# follows it into nothing, which bypassed the freeze a real marker triggers.
(mailbox / ".chain-break").symlink_to(mailbox / "no-such-target")
expect(lambda: landing(),
       "frozen by a recorded outbox chain break")
(mailbox / ".chain-break").unlink()

# landing: THE FORGERY MATRIX. Every one of these minted all five proved
# receipts and passed the real release CLI at some earlier head, and each
# failure had the same shape: the check was anchored to something inside the
# attacker's write set. The mailbox and the monitor-local state file share one
# directory, so neither can anchor the other. The anchor is now the
# CONTROLLER-OWNED verified chain tip.
kept_entries = {entry.name: entry.read_bytes() for entry in mailbox.iterdir()}

def wipe_mailbox():
    for entry in list(mailbox.iterdir()):
        entry.unlink()

def restore_mailbox():
    for entry in list(mailbox.iterdir()):
        entry.unlink()
    for name, body in kept_entries.items():
        (mailbox / name).write_bytes(body)

def honest():
    """A fresh copy of the state the honest monitor wrote, so one forgery
    never inherits the previous one's edits."""
    return json.loads(json.dumps(saved))

def rebuild_chain(entries):
    """Write a self-consistent chain from genesis and return its tip digest -
    what an attacker who can recompute SHA-256 produces at will."""
    chain = "0" * 64
    for sequence, body in enumerate(entries, 1):
        message = dict(body, sequence=sequence)
        unsigned = json.dumps(
            message, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
        content = hashlib.sha256(unsigned).hexdigest()
        chain = hashlib.sha256((chain + content).encode()).hexdigest()
        message["content_sha256"] = content
        message["chain_digest"] = chain
        (mailbox / "{:08d}-{}.json".format(sequence, content)).write_text(
            json.dumps(message, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
    return chain

MESSAGE_ENTRY = {"kind": "fm.secondmate-message/v1", "text": "checking in"}
NO_BUNDLE_SUMMARY = {"kind": "fm.secondmate-leg-summary/v1", "reason": "close",
                     "legs_completed": 2, "bundles": []}

# THE ANCHOR ITSELF. Absent controller tip refuses and names the sanctioned
# exit; it is never inferred from monitor-local state.
expect(lambda: landing(tip=ABSENT),
       "controller-owned worker record carries no verified chain tip")
for malformed in ({"sequence": "2", "chain_digest": "a" * 64}, {"sequence": 2},
                  {"sequence": 0, "chain_digest": "a" * 64},
                  {"sequence": 2, "chain_digest": "nothex"}, {}):
    expect(lambda m=malformed: landing(tip=m), "controller-owned verified chain tip is malformed")

# F1: empty the mailbox and zero the monitor-local sequence fields. Those
# fields no longer supply the extent at all, so the controller tip still
# demands the full chain.
value = honest()
value["landed_bundles"] = []
value["delivered_sequence"] = 0
value.pop("verified_tip", None)
put_state(value)
wipe_mailbox()
expect(lambda: landing(), "a rewound or truncated outbox")

# F3: the monitor-local sequence as a string, negative, float, or absent - all
# inert now, for the same reason.
for forged in ("2", -1, 2.0, None, True, 99):
    value = honest()
    value["landed_bundles"] = []
    value["delivered_sequence"] = forged
    value["verified_tip"] = {"sequence": 99, "chain_digest": "c" * 64}
    put_state(value)
    wipe_mailbox()
    expect(lambda: landing(), "a rewound or truncated outbox")
put_state(saved)
restore_mailbox()

# F2, THE ISOLATING FORM: keep the honest mailbox EXACTLY as the monitor
# wrote it - same filenames, same content_sha256 and chain_digest fields, so
# the chain links and reproduces the tip perfectly - and rewrite only the leg
# summary's BODY to drop its `bundles` declaration, deleting the collected
# bundle file too. Every structural check still passes and the unlanded bundle
# vanishes from view; ONLY recomputing SHA-256 over the body catches it.
value = honest()
value["landed_bundles"] = []
put_state(value)
restore_mailbox()
summary_entry = None
for entry in sorted(mailbox.iterdir()):
    if entry.name.endswith(".json"):
        body = json.loads(entry.read_text())
        if body.get("kind") == "fm.secondmate-leg-summary/v1":
            summary_entry = entry
            break
assert summary_entry is not None, "fixture has no leg summary to rewrite"
tampered = json.loads(summary_entry.read_text())
assert tampered["bundles"], "fixture leg summary declares no bundle"
tampered["bundles"] = []
summary_entry.write_text(
    json.dumps(tampered, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
for entry in list(mailbox.iterdir()):
    if entry.name.startswith("bundle-"):
        entry.unlink()
expect(lambda: landing(), "content differs from its content address")
put_state(saved)
restore_mailbox()

# G1: a fresh, wholly self-consistent chain minted from genesis declaring no
# bundles, with a matching monitor-local tip. Internally perfect; it simply is
# not the chain this compartment spoke on, and only a tip the attacker cannot
# write can tell the difference.
value = honest()
value["landed_bundles"] = []
put_state(value)
wipe_mailbox()
forged_tip = rebuild_chain([MESSAGE_ENTRY, NO_BUNDLE_SUMMARY])
value = honest()
value["landed_bundles"] = []
value["verified_tip"] = {"sequence": 2, "chain_digest": forged_tip}
put_state(value)
expect(lambda: landing(), "does not reproduce the controller-owned verified tip")

# G2: the same trick at length one - a single-entry re-genesis chain with the
# monitor-local delivered/tip set to 1.
wipe_mailbox()
short_tip = rebuild_chain([NO_BUNDLE_SUMMARY])
value = honest()
value["landed_bundles"] = []
value["delivered_sequence"] = 1
value["verified_tip"] = {"sequence": 1, "chain_digest": short_tip}
put_state(value)
expect(lambda: landing(), "a rewound or truncated outbox")
# ... and even told the controller tip is length one, the digest is not ours.
expect(lambda: landing(tip={"sequence": 1, "chain_digest": short_tip.replace(short_tip[0], "0", 1)}),
       "controller-owned verified tip")
put_state(saved)
restore_mailbox()

# T7, THE SHARPEST: take F2's isolating forgery, which correctly refuses, and
# add EXACTLY ONE more field write in the same monitor-local file the attacker
# was already editing - recompute the rewritten entry's content address and
# chain digest, and update verified_tip to match. Entry 1 stays byte-identical
# to what the real monitor wrote. Surgical, not a wipe. That minted while the
# tip was monitor-local; against a controller-owned tip it cannot.
value = honest()
value["landed_bundles"] = []
put_state(value)
restore_mailbox()
entry_one_before = None
summary_entry = None
for entry in sorted(mailbox.iterdir()):
    if not entry.name.endswith(".json"):
        continue
    body = json.loads(entry.read_text())
    if body.get("kind") == "fm.secondmate-leg-summary/v1":
        summary_entry = entry
    elif body.get("sequence") == 1:
        entry_one_before = (entry.name, entry.read_bytes())
assert summary_entry is not None and entry_one_before is not None
first_chain = json.loads((mailbox / entry_one_before[0]).read_text())["chain_digest"]
tampered = json.loads(summary_entry.read_text())
tampered["bundles"] = []
unsigned = dict(tampered)
unsigned.pop("content_sha256", None)
unsigned.pop("chain_digest", None)
new_content = hashlib.sha256(json.dumps(
    unsigned, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()
new_chain = hashlib.sha256((first_chain + new_content).encode()).hexdigest()
tampered["content_sha256"] = new_content
tampered["chain_digest"] = new_chain
summary_entry.unlink()
(mailbox / "{:08d}-{}.json".format(2, new_content)).write_text(
    json.dumps(tampered, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
for entry in list(mailbox.iterdir()):
    if entry.name.startswith("bundle-"):
        entry.unlink()
value = honest()
value["landed_bundles"] = []
value["verified_tip"] = {"sequence": 2, "chain_digest": new_chain}
put_state(value)
# Entry 1 is untouched, exactly as the reviewer's T7 requires.
assert (mailbox / entry_one_before[0]).read_bytes() == entry_one_before[1]
expect(lambda: landing(), "does not reproduce the controller-owned verified tip")
put_state(saved)
restore_mailbox()

# A truncated chain, a wiped mailbox, and a symlinked one all still refuse.
wipe_mailbox()
expect(lambda: landing(), "a rewound or truncated outbox")
mailbox.rmdir()
expect(lambda: landing(), "mailbox is absent or redirected")
decoy = home / "state" / "decoy-mailbox"
decoy.mkdir()
mailbox.symlink_to(decoy)
expect(lambda: landing(), "mailbox is absent or redirected")
mailbox.unlink()
mailbox.mkdir()
restore_mailbox()

# landing: the compartment head must descend from the assignment's exact
# starting repository generation, the same lineage tether the ordinary lane
# applies - local files alone are not a landing proof.
expect(lambda: landing("0" * 40),
       "does not descend from the assignment repository generation")

# landing: "provably none" is about BUNDLES, not about an empty chain. A
# VERIFIED chain whose leg summaries declare nothing, with nothing collected,
# proves - and that is the only shape that does.
value = honest()
value["landed_bundles"] = []
put_state(value)
wipe_mailbox()
chain = "0" * 64
for sequence, body in enumerate((
    {"kind": "fm.secondmate-message/v1", "text": "checking in"},
    {"kind": "fm.secondmate-leg-summary/v1", "reason": "close", "legs_completed": 2, "bundles": []},
), 1):
    message = dict(body, sequence=sequence)
    unsigned = json.dumps(message, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    content = hashlib.sha256(unsigned).hexdigest()
    chain = hashlib.sha256((chain + content).encode()).hexdigest()
    message["content_sha256"] = content
    message["chain_digest"] = chain
    (mailbox / "{:08d}-{}.json".format(sequence, content)).write_text(
        json.dumps(message, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
value = honest()
value["landed_bundles"] = []
put_state(value)
# The CONTROLLER tip is what must match; the monitor-local one is inert now.
empty = landing(tip={"sequence": 2, "chain_digest": chain})
# "landed" is now a PROOF map (digest -> reachable tip commits), so an honest
# chain declaring nothing proves with both sides empty.
assert b'"declared":[]' in empty and b'"landed":{}' in empty
put_state(saved)
restore_mailbox()

# worktree: tracked modifications are not a quiesced home.
(subhome / "charter.md").write_text("edited\n")
expect(lambda: module.secondmate_worktree_evidence(home, task, values, controller_worker()),
       "not quiesced: uncommitted or untracked work remains")
import subprocess
subprocess.run(["git", "-C", str(subhome), "checkout", "--", "charter.md"], check=True)
module.secondmate_worktree_evidence(home, task, values, controller_worker())
# UNTRACKED never-added work is work left behind too: a release receipt
# answers "is anything left here", not the monitor's narrower "can I
# fast-forward into this", and the ordinary lane has always refused it.
(subhome / "new_feature.py").write_text("print('unsaved')\n")
expect(lambda: module.secondmate_worktree_evidence(home, task, values, controller_worker()),
       "not quiesced: uncommitted or untracked work remains")
(subhome / "new_feature.py").unlink()
# A gitignored runtime path is still not "work left behind": --untracked-files=all
# never lists ignored paths, which is why the ordinary strictness is safe here.
(subhome / ".gitignore").write_text("runtime/\n")
subprocess.run(["git", "-C", str(subhome), "add", ".gitignore"], check=True)
subprocess.run(["git", "-C", str(subhome), "commit", "--quiet", "-m", "ignore runtime"], check=True)
(subhome / "runtime").mkdir()
(subhome / "runtime" / "monitor.log").write_text("noise\n")
module.secondmate_worktree_evidence(home, task, values, controller_worker())
PY
  pass "every secondmate evidence leg refuses distinctly and the ack mapping binds all three terminals"
}

secondmate_authority_bundle_end_to_end() {
  local tmp
  fm_test_tmproot_into tmp fm-authority-secondmate-e2e
  mkdir -p "$tmp/home" "$tmp/accounts/codex/1" "$tmp/shim"
  cat > "$tmp/accounts/codex/1/auth.json" <<'EOF'
{"openai-codex":{"type":"oauth","access":"fixture-access","refresh":"fixture-refresh","accountId":"fixture-account","expires":4102444800000}}
EOF
  cat > "$tmp/shim/tmux" <<'SH'
#!/bin/sh
echo "no server running on /tmp/fm-secondmate-authority-test" >&2
exit 1
SH
  chmod +x "$tmp/shim/tmux"
  write_home_worktree "$tmp/subhome"
  e2e_fixture=$(write_compartment_fixture "$tmp/home" smc-1 "$tmp/subhome") || fail "compartment fixture build failed"
  e2e_tip=$(printf '%s\n' "$e2e_fixture" | sed -n 2p)
  cat > "$tmp/home/state/smc-1.meta" <<EOF
window=fmtest:1
worktree=$tmp/subhome
kind=secondmate
mode=secondmate
placement=azure
worker_account_home=$tmp/accounts/codex/1
worker_account_profile=fixture-profile
yolo=off
generation_id=gen-s1
account_home=$tmp/accounts/codex/1
account_task=smc-1
EOF
  PATH="$tmp/shim:$PATH" \
  FM_ACCOUNT_DIRECTORY_TEST_LAB=firstmate-account-directory-test-lab-v1 \
  FM_ACCOUNT_DIRECTORY_ROOT="$tmp/accounts" \
  FM_HOME="$tmp/home" \
  FM_AZURE_SUBSCRIPTION_ID=$SUB \
  FM_AZURE_DEPLOYMENT_GENERATION=dep-one \
  FM_AZURE_OWNER_TAG=owner \
  FM_AZURE_NAMING_PREFIX=fmtest \
  python3 - "$AUTHORITY" "$CONTROLLER" "$WRAPPER" "$tmp/home" "$e2e_tip" <<'PY' || fail "the secondmate authority bundle did not verify through the unmodified release path"
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

authority, controller_path, wrapper, home_raw, honest_tip = sys.argv[1:]
home = Path(home_raw)

spec = importlib.util.spec_from_file_location("controller", controller_path)
controller = importlib.util.module_from_spec(spec)
spec.loader.exec_module(controller)
authority_spec = importlib.util.spec_from_file_location("authority", authority)
authority_module = importlib.util.module_from_spec(authority_spec)
authority_spec.loader.exec_module(authority_module)

# One assigned compartment in REAL durable controller state, hand-minted
# through the module's own constructors so load_state/verify_state accept it.
menv = controller.environment()
state = controller.empty_state(menv)
resources = {
    kind: {"id": "/fixture/slot/1/{}".format(kind), "immutable_id": "{}-1".format(kind)}
    for kind in controller.REQUIRED_RESOURCE_KINDS
}
# The compartment landing receipt is tethered to the controller-owned
# repository generation, so the fixture binds the home's REAL starting head.
subhome_path = Path(
    (home / "state" / "smc-1.meta").read_text().splitlines()[1].split("=", 1)[1])
start_head = subprocess.run(
    ["git", "-C", str(subhome_path), "rev-parse", "HEAD"],
    text=True, stdout=subprocess.PIPE, check=True).stdout.strip()
credential = json.loads((home.parent / "accounts" / "codex" / "1" / "auth.json").read_text())["openai-codex"]
upstream_account = authority_module.load_pi_projection().account_digest(credential)
account_binding = authority_module.digest({"provider": "pi", "upstream_account": upstream_account})
bindings = {
    "home_binding": "1" * 64, "task": "smc-1", "task_generation": "gen-s1",
    "assignment_generation": "asg-00000001", "account_binding": account_binding,
    "worktree_binding": "3" * 64, "repository_binding": "4" * 64,
    "repository_generation": start_head,
}
worker = {
    "slot": 1, "role": "secondmate", "sku": "sku", "sku_family": "fam",
    "deployment_generation": menv["deployment_generation"], "owner": menv["owner"],
    "assignment_generation": "asg-00000001", "cloud_generation": 1,
    "bindings": bindings, "queue_key": "smc-1@gen-s1", "phase": "assigned",
    "created_at": controller.iso_utc(), "assigned_at": controller.iso_utc(),
    "released_at": None, "release_proof": None, "cooldown_started_at": None,
    "reservation_usd": 1.0, "resources": resources, "cloud_instance_id": "cloud-1",
    "account_lease": {"account_home": str(home.parent / "accounts" / "codex" / "1"),
                      "account_profile": "fixture-profile"},
    "last_classification": "assigned", "last_refusal": None,
}
state["queue"]["smc-1@gen-s1"] = {
    "schema": "fm.worker-request/v1", "task": "smc-1", "task_generation": "gen-s1",
    "owner_kind": "primary", "role": "secondmate", "eligible": True,
    "discretionary": True, "status": "assigned", "slot": 1,
    "assignment_generation": "asg-00000001",
    "account_home": str(home.parent / "accounts" / "codex" / "1"),
    "account_profile": "fixture-profile", **bindings,
}
state["workers"]["1"] = worker
# The verified chain tip is CONTROLLER-owned. It is recorded below through the
# real compartment-chain-tip CLI, so this exercise covers the whole path the
# monitor will use rather than hand-planting the anchor.
menv["state_dir"].mkdir(parents=True, exist_ok=True)
menv["state_path"].write_text(json.dumps(state, sort_keys=True, separators=(",", ":")) + "\n")

# Record the tip through the REAL CLI, under the controller lock, exactly as
# the monitor will. This also proves the new command's own gates: it refuses a
# rewind and a same-sequence fork.
def record_tip(sequence, digest, check=True):
    result = subprocess.run(
        [wrapper, "compartment-chain-tip", "--task", "smc-1",
         "--task-generation", "gen-s1", "--assignment-generation", "asg-00000001",
         "--sequence", str(sequence), "--chain-digest", digest],
        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=os.environ.copy())
    if check and result.returncode != 0:
        raise AssertionError("compartment-chain-tip failed: {}".format(result.stderr))
    return result

record_tip(1, "d" * 64)
rewound = record_tip(1, "e" * 64, check=False)
assert rewound.returncode != 0 and "already recorded a different digest" in rewound.stderr, rewound.stderr
record_tip(2, honest_tip)
back = record_tip(1, "d" * 64, check=False)
assert back.returncode != 0 and "refuses to rewind" in back.stderr, back.stderr
recorded = json.loads(menv["state_path"].read_text())["workers"]["1"]["verified_chain_tip"]
assert recorded["sequence"] == 2 and recorded["chain_digest"] == honest_tip, recorded

worker_state = home / "worker-state.json"
worker = json.loads(menv["state_path"].read_text())["workers"]["1"]
worker_state.write_text(json.dumps(worker, sort_keys=True, separators=(",", ":")))
proof_path = home / "smc-1-proof.json"

def authority_run():
    return subprocess.run([
        "python3", authority, "--home", str(home), "--task", "smc-1",
        "--task-generation", "gen-s1", "--assignment-generation", "asg-00000001",
        "--worker-state", str(worker_state), "--output", str(proof_path),
    ], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

# Each missing compartment evidence leg refuses the REAL CLI distinctly.
smstate = home / "state"
status_path = smstate / "smc-1.cloud-secondmate-status"
monitor_path = smstate / "smc-1.cloud-secondmate-state.json"
terminal = status_path.read_text()
status_path.unlink()
refused = authority_run()
assert refused.returncode == 2 and "lacks the terminal session status" in refused.stderr, refused.stderr
status_path.write_text(terminal)

monitor = json.loads(monitor_path.read_text())
broken = json.loads(monitor_path.read_text())
broken["last_summary"]["reason"] = "idle"
monitor_path.write_text(json.dumps(broken, sort_keys=True, separators=(",", ":")))
refused = authority_run()
assert refused.returncode == 2 and "lacks the chained close ack" in refused.stderr, refused.stderr

# L1 THROUGH THE REAL CLI: landed_bundles is advisory, so emptying it over a
# genuinely-landed home changes nothing, and REMOVING the bundle file - the
# only thing that names the landed commits - refuses.
broken = json.loads(monitor_path.read_text())
broken["last_summary"]["reason"] = "close"
broken["landed_bundles"] = []
monitor_path.write_text(json.dumps(broken, sort_keys=True, separators=(",", ":")))
advisory = authority_run()
assert advisory.returncode == 0, advisory.stderr
mailbox_dir = smstate / "smc-1.cloud-mailbox"
stashed = {}
for entry in list(mailbox_dir.iterdir()):
    if entry.name.startswith("bundle-"):
        stashed[entry.name] = entry.read_bytes()
        entry.unlink()
refused = authority_run()
assert refused.returncode == 2 and "its collected file is absent" in refused.stderr, refused.stderr
for name, body in stashed.items():
    (mailbox_dir / name).write_bytes(body)
monitor_path.write_text(json.dumps(monitor, sort_keys=True, separators=(",", ":")))

subhome = subhome_path
(subhome / "charter.md").write_text("dirty\n")
refused = authority_run()
assert refused.returncode == 2 and "not quiesced: uncommitted or untracked work remains" in refused.stderr, refused.stderr
subprocess.run(["git", "-C", str(subhome), "checkout", "--", "charter.md"], check=True)

# The complete fixture mints five proved receipts.
minted = authority_run()
assert minted.returncode == 0, minted.stderr
proof = json.loads(proof_path.read_text())
assert proof["schema"] == "fm.worker-release/v2"
assert sorted(proof["authorities"]) == ["account", "endpoint", "landing", "report", "worktree"]
assert all(value["verdict"] == "proved" for value in proof["authorities"].values())
assert proof["assignment_generation"] == "asg-00000001"

# The UNMODIFIED release byte-path: the real CLI accepts the bundle...
released = subprocess.run(
    [wrapper, "release", "--task", "smc-1", "--task-generation", "gen-s1",
     "--proof-file", str(proof_path)],
    text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=os.environ.copy())
assert released.returncode == 0, released.stderr
after = json.loads(menv["state_path"].read_text())
assert after["queue"]["smc-1@gen-s1"]["status"] == "releasing"
assert after["workers"]["1"]["release_proof"] == proof

# ... and refuses a tampered receipt through the same unmodified validators:
# a fully re-signed non-proved verdict still cannot release.
import hashlib
def resign(value):
    unsigned = dict(value)
    unsigned.pop("receipt_digest", None)
    unsigned.pop("proof_digest", None)
    return hashlib.sha256(json.dumps(unsigned, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
tampered = json.loads(proof_path.read_text())
tampered["authorities"]["report"]["verdict"] = "surrendered"
tampered["authorities"]["report"]["receipt_digest"] = resign(tampered["authorities"]["report"])
tampered["proof_digest"] = resign(tampered)
tampered_path = home / "tampered-proof.json"
tampered_path.write_text(json.dumps(tampered, sort_keys=True, separators=(",", ":")))
menv["state_path"].write_text(json.dumps(state, sort_keys=True, separators=(",", ":")) + "\n")
refused = subprocess.run(
    [wrapper, "release", "--task", "smc-1", "--task-generation", "gen-s1",
     "--proof-file", str(tampered_path)],
    text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=os.environ.copy())
assert refused.returncode != 0 and "did not prove release safety" in refused.stderr, refused.stderr
PY
  pass "the secondmate bundle proves five receipts and releases through the unmodified verify path"
}

ordinary_mode_selection_golden() {
  # kind selects the mode: a non-secondmate meta must take the ORDINARY
  # evidence path (its refusal strings, not the compartment ones), and an
  # ambiguous kind refuses outright.
  local tmp
  fm_test_tmproot_into tmp fm-authority-mode-golden
  mkdir -p "$tmp/home/state" "$tmp/accounts/codex/1" "$tmp/shim"
  cat > "$tmp/shim/tmux" <<'SH'
#!/bin/sh
echo "no server running on /tmp/fm-secondmate-authority-test" >&2
exit 1
SH
  chmod +x "$tmp/shim/tmux"
  write_home_worktree "$tmp/subhome"
  cat > "$tmp/home/state/task-o.meta" <<EOF
window=fmtest:1
worktree=$tmp/subhome
kind=ship
generation_id=gen-o
account_home=$tmp/accounts/codex/1
account_task=task-o
EOF
  PATH="$tmp/shim:$PATH" python3 - "$AUTHORITY" "$tmp/home" <<'PY' || fail "kind-based evidence mode selection failed"
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

authority, home_raw = sys.argv[1:]
home = Path(home_raw)
worker_state = home / "worker-state.json"
worker_state.write_text(json.dumps({
    "assignment_generation": "asg-00000001",
    "bindings": {"repository_generation": "repo-o", "home_binding": "1" * 64,
                 "account_binding": "2" * 64, "worktree_binding": "3" * 64,
                 "repository_binding": "4" * 64},
    "cloud_instance_id": "cloud-1", "resources": {},
}))

def run(task):
    return subprocess.run([
        "python3", authority, "--home", str(home), "--task", task,
        "--task-generation", "gen-o", "--assignment-generation", "asg-00000001",
        "--worker-state", str(worker_state), "--output", str(home / "out.json"),
    ], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

# kind=ship: the ordinary lane runs - no compartment file is consulted; with
# the endpoint provably absent, the first refusal is the ORDINARY report one
# (no completion.md), never the secondmate terminal-status string.
result = run("task-o")
assert result.returncode == 2, result.stderr
assert "secondmate" not in result.stderr, result.stderr
assert "completion report authority is absent" in result.stderr, result.stderr

# An ambiguous kind refuses before any evidence is weighed.
meta = home / "state" / "task-o.meta"
meta.write_text(meta.read_text() + "kind=secondmate\n")
result = run("task-o")
assert result.returncode == 2 and "kind identity is not exact" in result.stderr, result.stderr
PY
  pass "evidence mode selection follows the exact task metadata kind"
}

role_kind_cross_check() {
  # The adversarial finding this closes: the evidence mode used to be chosen
  # from the LOCAL task meta's kind= line alone. Flipping that one line (plus
  # planting the two compartment state files) moved a role=author worker
  # holding an UNLANDED COMMIT onto the compartment lane, where the ordinary
  # "reachable from origin" landing proof does not apply - all five receipts
  # minted proved and the real release moved the queue to `releasing` with the
  # work still only local. The controller-owned role decides now, and both
  # directions refuse.
  local tmp
  fm_test_tmproot_into tmp fm-authority-role-kind
  mkdir -p "$tmp/home" "$tmp/accounts/codex/1" "$tmp/shim"
  cat > "$tmp/shim/tmux" <<'SH'
#!/bin/sh
echo "no server running on /tmp/fm-secondmate-authority-test" >&2
exit 1
SH
  chmod +x "$tmp/shim/tmux"
  write_home_worktree "$tmp/subhome"
  # A REAL origin with the base commit pushed, then an UNLANDED commit on top:
  # the ordinary landing authority reaches its own proof and refuses because
  # the work is not reachable from origin - which is exactly the refusal the
  # compartment lane was bypassing.
  git init --quiet --bare "$tmp/origin.git"
  git -C "$tmp/origin.git" symbolic-ref HEAD refs/heads/main
  git -C "$tmp/subhome" remote add origin "$tmp/origin.git"
  git -C "$tmp/subhome" push --quiet -u origin main
  printf 'unlanded\n' >"$tmp/subhome/feature.txt"
  git -C "$tmp/subhome" add feature.txt
  git -C "$tmp/subhome" commit --quiet -m "UNLANDED WORK"
  rk_fixture=$(write_compartment_fixture "$tmp/home" task-a "$tmp/subhome") || fail "compartment fixture build failed"
  rk_tip=$(printf '%s\n' "$rk_fixture" | sed -n 2p)
  cat > "$tmp/home/state/task-a.meta" <<EOF
window=fmtest:1
worktree=$tmp/subhome
kind=ship
generation_id=gen-a
account_home=$tmp/accounts/codex/1
account_task=task-a
EOF
  PATH="$tmp/shim:$PATH" \
  FM_ACCOUNT_DIRECTORY_TEST_LAB=firstmate-account-directory-test-lab-v1 \
  FM_ACCOUNT_DIRECTORY_ROOT="$tmp/accounts" \
  python3 - "$AUTHORITY" "$tmp/home" "$tmp/subhome" "$rk_tip" <<'PY' || fail "the controller role does not decide the evidence mode"
import json
from pathlib import Path
import subprocess
import sys

authority, home_raw, subhome_raw, honest_tip = sys.argv[1:]
home = Path(home_raw)
subhome = Path(subhome_raw)
meta = home / "state" / "task-a.meta"
worker_state = home / "worker-state.json"
head = subprocess.run(["git", "-C", str(subhome), "rev-parse", "HEAD"],
                      text=True, stdout=subprocess.PIPE, check=True).stdout.strip()

def write_worker(role):
    worker = {
        "assignment_generation": "asg-00000001", "role": role,
        "bindings": {"repository_generation": head, "home_binding": "1" * 64,
                     "account_binding": "2" * 64, "worktree_binding": "3" * 64,
                     "repository_binding": "4" * 64},
        "cloud_instance_id": "cloud-1", "resources": {},
        # Controller-owned: the compartment lane needs its verified chain tip
        # here, never from the monitor-local state file.
        "verified_chain_tip": {"sequence": 2, "chain_digest": honest_tip},
    }
    worker_state.write_text(json.dumps(worker, sort_keys=True, separators=(",", ":")))

def set_kind(kind):
    lines = [line for line in meta.read_text().splitlines() if not line.startswith("kind=")]
    lines.insert(3, "kind=" + kind)
    meta.write_text("\n".join(lines) + "\n")

def run():
    return subprocess.run([
        "python3", authority, "--home", str(home), "--task", "task-a",
        "--task-generation", "gen-a", "--assignment-generation", "asg-00000001",
        "--worker-state", str(worker_state), "--output", str(home / "out.json"),
    ], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

# The reviewer's exact escalation: an ORDINARY author worker whose meta claims
# a compartment. It must refuse on the role mismatch, never mint.
write_worker("author")
set_kind("secondmate")
result = run()
assert result.returncode == 2, (result.returncode, result.stdout)
assert "the controller-owned worker role is 'author'" in result.stderr, result.stderr
assert not (home / "out.json").exists(), "a refused authority still wrote a bundle"

# Control: the SAME author worker on its honest meta refuses for the ordinary
# reason - the commit is genuinely not landed. This is what the compartment
# lane was letting through.
set_kind("ship")
result = run()
assert result.returncode == 2, result.stdout
assert "landing authority did not prove committed work reachable" in result.stderr, result.stderr

# The mirror direction: a controller-owned compartment whose meta says
# otherwise refuses too, rather than quietly taking the ordinary lane.
write_worker("secondmate")
set_kind("ship")
result = run()
assert result.returncode == 2, result.stdout
assert "the task metadata kind is 'ship'" in result.stderr, result.stderr

# Positive control: role and kind agreeing on secondmate reaches the
# compartment evidence and mints (the fixture is a clean closed-out home).
set_kind("secondmate")
result = run()
assert result.returncode == 0, result.stderr
proof = json.loads((home / "out.json").read_text())
assert all(v["verdict"] == "proved" for v in proof["authorities"].values()), proof["authorities"]
PY
  pass "the controller-owned worker role decides the evidence mode in both directions"
}

landed_bundles_is_not_a_proof() {
  # THE L0/L1 ESCALATION. With an honest content-verified chain and an honest
  # controller-owned tip, the receipt still rested on landed_bundles - a bare
  # assertion in the attacker-writable durable file. Naming a digest there
  # minted a landing proof for commits that were nowhere in the home: one file
  # write, no CLI and no hashing, falsifying the receipt's own sentence.
  # Landing is now proven by reachability from the collected bundle's own tip.
  local tmp
  fm_test_tmproot_into tmp fm-authority-landed-claim
  mkdir -p "$tmp/home" "$tmp/shim"
  cat > "$tmp/shim/tmux" <<'SH'
#!/bin/sh
echo "no server running on /tmp/fm-secondmate-authority-test" >&2
exit 1
SH
  chmod +x "$tmp/shim/tmux"
  write_home_worktree "$tmp/subhome"
  # "unlanded": the bundle is built and the home is then rewound, so the
  # compartment's commits exist ONLY inside the bundle.
  fixture_out=$(write_compartment_fixture "$tmp/home" smc-1 "$tmp/subhome" unlanded) \
    || fail "compartment fixture build failed"
  bundle_digest=$(printf '%s\n' "$fixture_out" | sed -n 1p)
  honest_tip=$(printf '%s\n' "$fixture_out" | sed -n 2p)
  tip_commit=$(printf '%s\n' "$fixture_out" | sed -n 3p)
  PATH="$tmp/shim:$PATH" python3 - "$AUTHORITY" "$tmp/home" "$tmp/subhome" \
    "$bundle_digest" "$honest_tip" "$tip_commit" <<'PY' || fail "landed_bundles is still taken on trust"
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

spec = importlib.util.spec_from_file_location("worker_authority", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
home = Path(sys.argv[2])
subhome = Path(sys.argv[3])
bundle_digest, honest_tip, tip_commit = sys.argv[4:7]
task = "smc-1"
state_path = home / "state" / (task + ".cloud-secondmate-state.json")
HEAD = module.git(subhome, "rev-parse", "HEAD")

def worker():
    return {"verified_chain_tip": {"sequence": 2, "chain_digest": honest_tip}}

def landing():
    return module.secondmate_landing_evidence(home, task, worker(), subhome, HEAD)

def put(landed):
    value = json.loads(state_path.read_text())
    value["landed_bundles"] = landed
    state_path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")

# The premise: the compartment's commits are genuinely NOT in this home.
reachable = subprocess.run(
    ["git", "-C", str(subhome), "merge-base", "--is-ancestor", tip_commit, HEAD],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
assert reachable.returncode != 0, "fixture failure: the bundle's commit IS in the home"

# L0: the truthful claim refuses, as it always did.
put([])
try:
    landing()
except module.AuthorityError as exc:
    assert "not reachable from the home worktree head" in str(exc), exc
else:
    raise AssertionError("L0: unlanded work proved landed")

# L1: THE LIE. Naming the digest in landed_bundles used to mint all five
# receipts and pass the real release. It must now change nothing.
put([bundle_digest])
try:
    landing()
except module.AuthorityError as exc:
    assert "not reachable from the home worktree head" in str(exc), exc
else:
    raise AssertionError("L1: a lying landed_bundles still proved landing")

# The worktree receipt refuses on the same evidence, not on the same claim.
values = {"worktree": [str(subhome)]}
try:
    module.secondmate_worktree_evidence(home, task, values, worker())
except module.AuthorityError as exc:
    assert "not quiesced: unlanded outbox bundles remain" in str(exc), exc
else:
    raise AssertionError("L1: the worktree receipt accepted the claim")

# THE HONEST CONTROL: actually land the work, and the same fixture proves -
# with landed_bundles still EMPTY, since the file is advisory either way.
bundle_path = home / "state" / (task + ".cloud-mailbox") / (
    "bundle-00000001-{}.bundle".format(bundle_digest))
subprocess.run(["git", "-C", str(subhome), "fetch", "--quiet", "--no-tags",
                str(bundle_path), "HEAD"], check=True)
subprocess.run(["git", "-C", str(subhome), "merge", "--ff-only", "FETCH_HEAD"],
               check=True, stdout=subprocess.DEVNULL)
landed_head = module.git(subhome, "rev-parse", "HEAD")
put([])
evidence = module.secondmate_landing_evidence(home, task, worker(), subhome, landed_head)
assert tip_commit.encode() in evidence, evidence
module.secondmate_worktree_evidence(home, task, values, worker())
PY
  pass "landing is proven by reachability; a lying landed_bundles proves nothing"
}

secondmate_evidence_refusal_matrix
landed_bundles_is_not_a_proof
secondmate_authority_bundle_end_to_end
ordinary_mode_selection_golden
role_kind_cross_check

echo "# fm-worker-authority-secondmate.test.sh: all assertions passed"
