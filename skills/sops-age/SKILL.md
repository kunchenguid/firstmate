---
name: sops-age
description: >-
  Safe work with Mozilla SOPS and age for GitOps-managed secrets.
  Use before encrypting or decrypting files, editing encrypted manifests, rotating age recipients or data keys, or resolving an age private key from Bitwarden Secrets Manager.
---

<!-- maintainers: public installer-facing skill. Procedure owner for both firstmate and project workers. Firstmate loads `.agents/skills/sops-age/SKILL.md`, a stub that points here. -->

# sops-age

Mozilla SOPS encrypts structured files in place.
age provides the recipient and identity format SOPS uses for file encryption.
This skill owns safe probe, encrypt, decrypt, edit, recipient update, data-key rotation, verification, cleanup, and failure handling.

Load the `bws` skill before resolving age private keys from Bitwarden Secrets Manager.

## Current-source discovery

Never memorize flags or claim subcommands this install does not support.
Before operations, consult the installed tools:

```sh
sops --version
sops --help
age --version
age --help
age-keygen --help
```

Subcommand help is authoritative for the current version.

## Installation

Copy or link this directory into a project worker's skill discovery path:

- `.agents/skills/sops-age/` (recommended)
- `.claude/skills/sops-age/` (Claude Code)

From the firstmate repository, the source path is `skills/sops-age/`.
Installers such as [skills.sh](https://skills.sh) can add the same directory from the published firstmate repo.

The bundled helper is `scripts/sops-safe.sh` relative to this skill directory.

## Project AGENTS.md trigger

Add this exact line to the project's always-loaded agent instructions (for example `AGENTS.md`):

```md
- `sops-age` - load before any work with `sops`, `age`, or `age-keygen`: encrypting or decrypting files, editing encrypted manifests, rotating age recipients or data keys, or resolving an age private key from bws.
```

## Bundled helper

Use `scripts/sops-safe.sh` for probes, age-identity detection without printing keys, and trusted age-key injection.

```sh
HELPER="<skill-dir>/scripts/sops-safe.sh"
"$HELPER" probe
"$HELPER" detect-age-identity
"$HELPER" with-age-key bws <PROJECT_ID> -- sops --decrypt file.enc.yaml
"$HELPER" with-age-key file /path/to/key.txt -- sops --decrypt file.enc.yaml
```

`probe` prints `status=`, `sops_version=`, and `age_version=` only.
`status=ready` means both `sops` and `age` are present.
`sops_absent`, `age_absent`, and `unavailable` are not success.

`detect-age-identity` prints `age_identity_present=` and `source=` only.
It never prints `AGE-SECRET-KEY-...` or file contents.
Exit 0 means an identity is available to the current process; exit 1 means none.

Decrypted output has no generally safe field allowlist and must never be relayed to chat, logs, or saved diagnostics.
For verification, discard decrypted stdout and use only the command exit status.

`with-age-key` runs a supported direct SOPS command with age identity available only inside that child.
Modes:

- `bws <PROJECT_ID> -- <sops-command...>` runs `bws run --project-id <PROJECT_ID> -- <sops-command...>` so the age key stays in the trusted child environment.
- `file <KEY_FILE> -- <sops-command...>` sets `SOPS_AGE_KEY_FILE` for the child only when the operator provides a readable key file outside chat.

The wrapper accepts only direct SOPS decrypt, encrypt, edit, updatekeys, and rotate operations, refuses commands whose arguments contain `AGE-SECRET-KEY-...`, suppresses decrypt stdout, and unsets `SOPS_AGE_KEY` and `SOPS_AGE_KEY_FILE` after the child exits.
The operation token must immediately follow the `sops` executable, and any second operation token makes the command invalid.
It rejects intermediary executables such as `env` and shells because their eventual output cannot be classified safely.

## Environment separation

Each deployment environment must use its own age recipient set and its own private key.
Configure separate `.sops.yaml` creation rules per environment so path patterns bind to the correct recipients.
Never reuse one environment's private key to decrypt another environment's files.
Verify recipient lists in file metadata match the intended environment before any mutating work.

Name environments in task authority and commands with the operator's labels (for example `staging` and `production`).
Do not assume project-specific key or secret names; resolve them from the operator's secret manager or documented runbook.

## Age private key boundary

An age private key may enter a session only through one of these paths:

1. `bws run --project-id <PROJECT_ID> -- <trusted-command>` with the key stored as a Secrets Manager secret in that project.
2. An operator-managed key file on disk that never passes through chat, transcripts, or tracked files.
3. `with-age-key` wrapping either path above.

Never paste `AGE-SECRET-KEY-...` into chat, tool arguments, logs, commits, or status lines.
Never pass a private key as a visible command-line argument to `sops`, `age`, or any wrapper.
Never write a private key into a tracked file.

Prefer `with-age-key bws` over exporting `SOPS_AGE_KEY` in the parent shell.
When the operator supplies a key file, reference only the file path and keep permissions tight.

## Authority for mutating work

Read-only operations that do not create files (probe, encrypted metadata inspection, and decrypt-for-verification with stdout discarded) need no extra authority beyond the task itself.

Require current explicit authority naming the target file and environment before:

- encrypting a new or plaintext file
- `sops edit` or any in-place change to encrypted content
- `sops updatekeys` (recipient rotation)
- `sops rotate` (data-key rotation)
- creating or changing `.sops.yaml` creation rules
- creating, rotating, or deleting age keys or Secrets Manager secrets that hold private keys
- creating or deleting files containing decrypted values, including temporary files

Refuse mutating requests that name only a directory, only a key alias without environment context, or only a recipient fingerprint without the file set.

## Safe probe and prerequisites

1. Run `"$HELPER" probe` or `command -v sops age` plus version checks.
2. Confirm `.sops.yaml` exists when the repository uses creation rules.
3. For decrypt or edit, confirm an age identity is available via `detect-age-identity` or a planned `with-age-key` invocation.
4. Stop when `probe` reports anything other than `status=ready`.

## Encrypting files

Encrypt only with explicit authority naming the plaintext path, output path if different, and environment.

1. Confirm recipients in `.sops.yaml` match the named environment.
2. Never place plaintext secret values in chat or command arguments visible to tools.
3. Prefer encrypting from a gitignored staging copy when the plaintext must not remain on disk.
4. Run `sops --encrypt --in-place <file>` or the equivalent your `sops --help` documents for the installed version.
5. Verify by decrypting inside `with-age-key` with stdout discarded; use the exit status to confirm integrity without printing values.
6. Remove plaintext staging copies after verification when the workflow created them.

## Decrypting and inspecting

Decrypt only when the task requires reading content.
Prefer encrypted metadata inspection over decrypting values.

1. Run decrypt inside `with-age-key bws` or `with-age-key file`, never with a key in parent arguments.
2. Discard stdout when only the decryption result is needed for verification.
3. Require explicit authority naming the file and environment before writing decrypted output to a restrictive, gitignored temporary file.
4. Require the same authority to delete that temporary file, and clean it up in a `trap` or explicit cleanup step before finishing.

## Editing encrypted files

`sops edit` is mutating and needs explicit authority naming file and environment.

1. Confirm the age identity for that environment is available through an approved path.
2. Run edit inside `with-age-key`.
3. After edit, verify MAC and decrypt with stdout discarded.
4. Commit only the encrypted file, never editor backups that might hold plaintext.

## Recipient update and data-key rotation

`sops updatekeys` changes who can decrypt; `sops rotate` changes the data key.
Both are mutating and need explicit authority naming the files and environment.

Recipient update (`updatekeys`):

1. Confirm the new recipient public keys belong to the named environment only.
2. Update `.sops.yaml` creation rules when new files should use the new recipient set.
3. Run `sops updatekeys <file>` inside `with-age-key` using a key that already decrypts the file.
4. Verify every listed file decrypts under the expected identity after the update.

Data-key rotation (`rotate`):

1. Run `sops rotate --in-place <file>` inside `with-age-key`.
2. Verify decrypt after rotation.
3. Re-encrypt or update keys for every copy that must stay in sync.

## Verification

After encrypt, edit, `updatekeys`, or `rotate`:

1. Confirm `sops` exits 0.
2. Decrypt inside `with-age-key` with stdout discarded and confirm the exit status only.
3. For GitOps repos, confirm only encrypted blobs changed in the diff.
4. Never attach decrypted content to PR descriptions, status lines, or chat.

## Cleanup

Remove gitignored plaintext staging files, temp decrypt outputs, and editor swap files before reporting completion.
Unset any manual `SOPS_AGE_KEY` or `SOPS_AGE_KEY_FILE` exports in the current shell.
Do not leave decrypted content in the worktree.

## Failure handling

| Evidence | Meaning | Action |
| --- | --- | --- |
| `status=sops_absent` or `status=age_absent` | Required CLI missing | Stop; ask operator to install |
| `detect-age-identity` exit 1 | No usable private key in process | Use `with-age-key` or stop |
| MAC mismatch / decryption error | Wrong key or corrupted file | Stop; do not retry with another environment's key |
| `with-age-key` refuses arguments | Key material in argv | Remove key from command; use approved injection |
| `bws run` non-zero | Secret or project access failure | Report without secret values; load `bws` skill |
| `updatekeys` / `rotate` non-zero | Incomplete rotation | Stop; do not commit partial state |

Never retry mutating commands with guessed recipient lists, guessed key files, or a different environment's key.

## Never commit secrets

Never commit age private keys, plaintext secret files, decrypted output, or command transcripts that contain values.
Do not save diagnostics containing decrypted output.
Encrypted SOPS files belong in Git; plaintext secrets do not.
