# Startup-memory `/stow` verification

Audience: maintainer verification.

This record supports two active guarantees: that Firstmate can discover and JIT-load a user-owned local skill excluded through the clone's `.git/info/exclude`, and that the automatic stow nudge's default thresholds sit where Claude Code's compaction actually happens.
The internal [`stow` skill](../../.agents/skills/stow/SKILL.md) owns tiering, curation, archival, offload, and completion-receipt behavior.
[`docs/configuration.md`](../configuration.md) owns the current operator-facing startup-memory setting and estimate, and its "Stow nudge" section owns the nudge's operator-facing thresholds.

## Git-excluded local skill discovery and loading

The internal skill's offload destination relies on the harness discovering and JIT-loading a skill directory whose path is listed in the clone's local `.git/info/exclude`.
This check ran on 2026-08-08 with Claude Code 2.1.226 in a disposable scratch repository.
The unique sentinel appeared only in the skill body below the frontmatter, so returning it required the fresh session to load the excluded skill rather than merely see its indexed name or description.

The exact commands run from this repository root were:

```bash
set -eu
claude --version
PROBE_ROOT="$PWD/.stow-excluded-probe-tmp"
rm -rf "$PROBE_ROOT"
mkdir -p "$PROBE_ROOT"
cd "$PROBE_ROOT"
git init -q .
mkdir -p .claude/skills/excluded-probe
cat >.claude/skills/excluded-probe/SKILL.md <<'EOF'
---
name: excluded-probe
description: A neutral probe used when explicitly requested by name.
---

# Excluded probe

The sentinel token is STOW-EXCLUDE-LOAD-8F3K1.
EOF
printf '.claude/skills/excluded-probe/\n' >>.git/info/exclude
git check-ignore -v .claude/skills/excluded-probe/SKILL.md
claude --model haiku --allowedTools Skill -p "Use your Skill tool to load the skill named 'excluded-probe', then reply with exactly the sentinel token stated inside its body and nothing else."
cd ..
rm -rf "$PROBE_ROOT"
```

The exact observed output was:

```text
2.1.226 (Claude Code)
.git/info/exclude:7:.claude/skills/excluded-probe/	.claude/skills/excluded-probe/SKILL.md
STOW-EXCLUDE-LOAD-8F3K1
```

The `git check-ignore` line proves that the local exclude rule covered the skill body, and the exact sentinel reply proves that a fresh Claude Code session loaded that body through the Skill tool.
The same day, a `.gitignore`-ignored probe directory under this repository's own `.agents/skills/` was also listed by a fresh session alongside the tracked control skill through the `.claude/skills` symlink.
The direct local-exclude probe establishes the load-bearing guarantee, while the in-repository probe independently corroborates that ignore status does not suppress filesystem discovery.

## Stow nudge calibration

The automatic stow nudge (`bin/fm-stow-mark.sh check`, run by `bin/fm-turnend-guard.sh --claude`) defaults to a 1,000,000-token auto-compact window, a 60 percent growth threshold toward that window, and a 3 hour horizon.
This section records the evidence those defaults rest on; refresh it when Claude Code changes where it compacts or when the fleet's primaries move to a model with a different window.

### Where Claude Code compacts

Checked on 2026-09-02 against Claude Code 2.1.258 and its published documentation.

```bash
claude --version
claude --help | grep -A1 -- '--autocompact'
```

```text
2.1.258 (Claude Code)
  --autocompact <auto|tokens>           Auto-compact window size (auto, or
                                        100k–1M tokens)
```

The model configuration page (`https://code.claude.com/docs/en/model-config.md`, "Default auto-compact thresholds", fetched the same day) states: "If you don't set an auto-compact window, Claude Code compacts when the conversation reaches the model's context limit", that models with a native 1M window such as Sonnet 5 and the Fable models "compact at the 200K boundary" only when `CLAUDE_CODE_DISABLE_1M_CONTEXT=1` is set, that the command and the flag "accept a window size from 100K to 1M tokens" and "Claude Code caps the window at the model's context window", and that `CLAUDE_CODE_AUTO_COMPACT_WINDOW` "takes precedence over the command, the flag, and the setting" while accepting "only the plain token count".
Its "Extended context" section states that "Fable 5.1, Fable 5, Sonnet 5, and Opus 4.7 and later run with the 1M window by default" on the Anthropic API.
The hooks reference (`https://code.claude.com/docs/en/hooks.md`, "Stop") lists `session_id` and `transcript_path` among the fields every Stop payload carries, and documents exit code 2 as blocking the stop with stderr fed back to Claude.
Those four facts fix the measure's inputs: the window defaults to 1,000,000 tokens, honors the two documented environment overrides, and is read from the transcript the Stop payload names.

### Where this fleet's sessions actually stood

The same day, every Claude session transcript under `~/.claude/projects/` larger than 200 KB was read once, read-only, to relate transcript growth to the context size Claude Code reports in each assistant message's `usage` (input plus cache-creation plus cache-read tokens), and to find the largest context reached without a compaction.

```bash
python3 - <<'PY'
import json, glob, os
for f in sorted(glob.glob(os.path.expanduser('~/.claude/projects/*/*.jsonl'))):
    size = os.path.getsize(f)
    if size < 200000:
        continue
    offset, pts, models, compacts = 0, [], set(), 0
    with open(f, 'rb') as fh:
        for line in fh:
            offset += len(line)
            try:
                d = json.loads(line)
            except Exception:
                continue
            if d.get('type') == 'assistant':
                m = d.get('message', {})
                models.add(m.get('model'))
                u = m.get('usage') or {}
                ctx = (u.get('input_tokens') or 0) + (u.get('cache_creation_input_tokens') or 0) + (u.get('cache_read_input_tokens') or 0)
                if ctx:
                    pts.append((offset, ctx))
            if d.get('subtype') == 'compact_boundary' or d.get('isCompactSummary'):
                compacts += 1
    if not pts:
        continue
    (o0, c0), (o1, c1) = pts[0], pts[-1]
    ratio = (o1 - o0) / max(1, c1 - c0)
    print(f"{os.path.basename(os.path.dirname(f))[:40]}/{os.path.basename(f)[:8]} size={size} first_ctx={c0} peak_ctx={max(c for _, c in pts)} bytes_per_ctx_token={ratio:.2f} models={sorted(models)} compacts={compacts}")
PY
```

```text
-home-mk--no-mistakes-worktrees-9b77d9f4/de527cf2 size=285948 first_ctx=24765 peak_ctx=67184 bytes_per_ctx_token=5.49 models=['claude-fable-5-1'] compacts=0
-home-mk--no-mistakes-worktrees-9b77d9f4/383ef9c4 size=353172 first_ctx=26649 peak_ctx=77463 bytes_per_ctx_token=5.73 models=['claude-fable-5-1'] compacts=0
-home-mk--no-mistakes-worktrees-9b77d9f4/5b606a3a size=328792 first_ctx=28332 peak_ctx=72216 bytes_per_ctx_token=5.77 models=['claude-fable-5-1'] compacts=0
-home-mk--no-mistakes-worktrees-9b77d9f4/94d10e59 size=354610 first_ctx=26909 peak_ctx=69771 bytes_per_ctx_token=6.72 models=['claude-fable-5-1'] compacts=0
-home-mk--no-mistakes-worktrees-9b77d9f4/f8bdb4bb size=297583 first_ctx=27806 peak_ctx=60936 bytes_per_ctx_token=6.79 models=['claude-fable-5-1'] compacts=0
-home-mk--treehouse-Hello-World-0cfabe-1/9dfe49d8 size=310948 first_ctx=37228 peak_ctx=79541 bytes_per_ctx_token=6.68 models=['claude-opus-5'] compacts=0
-home-mk--treehouse-Probiz-ed10be-1-Prob/0580f806 size=518368 first_ctx=40259 peak_ctx=102672 bytes_per_ctx_token=7.75 models=['claude-fable-5-1'] compacts=0
-home-mk--treehouse-Probiz-ed10be-2-Prob/12a9e383 size=308677 first_ctx=39040 peak_ctx=76308 bytes_per_ctx_token=7.46 models=['claude-fable-5-1'] compacts=0
-home-mk--treehouse-firstmate-8bf1b0-1-f/3cc5f169 size=1832281 first_ctx=68141 peak_ctx=315800 bytes_per_ctx_token=6.82 models=['claude-fable-5-1'] compacts=0
-home-mk--treehouse-firstmate-8bf1b0-1-f/913b350d size=1124657 first_ctx=67457 peak_ctx=262132 bytes_per_ctx_token=5.56 models=['claude-fable-5-1'] compacts=0
-home-mk--treehouse-firstmate-8bf1b0-1-f/c8e73f8a size=293843 first_ctx=66220 peak_ctx=91647 bytes_per_ctx_token=6.42 models=['claude-fable-5-1'] compacts=0
-home-mk-firstmate/d6a70dee size=3257841 first_ctx=74027 peak_ctx=486478 bytes_per_ctx_token=7.71 models=['claude-fable-5-1'] compacts=0
-home-mk-src-firstmate/e8324277 size=579277 first_ctx=68353 peak_ctx=137507 bytes_per_ctx_token=7.48 models=['claude-opus-5'] compacts=0
-home-mk-src-scratch-smoke/74f20145 size=343322 first_ctx=38365 peak_ctx=117825 bytes_per_ctx_token=3.85 models=['claude-fable-5-1'] compacts=0
```

Three conclusions follow.
The primary firstmate session (`-home-mk-firstmate/d6a70dee`) reached a 486,478-token context with no compaction, which is consistent with the documented 1,000,000-token default window and rules out a 200,000-token one for this fleet's Fable 5.1 primaries, so 1,000,000 is the default the measure targets.
A firstmate primary starts a session at 66,000 to 74,000 tokens of context, so measuring growth from the point the last pass was recorded, rather than from zero, is what makes the 60 percent threshold mean 60 percent of the room that is actually left.
Transcript bytes grow between 3.9 and 7.8 bytes per context token across these sessions, too wide a spread to calibrate a byte threshold within the requested accuracy, which is why the measure reads the context size Claude Code itself reports instead of the transcript's byte growth; the byte offset is still recorded alongside it and is readable through `bin/fm-stow-mark.sh read`.
