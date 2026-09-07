---
name: lv1-access
description: Operate the LV1 Windows PC (AT3 customer client) over Tailscale plus SSH. Use before running any command on, pulling files from, pushing files to, or messaging the operator side of the LV1 machine.
user-invocable: false
metadata:
  internal: true
---

# lv1-access

LV1 is the customer Windows PC that runs the live AT3 scoring system.
It is reachable only over Tailscale plus SSH, plus a Telegram bot channel to its on-box agent.
This skill owns the connection mechanics; the AT3 rollout plan lives with its backlog task, never here.

## Identity (stable)

- Tailscale node `desktop-pgnkjak`, IPv4 `100.98.201.14`, MagicDNS `desktop-pgnkjak.tail002129.ts.net`.
- Windows 11, local admin user `admin`, Python 3.11, git present, `langgraph` absent until cutover installs it.
- Live repo `D:\AT3LV1\implementation` at `57522ba` (old architecture, customer-drifted, uncommitted).
- Rollback snapshot `F:\at3-backup-20260907\` (full mirror, 1223 files, taken 2026-09-07).
- sshd runs from `F:\OpenSSH\sshd.exe` as an Automatic service on port 22.

## Secrets (paths only, never values)

- `config/at3-client-admin.key` is the bootstrap private key the LV1 agent generated (mode 0600).
- `config/at3-client-jala.key` plus `.pub` is the fleet keypair; the public half goes to LV1, the private half never leaves this home.
- `config/at3-client-bot.token` is the Telegram bot token for the LV1 agent channel (mode 0600).
- `config/at3-client-chat.id` is the operator chat id for that channel (mode 0600).
- All four live gitignored under `config/`; never commit, print, or paste any of them into chat, briefs, reports, or repos.
- Current key rotation state lives in the `at3-pc-client-cutover` backlog note, not here.

## SSH pattern

- Connect as `admin@100.98.201.14` with `-i` pointing at the active key, plus `-o BatchMode=yes -o ConnectTimeout=15`.
- Use `-o StrictHostKeyChecking=accept-new` exactly once per new host key, then strict afterwards.
- Pull files with `scp` using the same `-i` and `-o` flags; host paths use forward slashes.

## Shell contract (Windows cmd.exe by default)

- Separate commands with `&`, never `;`, because cmd does not understand semicolons.
- There is no `head` or `tail`; cap output with PowerShell `Select-Object -First N` or `findstr`.
- Quote in layers: single-quoted ssh argument, double-quoted `powershell -Command "..."`, PowerShell-internal `$_.FullName` needs no extra quoting.
- Never type emoji directory names through ssh; filter by size in PowerShell instead (for example keep entries under 100MB to skip the 729MB raw-audio dir).
- Guard every enumerating script with a root check first, for example `Test-Path` on a known repo file with `exit 1` on failure, because a wrong root once pulled the whole user profile here.
- CRLF scripts fail under POSIX `bash`; convert to LF before running or porting them.

## Common operations

- Recon: `git -C D:\AT3LV1\implementation rev-parse HEAD`, capped `status`, `schtasks /query | findstr`, `tasklist | findstr python`, `fsutil volume diskfree F:`.
- Snapshot: `robocopy <src> <F:\backup-...>` with `/E /MT:8 /R:2 /W:2 /NP /NFL /NDL`, then confirm the tail summary shows zero FAILED.
- Light pull: `git bundle create` plus a size-filtered copy into a stage dir, `Compress-Archive` to one zip, `scp` it here, verify with `git bundle verify`, then delete the stage and zip over there.
- Backslash-path zips from Windows extract with literal backslashes in names; `ditto -x -k` handles them where `unzip` refuses.
- Service check: `sc qc sshd` must show `BINARY_PATH_NAME: "F:\OpenSSH\sshd.exe"` and `AUTO_START`.

## Telegram channel to the on-box agent

- Bot API `sendMessage` arrives as the bot itself, which the polling agent can never see; it is useful only for testing the token, never for tasking.
- Real tasking goes out as the captain over Telegram Web through `browser-harness` on the captain's live Chrome tab.
- Keep every tasking message short, ASCII, self-contained, and numbered when it has parts; the agent confirms part numbers back.
- Verify delivery by reading the last chat bubbles, never by bubble count, because the chat list virtualizes rendering.
- File attachments download by clicking the document icon; confirm the new file in the download dir before claiming receipt.

## Gotchas

- `browser-harness` clicks sometimes hang while reads stay reliable, so send fire-and-verify: act, tolerate the abort, then confirm with a read-only check.
- The agent answers quickly and asks precise blocking questions; unanswered detail requests stall it, so reply to its exact question first.
- LV1 local time runs behind this machine's clock by a few minutes; compare mtimes loosely.
