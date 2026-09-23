# Verification: Kimi Code workspace trust

Active empirical facts for Kimi Code's folder-trust store and firstmate's pre-registration of it.
The skill tree rooted at [`../../.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts through [`references/harness/kimi.md`](../../.agents/skills/harness-adapters/references/harness/kimi.md), and [`../../bin/fm-kimi-trust.sh`](../../bin/fm-kimi-trust.sh)'s header owns the store contract it implements.
This record owns how those facts were established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Version | `kimi 2.0.2` |
| Verified | 2026-09-23 |
| Binary | `~/.kimi-code/bin/kimi`, a Mach-O 64-bit arm64 executable |
| Platform | macOS (Darwin 23.6.0), arm64 |
| Backend | tmux 3.7c, in throwaway sessions launched per probe |

Every launch below ran against a throwaway `KIMI_CODE_HOME` holding a copy of the credential and config files only, with the Firstmate turn-end hook region stripped so the probe home was inert.
The operator's own `~/.kimi-code` was read but never written, and no firstmate fleet state was touched.

## The dialog still renders on 2.0.2

The reason this matters: the task that produced this record was written against 0.43.1, and a report suggested 2.0.2 might no longer prompt at all.
It does.
A fresh folder Kimi has never seen, launched with `--auto`:

```
$ tmux new-session -d -s kimiprobe -x 200 -y 50 -c "$SP/probe1" \
    "KIMI_CODE_HOME=$SP/kh $HOME/.kimi-code/bin/kimi --auto"
$ tmux capture-pane -t kimiprobe -p -S -0
  Trust this folder?
  ↑↓ navigate · Enter select · Esc exit

  /private/tmp/.../scratchpad/probe1

  Project-level MCP servers are disabled until you explicitly choose Trust. Trust starts the listed project MCP targets and remembers this folder.

   ❯ Trust this folder
     Enable project MCP servers. Remembered for this folder.

     Don't trust
     Exit Kimi Code. Asked again next launch.
```

`kimi --help` on 2.0.2 lists no trust flag; `--auto` selects the `Never Ask` permission tier, which is a separate concern from folder trust.

## What answering it writes

Answering with Enter produced exactly one new file plus a registry entry:

```
$ ls -la "$SP/kh/workspace-trust"
-rw-------  1 lele  wheel  167 Sep 23 20:30 wd_probe1_4724149180fa
$ cat "$SP/kh/workspace-trust/wd_probe1_4724149180fa"
{"root":"/private/tmp/.../scratchpad/probe1","trustedAt":1790166600565}
$ stat -f 'mode=%Sp' "$SP/kh/workspace-trust"
mode=drwx------
$ cat "$SP/kh/workspaces.json"
{"version":1,"workspaces":{"wd_probe1_4724149180fa":{"root":"/private/tmp/.../scratchpad/probe1","name":"probe1","created_at":"2026-09-23T12:29:20.802Z","last_opened_at":"2026-09-23T12:30:00.646Z"}},"deleted_workspace_ids":[]}
```

The record is mode 0600 inside a 0700 directory, and the registry carries a `deleted_workspace_ids` key alongside `workspaces`.

## The trust file alone decides; the registry does not

Two complementary probes, each launched into the same already-known folder:

```
# trust file kept, workspaces.json emptied
$ printf '%s\n' '{"version":1,"workspaces":{},"deleted_workspace_ids":[]}' > "$SP/kh/workspaces.json"
$ ls "$SP/kh/workspace-trust"
wd_probe1_4724149180fa
-> VERDICT: no trust prompt (pane reached "Welcome to Kimi Code!" and the composer)

# workspaces.json entry kept, trust file removed
$ rm -f "$SP/kh/workspace-trust"/*
-> VERDICT: PROMPTED
```

So the registry is Kimi's own bookkeeping and has no part in the trust decision.
`bin/fm-kimi-trust.sh` therefore writes the single trust file and leaves `workspaces.json` alone, which is also why it needs no read-modify-write over a document the vendor rewrites.

## The lookup key is the filename, not the file's content

```
# correct id filename, unrelated "root" inside
$ printf '%s' '{"root":"/tmp/some-other-place","trustedAt":1790166600565}' \
    > "$SP/kh/workspace-trust/wd_probe1_4724149180fa"
-> VERDICT: no trust prompt

# correct "root" inside, any other filename
$ printf '%s' "{\"root\":\"$SP/probe1\",\"trustedAt\":1790166600565}" \
    > "$SP/kh/workspace-trust/wd_probe1_deadbeefcafe"
-> VERDICT: PROMPTED
```

The `root` field is informational.
`bin/fm-kimi-trust.sh` writes it faithfully anyway, for the operator reading the store and for any later version that starts validating it, but never relies on it.

## The workspace id derivation

`wd_` + a slug of the resolved directory's basename + `_` + the first 12 hex characters of the sha256 of the resolved absolute path with no trailing slash.

```
$ node -e 'console.log(require("crypto").createHash("sha256").update("/private/tmp/.../scratchpad/probe1").digest("hex").slice(0,12))'
4724149180fa      # and the observed id was wd_probe1_4724149180fa
```

The slug lowercases, replaces each run of characters outside `[a-z0-9._-]` with a single `-`, strips leading `-`, truncates to 40 characters, then strips trailing `-`, falling back to `workspace` when nothing is left.
Each step, and the order of the two strips around the truncation, was read off Kimi directly by creating the folder and harvesting the id Kimi records at launch (it writes the `workspaces.json` entry before the dialog is answered, so no answer is needed):

| Basename | Slug Kimi produced |
|---|---|
| `UPPER` | `upper` |
| `a  b   c` | `a-b-c` |
| `très-café` | `tr-s-caf` |
| `.hidden` | `.hidden` |
| `trail--` | `trail` |
| `-lead`, `--lead2` | `lead`, `lead2` |
| `x@#$%^&y` | `x-y` |
| `__under__` | `__under__` |
| `mid--dle` | `mid--dle` |
| `@@@`, `é` | `workspace` |
| `ünïcode-x` | `n-code-x` |
| 132 `a`-runs | first 40 characters |
| 39 `a`s + `-bbbb` | 39 `a`s (truncation lands on the dash, then the trailing strip removes it) |
| 5 `-`s + 40 `b`s | 40 `b`s (the leading strip runs before the cap) |

The completed rule reproduces all 81 workspace ids across the five Kimi homes on this box plus every probe above:

```
$ node -e '...slug+sha256 over every workspaces.json...' \
    ~/.kimi-code/workspaces.json ~/.kimi-code-{2,3,4,5}/workspaces.json "$SP/kh/workspaces.json"
TOTAL matched=81  mismatched=0
```

`tests/fm-kimi-trust.test.sh` pins the slug rule and both truncation-order facts through the executable, with the hash expectation computed by `shasum` rather than by the subject's own `node` implementation.

## Trust is exact-directory, and the path is resolved

No ancestor walk: a trusted parent does not cover its child.

```
# only $SP/T7/parent pre-registered, launched in $SP/T7/parent/child
-> VERDICT: PROMPTED
```

That is why the registration records only the directory the pane starts in and never the primary checkout.

Kimi resolves the launch directory before deriving the id.
Launched through a symlink with both the pane's cwd and `PWD` set to the link:

```
$ ln -s "$SP/probe1" "$SP/probe1-link"
# launched with -c "$SP/probe1-link" and PWD="$SP/probe1-link"
$ ls "$SP/kh/workspace-trust"
wd_probe1_4724149180fa          # the resolved path's id
# wd_probe1-link_e989c0974937 would have been the logical path's id
```

So every path is resolved before the id is derived, and the logical form is deliberately not registered.
This is the opposite of agy, which compares the logical path (see [`agy.md`](agy.md)).

## The pre-registration works end to end

Control and treatment, same probe home, two fresh linked worktrees Kimi had never seen:

```
# CONTROL: no pre-registration
$ tmux new-session -d -s kp -x 200 -y 50 -c "$SP/unit/live1" \
    "KIMI_CODE_HOME=$SP/kh $HOME/.kimi-code/bin/kimi --auto"
[control] VERDICT: PROMPTED
  Trust this folder?

# TREATMENT: pre-registered with the helper, then launched
$ KIMI_CODE_HOME="$SP/kh" bin/fm-kimi-trust.sh "$SP/unit/live2" "$SP/unit/proj"
trusted: /private/tmp/.../scratchpad/unit/live2 (wd_live2_68a84f6cd0d8)
$ ls "$SP/kh/workspace-trust/"
wd_live2_68a84f6cd0d8
[pre-registered] VERDICT: no trust prompt
 │  ▐█▛█▛█▌  Welcome to Kimi Code!                                        │
 │ >                                                                      │
```

The pre-registered worktree reached the composer with no prompt; the unregistered sibling stopped on the dialog.

## Multiple Kimi homes

This box carries five:

```
$ ls -d ~/.kimi-code*
/Users/lele/.kimi-code  /Users/lele/.kimi-code-2  /Users/lele/.kimi-code-3
/Users/lele/.kimi-code-4  /Users/lele/.kimi-code-5
```

`KIMI_CODE_HOME` is a real variable in the 2.0.2 binary's own string table, alongside `KIMI_CODE_HOME_ENV`.
A registration in the wrong home is a silent no-op, so `bin/fm-kimi-trust.sh` resolves `${KIMI_CODE_HOME:-$HOME/.kimi-code}` and refuses a relative value, and `bin/fm-spawn.sh` forwards a set value onto the launch so both sides name the same home.

## What is still unproven

Whether a future version begins validating the `root` field inside the record; the field is written correctly, so this would be a silent no-change rather than a break.
Whether the 40-character slug cap or the fallback literal differ on Linux or Windows builds; only macOS arm64 2.0.2 was exercised.
No secondmate Kimi home was launched live - that mode's scope test is covered by `tests/fm-kimi-trust.test.sh` against seeded fixture homes, and the store write is the same single-file path as worktree mode.
Kimi's behavior when the trust file exists but is unreadable was not probed.

## Refreshing this record

The store layout, the id derivation, and the dialog text are all vendor-controlled surfaces the helper matches exactly, so re-run these after any Kimi upgrade:

```sh
bin/fm-test-run.sh tests/fm-kimi-trust.test.sh tests/fm-kimi-harness.test.sh
```

Those are portable and need no Kimi.
To re-confirm the vendor surface itself, repeat the control-and-treatment launch above against a throwaway `KIMI_CODE_HOME` and a folder Kimi has never seen, and re-harvest the slug table from `workspaces.json`, which Kimi writes at launch before the dialog is answered.
