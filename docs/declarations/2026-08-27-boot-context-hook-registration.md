# Declaration: register the boot-context emitter as a SessionStart hook

**Target repo:** `mac-config` (`https://github.com/stoneevenson-biz/mac-config`, default branch `main`, registered `[direct-PR]`).
**Status:** NOT APPLIED. This file is the exact content a dependent task applies. Nothing here has been written to `~/.claude/settings.json`, to `mac-config`, or anywhere outside this repo.
**Unblocks:** gate `m1-hook-registered`, which is frozen red in `gates/ledger.json` and goes green on `stone apply` with no further change in firstmate.
**Spec:** `docs/specs/2026-08-27-n-concurrent-firstmates.md` section 5.

---

## Why this is not a firstmate change

`~/.claude/settings.json` is not a file anyone edits. It is **rendered** from `mac-config`'s desired state (`desired/registry.yaml:88-90`, `render: json`), and a render **deletes every key it does not declare**. A hand-written hook entry would work until the next `stone apply` and then silently revert — a boot path that is intermittently blind, which is strictly worse than one that is reliably blind. It would also be blocked three other ways: the `Edit(~/.claude/settings.json)` permissions deny rule, and validators V12, V13 and V15.

So registration is a declared change in the control plane, applied there, rendered from there.

**Note a two-claimant conflict, so the applying task does not trip over it:** `~/.claude/settings.json` is also tracked by the `claude-global-config` repo. A commit there is not a change here. `mac-config` is the effective owner — declare in `mac-config`, and let the render land in `~/.claude`.

---

## The command string

```
bash "$HOME/firstmate/bin/fm-boot-context.sh"
```

`$HOME`, not `~` and not an absolute path, matching the existing convention and the deliberate `$HOME` pinning noted at `desired/policy.yaml:151-155`.

**Timeout `10`**, matching the existing hook. This is not cosmetic: validator V15 matches on the exact 4-tuple `(agent, event, command, timeout)`, and a `timeout` omitted from the YAML renders as `null`, which will not match an allowlist entry carrying `10`. Declare it explicitly on **both** sides.

---

## Edit 1 — `desired/registry.yaml`, the hooks block at 189-195

Add the second hook object to the existing `SessionStart` matcher group. Replace:

```yaml
          hooks:
            SessionStart:
              - matcher: '*'
                hooks:
                  - type: command
                    command: 'bash "$HOME/.claude/hooks/herdr-agent-state.sh" session'
                    timeout: 10
```

with:

```yaml
          hooks:
            SessionStart:
              - matcher: '*'
                hooks:
                  - type: command
                    command: 'bash "$HOME/.claude/hooks/herdr-agent-state.sh" session'
                    timeout: 10
                  - type: command
                    command: 'bash "$HOME/firstmate/bin/fm-boot-context.sh"'
                    timeout: 10
```

---

## Edit 2 — `desired/policy.yaml`, a new `hook_allowlist` entry after line 185

Required fields per `plane/schema.py:785-824` are `id`, `agent`, `event`, `owner`, `command`, `declares_no_durable_writes`; `timeout`, `installed_by` and `reason` are optional. `declares_no_durable_writes` must be `true` — `false` is a hard ValidationError.

```yaml
  - id: firstmate-boot-context-claude
    agent: claude
    event: SessionStart
    owner: firstmate
    command: 'bash "$HOME/firstmate/bin/fm-boot-context.sh"'
    timeout: 10
    installed_by: declared here; firstmate ships the script, mac-config registers it
    declares_no_durable_writes: true
    reason: >
      Injects the fleet state a firstmate session would otherwise spend several tool
      calls rediscovering. Strictly read-only, and that is machine-checked rather than
      asserted: firstmate gate m2-boot-emitter-is-read-only runs a full boot with a
      recursive before/after manifest of the home (path, size, mtime, ctime, inode,
      mode) and demands they be identical, then repeats it with the home held read-only
      via chmod a-w and demands valid output anyway. Measured at 0.23s against a live
      home, under a 1.5s self-enforced ceiling with a shared deadline across helpers,
      so it cannot approach the declared 10s timeout. This is the read-only half of
      fm-captain-bootstrap.sh, split out precisely so D-11's objection no longer
      applies to anything registered.
```

`declares_no_durable_writes: true` is the load-bearing claim of this entry, and gate `m2` is the evidence for it.

---

## Edit 3 — `desired/policy.yaml:199`, raise the hook budget

```yaml
  global_hooks_max: 1
```

becomes

```yaml
  global_hooks_max: 2
```

The budget is counted **per agent** (`plane/hotpath.py:171-179`), so this is what a second *Claude* hook needs. Codex's own hook does not count against Claude's budget, and is unaffected.

---

## Edit 4 — `desired/policy.yaml:266-269`, retire the spent forbidden-substring rule

Delete exactly these four lines (the `- value:` line and its three-line folded `reason:`):

```yaml
  - value: fm-captain-bootstrap
    reason: >
      D-11 — a SessionStart hook that moves and deletes files, keyed to tmux, whose writer
      has been dead since 2026-06-25.
```

The list survives with its other three entries (`skipDangerousModePermissionPrompt` at 255, `.cmux/hooks` at 260, `cmux-codex-hook` at 264), which are untouched.

**Also update `tests/test_phase2.py:206-213`**, which restates this list and asserts it matches `shipped.policy.forbidden_substrings`. Removing the entry without updating the test breaks the mac-config suite.

### One caveat the applying task should weigh, rather than delete on autopilot

The rule bans a *name*, and `bin/fm-captain-bootstrap.sh` still exists in firstmate and still mutates. The design's argument for deleting rather than excepting is that the ban's stated purpose — keeping a mutating hook out of the boot path — is now served on the merits by a read-only alternative that is gated, so the tripwire has nothing left to catch that policy does not already catch. That reasoning is sound but not airtight: deleting the rule does remove the one thing that would stop `fm-captain-bootstrap` being re-registered later.

The design is authoritative and calls for the deletion, so that is what this declaration specifies. If the captain prefers to keep the tripwire, the alternative is to leave all four lines in place and **change nothing else** — the new command string does not contain the substring `fm-captain-bootstrap`, so edits 1-3 are sufficient on their own and V13 will not fire. That option costs nothing and is available at apply time; it is called out here so the choice is made deliberately rather than by omission.

---

## After applying

1. `stone apply` renders `~/.claude/settings.json`.
2. `stone verify` — V12 (budget), V13 (forbidden substrings), V15 (hook allowlist) must all pass.
3. Back in firstmate: `bash tests/fm-boot-m1.test.sh` should print `ok`, then `ledger verify --dir gates` moves `m1-hook-registered` to green and `ledger freeze m1-hook-registered` freezes it.

Registration needs no change in firstmate. The script, the gate and this declaration are already on `main`.
