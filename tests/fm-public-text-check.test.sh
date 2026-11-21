#!/usr/bin/env bash
# Exercise exact outgoing publication text and the generated worker command.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$ROOT/bin/fm-dod-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-public-text-check)
CHECK="$ROOT/bin/fm-public-text-check.sh"

# shellcheck disable=SC2016 # Markdown backticks are literal publication input.
unsafe=(
  'Private proof: /Users/example/private/report.md'
  '`/home/example/proof.txt`'
  'Reproduced from /Users/alice'
  'Reproduced from /home/alice'
  'Reproduced from C:\Users\alice'
  'Reproduced from C:/Users/alice'
  'Reproduced from `/Users/alice`.'
  'Reproduced from (/home/alice).'
  'Reproduced from "C:\Users\alice".'
  'Evidence at /private/var/folders/example/report.md'
  'Evidence: /private/tmp/claude-12345/proof.md'
  'Evidence: /tmp/claude-501/proof.md'
  'Working directory: /private/tmp/claude-501'
  'Working directory: /tmp/claude-501'
  'Working directory: `/private/tmp/claude-501`'
  'Working directory: `/tmp/claude-501`'
  'Working directory: (/private/tmp/claude-501).'
  'Working directory: "/tmp/claude-501".'
  'Working directory: /private/tmp/claude-501, then retry.'
  'Working directory: /tmp/claude-501 is private.'
  'Evidence: /var/folders/example/session/proof.md'
  'Evidence: /workspace/firstmate/data/task/report.md'
  'Evidence: file:///Users/example/proof.md'
  'Evidence: C:\Users\example\proof.md'
  'Evidence: \\example\private\proof.md'
  'Private proof: data/example-task/report.md'
  'Private evidence: state/example-task.status'
  'Evidence: .no-mistakes/runs/example/proof.md'
  'Evidence: http://localhost:8080/proof'
  'Evidence: http://benchmark.localhost:8080/report'
  'Evidence: https://benchmark.localhost/report'
  'Evidence: http://nested.benchmark.localhost'
  'Evidence: HTTP://BENCHMARK.LOCALHOST/report'
  'Evidence: http://benchmark.localhost./report'
  'Evidence: http://benchmark.localhost.:8080/report'
  'Evidence: http://benchmark.localhost?report=1'
  'Evidence: http://benchmark.localhost#report'
  'Evidence: https://reader:secret@benchmark.localhost/report'
  'Evidence: **http://benchmark.localhost**'
  '[http://benchmark.localhost](https://example.org)'
  '|https://example.org/report|http://benchmark.localhost/report|'
  'Evidence: http://localhost?report=1'
  'Evidence: http://localhost#report'
  'Evidence: http://localhost'
  'Evidence: (http://localhost).'
  'Evidence: **http://192.168.1.20**'
  'Evidence: *http://localhost*'
  'Evidence: __http://localhost__'
  'Evidence: _http://localhost_'
  'Evidence: ~~http://localhost~~'
  '[http://localhost](https://example.org)'
  '[http://192.168.1.20](https://example.org)'
  '[http://proof.local](https://example.org)'
  'Evidence: **http://[::1]**'
  '[http://[fd12::1]](https://example.org)'
  'Evidence: **http://reader:secret@[::ffff:c0a8:114]:8080**'
  '[https://example.org]/Users/alice/report'
  '**https://example.org**/home/alice/report'
  '[https://example.org][http://localhost]'
  'Evidence: http://localhost./proof'
  'Evidence: http://reader:secret@localhost?report=1'
  'Evidence: http://reader:p*ss@192.168.1.20/report'
  'Evidence: http://reader:p(ss)@192.168.1.20/report'
  "Evidence: http://reader:p'ss@192.168.1.20/report"
  'Evidence: http://reader:p!$&()*+,;=:%40-._~ss@192.168.1.20/report'
  'Evidence: http://reader:p*ss@localhost/report'
  'Evidence: http://@localhost/report'
  'Evidence: https://reader:p(ss)@benchmark.localhost/report'
  "Evidence: http://reader:p'ss@[fd12::1]/report"
  'Evidence: http://reader:p*ss@[::ffff:c0a8:114]:8080/report'
  'Evidence: **http://reader:p*ss@192.168.1.20/report**'
  '[http://reader:p(ss)@192.168.1.20/report](https://example.org)'
  '|https://example.org/report|http://reader:p*ss@192.168.1.20/report|'
  '**https://example.org/report**/home/alice/report'
  '_https://example.org/report_/home/alice/report'
  '_https://example.org_/home/alice/report'
  '(https://example.org/docs/(v1))/home/alice/report'
  '[public](https://example.org/docs/(v1))/home/alice/report'
  "'https://example.org/report'/home/alice/report"
  'Evidence: http://169.254.1.20/report'
  'Evidence: http://[fd12::1]/report'
  'Evidence: https://[fc00::1]:8080?report=1'
  'Evidence: http://[fe80::1%25en0]/report'
  'Evidence: http://[::1]?report=1'
  'Evidence: http://[0:0:0:0:0:0:0:1]/report'
  'Evidence: http://[::ffff:192.168.1.20]/report'
  'Evidence: http://[::ffff:c0a8:114]/report'
  'Evidence: http://[::ffff:7f00:1]/report'
  'Evidence: http://[::ffff:a00:1]/report'
  'Evidence: http://[::ffff:a9fe:114]/report'
  'Evidence: http://[::ffff:ac10:1]/report'
  'Evidence: http://[::ffff:ac1f:ffff]/report'
  'Evidence: http://[0:0:0:0:0:ffff:0a00:0001]/report'
  'Evidence: https://[::FFFF:C0A8:0114]:8080?report=1'
  'Evidence: https://proof.local?report=1'
  'Public then private: https://example.org/report http://localhost?report=1'
  '|https://example.org/results|http://192.168.1.20/report|'
  '|http://192.168.1.20/report|https://example.org/results|'
  '|https://example.org/results|/Users/alice/report|'
  '|/home/alice/report|https://example.org/results|'
  '|https://example.org/results|C:\Users\alice\report|'
  '|https://example.org/results|http://[::ffff:c0a8:114]/report|'
  '[https://example.org/results](http://localhost?report=1)'
  '[https://example.org/results](/home/alice/report)'
  'Evidence: https://proof.local/report'
  'Evidence: http://192.168.1.20/private/report.md'
  'Evidence: http://10.0.0.5/proof'
  'Evidence: http://172.16.0.1/proof'
  'Evidence: https://172.31.255.254:8080/proof'
  'Private proof: report.md'
)
for text in "${unsafe[@]}"; do
  printf '%s\n' "$text" > "$TMP_ROOT/input"
  cp "$TMP_ROOT/input" "$TMP_ROOT/before"
  if "$CHECK" "$TMP_ROOT/input" > "$TMP_ROOT/out" 2> "$TMP_ROOT/err"; then
    fail "accepted private reference"
  fi
  cmp -s "$TMP_ROOT/input" "$TMP_ROOT/before" || fail "mutated private evidence"
  assert_grep 'line 1' "$TMP_ROOT/err" 'missing location-only diagnostic'
  grep -Fq "$text" "$TMP_ROOT/err" && fail "echoed sensitive input"
done
pass "private references are rejected without disclosure or mutation"

cat > "$TMP_ROOT/public" <<'EOF'
Benchmarks passed 50 iterations with zero failed oracle comparisons.
Source: tests/benchmark.test.sh; state/parser.go; data/schema/report.md.
Public proof: https://github.com/example/repo/actions/runs/123
Public URL paths stay intact: https://example.org/home/example/report.md
Public host outside the private range: https://172.32.0.1/proof
Public IPv6 host: https://[2606:4700:4700::1111]/report
Public mapped hosts: http://[::ffff:808:808]/report, http://[::ffff:8.8.8.8]/report.
Public mapped range boundaries: http://[::ffff:ac0f:ffff]/report, http://[::ffff:ac20:1]/report.
Public table: |https://example.org/home/alice|https://example.net/Users/alice|
Public link: [https://example.org/results](https://example.net/home/alice)
Public Markdown: **https://example.org/home/alice**, _https://example.org/report_, ~~https://example.org/report~~.
Public IPv6 Markdown: [https://[2606:4700:4700::1111]/home/alice](https://example.org/report).
Public IPv6 credentials: https://reader:password@[2606:4700:4700::1111]/Users/alice
Public URL underscores: https://example.org/some_report/home/alice
Public authorities: https://localhost.example.org?report=1, https://proof.local.example.org/report.
Public localhost lookalikes: https://benchmark.localhost.example.org/report, https://notlocalhost.example.org/report.
Public localhost path: https://example.org/benchmark.localhost/report.
Public URL components: https://example.org?next=http-localhost, https://example.org/#localhost.
Public URL credentials: https://localhost@example.org/report
Public credential punctuation: https://reader:p*ss@example.org/home/alice, https://reader:p(ss)@example.org/home/alice, https://reader:p'ss@example.org/home/alice.
Public credential subdelimiters: https://reader:p!$&'()*+,;=:%40-._~ss@example.org/home/alice.
Public credential IPv6: https://reader:p*ss@[2606:4700:4700::1111]/home/alice.
Public empty userinfo: https://@example.org/home/alice.
Public path punctuation: https://example.org/docs/(v1)/home/alice, https://example.org/docs/*/home/alice, https://example.org/docs/o'brien/home/alice.
Public nested parentheses: https://example.org/docs/(v1(test))/home/alice.
Public unwrapped parentheses: https://example.org/docs/)v1/home/alice, https://example.org/docs/(v1/home/alice.
Public query and fragment: https://example.org?next=(v1)/home/alice, https://example.org#section'(v1)/home/alice.
Public wrapped paths: (https://example.org/docs/(v1)/home/alice), 'https://example.org/docs/(v1)/home/alice'.
Public Markdown paths: **https://example.org/docs/(v1)/home/alice**, _https://example.org/some_report/home/alice_.
Public Markdown credentials: [http://reader:p(ss)@example.org/home/alice](https://example.org/report).
Intended system examples: /usr/bin/env, /etc/hosts and /dev/null.
Web route example: /api/v1/users.
Generic maintainer examples: ~/.factory/settings.json, ~/.factory/..., ~/.config/..., /opt/homebrew, /tmp/.
Other generic examples: /usr/local, /etc, /tmp/example.txt, ~/.config/app/settings.json.
Generic placeholders: /Users/<user>/project/notes.txt, /home/<name>/notes.txt, C:\Users\<name>\notes.txt, /private/tmp/claude-<uid>/notes.txt.
Terminal placeholders: /Users/<user>, /home/<name>, C:\Users\<name>.
Terminal session placeholders: /tmp/claude-<uid>, `/private/tmp/claude-<session>`.
EOF
"$CHECK" "$TMP_ROOT/public" || fail 'valid public explanation rejected'
"$CHECK" - < "$TMP_ROOT/public" || fail 'stdin public explanation rejected'
pass "repository paths, public URLs, system examples and useful facts survive"

# Consume the command from the rendered delivery instructions, not source bytes.
for mode in direct-PR no-mistakes; do
  fm_dod_block "$mode" example-task > "$TMP_ROOT/$mode.md"
  command=$(awk '/owns the public-evidence policy/ { sub(/^`/, ""); sub(/`.*/, ""); print; exit }' "$TMP_ROOT/$mode.md")
  [ -n "$command" ] || fail "$mode omitted the publication check"
  if printf '%s\n' 'Private proof: /Users/example/private/report.md' | bash -c "$command -" > "$TMP_ROOT/out" 2> "$TMP_ROOT/err"; then
    fail "$mode generated command accepted private proof"
  fi
  bash -c "$command -" < "$TMP_ROOT/public" || fail "$mode generated command rejected public facts"
done
pass "both generated delivery paths execute the same publication policy"

# The real public reply interface must refuse before recording or transport.
for method in answer followup; do
  home="$TMP_ROOT/$method"
  mkdir -p "$home"
  args=()
  [ "$method" = answer ] || args=(--followup)
  for text in 'Private proof: /Users/example/private/report.md' \
    'Evidence: http://reader:p*ss@192.168.1.20/report'; do
    if FM_HOME="$home" FMX_DRY_RUN=1 "$ROOT/bin/fm-x-reply.sh" example-request "${args[@]}" \
      "$text" > "$TMP_ROOT/out" 2> "$TMP_ROOT/err"; then
      fail "$method accepted private proof"
    fi
    [ ! -e "$home/state/x-outbox" ] || fail "$method recorded unsafe outbound text"
    ! grep -q '/Users/example' "$TMP_ROOT/err" || fail "$method disclosed rejected text"
    ! grep -Fq '192.168.1.20' "$TMP_ROOT/err" || fail "$method disclosed rejected host"
  done
  FM_HOME="$home" FMX_DRY_RUN=1 FMX_REPLY_PLATFORM=x FMX_REPLY_MAX_CHARS=280 \
    "$ROOT/bin/fm-x-reply.sh" example-request "${args[@]}" \
    'Benchmark: 50 iterations passed without oracle mismatches.' > "$TMP_ROOT/out" 2> "$TMP_ROOT/err" \
    || fail "$method refused useful public validation"
done
pass "answer and followup refuse private text before their publication boundary"
