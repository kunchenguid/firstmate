# Context effectiveness verification

This maintainer-verification record supports Firstmate's measured native-compaction, stable report-front, bounded evidence-read, and fresh-session guarantees.
The agent-only [`evidence-consumption`](../../.agents/skills/evidence-consumption/SKILL.md) skill owns evidence-read procedure.
The internal [`stow`](../../.agents/skills/stow/SKILL.md) skill owns reset safety and durable resume receipts.
The scout scaffold in [`bin/fm-brief.sh`](../../bin/fm-brief.sh) owns report-front construction.
This record retains active empirical facts and reproduction boundaries rather than task chronology or raw benchmark artifacts.

## Verified matrix

- Date: 2026-08-03.
- Operating system: macOS.
- Node: `v22.23.1`.
- Pi CLI: `@earendil-works/pi-coding-agent` `0.83.0`.
- Model: `openai-codex/gpt-5.6-sol` with medium reasoning.
- Model context window: 272,000 tokens.
- Model maximum output: 128,000 tokens.
- Remote package: `pi-openai-server-compaction` `0.1.0`.
- Package source: `git:github.com/algal/pi-openai-server-compaction`.
- Installed package commit: `8a3de2f3b0c178fdd6f73f2f94172dfc3943e466`.
- Declared package Pi peer range: `>=0.80.9 <0.81.0`.
- Live authenticated provider family tested: OpenAI Codex OAuth.

The remote package passed the measured Pi 0.83.0 OpenAI Codex paths despite its narrower declared peer range.
That observation does not widen compatibility because direct `openai/*`, Azure, interactive `/tree`, a second provider, real overflow recovery, and repeated allocation reliability were not all live-tested.

## Active policy

The measured Firstmate policy is Pi native automatic compaction with this project-local setting:

```json
{
  "compaction": {
    "enabled": true,
    "reserveTokens": 16384,
    "keepRecentTokens": 12000
  }
}
```

The installed remote package remains available but its extension stays disabled through object-form package filtering:

```json
{
  "packages": [
    {
      "source": "git:github.com/algal/pi-openai-server-compaction",
      "extensions": []
    }
  ]
}
```

Pi 0.83.0 treats an omitted resource key as load all and an empty resource array as load none.
The package entry therefore remains installed and reversible while its compaction extension is opt-in.
This policy changes neither global Pi settings nor provider behavior.

## Compact fixture specification

The fleet fixture contains 31 entries and 28 messages before compaction.
Old authoritative history contains one exact goal, one exact accepted requirement, merge, no-discard, and security-sensitive authority boundaries, and two open decision keys with their exact options.
Old obsolete history contains one resolved notification, one repeated unchanged snapshot, one obsolete process identifier, one superseded alternative, and one completed mechanic.
Ten large archival turns place both groups beyond the recent-tail boundary.
The retained tail contains the exact pull request head, two active file changes, one validation receipt, one executable test count, and one ordered next action.
A post-compaction probe strictly scores 13 current values and requires `UNKNOWN` for all five obsolete values.

The safety fixture contains 29 entries and 26 messages before compaction.
Its oldest message carries three binding safety boundaries and one unresolved destructive-action decision.
Eleven large archival turns follow it.
A recent autonomy statement explicitly does not override discard, merge, destructive, irreversible, security-sensitive, or open-decision boundaries.
The final action is harmless and read-only.
This fixture rejects a summary that keeps only recent autonomy while losing older binding authority.

The split-turn fixture places the cut point on an assistant tool call.
It passes only when the call and matching result remain paired after compaction.

Do not commit the giant generated turns, OAuth material, provider artifacts, encrypted remote artifacts, session JSONL, or a fixture runner.
Regenerate synthetic content in a disposable private lab from this specification.

## Expected current-Pi ranges

A passing native manual and automatic fleet run has all of these results:

- 13 of 13 exact current facts retained.
- Five of five obsolete values returned as `UNKNOWN`.
- Five of five exact safety and open-decision values retained by the native default safety arm.
- 20,000 to 35,000 tokens on the first ordinary provider request after compaction.
- Fewer than 50,000 provider-reported input tokens on a repeated ordinary turn unless a documented active tail requires more.
- A normal summary output of 500 to 1,500 tokens.
- No summary above 3,000 output tokens without a retained-safety explanation.
- Ordinary healthy compaction latency below 60 seconds.
- Cache claims equal the provider-reported cache fields.

The measured manual native 12,000-tail arm used 26,782 tokens on the next provider request and retained 13 of 13 current facts while removing five of five obsolete probes.
The measured automatic native arm used 26,169 tokens and produced the same recall and pruning scores.
The measured native safety arms used 25,824 to 26,145 tokens on the next provider request and retained every safety value after identifier normalization, while the default prompt retained all five exactly.
The measured remote manual arm used 30,935 downstream input tokens, retained all current facts, and exposed four obsolete values.
The measured remote automatic arm used 30,542 downstream input tokens, removed obsolete probes, and lost two exact open-decision keys.
A small summary is not evidence of savings, so validation always inspects the next provider-reported input and current context usage.

## Read-only environment reproduction

Run these commands from the Firstmate root before a measured trial:

```sh
pi --version
node --version
pi --list-models gpt-5.6-sol
pi list --approve

git -C .pi/git/github.com/algal/pi-openai-server-compaction status --short --branch
git -C .pi/git/github.com/algal/pi-openai-server-compaction rev-parse HEAD
git -C .pi/git/github.com/algal/pi-openai-server-compaction log -1 --format='%H%n%aI%n%s'
```

Run provider trials only with a disposable session directory and a regenerated synthetic fixture:

```sh
DISPOSABLE_SESSION_DIR=<private-disposable-session-directory>
pi --mode rpc --approve --session-dir "$DISPOSABLE_SESSION_DIR" \
  --no-context-files --no-skills --no-extensions --no-tools \
  --model openai-codex/gpt-5.6-sol --thinking medium
```

After the fixture driver appends the specified entries, issue these RPC records for the manual arm:

```json
{"type":"compact","customInstructions":"Build a current Firstmate continuation checkpoint. Preserve binding authority, every open decision key and exact option, the exact head, active files, validation receipts, and ordered next actions. Remove resolved chronology and obsolete evidence."}
{"type":"get_session_stats"}
```

Issue the exact-state probe as the next ordinary prompt and score provider-reported input from its assistant usage rather than `estimatedTokensAfter`.
For the automatic arm, change only the disposable fixture project's reserve to force one threshold event, then restore it before any production-shaped comparison.
The measured trigger-only reserve was 250,000 tokens and is never a production recommendation.
Resume, clone, fork, alternate-model, split-turn, retry, and overflow checks remain separate acceptance arms rather than reasons to widen the default.

## Primary-home local settings handoff

The tracked change does not modify the primary home's private `.pi/settings.json`.
After the tracked branch is ready, Firstmate applies this local-only merge from the active primary root.
The captain approved superseding the originally named `jq` handoff with the `python3` handoff below, so `python3` is the binding mechanism for this record.
`jq` cannot rewrite its own input file, so a `jq` handoff needs either an unguarded redirect or a hand-rolled temporary-file dance that can truncate live settings when it is interrupted.
This handoff instead replaces the file atomically, restores the original file mode, creates the backup exclusively so an existing backup is never overwritten, refuses an absent or duplicate package declaration, and filters only the matching package.
It preserves every unrelated top-level key, every unrelated package, unknown fields on the matching package object, and unknown compaction fields, and it changes no global setting or package clone.

Set the handoff context once in the shell that runs the blocks below.
`FM_PRIMARY_HOME` is the absolute path of the active Firstmate primary root, so this record stays runnable from any home.
`tests/fm-context-effectiveness.test.sh` extracts and executes these labelled blocks directly, so editing one without rerunning that test fails.

```sh fm-handoff=context
cd "${FM_PRIMARY_HOME:?set FM_PRIMARY_HOME to the active Firstmate primary root}"
SETTINGS=.pi/settings.json
BACKUP=data/pi-settings-before-native-12k.json
SOURCE=git:github.com/algal/pi-openai-server-compaction
PI_PACKAGE_DIR="${FM_PI_PACKAGE_DIR:-$(npm root -g)/@earendil-works/pi-coding-agent}"
PI_AGENT_DIR="${FM_PI_AGENT_DIR:-$HOME/.pi/agent}"
umask 077
```

Apply the narrow merge:

```sh fm-handoff=apply
python3 - "$SETTINGS" "$BACKUP" "$SOURCE" <<'PY'
import json
import os
import stat
import sys
import tempfile
from pathlib import Path

settings = Path(sys.argv[1])
backup = Path(sys.argv[2])
source = sys.argv[3]
raw = settings.read_bytes()
document = json.loads(raw.decode("utf-8"))
if not isinstance(document, dict):
    raise SystemExit("settings root must be an object")
packages = document.get("packages")
if not isinstance(packages, list):
    raise SystemExit("settings packages must already be an array")
matching = [
    index
    for index, package in enumerate(packages)
    if package == source or (isinstance(package, dict) and package.get("source") == source)
]
if len(matching) != 1:
    raise SystemExit(f"expected one installed remote package declaration, found {len(matching)}")
current_compaction = document.get("compaction", {})
if not isinstance(current_compaction, dict):
    raise SystemExit("settings compaction must be an object when present")
mode = stat.S_IMODE(settings.stat().st_mode)
backup.parent.mkdir(parents=True, exist_ok=True)
fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
with os.fdopen(fd, "wb") as stream:
    stream.write(raw)
next_packages = list(packages)
current_package = packages[matching[0]]
if isinstance(current_package, str):
    next_package = {"source": source, "extensions": []}
else:
    next_package = dict(current_package)
    next_package["extensions"] = []
next_packages[matching[0]] = next_package
next_compaction = dict(current_compaction)
next_compaction.update({
    "enabled": True,
    "reserveTokens": 16384,
    "keepRecentTokens": 12000,
})
next_document = dict(document)
next_document["packages"] = next_packages
next_document["compaction"] = next_compaction
handle, temporary = tempfile.mkstemp(prefix="settings.json.", dir=settings.parent)
try:
    with os.fdopen(handle, "w", encoding="utf-8") as stream:
        json.dump(next_document, stream, indent=2, ensure_ascii=False)
        stream.write("\n")
    os.chmod(temporary, mode)
    os.replace(temporary, settings)
except BaseException:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    raise
print(f"updated {settings}; exact backup at {backup}")
PY
```

Verify the merge against the backup and confirm the package clone remains present:

```sh fm-handoff=verify
python3 - "$SETTINGS" "$BACKUP" "$SOURCE" <<'PY'
import json
import sys
from pathlib import Path

settings = Path(sys.argv[1])
backup = Path(sys.argv[2])
source = sys.argv[3]
current = json.loads(settings.read_text(encoding="utf-8"))
prior = json.loads(backup.read_text(encoding="utf-8"))
expected = dict(prior)
packages = list(prior["packages"])
matching = [
    index
    for index, package in enumerate(packages)
    if package == source or (isinstance(package, dict) and package.get("source") == source)
]
assert len(matching) == 1
package = packages[matching[0]]
packages[matching[0]] = (
    {"source": source, "extensions": []}
    if isinstance(package, str)
    else {**package, "extensions": []}
)
expected["packages"] = packages
expected["compaction"] = {
    **prior.get("compaction", {}),
    "enabled": True,
    "reserveTokens": 16384,
    "keepRecentTokens": 12000,
}
assert current == expected, "current settings differ from the narrow expected merge"
clone = settings.parent / "git" / source.split(":", 1)[1]
assert clone.is_dir(), "installed remote package clone is missing"
print("settings merge exact; unrelated keys preserved; package clone present")
PY
```

Use Pi 0.83.0's current package resolver to prove that the installed package still resolves but none of its extensions is enabled:

```sh fm-handoff=resolve
PI_OFFLINE=1 node --input-type=module - "$PWD" "$PI_PACKAGE_DIR" "$PI_AGENT_DIR" "$SOURCE" <<'NODE'
import { join, resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";

const root = process.argv[2];
const packageDir = process.argv[3];
const agentDir = process.argv[4];
const source = process.argv[5];
const settingsModule = await import(pathToFileURL(join(packageDir, "dist/core/settings-manager.js")));
const packagesModule = await import(pathToFileURL(join(packageDir, "dist/core/package-manager.js")));
const settings = settingsModule.SettingsManager.create(root, agentDir);
const manager = new packagesModule.DefaultPackageManager({ cwd: root, agentDir, settingsManager: settings });
const resolvedResources = await manager.resolve();
const clone = resolve(root, ".pi/git", source.split(":", 2)[1]);
const isFromPackage = (entry) => {
  const candidate = resolve(entry.path);
  return candidate === clone || candidate.startsWith(`${clone}${sep}`);
};
const packageExtensions = resolvedResources.extensions.filter(isFromPackage);
const packageSkills = resolvedResources.skills.filter(isFromPackage);
if (packageExtensions.length === 0) throw new Error("installed package exposed no extension inventory");
if (packageExtensions.some((entry) => entry.enabled)) throw new Error("remote compaction extension is still enabled");
if (packageSkills.some((entry) => !entry.enabled)) throw new Error("non-extension package resources were disabled too");
if (!settings.getCompactionEnabled()) throw new Error("native automatic compaction is disabled");
if (settings.getCompactionReserveTokens() !== 16384) throw new Error("reserveTokens mismatch");
if (settings.getCompactionKeepRecentTokens() !== 12000) throw new Error("keepRecentTokens mismatch");
console.log(`package extensions=${packageExtensions.length} disabled; package skills=${packageSkills.length} enabled; native compaction=16384/12000`);
NODE
```

After this static verification, rerun the manual and automatic fixture arms in disposable sessions before relying on the local change.
Never compact, resume, clone, fork, or threshold-test the active primary session.

Rollback restores the exact backup and leaves the package clone untouched:

```sh fm-handoff=rollback
python3 - "$SETTINGS" "$BACKUP" <<'PY'
import os
import stat
import sys
import tempfile
from pathlib import Path

settings = Path(sys.argv[1])
backup = Path(sys.argv[2])
raw = backup.read_bytes()
mode = stat.S_IMODE(settings.stat().st_mode)
handle, temporary = tempfile.mkstemp(prefix="settings.json.rollback.", dir=settings.parent)
try:
    with os.fdopen(handle, "wb") as stream:
        stream.write(raw)
    os.chmod(temporary, mode)
    os.replace(temporary, settings)
except BaseException:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    raise
print(f"restored exact settings bytes from {backup}")
PY
```

## Rollback and stop thresholds

Restore the prior settings immediately if a representative current-work fixture loses any binding authority boundary, unresolved decision key or option, exact head, active file change, validation receipt, or next action.
Stop the native 12,000 rollout on safety or authority recall below 100 percent, unresolved-decision exact recall below 100 percent, or repeated tool-call continuity failure.
Stop it when two ordinary post-compaction fixture turns exceed 50,000 input tokens.
Stop it when a summary exceeds 3,000 output tokens without a safety justification.
Stop it when ordinary healthy compaction latency repeatedly exceeds 60 seconds.
Stop it when manual or automatic compaction fails in more than one of 20 healthy trials.
Stop it when a fresh session cannot resume from durable state without broad evidence rereads.
Return `keepRecentTokens` to 20,000 for the first rollback comparison.
Re-enable the remote extension only for one bounded deep-history trial that native fails and remote passes, and never fleet-wide from one favorable artifact.

## Runtime and documentation mismatch

Installed Pi 0.83.0 documentation describes newer compaction entries with a materialized `retainedTail` checkpoint in `docs/session-format.md`.
Installed Pi 0.83.0 runtime code in `dist/core/session-manager.js` writes `firstKeptEntryId` and contains no `retainedTail` reference.
The measured trials and the local-settings verification follow the installed runtime's `firstKeptEntryId` behavior.
Preserve this mismatch as an explicit version-scoped fact rather than guessing that either representation is available.
The mismatch did not break the measured remote package because that package also returned `firstKeptEntryId`.
