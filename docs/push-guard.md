# push-guard PreToolUse seatbelt

This document is the authoritative human-readable contract for the push-guard PreToolUse seatbelt.
`bin/fm-push-guard-command-policy.mjs` is the single decision owner for everything text alone can settle.
`bin/fm-push-guard-pretool-check.sh` is the stable harness transport, the one place that queries real repository state (never the submitted command), and the output renderer.

It is a member of the same family of cross-harness PreToolUse guards as the cd-guard (`bin/fm-cd-pretool-check.sh`, `docs/cd-guard.md`) and the watcher-arm seatbelt (`bin/fm-arm-pretool-check.sh`, `docs/arm-pretool-check.md`), and reuses the same shell tokenizer and command-position analysis (`bin/fm-arm-command-policy.mjs`, the sole owner of firstmate's shell classification).
Unlike those two, it is **not** scoped to the primary firstmate checkout - see "Scope" below.

## Purpose and boundary

On 2026-09-04, firstmate pushed two configuration commits straight to a project's `main` from a scratch clone, without the pipeline that would have caught the regression; each turned that project's `main` red.
GitHub branch protection would prevent this, but it needs a paid plan the captain declined, so this seatbelt is the backstop: it denies a direct `git push` to `main` or `master` on any remote before it runs, in any git repository, from any working directory.

This guard is not a general sandbox.
It classifies shell command positions only; it never evaluates, expands, sources, or runs any byte of the submitted command.
Its threat model is an agent mistake - a direct `git push origin main` typed instead of going through a PR - not a deliberately obfuscated bypass.

## Scope: any path, not just the primary checkout

The cd-guard and watcher-arm seatbelt protect state that only exists in the primary firstmate checkout (the backlog, the watcher), so they scope themselves to it and stand down everywhere else.
A direct push to a project's `main` is unsafe regardless of which checkout the shell has wandered into - that is exactly what the originating incident was - so this guard applies universally instead of gating on `bin/fm-cd-pretool-check.sh`'s primary-checkout test.

In practice this means:

- **Claude**: `.claude/settings.json` locates the script through the fixed `$CLAUDE_PROJECT_DIR` environment variable, which does not change when the shell `cd`s, so the guard fires against a `git push` from any working directory, in any git repository.
- **Codex**: `.codex/hooks.json` re-resolves the script's path from `pwd -P` on every call (the same mechanism its sibling guards already use there) and requires that directory to itself carry `AGENTS.md` and a `.codex/hooks.json` naming this script.
  A Codex session that has `cd`'d away from the firstmate checkout root into a project clone therefore cannot even locate the script, so under Codex this guard's practical reach is bounded to sessions whose tracked `cwd` is still the firstmate checkout root.
  This is a genuine per-harness difference from Claude's reach, not a bug, and it is the same limitation the cd-guard and watcher-arm seatbelt already carry under Codex.
- Grok, OpenCode, Pi, and Cursor have no registration for this guard.
  This is a documented vendor gap: the guard was built to satisfy the "must work for both Claude and Codex" requirement it shipped under, and extending it to the other harnesses is future work, not a silent omission.

Because the guard is not primary-scoped, it also protects a crewmate or secondmate session that types a direct `git push` to `main` or `master` - a defense-in-depth backstop, since every crewmate brief already forbids that push, not a new restriction.

## Block vs allow

The guard **blocks** a `git push` invocation, anywhere shell control can reach it (a top-level command, a subshell, a pipeline stage, a background job, an `eval` payload, or a literal `sh -c`/`bash -c`/`zsh -c` payload - unlike the cd-guard, there is no persistence-to-parent-shell filter, because `git push` executes regardless), whose destination is `main` or `master` on any remote. This covers:

- `git push origin main`
- `git push origin HEAD:main`
- `git push -u origin main`
- `git push origin +main` (a leading `+` force marker on the refspec)
- `git push origin refs/heads/main` and `git push origin HEAD:refs/heads/main`
- `git push --all origin` and `git push --mirror origin` (these reach `main`/`master` along with every other ref, from a command line that names no branch at all)
- a bare `git push`, `git push origin`, or `git push --force-with-lease` (no repository/refspec, or only a repository) when the current branch is `main` or `master` - see "The one case text cannot settle" below
- any `git` invocation reaching one of the above through `-C <dir>`, `-c <k>=<v>`, `--git-dir=`, `--work-tree=`, `--namespace=`, or `--exec-path=` global options first
- any of the above nested inside `(...)`, `{ ...; }`, `$(...)`, backticks, a literal `eval "..."`, or a literal `sh -c "..."`/`bash -c "..."`/`zsh -c "..."` payload

The guard **allows** everything else, including:

- `git push origin <feature-branch>` (any target that is not `main`/`master`)
- `git -C <dir> status`, `git checkout main`, or any non-push `git` subcommand
- `git push origin :main` (a refspec that **deletes** the remote `main`) - see "Accepted non-goals"
- `git push` reached only through indirection this classifier does not treat as a transparent wrapper (`xargs git push ...`, a Makefile target, a helper script that shells out to `git push`)
- the exact command carrying the owner marker described below

### The one case text cannot settle: a bare push

A `git push` with no repository/refspec argument (or with only a repository) pushes the current branch under git's own `simple`/`current` push default, which the policy cannot determine from text alone.
For that case, `bin/fm-push-guard-command-policy.mjs` returns a `check-branch` decision naming the effective directory (from a `-C <dir>` global option, when present, else empty).
`bin/fm-push-guard-pretool-check.sh` is the only place that resolves it: it runs `git -C <dir-or-cwd> symbolic-ref --quiet --short HEAD` - real, already-committed repository state, never a byte of the submitted command - and denies only when that branch is exactly `main` or `master`.
When the branch cannot be determined (not a git repository, detached `HEAD`, missing `git`), the transport fails open: this guard denies known `main`/`master` targets, not every ambiguous repository state.

### The owner marker

`bin/fm-pr-merge.sh` (server-side PR merge via `gh`/`glab`) and `bin/fm-merge-local.sh` (a local `git merge --ff-only`) are the two sanctioned paths that land work on `main`; neither currently issues `git push` itself.
The brief for this guard required that any future exemption for those two owners be an explicit marker they set, never a path pattern, so a command carrying the exact leading assignment `FM_PUSH_GUARD_OWNER=fm-pr-merge` or `FM_PUSH_GUARD_OWNER=fm-merge-local` immediately before the `git push` on the same command line is exempted from this guard.
This exemption is unexercised by any current call site - it exists so a future change to either owner script has a sanctioned way to push directly without widening this policy into a path-based bypass.

### Accepted non-goals

Consistent with the agent-mistake threat model, the guard deliberately does not chase every construction:

- A refspec that **deletes** the remote branch (`git push origin :main`) is not denied. Deleting `main` is a different, rarer mistake than overwriting it, and is outside the enumerated case list this guard was built against.
- Indirection through a program this classifier does not treat as a transparent wrapper (`xargs`, a Makefile target, a custom script that shells out to `git push`) is not traced.
- Obscure git global options with an attached, unenumerated argument form are treated as taking no argument; only the options germane to reaching `push` (`-C`, `-c`, `--git-dir`, `--work-tree`, `--namespace`, `--exec-path`, and `--`) are argument-aware.

If a genuinely ambiguous command shape is found that risks a false allow, the guard is not extended by guesswork; the ambiguity is escalated and the guard stays precise.

## Stable reason codes

| Code | Meaning |
| --- | --- |
| `protected-branch-push` | A `git push` targets `main` or `master` on some remote, either explicitly in the refspec or because the current branch resolved to one of them for a bare push. |
| `push-all-mirror` | A `--all` or `--mirror` push reaches `main`/`master` along with every other ref. |
| `unclassifiable-push` | Shell syntax this classifier cannot tokenize, in a command whose raw text mentions both `git` and `push`, is denied rather than guessed at - the same fail-closed stance `bin/fm-arm-command-policy.mjs` takes for its own protected commands. A blocked push costs one clarifying turn; a red `main` costs a captain incident. |

Every deny carries one of these stable codes in square brackets before the shared prose reason: land it through a PR so CI proves it before `main` - use `bin/fm-pr-merge.sh` or `bin/fm-merge-local.sh`.

## Transport and fail-open behavior

`bin/fm-push-guard-pretool-check.sh` supports the two harness entry shapes this guard is registered for, both delivering the same stdin JSON shape:

- Claude sends stdin JSON at `.tool_input.command` and adds `--claude` to preserve Claude's stderr-only deny requirement.
- Codex sends stdin JSON at `.tool_input.command` without `--claude`.
- `--command <exact string>` is also accepted directly, for testing and any future CLI-driven harness.

Processing order is cheapest-first: a strict-superset prefilter, then the Node policy owner, then (only for a `check-branch` result) one real `git symbolic-ref` call.
The prefilter fast-allows any command whose raw text carries no `push` substring, so the vast majority of Bash tool calls never pay for the Node process.

Empty stdin, unparseable JSON, missing `jq` on the stdin path, missing Node, a missing policy owner, an invalid policy response, or an undeterminable branch for a `check-branch` result all fail open with exit 0 and no output.
A broken hook must never deny every shell tool call.

## Output contract

Identical in shape to `docs/cd-guard.md`:

- Allow returns exit 0 with both streams empty.
- Deny returns exit 2 and writes `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"[code] reason"}` to stderr.
- Default deny mode also writes `{"decision":"deny","reason":"[code] reason"}` to stdout.
- `--claude` suppresses stdout completely because Claude ignores a PreToolUse deny when stdout is nonempty.
- Codex blocks on exit 2 and displays stderr.

## Harness wiring

| Harness | Entry | Adapter behavior on checker exit 2 |
| --- | --- | --- |
| Claude | `.claude/settings.json` PreToolUse Bash hook forwarding stdin with `--claude` | Blocks the tool call; stderr deny object, stdout empty. |
| Codex | `.codex/hooks.json` PreToolUse hook that anchors from `pwd -P`, verifies the hook-loaded firstmate root, and forwards the payload | Blocks on exit 2 and displays stderr. Confirmed current as of the Codex CLI hooks reference at <https://learn.chatgpt.com/docs/hooks> (redirected from `developers.openai.com/codex/hooks`), which documents the same `hooks.json` schema, `PreToolUse` stdin shape (`tool_input.command`), and `permissionDecision: "deny"` / exit-2 block contract already in use by the cd-guard and watcher-arm registrations this entry copies. |
| Grok, OpenCode, Pi, Cursor | Not registered | Documented vendor gap (see "Scope" above); a bare `git push` to `main`/`master` from one of these harnesses is not currently intercepted. |

Each harness runs the push-guard alongside the watcher-arm and cd-guard seatbelts; all are independent checks, and any one deny blocks the command.

## Automated validation

`tests/fm-push-guard.test.sh` owns the acceptance matrix: every refspec form in "Block vs allow" above, the owner-marker exemption, the bare-push branch check (both branches, and the fail-open cases where the branch cannot be determined), the recursion into subshells/substitutions/eval/`sh -c`, the fail-open transport behavior, the prefilter fast path, the policy CLI output contract, and shellcheck cleanliness via `bin/fm-lint.sh`.

Run:

```sh
bash -n bin/fm-push-guard-pretool-check.sh
shellcheck bin/fm-push-guard-pretool-check.sh tests/fm-push-guard.test.sh
node --check bin/fm-push-guard-command-policy.mjs
tests/fm-push-guard.test.sh
```
