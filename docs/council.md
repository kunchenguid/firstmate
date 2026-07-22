# Persistent councils

`/council` is a thin read-only workflow for asking the same project question of persistent Claude and Codex conversations, then accepting one canonical decision.
It is not a task type, a second mate, a judge service, or an implementation lane.
The [`council` skill](../.agents/skills/council/SKILL.md) owns the captain-facing procedure, while `bin/fm-council.sh --help` owns exact commands and state mechanics.

## Supported MVP

The first supported lane is Linux x86_64 with Herdr and two exact participant profiles: Claude Code `claude-fable-5` at `xhigh`, and Codex `gpt-5.6-sol` at `xhigh`.
The data format admits more participants later, but the command refuses every profile that has not passed the same isolation and lifecycle verification.
It never substitutes a model, harness, or effort.

Each council has a durable name, one absolute local project path, fresh participant conversations, exact Herdr endpoint identity, and a list of applicable accepted decisions.
Only one round can be active in one council, but separate council locks allow unrelated councils to run in parallel.
An interrupted collecting round is marked for explicit retry instead of being silently resumed or duplicated.

Before fan-out, Firstmate builds one stable filtered project view and makes its files read-only.
The Linux participant process installs a Landlock policy before the model starts, so the source project and other participant homes are unreadable and unwritable while the fixed view is readable but unwritable.
Persistent filesystem writes are limited to the participant's own private home and answer outbox, with only its terminal and `/dev/null` admitted as device sinks.
Execution is granted only on the exact controller-supplied binary allowlist, never on the whole system tree.
A seccomp filter denies new Unix-domain sockets (from `socket` and `socketpair` alike) and io_uring setup while retaining provider TCP access, so a participant cannot reach Herdr or another terminal-control service by guessing its socket path or through ring-submitted socket operations; it verifies the x86_64 audit architecture and denies alternate syscall ABIs outright.
Home-local control clients and socket metadata are also outside the admitted filesystem and absent from the sanitized environment, which passes through only the participant's own provider credentials.
Round and decision content is written into each participant's own inbox as a payload file whose bytes are identical across members, and the terminal receives only a short pointer naming that exact file, its hash, and the private answer path, never the full body as a command argument.

The filter excludes version-control metadata, common dependency and cache directories, symlinks, special files, oversized files, `.env` variants, private keys, common credential files, and exact secret- and token-named data files such as `secrets.yaml` or `token.txt` (ordinary source modules like `secrets.py` stay visible).
`.env.example` remains visible.
The manifest names every exclusion so an answer cannot imply that the participant reviewed omitted material.
This is a local filesystem boundary, not permission to disclose code to a remote model provider.
Project-specific durable consent is required separately for Anthropic and OpenAI before the first round can be sent.

Available answers remain in participant-private outboxes until collection.
An answer is ingested only as a private regular single-link file at the exact recorded outbox path; a symlinked, hard-linked, group-writable, oversized, or otherwise unsafe answer file is honestly treated as unavailable rather than followed, with one bounded refusal reason surfaced by `ready` and recorded durably in the round evidence at collection.
Firstmate then presents either one best answer or a short synthesis without adding a separate judge model or numeric scorecard.
One available answer is labeled only as the available answer.
Raw answers and rejected presentations are removed when a round is accepted, rejected, or rerun; accepted canonical decision bodies remain durable.

Acceptance copies exactly the presented bytes into the project's decision journal before any participant notification.
A failed notification remains pending and is delivered before that participant receives its next task.
“Accept and implement” performs the same acceptance and returns a structured request for an ordinary Firstmate implementation task, which is always separate from the council.

Close is explicit and exact.
It verifies each response-derived session, workspace, tab, pane, owner token, and machine label before closing only those participant panes, then removes their conversation homes.
A close that fails partway can simply be rerun: members recorded in the durable close journal are skipped, while an absent or ambiguous pane is never inferred to be council-owned.
It never searches by a friendly title and never closes a Herdr workspace directly.

## Short example

Create `Atlas API` for `/work/atlas` with the two supported profiles, approve Anthropic and OpenAI disclosure for that project when prompted, and ask: “Choose a cache strategy without changing the public API.”
Firstmate collects both independent answers, presents a short synthesis, and “accept” saves that exact synthesis as `D0001` before sending it to both persistent conversations.
Ask a second round: “Plan the schema migration.”
The same participant conversations answer with `D0001` in their shared accepted context.

While the Atlas round is active, create a separate `Docs` council for `/work/docs` and ask it to choose an information architecture.
The Docs round runs independently because serialization is per council, not global.
Closing `Atlas API` clears only its two conversations and leaves `Docs` running.
A later `Atlas API 2` starts fresh conversations with active Atlas decisions by default, while “start clean” maps to `--clean-slate` and omits them.

## Deferred on purpose

The MVP has no scorecard, separate judge model, budget dashboard, transcript analytics, card UI, display-title migration, cross-backend matrix, mid-answer recovery, or broad retention controls.
Those features must not be inferred from the durable schema or added by bypassing the supported-profile refusal.
