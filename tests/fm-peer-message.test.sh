#!/usr/bin/env bash
# Structured message composition: real send/codec/inbox/ledger/wake owners with
# fake tmux endpoints. No model, remote service, or live fleet state is used.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-peer-message)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
trap 'rm -rf "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/home/state"
export FM_HOME="$TMP_ROOT/home" FM_ROOT_OVERRIDE="$TMP_ROOT/home"
unset FM_STATE_OVERRIDE
export FM_PEER_TEST_ROOT="$TMP_ROOT"
cat > "$TMP_ROOT/bin/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  display-message)
    case "$*" in
      *pane_current_command*)
        if [ -f "$FM_PEER_TEST_ROOT/dead" ] || { [[ "$*" == *sess:fm-b* ]] && [ -f "$FM_PEER_TEST_ROOT/dead-b" ]; }; then
          printf zsh
        else printf claude; fi ;;
      *cursor_y*) printf 1 ;;
      *) printf fakepane ;;
    esac ;;
  list-windows) printf 'fm-a\nfm-b\nfm-c\nfm-d\n' ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n' ;;
  send-keys) printf '%s\n' "$*" >> "$FM_PEER_TEST_ROOT/typed" ;;
esac
exit 0
SH
# The real inbox writer's publication port must see the ledger already durable.
cat > "$TMP_ROOT/bin/mv" <<'SH'
#!/usr/bin/env bash
set -eu
target=${@: -1}; source=${@: -2:1}
case "$target" in
  *.inbox/*.msg)
    header=$(awk '/^message=/ {print substr($0,9); exit}' "$source")
    thread=$(printf '%s' "$header" | jq -r '.thread // empty')
    if [ -n "$thread" ]; then
      id=$(printf '%s' "$header" | jq -r .id)
      jq -se --arg id "$id" 'any(.[]; .id==$id)' "$FM_HOME/data/threads/$thread.md" >/dev/null
      printf 'ledger-before-inbox\n' >> "$FM_PEER_TEST_ROOT/order"
    fi ;;
esac
exec /bin/mv "$@"
SH
chmod +x "$TMP_ROOT/bin/tmux" "$TMP_ROOT/bin/mv"
export PATH="$TMP_ROOT/bin:$PATH"
for task in a b c d; do
  fm_git_worktree "$TMP_ROOT/proj-$task" "$TMP_ROOT/wt-$task" "task-$task"
  fm_write_meta "$FM_HOME/state/$task.meta" "window=sess:fm-$task" \
    "endpoint_task_id=$task" "project=$TMP_ROOT/proj-$task" "worktree=$TMP_ROOT/wt-$task" \
    'kind=ship' 'harness=claude' 'model=default' 'effort=medium'
done
send() { # <actor> <args...>
  local actor=$1; shift
  (cd "$TMP_ROOT/wt-$actor"; FM_TASK_ID="$actor" "$ROOT/bin/fm-send.sh" "$@")
}
body() { "$ROOT/bin/fm-message.sh" read "$1"; }
refuse() {
  local name=$1; shift
  if "$@" >"$TMP_ROOT/refusal.out" 2>"$TMP_ROOT/refusal.err"; then fail "$name unexpectedly succeeded"; fi
  pass "$name refuses"
}

send a b,c --thread review --kind request 'please check contracts' > "$TMP_ROOT/receipt"
a_id=$(body "$FM_HOME/state/b.inbox/001.msg" | jq -r .id)
b_message=$(body "$FM_HOME/state/b.inbox/001.msg")
c_message=$(body "$FM_HOME/state/c.inbox/001.msg")
[ "$b_message" = "$c_message" ] || fail 'fanout copies differ'
printf '%s' "$b_message" | jq -e '.from=="a" and .to==["b","c"] and .thread=="review" and .kind=="request"' >/dev/null || fail 'shared fields differ'
[ "$(jq -s length "$FM_HOME/data/threads/review.md")" = 1 ] || fail 'ledger did not record exactly one message'
assert_contains "$(<"$FM_HOME/state/a.status")" 'peer: a -> b,c: please check contracts' 'sender trace'
assert_contains "$(<"$TMP_ROOT/typed")" 'PEER INPUT' 'peer data doorbell'
case "$(<"$TMP_ROOT/typed")" in *'please check contracts'*) fail 'payload was typed' ;; esac
[ "$(grep -c '^ledger-before-inbox$' "$TMP_ROOT/order")" = 2 ] || fail 'ledger-before-delivery continuity was not observed for every copy'
pass 'fanout shares id and thread, records one ledger entry and only types a data doorbell'

mkdir -p "$FM_HOME/state/b.inbox/handled"
mv "$FM_HOME/state/b.inbox/001.msg" "$FM_HOME/state/b.inbox/handled/001.msg"
send b --reply "$a_id" 'contracts checked' >/dev/null
body "$FM_HOME/state/a.inbox/001.msg" | jq -e --arg ref "$a_id" '.ref==$ref and .kind=="reply" and .to==["a","c"]' >/dev/null || fail 'default reply did not reach thread members'
[ -f "$FM_HOME/state/c.inbox/002.msg" ] || fail 'reply missed another member'
pass 'reply follows handled request correlation and defaults to all other thread members'

refuse 'nonmember admission' send d a --thread review 'not invited'
send b d --thread review 'adding implementation reviewer' >/dev/null
send d a --thread review 'joined' >/dev/null
[ "$(jq -s length "$FM_HOME/data/threads/review.md")" = 4 ] || fail 'thread membership additions were lost'
pass 'a member can add another live member through an ordinary message'

refuse 'nonmember thread send' send c a --thread missing-membership --kind reply --ref "$a_id" 'wrong thread'
# shellcheck disable=SC2016 # The child shell expands its positional arguments.
refuse 'forged sender hint' bash -c 'cd "$1/wt-a"; FM_TASK_ID=b "$2/bin/fm-send.sh" c forged' _ "$TMP_ROOT" "$ROOT"
refuse 'raw endpoint' send a sess:fm-b nope
refuse 'lifecycle keys' send a b --key Enter
refuse 'decision authority' send a b --resolve-key approval yes
refuse 'unknown remote-home task' send a elsewhere nope
refuse 'atomic preflight of every recipient' send a b,elsewhere --thread refused-fanout nope
[ ! -e "$FM_HOME/data/threads/refused-fanout.md" ] || fail 'invalid fanout wrote a ledger entry'
mkdir -p "$TMP_ROOT/other-state"
refuse 'cross-home state override' env FM_STATE_OVERRIDE="$TMP_ROOT/other-state" FM_TASK_ID=a "$ROOT/bin/fm-send.sh" b nope
refuse 'forged reply ref' send b a --kind reply --ref msg-00000000000000000000000000000000 nope
refuse 'multiline peer text' send a b $'line\nforged: status'
refuse 'invalid thread identifier' send a b --thread $'bad\nprivate-value-not-an-id' nope
refuse 'path traversal recipient' send a ../outside nope
printf 'remote_host=somewhere\n' >> "$FM_HOME/state/d.meta"
refuse 'remote route' send a d nope
# Restore the fixture record, never a production guard.
fm_write_meta "$FM_HOME/state/d.meta" 'window=sess:fm-d' 'endpoint_task_id=d' \
  "project=$TMP_ROOT/proj-d" "worktree=$TMP_ROOT/wt-d" 'kind=ship' 'harness=claude'
printf 'endpoint_task_id=other\n' >> "$FM_HOME/state/d.meta"
refuse 'ambiguous metadata identity' send a d nope
: > "$TMP_ROOT/dead"
refuse 'dead sender' send a b nope
rm "$TMP_ROOT/dead"
: > "$TMP_ROOT/dead-b"
refuse 'dead recipient' send a b nope
rm "$TMP_ROOT/dead-b"
cp "$FM_HOME/state/a.meta" "$FM_HOME/state/supervisor.meta"
refuse 'reserved participant collision' send a supervisor nope
rm "$FM_HOME/state/supervisor.meta"

send c supervisor --thread review --kind needs-decision 'scope needs approval' >/dev/null
body "$FM_HOME/state/supervisor.inbox/001.msg" | jq -e '.to==["supervisor"] and .kind=="needs-decision" and .from=="c"' >/dev/null || fail 'supervisor return differs'
[ -s "$FM_HOME/state/.wake-queue" ] || fail 'supervisor was not durably notified'
pass 'worker-to-supervisor is the shared inbox plus a durable wake, never user chat'

# The existing plain supervisory path also emits the shared codec while keeping
# its text body byte-identical for existing agents and remote adapters.
(cd "$FM_HOME"; "$ROOT/bin/fm-send.sh" a 'ordinary instruction') >/dev/null
body "$FM_HOME/state/a.inbox/003.msg" | jq -e '.from=="supervisor" and .to==["a"] and .text=="ordinary instruction"' >/dev/null || fail 'supervisory compatibility record missing'
pass 'ordinary supervisory sends share the record shape without rewriting text'

# Partial fan-out: one target cannot be written after every endpoint passed.
# Its ledger must precede any delivery; retry repairs the missing copy, without
# reissuing a copy that another recipient has already acknowledged.
: > "$FM_HOME/state/c.inbox.block"
mv "$FM_HOME/state/c.inbox" "$FM_HOME/state/c.saved"
mv "$FM_HOME/state/c.inbox.block" "$FM_HOME/state/c.inbox"
rc=0
send b a,c --thread review 'durable partial' >"$TMP_ROOT/partial.out" 2>"$TMP_ROOT/partial.err" || rc=$?
[ "$rc" = 3 ] || fail "partial fanout exit should be 3, got $rc"
partial_id=$(jq -sr '.[-1].id' "$FM_HOME/data/threads/review.md")
[ "$(jq -sr '.[-1].text' "$FM_HOME/data/threads/review.md")" = 'durable partial' ] || fail 'ledger missing partial message'
before=$(find "$FM_HOME/state/a.inbox" -name '*.msg' | wc -l | tr -d ' ')
rm "$FM_HOME/state/c.inbox"
mv "$FM_HOME/state/c.saved" "$FM_HOME/state/c.inbox"
send b --retry "$partial_id" --thread review >/dev/null
[ "$(find "$FM_HOME/state/a.inbox" -name '*.msg' | wc -l | tr -d ' ')" = "$before" ] || fail 'retry duplicated a delivered copy'
[ "$(jq -s --arg id "$partial_id" '[.[]|select(.id==$id)]|length' "$FM_HOME/data/threads/review.md")" = 1 ] || fail 'retry duplicated the ledger'
refuse 'retry by another sender' send a --retry "$partial_id" --thread review
refuse 'retry with replacement attributes' send b --retry "$partial_id" --thread review --kind request
pass 'partial fanout is durable before delivery and resumes with the same message id'

cp "$FM_HOME/data/threads/review.md" "$FM_HOME/data/threads/wrong-ledger.md"
refuse 'ledger thread identity mismatch' send a b --thread wrong-ledger nope
printf '{"thread":"torn-ledger",' > "$FM_HOME/data/threads/torn-ledger.md"
refuse 'torn final ledger line' send a b --thread torn-ledger nope

printf '%s 10\n' "$(date +%s)" > "$FM_HOME/state/a.inbox/.peer.rate"
refuse 'sender rate cap' send a b nope
printf '%s 10\n' "$(( $(date +%s)-61 ))" > "$FM_HOME/state/a.inbox/.peer.rate"
send a b 'rate window reset' >/dev/null
pass 'sender cap is bounded and resets only after the window'

send a b --thread review '/quit is peer data' >/dev/null
case "$(<"$TMP_ROOT/typed")" in *'/quit is peer data'*) fail 'peer slash command entered typed plane' ;; esac
pass 'slash-prefixed peer messages never invoke the target harness parser'

# A service adapter can consume and deliver the exact shared shape without a
# second codec; text round-trips including its final newline.
encoded=$(bash -c '. "$1/bin/fm-task-inbox-lib.sh"; fm_message_encode _service-a b note "" "$2"' _ "$ROOT" $'payload\n')
printf '%s' "$encoded" > "$TMP_ROOT/service.json"
"$ROOT/bin/fm-message.sh" validate "$TMP_ROOT/service.json" >/dev/null
service_record=$(bash -c '. "$1/bin/fm-task-inbox-lib.sh"; fm_task_inbox_deliver_message "$2" b "$3"' _ "$ROOT" "$FM_HOME/state" "$encoded")
[ "$(body "$service_record" | jq -cS .)" = "$(printf '%s' "$encoded" | jq -cS .)" ] || fail 'service record codec differs'
printf '%s\n%s\n' "$encoded" "$encoded" > "$TMP_ROOT/two.json"
refuse 'multiple JSON messages on one validation call' "$ROOT/bin/fm-message.sh" validate "$TMP_ROOT/two.json"
pass 'service port uses the same codec and preserves trailing text newlines'

printf 'code=A2-recipient\n' >> "$FM_HOME/state/b.meta"
send a '[A2-recipient]' --thread bracketed-code 'bracketed code delivery' >/dev/null
jq -se '.[-1].to==["b"]' "$FM_HOME/data/threads/bracketed-code.md" >/dev/null \
  || fail 'bracketed stored code did not resolve before structured delivery'
send a A2-recip --thread prefixed-code 'prefixed code delivery' >/dev/null
jq -se '.[-1].to==["b"]' "$FM_HOME/data/threads/prefixed-code.md" >/dev/null \
  || fail 'unique stored-code prefix did not resolve before structured delivery'
refuse 'leading empty structured recipient' send a ',b' --thread empty-recipient nope
refuse 'trailing empty structured recipient' send a 'b,' --thread empty-recipient nope
pass 'structured sends resolve stored code selectors without dropping empty recipients'

FM_HOME="$FM_HOME" "$ROOT/bin/fm-message.sh" stats > "$TMP_ROOT/stats"
jq -e '.accepted>=8 and .rejected>=13 and .errors==1 and .delivered>=9' "$TMP_ROOT/stats" >/dev/null || fail "telemetry stats differ: $(<"$TMP_ROOT/stats")"
if grep -R -E 'scope needs approval|private-value-not-an-id' "$FM_HOME/state/fm-message/telemetry"; then fail 'private text or rejected input leaked into telemetry'; fi
[ ! -e "$TMP_ROOT/other-state/fm-message" ] || fail 'state override redirected telemetry writes'
jq -se 'all(.[]; .schema=="fm-message-telemetry.v1" and .tokens==null and .cost==null)' "$FM_HOME/state/fm-message/telemetry/"*.jsonl >/dev/null || fail 'telemetry shape differs'
pass 'daily structured telemetry counts outcomes without logging message text'

# Persistent homes participate in their parent's shared transport under their
# own ids, not the parent's supervisor identity. Endpoints remain explicit fakes.
for task in c d; do
  mkdir -p "$TMP_ROOT/wt-$task/state"
  printf '%s\n' "$task" > "$TMP_ROOT/wt-$task/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$FM_HOME" > "$TMP_ROOT/wt-$task/.fm-secondmate-parent"
  fm_write_meta "$FM_HOME/state/$task.meta" "window=sess:fm-$task" "endpoint_task_id=$task" \
    "project=$TMP_ROOT/proj-$task" "worktree=$TMP_ROOT/wt-$task" "home=$TMP_ROOT/wt-$task" 'kind=secondmate' 'harness=claude'
done
receive() { (cd "$TMP_ROOT/wt-$1"; FM_TASK_ID="$1" "$ROOT/bin/fm-message.sh" receive); }
send c d --thread home-exchange --kind request 'QA findings' > "$TMP_ROOT/home-request"
home_ref=$(sed -n 's/^message=\([^ ]*\).*/\1/p' "$TMP_ROOT/home-request")
receive d > "$TMP_ROOT/home-received"
jq -se --arg ref "$home_ref" 'any(.[]; .message.id==$ref and .message.from=="c" and .message.to==["d"])' "$TMP_ROOT/home-received" >/dev/null || fail 'home recipient did not receive under its own identity'
send d --reply "$home_ref" 'review findings received' >/dev/null
receive c | jq -se --arg ref "$home_ref" 'any(.[]; .message.ref==$ref and .message.from=="d" and .message.to==["c"])' >/dev/null || fail 'home-to-home reply did not return'
name=$(jq -r --arg ref "$home_ref" 'select(.message.id==$ref)|.name' "$TMP_ROOT/home-received")
(cd "$TMP_ROOT/wt-d"; FM_TASK_ID=d "$ROOT/bin/fm-message.sh" ack "$name")
receive d | jq -se --arg ref "$home_ref" 'all(.[]; .message.id!=$ref)' >/dev/null || fail 'home acknowledgement lost identity'
pass 'recorded persistent homes exchange requests and replies and acknowledge under their own ids'

send a d --thread worker-home --kind request 'worker evidence' > "$TMP_ROOT/worker-home"
worker_ref=$(sed -n 's/^message=\([^ ]*\).*/\1/p' "$TMP_ROOT/worker-home")
receive d | jq -se --arg ref "$worker_ref" 'any(.[]; .message.id==$ref and .message.from=="a")' >/dev/null || fail 'worker-to-home request missing'
send d --reply "$worker_ref" 'home result' >/dev/null
receive a | jq -se --arg ref "$worker_ref" 'any(.[]; .message.ref==$ref and .message.from=="d" and .message.to==["a"])' >/dev/null || fail 'home-to-worker reply missing'
pass 'worker and persistent home communicate in both directions through the existing inbox'

# shellcheck disable=SC2016 # Positional arguments expand in the child shell.
refuse 'home cannot borrow peer identity' bash -c 'cd "$1/wt-c"; FM_TASK_ID=d "$2/bin/fm-message.sh" send a nope' _ "$TMP_ROOT" "$ROOT"
# shellcheck disable=SC2016
refuse 'home cannot borrow supervisor identity' bash -c 'cd "$1/wt-c"; FM_TASK_ID=supervisor "$2/bin/fm-message.sh" send a nope' _ "$TMP_ROOT" "$ROOT"
# shellcheck disable=SC2016
refuse 'unmarked home cannot use parent supervisor' bash -c 'cd "$1/wt-c"; unset FM_TASK_ID; "$2/bin/fm-message.sh" send a --kind note nope' _ "$TMP_ROOT" "$ROOT"
refuse 'home cannot send lifecycle keys' send c d --key Enter
refuse 'home cannot resolve approvals' send c d --resolve-key approval yes
printf 'wrong-id\n' > "$TMP_ROOT/wt-d/.fm-secondmate-home"
refuse 'mismatched home marker sender' send d a nope
refuse 'mismatched home marker receiver' send a d nope
printf 'd\n' > "$TMP_ROOT/wt-d/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$TMP_ROOT/wt-c" > "$TMP_ROOT/wt-d/.fm-secondmate-parent"
refuse 'foreign parent binding' send a d nope
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$FM_HOME" > "$TMP_ROOT/wt-d/.fm-secondmate-parent"
printf 'home=%s\n' "$TMP_ROOT/wt-c" >> "$FM_HOME/state/d.meta"
refuse 'ambiguous home field' send a d nope
