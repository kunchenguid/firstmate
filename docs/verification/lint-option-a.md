# Local ShellCheck option A measurement

The 2026-09-05 lint-cost audit measured the seven roots from the missed-reply incident at commit `f09de8a3d3a550b13b4d535346fbc7b9ac0d6c19`:

```text
bin/fm-brief.sh
bin/fm-parent-channel-lib.sh
bin/fm-pending-reply-lib.sh
bin/fm-secondmate-report.sh
tests/fm-brief.test.sh
tests/fm-classify-corr-token.test.sh
tests/fm-pending-reply.test.sh
```

ShellCheck was the repository-pinned 0.11.0 Darwin arm64 build.
The baseline was one source-aware invocation containing all seven roots.
Option A used one process per root, omitted `--external-sources`, retained extended dataflow, and applied the local cross-file exclusion list.
Both variants were measured in the same quiet-host window:

| Variant | User + system CPU | Reduction | Worst-process RSS | Reduction |
| --- | ---: | ---: | ---: | ---: |
| source-aware baseline | 140.1 s | n/a | 8.30 GB | n/a |
| option A, per-root processes | 9.8 s | 93.0% | 0.56 GB | 93.3% |

## Reproduction

Check out the recorded commit, install the pinned binary with `bin/fm-install-shellcheck.sh`, put it first on `PATH`, and run the following on macOS.
No `--extended-analysis=false` flag is present, so dataflow remains on.
Diagnostics are discarded because only process cost is under measurement.

```bash
set -eu
[ "$(bin/fm-lint.sh --required-version)" = "$(shellcheck --version | awk '/^version:/ {print $2; exit}')" ]
roots=(
  bin/fm-brief.sh
  bin/fm-parent-channel-lib.sh
  bin/fm-pending-reply-lib.sh
  bin/fm-secondmate-report.sh
  tests/fm-brief.test.sh
  tests/fm-classify-corr-token.test.sh
  tests/fm-pending-reply.test.sh
)
rm -rf .lint-option-a-measurement
mkdir .lint-option-a-measurement
/usr/bin/time -lp -o .lint-option-a-measurement/baseline.time \
  shellcheck --norc --external-sources -- "${roots[@]}" >/dev/null || true
index=0
for root in "${roots[@]}"; do
  index=$((index + 1))
  /usr/bin/time -lp -o ".lint-option-a-measurement/option-a.$index.time" \
    shellcheck --norc --exclude=SC1091,SC2034,SC2153,SC2329 -- "$root" \
    >/dev/null || true
done
awk '
  /^user / {cpu += $2}
  /^sys / {cpu += $2}
  /maximum resident set size/ {if ($1 > rss) rss=$1}
  /bytes allocated/ {allocated += $1}
  END {printf "cpu_seconds=%.2f worst_rss_bytes=%.0f bytes_allocated=%.0f\n", cpu, rss, allocated}
' .lint-option-a-measurement/baseline.time
awk '
  /^user / {cpu += $2}
  /^sys / {cpu += $2}
  /maximum resident set size/ {if ($1 > rss) rss=$1}
  /bytes allocated/ {allocated += $1}
  END {printf "cpu_seconds=%.2f worst_rss_bytes=%.0f bytes_allocated=%.0f\n", cpu, rss, allocated}
' .lint-option-a-measurement/option-a.*.time
```

CPU and RSS vary with host load, so percentage claims must compare runs from one measurement window.
When results must be compared across windows, use the reported `bytes_allocated` totals as the stable work proxy rather than quoting a CPU or RSS ratio.
