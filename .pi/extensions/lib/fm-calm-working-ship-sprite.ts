// Re-export shim for Firstmate's harness-neutral Calm working-ship sprite.
//
// The canonical sprite core lives at
// ../../../.claude/mods/firstmate-calm/lib/fm-calm-working-ship-sprite.ts because Claude
// Code's hooks-module loader refuses to import a file from outside its own plugin
// folder, symlinks included. Pi's loader has no equivalent restriction, so this file is
// a plain re-export rather than a git symlink: a tracked symlink checks out as an
// unusable text file (the literal target path string, not the target's content or a
// working link) on a filesystem/git configuration that does not materialize real
// symlinks, such as this repo's Windows checkouts, and fm-calm.ts then fails to parse
// it as TypeScript. A plain re-export needs no filesystem symlink support at all, so it
// resolves identically everywhere `pi -e` runs, while keeping one canonical copy of the
// sprite geometry, bounce track, cadences, and freeze/resume state.
//
// tests/fm-calm-claude-mod.test.sh's test_plugin_shape imports both this file and the
// canonical core and asserts identical export sets and function identity, so a future
// change that duplicates the sprite instead of re-exporting it fails that check.
export * from "../../../.claude/mods/firstmate-calm/lib/fm-calm-working-ship-sprite.ts";
