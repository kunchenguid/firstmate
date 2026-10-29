# Mistral Vibe

Vibe is verified for crewmate and scout work on tmux and Herdr only.
The [verification record](../../../../../docs/verification/vibe.md) owns versions, refresh commands, and empirical limits.
`../../../../../bin/fm-spawn.sh` owns launch arguments and version refusal.

## Dispatch and models

Use Vibe's own configured model alias, discovered through its `/model` picker or installed config loader, rather than a provider-qualified name borrowed from another tool.
`../../../../../bin/fm-vibe-config.py` validates a requested pin against the installed packaged Python config loader and cached account configuration before spawn; an unavailable pin refuses instead of accepting Vibe's native fallback.
The packaged Python entrypoint and its interpreter must remain installed beside the Rust TUI.
A stale or unavailable account catalog can therefore require opening Vibe normally to refresh its configuration before retrying.
Omitting the model uses Vibe's configured default.

Effort pinning is unsupported: omit effort to retain Vibe's configured reasoning level.
Any explicit effort refuses rather than pretending the requested level applied.
Authentication stays in Vibe's own credential sources; inspect presence or login status without printing keys or reading credential values.

## Launch and control

Launch uses invocation-only trust and automatic tool approval, with the typed task instructions as the initial positional prompt.
Firstmate owns the isolated project copy; Vibe's native worktree option is not used.
An exact foreground `vibe-rs` process establishes identity even under inherited foreign harness markers.

Use the router's lifecycle control path.
One Escape leaves the agent alive; cancellation acknowledgement is unconfirmed, not a semantic cancellation guarantee.
The exit command is `/exit` and completion requires observed process exit.
Replacement launches start a fresh session from instructions on disk and retain old journal directories for recovery.
Final teardown removes every generation's journals and Vibe's read-only plugin cache.
Native `--continue` and `--resume` exist but are not verified recovery paths.

## State and scope

`../../../../../bin/fm-vibe-state.py` reads the current launch generation's unique work-directory-bound session and replays journal envelope updates after its checkpoint.
Missing, malformed, partial, or ambiguous state is unknown.
`../../../../../bin/fm-composer-lib.sh` owns the ruled `>` composer with the cwd/PID/token footer; pending text remains pending.
Rendered generation hints acknowledge delivery only, never semantic completion.

Invoke an unfamiliar skill by asking Vibe to load its instructions by name or path; slash-skill invocation is unverified.
Vibe is not a verified primary or secondmate and has no Firstmate primary supervision or turn-ended notification hook.
