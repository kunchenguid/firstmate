# Agentic engineering cycle verification

The normative procedure is owned only by `.agents/skills/agentic-engineering-cycle/SKILL.md`.
This record verifies that the procedure is classified, discoverable from the always-loaded skill index and generated ordinary task briefs, and composed with the existing task lifecycle rather than replacing it.

Verification date: 2026-08-02.

## Discovery surfaces

`AGENTS.md` section 13 declares the precise load trigger without restating the procedure.
`bin/fm-brief.sh` emits one conditional pointer for both Ship and Scout briefs and directs numbered brief or report decisions to the skill's single template owner.
`docs/documentation-audiences.json` classifies the procedure as `agent-runtime` and this record as `maintainer-verification`.

## Verification commands

The focused behavior test generates real Ship and Scout briefs through the public scaffold and checks their owner pointer, numbered-decision routing, and non-expansion of authority.

```text
$ bin/fm-test-run.sh tests/fm-brief.test.sh
ok - fm-brief.sh: investigation and visual-review completions load the shared decision policy
ok - fm-brief.sh: ship and scout briefs discover the agentic engineering cycle
ok - fm-brief: scout and secondmate code paths still scaffold well-formed briefs
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=1244
FM_TEST_SUMMARY_FAMILY family=pure-contract-unit count=1 duration_ms=1177 failed=0

$ bin/fm-doc-audience-check.sh
fm-doc-audience-check: ok surfaces=63 local_links=171

$ lint_bin_dir=$(mktemp -d /tmp/fm-cycle-shellcheck.XXXXXX) && bin/fm-install-shellcheck.sh "$lint_bin_dir" && PATH="$lint_bin_dir:$PATH" bin/fm-lint.sh
ShellCheck - shell script analysis tool
version: 0.11.0
license: GNU General Public License, version 3
website: https://www.shellcheck.net
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ git diff --check
(no output)
```

The complete branch diff must also be reviewed against `firstmate-coding-guidelines` after automated fixes so that the procedure remains single-owned and the always-loaded surface stays a trigger rather than a duplicate contract.
