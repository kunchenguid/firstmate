# Pi `+yolo` Permission Propagation Design

**Date:** 2026-07-27

**Status:** Approved in conversation; written review pending

**GavLife:** OPS-232

## Problem

FirstMate resolves and records a per-project `yolo=on|off` value, but its Pi
launch command does not pass that value to Pi's installed permission system.
On a `+yolo` project, `@gotgenes/pi-permission-system` therefore continues to
render interactive `ask` prompts. Herdr still reports the Pi process as
working, so the primary FirstMate session is not notified and the delegated
task waits indefinitely for input in its own terminal.

The affected `rt-ebook` project is already configured as `+yolo`. Changing the
user's global Pi permission config would unblock it, but would also weaken
permission handling for unrelated Pi sessions and non-yolo FirstMate projects.

## Desired Behaviour

| Launch context | Permission behaviour |
| --- | --- |
| FirstMate delegated Pi task, project `+yolo` | Convert permission results of `ask` to `allow` for this Pi process |
| FirstMate delegated Pi task, yolo off | Use the normal merged permission configuration unchanged |
| Pi launched outside FirstMate | Use the normal merged permission configuration unchanged |
| Any session with an explicit `deny` rule | Preserve the denial, including when the session-scoped override is active |

This change removes routine interactive permission stalls only for delegated
work that FirstMate has already classified as yolo. It does not make yolo a
global default and does not reinterpret explicit denial rules.

## Design

### 1. Permission-system runtime contract

Add an opt-in process environment variable to
`@gotgenes/pi-permission-system`:

```text
PI_PERMISSION_SYSTEM_YOLO=1
```

The extension reads the variable when it constructs the effective runtime
configuration for a session.

- The only enabling value is the exact string `1`.
- Missing, empty, or any other value leaves file-based configuration unchanged.
- When enabled, it sets the effective `yoloMode` runtime knob to `true`.
- It uses the package's existing yolo composition behaviour: `ask` becomes
  `allow`, while `deny` remains `deny`.
- The environment value is process-scoped and is never written into global or
  project configuration files.
- Reloading configuration during the same process retains the runtime override.
- Existing config summaries and diagnostics show the effective yolo state; the
  documentation identifies the environment variable as a trusted-launcher
  override.

This is intentionally an additive launcher API. It avoids a mutable temporary
config file, project-trust coupling, and races between concurrent Pi sessions.

### 2. FirstMate propagation

Update `bin/fm-spawn.sh` so the Pi command receives:

```text
PI_PERMISSION_SYSTEM_YOLO=1
```

only when all of the following are true:

1. the selected harness is Pi;
2. the spawned task is a delegated project task (`ship` or `scout`);
3. the resolved project metadata is `yolo=on`.

Secondmate launches remain `yolo=off` under the existing contract. Primary Pi
sessions and Pi sessions started independently of FirstMate are outside this
launch path and remain unchanged.

The variable is added to the environment of the Pi process, not exported in the
parent shell. If the permission-system extension is not installed, the variable
is harmless. If an older installed extension does not recognise it, normal
prompts remain; FirstMate does not attempt to edit user-global permission files
as a fallback.

### 3. Safety boundary

The source of authority remains FirstMate's resolved project mode. Repository
content cannot opt itself into this override by adding a Pi permission config,
and the FirstMate launcher does not infer yolo from the current directory or
from arbitrary task text.

The permission system continues to own rule evaluation. The launcher only
activates its existing deny-preserving yolo composition for the lifetime of the
delegated Pi process. Explicit user denials such as protected environment files
or destructive command patterns still apply.

## Test Strategy

### Permission-system package

Add unit tests before implementation for:

1. `PI_PERMISSION_SYSTEM_YOLO=1` changes an effective `ask` decision to
   `allow`;
2. the override preserves an explicit `deny`;
3. an unset variable leaves `yoloMode` and decisions unchanged;
4. values other than exact `1` do not enable the override;
5. a configuration reload cannot discard the process-scoped override.

The environment source must be injectable in unit tests so tests do not mutate
the runner's process environment.

### FirstMate

Add shell regression coverage before implementation for the generated Pi launch
command:

1. a Pi `ship` task with `yolo=on` contains
   `PI_PERMISSION_SYSTEM_YOLO=1`;
2. a Pi `scout` task with `yolo=on` contains it;
3. a Pi task with `yolo=off` does not contain it;
4. non-Pi harness commands do not contain it;
5. secondmate Pi launches do not contain it.

Run the targeted spawn test, shell syntax checks for changed scripts, lint, and
the changed-file-informed test selection.

### Local integration proof

After both changes are available locally, launch an isolated Pi session twice
against a command that the current policy resolves to `ask`:

1. without the environment variable, verify that the permission prompt appears;
2. with `PI_PERMISSION_SYSTEM_YOLO=1`, verify that the same action proceeds
   without a prompt;
3. with the override active, exercise an explicitly denied action and verify it
   remains denied.

Then spawn a disposable FirstMate Pi task for a yolo-on fixture and inspect the
actual child process environment or observable permission behaviour. Repeat
with yolo off to prove normal permission handling remains intact.

## Delivery

This integration spans two independently versioned repositories:

1. submit the runtime override to `gotgenes/pi-packages`;
2. submit the conditional propagation to `kunchenguid/firstmate`;
3. document the minimum permission-system release containing the override;
4. update the installed package only after the package change is available
   from a reviewable commit or release;
5. keep the two pull requests linked so the FirstMate change cannot be mistaken
   for a standalone global permission bypass.

The local user configuration remains unchanged throughout.
