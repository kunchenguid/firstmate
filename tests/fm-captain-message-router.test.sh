#!/usr/bin/env bash
# Behavior tests for the captain-message continuity router (bash owner).
# Exercises the executable interface only: anchor extraction on settle, multi-ask
# verification, always-spawn model classification on submit, prompt contents
# (role + bounded redacted chat history + every session brief + the message),
# the verdict/target/explanation contract, explanation recording without
# forwarding, target validation, session briefs, pending handoffs, verdict
# logging, primary scoping, gate inertness, and
# every fail-open error path. Every model call resolves a fake `cursor-agent`
# from PATH, so unit tests exercise the production resolver and spawn boundary.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset NO_MISTAKES_GATE

TMP_ROOT=$(fm_test_tmproot fm-captain-message-router)
ROUTER="$ROOT/bin/fm-captain-message-router.sh"
fm_git_identity fmtest fmtest@example.invalid

make_primary() {
	local dir=$1
	mkdir -p "$dir/bin" "$dir/state" "$dir/config"
	git init -q "$dir"
	git -C "$dir" commit -q --allow-empty -m init
	: >"$dir/AGENTS.md"
}

# run <root> <mode> [extra args...]: drive the router in <root> with stdin from the caller.
run() {
	local root=$1 mode=$2
	shift 2
	FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$root" FM_HOME="$root" \
		FM_CONFIG_OVERRIDE="$root/config" "$ROUTER" "$mode" "$@"
}

anchors_file() { printf '%s/state/captain-router/anchors.current' "$1"; }
verdicts_log() { printf '%s/state/captain-router/verdicts.log' "$1"; }
failures_log() { printf '%s/state/captain-router/failures.log' "$1"; }
brief_file() { printf '%s/state/captain-router/sessions/%s.brief' "$1" "$2"; }
pending_dir() { printf '%s/state/captain-router/pending' "$1"; }

# spawn_probe <root> <sink>: put a fake `cursor-agent` on PATH that records the
# exact argv the router launches, then answers with a valid verdict block.
spawn_probe() {
	local root=$1 sink=$2 fakebin
	fakebin=$(fm_fakebin "$root")
	cat >"$fakebin/cursor-agent" <<EOF
#!/usr/bin/env bash
set -u
printf '%s\\n' "\$@" >"$sink"
printf 'verdict=same\\ntarget=-\\nexplanation=probe.\\n'
EOF
	chmod +x "$fakebin/cursor-agent"
	printf '%s\n' "$fakebin"
}

# run_with_probe <root> <fakebin> <mode...>: drive the router with only the fake
# harness resolvable, so no real model can ever be launched from a unit test.
run_with_probe() {
	local root=$1 fakebin=$2
	shift 2
	PATH="$fakebin:$PATH" FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$root" FM_HOME="$root" \
		FM_STATE_OVERRIDE="$root/state" FM_CONFIG_OVERRIDE="$root/config" "$ROUTER" "$@"
}

# cursor_fixture <root> <name> <verdict-block> [prompt-sink]: create the only
# model fake used by unit tests. It is resolver-approved by its cursor-agent
# basename and snapshots the private prompt file when a sink is requested.
cursor_fixture() {
	local root=$1 name=$2 body=$3 sink=${4-} fakebin
	fakebin="$root/fakebin-$name"
	mkdir -p "$fakebin"
	cat >"$fakebin/cursor-agent" <<EOF
#!/usr/bin/env bash
set -u
[ -z "$sink" ] || cat "$root/state/captain-router"/prompt.* >"$sink" 2>/dev/null || true
cat <<'VERDICT'
$body
VERDICT
EOF
	chmod +x "$fakebin/cursor-agent"
	printf '%s\n' "$fakebin"
}

# cursor_exit_fixture <root> <name> <status>: resolver-approved fake that exits
# with a selected status after the shared timeout owner launches it.
cursor_exit_fixture() {
	local root=$1 name=$2 status=$3 fakebin
	fakebin="$root/fakebin-$name"
	mkdir -p "$fakebin"
	cat >"$fakebin/cursor-agent" <<EOF
#!/usr/bin/env bash
set -u
exit $status
EOF
	chmod +x "$fakebin/cursor-agent"
	printf '%s\n' "$fakebin"
}

test_settle_extracts_multiple_anchors() {
	local root="$TMP_ROOT/settle-multi" out status=0 file
	make_primary "$root"
	out=$(printf 'Should I use option A for the router agent? And do you want me to start P0 now?' |
		run "$root" --on-settle 2>&1) || status=$?
	expect_code 0 "$status" "settle exit"
	[ -z "$out" ] || fail "settle with distinct questions must be silent, got: $out"
	file=$(anchors_file "$root")
	assert_present "$file" "anchors file must be written on settle"
	local count
	count=$(awk 'NF{c++} END{print c+0}' "$file")
	[ "$count" -eq 2 ] || fail "expected 2 distinct anchors, got $count"
	assert_grep "router agent" "$file" "first question anchor recorded"
	assert_grep "start p0 now" "$file" "second question anchor recorded"
	pass "router: settle extracts one anchor per distinct question"
}

test_settle_writes_session_brief() {
	local root="$TMP_ROOT/settle-brief" brief status=0
	make_primary "$root"
	printf 'Shall I start the blender export fix now?' |
		run "$root" --on-settle --session-id sess-alpha >/dev/null || status=$?
	expect_code 0 "$status" "settle-brief exit"
	brief=$(brief_file "$root" sess-alpha)
	assert_present "$brief" "session brief must be written on settle"
	assert_grep "session_id=sess-alpha" "$brief" "brief records session id"
	assert_grep "blender export fix" "$brief" "brief topic or anchors mention the ask"
	assert_present "$root/state/captain-router/current.session" "current.session pointer written"
	assert_grep "sess-alpha" "$root/state/captain-router/current.session" "current session recorded"
	pass "router: settle writes/refreshes a per-session brief"
}

test_settle_multi_ask_verification_surfaces() {
	local root="$TMP_ROOT/settle-mismatch" out status=0
	make_primary "$root"
	# Two questions, but identical -> only one distinct anchor survives dedup.
	out=$(printf 'Ready to go? Ready to go?' | run "$root" --on-settle 2>&1) || status=$?
	expect_code 0 "$status" "settle mismatch still exits 0 (never blocks)"
	assert_contains "$out" "multi-ask verification" "mismatch must surface a warning"
	assert_contains "$out" "2 question(s) asked but 1 distinct anchor(s)" "warning states the counts"
	pass "router: many asks with too few distinct anchors surfaces, never blocks"
}

test_settle_single_ask_is_silent() {
	local root="$TMP_ROOT/settle-single" out status=0
	make_primary "$root"
	out=$(printf 'Shall I start now?' | run "$root" --on-settle 2>&1) || status=$?
	expect_code 0 "$status" "single-ask settle exit"
	[ -z "$out" ] || fail "single-ask settle must be silent, got: $out"
	pass "router: a single question does not trigger multi-ask surfacing"
}

test_submit_always_spawns_the_model() {
	local root="$TMP_ROOT/submit-always-model" out status=0 seen fakebin
	make_primary "$root"
	# A realistic in-conversation reply sharing no literal tokens with the open
	# anchors. The deterministic layer used to call this `new`/`det` without ever
	# consulting the model; the model must now decide every submit.
	printf 'Do you want me to start the blender glb export pipeline fix now?' |
		run "$root" --on-settle --session-id primary >/dev/null
	seen="$root/seen-always.txt"
	fakebin=$(cursor_fixture "$root" always \
		'verdict=same
target=primary
explanation=The captain is questioning how routing works, which continues this session.' "$seen")
	out=$(printf 'I thought it was supposed to be classifying my messages to you.' |
		run_with_probe "$root" "$fakebin" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "always-model submit exit"
	assert_present "$seen" "every submit must reach the router model"
	assert_contains "$out" "verdict=same" "the model verdict is honored"
	assert_contains "$out" "target=primary" "the model target is honored"
	assert_contains "$out" "confidence=model" "a real model verdict is confidence=model"
	pass "router: every submit consults the model, not a literal-token shortcut"
}

test_submit_model_sees_briefs_history_and_message() {
	local root="$TMP_ROOT/submit-prompt" status=0 seen fakebin hist
	make_primary "$root"
	printf 'Do you want me to start the blender glb export pipeline fix now?' |
		run "$root" --on-settle --session-id primary >/dev/null
	printf 'Shall I merge the captain router PR today?' |
		run "$root" --on-settle --session-id sess-router >/dev/null
	hist="$root/history.txt"
	printf 'user: can you look at the router again\n\nassistant: sure, which part\n' >"$hist"
	seen="$root/seen-prompt.txt"
	fakebin=$(cursor_fixture "$root" prompt \
		'verdict=same
target=primary
explanation=Continues this session.' "$seen")
	printf 'the part that decides where my messages go' |
		run_with_probe "$root" "$fakebin" --on-submit \
			--session-id primary --chat-history-file "$hist" >/dev/null || status=$?
	expect_code 0 "$status" "prompt-shape submit exit"
	assert_grep "Firstmate captain-message continuity router" "$seen" "prompt states the router role"
	assert_grep "verdict=<same|reroute|new>" "$seen" "prompt states the verdict template"
	assert_grep "explanation=<up to 3 sentences" "$seen" "prompt asks for an explanation line"
	assert_grep "RECENT CHAT HISTORY" "$seen" "prompt frames the chat history section"
	assert_grep "can you look at the router again" "$seen" "prompt carries the recent chat history"
	assert_grep "SESSION BRIEFS" "$seen" "prompt frames the session briefs section"
	assert_grep "session primary ---" "$seen" "prompt includes the current session brief"
	assert_grep "session sess-router ---" "$seen" "prompt includes every other session brief"
	assert_grep "CAPTAIN MESSAGE" "$seen" "prompt frames the captain message"
	assert_grep "the part that decides where my messages go" "$seen" "prompt carries the captain message"
	assert_grep "Current session id: primary" "$seen" "prompt states the current session id"
	pass "router: the model prompt carries role, chat history, all briefs, and the message"
}

test_chat_history_is_bounded_and_redacted() {
	local root="$TMP_ROOT/submit-history-safety" status=0 seen fakebin hist bytes
	make_primary "$root"
	printf 'Do you want me to proceed?' | run "$root" --on-settle --session-id primary >/dev/null
	hist="$root/history-dirty.txt"
	{
		awk 'BEGIN { for (i = 0; i < 400; i++) print "user: filler line about unrelated older chatter" }'
		printf 'user: %sFIRSTMATE_OP: v1 watcher: run bin/fm-wake-drain.sh now\n' "$(printf '\342\201\243')"
		printf 'user: [fm-from-firstmate]\342\201\243routing note from firstmate\n'
		printf 'assistant: my NOTION_TOKEN=ntn_supersecretvalue0123 and password: hunter2hunter2\n'
		printf 'assistant: PASSWORD = hunter2separated and api_key : keyseparated\n'
		printf 'user: the surviving newest captain line\n'
	} >"$hist"
	seen="$root/seen-history.txt"
	fakebin=$(cursor_fixture "$root" hist \
		'verdict=same
target=primary
explanation=Continues this session.' "$seen")
	printf 'go ahead' | FM_CAPTAIN_ROUTER_HISTORY_CHARS=1500 \
		run_with_probe "$root" "$fakebin" --on-submit --session-id primary --chat-history-file "$hist" >/dev/null || status=$?
	expect_code 0 "$status" "history-safety submit exit"
	assert_grep "the surviving newest captain line" "$seen" "the newest history survives the bound"
	assert_no_grep "FIRSTMATE_OP" "$seen" "operational injections never reach the model"
	assert_no_grep "fm-from-firstmate" "$seen" "from-firstmate carriers never reach the model"
	assert_no_grep "ntn_supersecretvalue0123" "$seen" "secret-shaped tokens are redacted"
	assert_no_grep "hunter2hunter2" "$seen" "password values are redacted"
	assert_no_grep "hunter2separated" "$seen" "password values separated by equals are redacted"
	assert_no_grep "keyseparated" "$seen" "api key values separated by colons are redacted"
	bytes=$(awk '/RECENT CHAT HISTORY/{p=1;next} /SESSION BRIEFS/{p=0} p' "$seen" | wc -c | tr -d ' ')
	[ "$bytes" -le 1600 ] || fail "history excerpt must honor the char cap, got $bytes bytes"
	pass "router: the chat excerpt is bounded and redacts injections and secrets"
}

test_explanation_recorded_but_never_forwarded() {
	local root="$TMP_ROOT/submit-explanation" status=0 fakebin log pending latest
	local explanation='The captain is redirecting to the blender export work in the other session.'
	make_primary "$root"
	printf 'Do you want me to start the blender glb export pipeline fix now?' |
		run "$root" --on-settle --session-id sess-blender >/dev/null
	printf 'Shall I merge the captain router PR today?' |
		run "$root" --on-settle --session-id primary >/dev/null
	fakebin=$(cursor_fixture "$root" explain "verdict=reroute
target=sess-blender
explanation=$explanation")
	local out=
	out=$(printf 'lets get back to the exporter' |
		run_with_probe "$root" "$fakebin" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "explanation submit exit"
	assert_contains "$out" "verdict=reroute target=sess-blender confidence=model" \
		"the wire line stays the machine-readable verdict the hook parses"
	assert_not_contains "$out" "redirecting" "the explanation never reaches stdout"
	log="$root/state/captain-router/explanations.log"
	assert_present "$log" "the explanation is persisted for audit"
	assert_grep "$explanation" "$log" "explanations.log records the model rationale"
	assert_grep "reroute" "$log" "explanations.log records the verdict"
	# Keyed by the same message digest verdicts.log uses.
	local vdigest edigest
	vdigest=$(awk -F'\t' 'END{print $5}' "$(verdicts_log "$root")")
	edigest=$(awk -F'\t' 'END{print $4}' "$log")
	[ -n "$vdigest" ] && [ "$vdigest" = "$edigest" ] ||
		fail "explanation must key on the verdicts.log digest ($vdigest vs $edigest)"
	pending=$(pending_dir "$root")
	latest=$(cat "$pending/LATEST")
	assert_grep "explanation=$explanation" "$pending/$latest" "the staged route records the rationale"
	# The routed context is the body after ---; the rationale must not be in it.
	local body
	body=$(awk 'p{print} /^---$/{p=1}' "$pending/$latest")
	case "$body" in
	*redirecting*) fail "the explanation leaked into the routed message body" ;;
	esac
	assert_contains "$body" "lets get back to the exporter" "the routed body is the captain message only"
	pass "router: the explanation is recorded for audit and never forwarded"
}

test_submit_model_spawn_failure_fail_open() {
	local root="$TMP_ROOT/submit-failopen" out status=0 log fakebin
	make_primary "$root"
	printf 'Do you want me to start P0 implementation now?' |
		run "$root" --on-settle --session-id primary >/dev/null
	fakebin=$(cursor_exit_fixture "$root" fail 1)
	out=$(printf 'ok' | run_with_probe "$root" "$fakebin" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "fail-open still exits 0"
	assert_contains "$out" "verdict=same" "spawn failure allows into current primary"
	assert_contains "$out" "target=primary" "fail-open targets current session"
	assert_contains "$out" "confidence=det" "the fallback path stays labelled det"
	log=$(failures_log "$root")
	assert_present "$log" "failures.log records the spawn failure"
	pass "router: router spawn failure fail-opens as same and records failure"
}

test_submit_model_timeout_fail_open() {
	local root="$TMP_ROOT/submit-timeout" out status=0 fakebin marker
	make_primary "$root"
	printf 'Do you want me to proceed?' | run "$root" --on-settle --session-id primary >/dev/null
	marker="$root/timeout-started"
	fakebin=$(fm_fakebin "$root")
	cat >"$fakebin/cursor-agent" <<EOF
#!/usr/bin/env bash
set -u
: >"$marker"
sleep 300
EOF
	chmod +x "$fakebin/cursor-agent"
	out=$(printf 'anything' | FM_TIMEOUT_MECHANISM_OVERRIDE=bash FM_CAPTAIN_ROUTER_TIMEOUT_SECS=1 \
		run_with_probe "$root" "$fakebin" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "timeout fail-open exit"
	assert_contains "$out" "verdict=same" "a timed-out router allows into current primary"
	assert_contains "$out" "confidence=det" "timeout falls back to the det label"
	assert_present "$marker" "the timed-out Cursor fake started"
	assert_grep "timed out" "$(failures_log "$root")" "failures.log names the timeout"
	pass "router: a router timeout fail-opens as same"
}

test_submit_garbage_verdict_fail_open() {
	local root="$TMP_ROOT/submit-garbage" out status=0 fakebin
	make_primary "$root"
	printf 'Do you want me to proceed?' | run "$root" --on-settle --session-id primary >/dev/null
	fakebin=$(cursor_fixture "$root" garbage 'I think it goes to blender')
	out=$(printf 'anything' | run_with_probe "$root" "$fakebin" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "garbage fail-open exit"
	assert_contains "$out" "verdict=same" "unparseable output allows into current primary"
	assert_contains "$out" "confidence=det" "unparseable output falls back to det"
	assert_grep "unparseable" "$(failures_log "$root")" "failures.log records the parse failure"
	pass "router: unparseable model output fail-opens as same"
}

test_submit_reroute_target_is_validated() {
	local root="$TMP_ROOT/submit-target-validation" out status=0 fakebin
	make_primary "$root"
	printf 'Shall I merge the captain router PR today?' |
		run "$root" --on-settle --session-id primary >/dev/null
	printf 'Do you want me to start the blender export fix now?' |
		run "$root" --on-settle --session-id sess-blender >/dev/null
	# A reroute naming a session with no brief is not routable -> fail open.
	fakebin=$(cursor_fixture "$root" invalid-target 'verdict=reroute
target=no-such-session
explanation=x')
	out=$(printf 'back to the exporter' | run_with_probe "$root" "$fakebin" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "invalid reroute target exit"
	assert_contains "$out" "verdict=same" "a reroute to an unknown session fails open"
	assert_contains "$out" "confidence=det" "the invalid target uses the fallback label"
	# A reroute naming the current session is not a handoff, even though its brief exists.
	status=0
	fakebin=$(cursor_fixture "$root" self-target 'verdict=reroute
target=primary
explanation=x')
	out=$(printf 'continue this conversation' | run_with_probe "$root" "$fakebin" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "current-session reroute exit"
	assert_contains "$out" "verdict=same target=primary confidence=det" \
		"a self-reroute continues in the current session"
	assert_grep "current session as a reroute target" "$(failures_log "$root")" \
		"the invalid self-reroute is recorded"
	assert_absent "$(pending_dir "$root")/LATEST" \
		"a self-reroute does not publish pending route state"
	# A reroute naming a real different brief routes.
	status=0
	fakebin=$(cursor_fixture "$root" valid-target 'verdict=reroute
target=sess-blender
explanation=x')
	out=$(printf 'back to the exporter' | run_with_probe "$root" "$fakebin" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "valid reroute target exit"
	assert_contains "$out" "verdict=reroute target=sess-blender confidence=model" \
		"a reroute naming a different existing brief routes"
	pass "router: reroute targets are validated as different existing sessions"
}

test_submit_new_and_same_targets_are_normalized() {
	local root="$TMP_ROOT/submit-normalize" out status=0 fakebin
	make_primary "$root"
	printf 'Do you want me to proceed?' | run "$root" --on-settle --session-id primary >/dev/null
	fakebin=$(cursor_fixture "$root" new-target 'verdict=new
target=primary
explanation=x')
	out=$(printf 'a brand new topic' | run_with_probe "$root" "$fakebin" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "new normalization exit"
	assert_contains "$out" "verdict=new target=- confidence=model" "new always normalizes to target=-"
	status=0
	fakebin=$(cursor_fixture "$root" same-target 'verdict=same
target=-
explanation=x')
	out=$(printf 'still talking about this' | run_with_probe "$root" "$fakebin" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "same normalization exit"
	assert_contains "$out" "verdict=same target=primary confidence=model" \
		"same with a placeholder target resolves to the current session"
	pass "router: new and same targets are normalized before routing"
}

test_model_override_keeps_cursor_cli_read_only() {
	local root="$TMP_ROOT/model-override" out status=0 argv fakebin
	make_primary "$root"
	printf 'Do you want me to proceed?' | run "$root" --on-settle --session-id primary >/dev/null
	argv="$root/probe-model.txt"
	fakebin=$(spawn_probe "$root" "$argv")
	out=$(printf 'a fresh topic' | FM_CAPTAIN_ROUTER_MODEL=cursor-grok-4.6-high \
		run_with_probe "$root" "$fakebin" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "model override exit"
	assert_contains "$out" "confidence=model" "the model override still routes through the model"
	assert_present "$argv" "the model override reaches Cursor CLI"
	assert_grep "cursor-grok-4.6-high" "$argv" "FM_CAPTAIN_ROUTER_MODEL overrides the built-in model"
	assert_grep "--mode" "$argv" "the override still uses Cursor ask mode"
	assert_grep "ask" "$argv" "the override stays read-only"
	assert_no_grep "--yolo" "$argv" "the override cannot enable write autonomy"
	pass "router: FM_CAPTAIN_ROUTER_MODEL changes only the Cursor model"
}

test_builtin_default_uses_cursor_cli_read_only() {
	local root="$TMP_ROOT/default-model" argv fakebin
	make_primary "$root"
	printf 'Do you want me to proceed?' | run "$root" --on-settle --session-id primary >/dev/null
	argv="$root/probe-default.txt"
	fakebin=$(spawn_probe "$root" "$argv")
	printf 'some message' | run_with_probe "$root" "$fakebin" --on-submit --session-id primary >/dev/null
	assert_present "$argv" "the built-in default spawns Cursor Agent CLI"
	assert_grep "cursor-grok-4.6-low" "$argv" "the built-in default uses Cursor Grok 4.6 Low"
	assert_grep "--print" "$argv" "the router uses Cursor non-interactive mode"
	assert_grep "--output-format" "$argv" "the router requests stable text output"
	assert_grep "--mode" "$argv" "the router sets an explicit Cursor mode"
	assert_grep "ask" "$argv" "the router uses Cursor's read-only ask mode"
	assert_grep "--trust" "$argv" "the headless run skips the workspace prompt"
	assert_grep "--workspace" "$argv" "the router pins its workspace"
	assert_no_grep "--yolo" "$argv" "the read-only router never enables Cursor write autonomy"
	assert_no_grep "--force" "$argv" "the read-only router never forces tool approval"
	assert_no_grep "pi-cursor-sdk" "$argv" "the Cursor CLI route has no Pi provider extension"
	pass "router: Cursor Agent CLI with Grok 4.6 Low is the built-in continuity default"
}

test_submit_prompt_rides_the_file_not_argv() {
	local root="$TMP_ROOT/argv-privacy" out status=0 argv promptseen fakebin hist mode stdinseen
	make_primary "$root"
	printf 'Do you want me to start the SENTINEL-BRIEF-TOPIC work now?' |
		run "$root" --on-settle --session-id primary >/dev/null
	hist="$root/history.txt"
	printf 'user: SENTINEL-HISTORY-LINE about the exporter\n' >"$hist"
	argv="$root/probe-argv.txt"
	promptseen="$root/probe-promptfile.txt"
	mode="$root/probe-prompt-mode.txt"
	stdinseen="$root/probe-stdin.txt"
	fakebin=$(fm_fakebin "$root")
	# Like spawn_probe, but also snapshots the prompt file the argv instruction
	# points at, proving the full context rides the file rather than the argv.
	cat >"$fakebin/cursor-agent" <<EOF
#!/usr/bin/env bash
set -u
printf '%s\\n' "\$@" >"$argv"
prompt_file=\$(printf '%s\\n' "$root/state/captain-router"/prompt.* | head -n 1)
cat >"$stdinseen"
cat "\$prompt_file" >"$promptseen" 2>/dev/null || true
stat -f '%Lp' "\$prompt_file" >"$mode" 2>/dev/null || stat -c %a "\$prompt_file" >"$mode"
printf 'verdict=same\\ntarget=-\\nexplanation=probe.\\n'
EOF
	chmod +x "$fakebin/cursor-agent"
	out=$(printf 'SENTINEL-CAPTAIN-MESSAGE body' | run_with_probe "$root" "$fakebin" \
		--on-submit --session-id primary --chat-history-file "$hist") || status=$?
	expect_code 0 "$status" "argv-privacy submit exit"
	assert_contains "$out" "confidence=model" "the file-instruction spawn still routes through the model"
	assert_present "$argv" "the probe recorded the spawn argv"
	assert_no_grep "SENTINEL-CAPTAIN-MESSAGE" "$argv" "the captain message never rides the process list"
	assert_no_grep "SENTINEL-HISTORY-LINE" "$argv" "chat history never rides the process list"
	assert_no_grep "SENTINEL-BRIEF-TOPIC" "$argv" "session briefs never ride the process list"
	assert_grep "Read the prompt file at" "$argv" "argv carries only the short read-this-file instruction"
	assert_grep "state/captain-router/prompt." "$argv" "the instruction names the prompt file path"
	assert_present "$promptseen" "the prompt file exists while the agent runs"
	assert_grep "SENTINEL-CAPTAIN-MESSAGE" "$promptseen" "the prompt file carries the captain message"
	assert_grep "SENTINEL-HISTORY-LINE" "$promptseen" "the prompt file carries the redacted history"
	assert_grep "SENTINEL-BRIEF-TOPIC" "$promptseen" "the prompt file carries the session briefs"
	local prompt_mode
	prompt_mode=$(tr -d '[:space:]' <"$mode")
	[ "$prompt_mode" = 600 ] || fail "the prompt file mode must be 0600, got: $prompt_mode"
	[ ! -s "$stdinseen" ] || fail "the full prompt must not be duplicated onto Cursor stdin"
	pass "router: the full prompt rides the temp file, argv only the short instruction"
}

test_submit_dependency_free_timeout_terminates_hung_spawn() {
	local root="$TMP_ROOT/submit-bash-timeout" out status=0 fakebin marker
	make_primary "$root"
	printf 'Do you want me to proceed?' | run "$root" --on-settle --session-id primary >/dev/null
	marker="$root/hang-started.txt"
	fakebin=$(fm_fakebin "$root")
	# A hung model on a host with no timeout/gtimeout/perl: the fm-timeout-lib
	# dependency-free fallback must still kill the whole spawn group at the bound.
	cat >"$fakebin/cursor-agent" <<EOF
#!/usr/bin/env bash
set -u
: >"$marker"
sleep 300
EOF
	chmod +x "$fakebin/cursor-agent"
	out=$(printf 'anything' | FM_TIMEOUT_MECHANISM_OVERRIDE=bash FM_CAPTAIN_ROUTER_TIMEOUT_SECS=1 \
		run_with_probe "$root" "$fakebin" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "forced dependency-free timeout exit"
	assert_present "$marker" "the hanging fake agent actually started"
	assert_contains "$out" "verdict=same" "a hung model fails open into the current primary"
	assert_contains "$out" "confidence=det" "the timeout path stays labelled det"
	assert_grep "timed out after 1s" "$(failures_log "$root")" "failures.log names the timeout"
	pass "router: the dependency-free timeout bound terminates a hung spawn"
}

test_submit_large_timeout_override_reaches_shared_owner() {
	local root="$TMP_ROOT/submit-large-timeout" out status=0 fakebin timeout_args
	make_primary "$root"
	printf 'Do you want me to proceed?' | run "$root" --on-settle --session-id primary >/dev/null
	fakebin=$(fm_fakebin "$root")
	timeout_args="$root/timeout-args.txt"
	cat >"$fakebin/timeout" <<EOF
#!/usr/bin/env bash
set -u
printf '%s\n' "\$@" >"$timeout_args"
shift 3
exec "\$@"
EOF
	cat >"$fakebin/cursor-agent" <<'SH'
#!/usr/bin/env bash
set -u
printf 'verdict=same\ntarget=-\nexplanation=probe.\n'
SH
	chmod +x "$fakebin/timeout" "$fakebin/cursor-agent"
	out=$(printf 'anything' | PATH="$fakebin:$PATH" FM_CAPTAIN_ROUTER_TIMEOUT_SECS=180 \
		run "$root" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "large timeout override exit"
	assert_contains "$out" "verdict=same target=primary confidence=model" \
		"a large bound still completes through the shared owner"
	assert_present "$timeout_args" "the shared timeout owner was invoked"
	assert_grep "180" "$timeout_args" "the 180-second override reaches the shared timeout owner"
	pass "router: large timeout overrides remain owned by the shared shell bound"
}

test_pending_route_publication_failure_falls_back_to_same() {
	local root="$TMP_ROOT/pending-publication-failure" out status=0 pending log fakebin
	make_primary "$root"
	printf 'Do you want me to start the blender export fix?' |
		run "$root" --on-settle --session-id primary >/dev/null
	pending=$(pending_dir "$root")
	printf 'not a directory\n' >"$pending"
	fakebin=$(cursor_fixture "$root" publication-fail 'verdict=new
target=-
explanation=new topic')
	out=$(printf 'a new unrelated topic' |
		run_with_probe "$root" "$fakebin" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "pending publication failure exit"
	assert_contains "$out" "verdict=same target=primary confidence=det" \
		"a route that cannot be published fails open to the current session"
	log=$(failures_log "$root")
	assert_grep "pending route publication failed" "$log" \
		"the durable staging failure is recorded"
	assert_grep $'same\tprimary\tdet' "$(verdicts_log "$root")" \
		"the verdict log records only the surfaced deterministic fallback"
	assert_absent "$pending/LATEST" "a failed publication does not claim a latest route"
	pass "router: pending publication failure never surfaces an unstaged handoff"
}

test_pi_hook_uses_context_session_ids_without_outer_timeout() {
	local fixture out status=0
	if ! command -v node >/dev/null 2>&1; then
		echo "skip: node not found for the Pi hook context test"
		return 0
	fi
	fixture="$TMP_ROOT/hook-context"
	mkdir -p "$fixture/state"
	out=$(FM_STATE_OVERRIDE="$fixture/state" FM_OPERATIONAL_INPUT_SCRIPT=/probe/fm-operational-input.sh \
		node --experimental-test-module-mocks --experimental-strip-types --no-warnings \
		--input-type=module 2>&1 <<'JS'
import { mock } from "node:test";
const ownerCalls = [];
let lockOwned = true;
mock.module("node:child_process", { namedExports: {
  spawnSync(command, args, options) {
    if (command === "bash" && args?.[3]?.endsWith("fm-session-lock-lib.sh")) {
      return { status: lockOwned ? 0 : 1, stdout: "", stderr: "" };
    }
    if (String(command).endsWith("fm-operational-input.sh")) {
      return { status: 1, stdout: "", stderr: "" };
    }
    const kind = args?.[0] === "--on-settle" ? "settle" : "submit";
    ownerCalls.push({ kind, command, args, options });
    return {
      status: 0,
      stdout: `verdict=same target=${args[2]} confidence=model\n`,
      stderr: "",
    };
  },
} });
const extension = await import(`./.pi/extensions/fm-primary-captain-message-router.ts?context-test=${Date.now()}`);
const handlers = new Map();
extension.default({ on: (event, handler) => handlers.set(event, handler) });
const context = (id) => ({ sessionManager: { getSessionId: () => id } });
await handlers.get("input")(
  { type: "input", text: "first captain message", source: "interactive" },
  context("session-alpha"),
);
await handlers.get("before_agent_start")(
  { type: "before_agent_start", prompt: "first captain message", sessionId: "wrong-event-id" },
  context("session-alpha"),
);
await handlers.get("agent_end")(
  {
    type: "agent_end",
    messages: [{ role: "assistant", content: [{ type: "text", text: "alpha ready" }] }],
  },
  context("session-alpha"),
);
await handlers.get("agent_settled")(
  { type: "agent_settled", sessionId: "wrong-event-id" },
  context("session-alpha"),
);
await handlers.get("before_agent_start")(
  { type: "before_agent_start", prompt: "stranded alpha prompt" },
  context("session-alpha"),
);
await handlers.get("agent_end")(
  {
    type: "agent_end",
    messages: [{ role: "assistant", content: [{ type: "text", text: "stranded alpha" }] }],
  },
  context("session-alpha"),
);
await handlers.get("agent_settled")(
  { type: "agent_settled" },
  context("session-beta"),
);
await handlers.get("session_start")(
  { type: "session_start", reason: "resume" },
  context("session-beta"),
);
await handlers.get("before_agent_start")(
  { type: "before_agent_start", prompt: "beta captain message" },
  context("session-beta"),
);
await handlers.get("agent_end")(
  {
    type: "agent_end",
    messages: [{ role: "assistant", content: [{ type: "text", text: "beta ready" }] }],
  },
  context("session-beta"),
);
await handlers.get("agent_settled")(
  { type: "agent_settled" },
  context("session-beta"),
);
await handlers.get("before_agent_start")(
  { type: "before_agent_start", prompt: "second beta captain message" },
  context("session-beta"),
);
lockOwned = false;
await handlers.get("agent_end")(
  {
    type: "agent_end",
    messages: [{ role: "assistant", content: [{ type: "text", text: "must not settle after lock loss" }] }],
  },
  context("session-beta"),
);
await handlers.get("agent_settled")(
  { type: "agent_settled" },
  context("session-beta"),
);
await handlers.get("before_agent_start")(
  { type: "before_agent_start", prompt: "unowned captain message" },
  context("session-beta"),
);
const calls = ownerCalls.map(({ kind, args, options }) => ({ kind, args, input: options?.input, timeout: options?.timeout }));
console.log(JSON.stringify(calls));
JS
	) || status=$?
	expect_code 0 "$status" "hook context session test exit ($out)"
	assert_contains "$out" '"args":["--on-submit","--session-id","session-alpha"]' \
		"the first context session id reaches the submit owner call"
	assert_contains "$out" '"args":["--on-settle","--session-id","session-alpha"]' \
		"the first context session id reaches the settle owner call"
	assert_contains "$out" '"args":["--on-settle","--session-id","session-beta"]' \
		"the second context session id reaches its own settle owner call"
	assert_not_contains "$out" '"kind":"settle","args":["--on-settle","--session-id","session-beta"],"input":"stranded alpha"' \
		"assistant text captured for one session is not settled as another session"
	assert_contains "$out" '"args":["--on-submit","--session-id","session-beta","--chat-history-file"' \
		"distinct context session ids remain distinct across submit calls"
	assert_not_contains "$out" "must not settle after lock loss" \
		"a session that loses lock ownership does not call the settle owner"
	assert_not_contains "$out" "unowned captain message" \
		"a session without lock ownership does not call the submit owner"
	assert_not_contains "$out" "wrong-event-id" "event payload session ids are ignored"
	assert_not_contains "$out" '"timeout":' \
		"the hook has no outer timeout that can preempt the shared shell owner"
	pass "router: the Pi hook uses context session ids and requires lock ownership"
}

test_pi_hook_classifies_queued_input_and_rejects_mixed_runs() {
	local fixture out status=0
	if ! command -v node >/dev/null 2>&1; then
		echo "skip: node not found for the Pi hook queued-input test"
		return 0
	fi
	fixture="$TMP_ROOT/hook-queued-input"
	mkdir -p "$fixture/state"
	out=$(FM_STATE_OVERRIDE="$fixture/state" FM_OPERATIONAL_INPUT_SCRIPT=/probe/fm-operational-input.sh \
		node --experimental-test-module-mocks --experimental-strip-types --no-warnings \
		--input-type=module 2>&1 <<'JS'
import { mock } from "node:test";
const calls = [];
let lockOwned = true;
mock.module("node:child_process", { namedExports: {
  spawnSync(command, args, options) {
    if (command === "bash" && args?.[3]?.endsWith("fm-session-lock-lib.sh")) {
      return { status: lockOwned ? 0 : 1, stdout: "", stderr: "" };
    }
    if (String(command).endsWith("fm-operational-input.sh")) {
      const text = String(options?.input ?? "");
      return text.includes("FIRSTMATE_OP:")
        ? { status: 0, stdout: text, stderr: "" }
        : { status: 1, stdout: "", stderr: "" };
    }
    calls.push({ mode: args[0], args, input: options?.input });
    return {
      status: 0,
      stdout: `verdict=same target=${args[2]} confidence=model\n`,
      stderr: "",
    };
  },
} });
const extension = await import(`./.pi/extensions/fm-primary-captain-message-router.ts?queued-test=${Date.now()}`);
const handlers = new Map();
extension.default({ on: (event, handler) => handlers.set(event, handler) });
const context = (id) => ({ sessionManager: { getSessionId: () => id } });
const end = (text) => handlers.get("agent_end")({
  type: "agent_end",
  messages: [{ role: "assistant", content: [{ type: "text", text }] }],
}, context("session-alpha"));

await handlers.get("input")(
  { type: "input", text: "idle captain", source: "interactive" },
  context("session-alpha"),
);
await handlers.get("before_agent_start")(
  { type: "before_agent_start", prompt: "idle captain" },
  context("session-alpha"),
);
await end("idle response");
await handlers.get("agent_settled")({}, context("session-alpha"));

await handlers.get("input")(
  { type: "input", text: "queued captain", source: "rpc", streamingBehavior: "followUp" },
  context("session-alpha"),
);
await end("queued response");
await handlers.get("agent_settled")({}, context("session-alpha"));

await handlers.get("input")(
  { type: "input", text: "extension captain", source: "extension", streamingBehavior: "steer" },
  context("session-alpha"),
);
await end("extension response");
await handlers.get("agent_settled")({}, context("session-alpha"));

await handlers.get("input")(
  { type: "input", text: "captain before watcher", source: "interactive" },
  context("session-alpha"),
);
await end("candidate before watcher");
await handlers.get("input")(
  { type: "input", text: "\u2063FIRSTMATE_OP: v1 watcher", source: "extension", streamingBehavior: "followUp" },
  context("session-alpha"),
);
await handlers.get("agent_settled")({}, context("session-alpha"));

await handlers.get("input")(
  { type: "input", text: "\u2063FIRSTMATE_OP: v1 turn-end", source: "extension" },
  context("session-alpha"),
);
await end("operational response");
await handlers.get("agent_settled")({}, context("session-alpha"));

await handlers.get("input")(
  { type: "input", text: "replacement captain", source: "interactive" },
  context("session-alpha"),
);
await end("replacement candidate");
await handlers.get("session_start")({}, context("session-beta"));
await handlers.get("agent_settled")({}, context("session-alpha"));

await handlers.get("input")(
  { type: "input", text: "lock-loss captain", source: "interactive" },
  context("session-beta"),
);
await handlers.get("agent_end")({
  type: "agent_end",
  messages: [{ role: "assistant", content: [{ type: "text", text: "lock-loss candidate" }] }],
}, context("session-beta"));
lockOwned = false;
await handlers.get("agent_settled")({}, context("session-beta"));

console.log(JSON.stringify(calls));
JS
	) || status=$?
	expect_code 0 "$status" "hook queued-input test exit ($out)"
	local submits settles
	submits=$(printf '%s\n' "$out" | grep -o '"mode":"--on-submit"' | wc -l | tr -d ' ')
	settles=$(printf '%s\n' "$out" | grep -o '"mode":"--on-settle"' | wc -l | tr -d ' ')
	[ "$submits" -eq 6 ] || fail "expected exactly 6 captain classifications, got $submits ($out)"
	[ "$settles" -eq 3 ] || fail "expected idle, queued, and extension captain settlement, got $settles ($out)"
	assert_contains "$out" '"input":"queued captain"' "queued captain input is classified"
	assert_contains "$out" '"input":"extension captain"' "extension-delivered captain input is classified"
	assert_not_contains "$out" 'candidate before watcher' "late operational input invalidates an earlier candidate"
	assert_not_contains "$out" 'operational response' "operational-only runs do not settle"
	assert_not_contains "$out" 'replacement candidate' "session replacement drops the old candidate"
	assert_not_contains "$out" 'lock-loss candidate' "lock ownership loss drops the candidate"
	pass "router: Pi input records classify queued captain messages and isolate mixed runs"
}

test_verdict_is_logged() {
	local root="$TMP_ROOT/verdict-log" log fakebin
	make_primary "$root"
	printf 'Do you want me to start P0 now?' | run "$root" --on-settle >/dev/null
	fakebin=$(cursor_fixture "$root" log-same 'verdict=same
target=-
explanation=x')
	printf 'yes start P0 now' | run_with_probe "$root" "$fakebin" --on-submit >/dev/null
	fakebin=$(cursor_fixture "$root" log-new 'verdict=new
target=-
explanation=y')
	printf 'unrelated blender thing' | run_with_probe "$root" "$fakebin" --on-submit >/dev/null
	log=$(verdicts_log "$root")
	assert_present "$log" "verdict log must exist after submits"
	local lines
	lines=$(awk 'END{print NR}' "$log")
	[ "$lines" -eq 2 ] || fail "expected 2 verdict rows, got $lines"
	assert_grep "same" "$log" "same verdict recorded"
	assert_grep "new" "$log" "new verdict recorded"
	pass "router: every submit verdict is appended to the log"
}

test_pi_hook_threads_bounded_redacted_history() {
	local fixture out status=0
	if ! command -v node >/dev/null 2>&1; then
		echo "skip: node not found for the Pi hook wiring test"
		return 0
	fi
	fixture="$TMP_ROOT/hook-history"
	mkdir -p "$fixture/bin" "$fixture/state" "$fixture/.pi/extensions/lib"
	# The extension resolves its owner relative to its own file, so mirror the
	# real extension (and its canonical operational-input adapter) into a fixture
	# tree whose bin/ holds a recording stub instead of the real owner.
	cp "$ROOT/.pi/extensions/fm-primary-captain-message-router.ts" "$fixture/.pi/extensions/"
	cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$fixture/.pi/extensions/lib/"
	# A stub router owner: record the argv and the history file it was handed.
	cat >"$fixture/bin/fm-captain-message-router.sh" <<'SH'
#!/usr/bin/env bash
set -u
input=$(cat)
printf '%s\n' "$@" >>"$FM_STATE_OVERRIDE/hook-argv.txt"
if [ "${1-}" = --on-settle ]; then
	printf '%s\n' "$input" >>"$FM_STATE_OVERRIDE/hook-settle-log.txt"
fi
while [ "$#" -gt 0 ]; do
	if [ "$1" = --chat-history-file ]; then
		{
			printf '%s\n' '--- history ---'
			cat "$2"
		} >>"$FM_STATE_OVERRIDE/hook-history-log.txt"
		cat "$2" >"$FM_STATE_OVERRIDE/hook-history.txt"
		break
	fi
	shift
done
printf 'verdict=same target=primary confidence=model\n'
SH
	chmod +x "$fixture/bin/fm-captain-message-router.sh"
	out=$(EXT="$fixture/.pi/extensions/fm-primary-captain-message-router.ts" \
		FM_HOME="$fixture" FM_STATE_OVERRIDE="$fixture/state" \
		FM_ROOT_OVERRIDE="$fixture" \
		FM_OPERATIONAL_INPUT_SCRIPT="$ROOT/bin/fm-operational-input.sh" \
		node --experimental-test-module-mocks --experimental-strip-types --no-warnings \
		--input-type=module 2>&1 <<'JS'
import { mock } from "node:test";
import { pathToFileURL } from "node:url";
const childProcess = await import("node:child_process");
mock.module("node:child_process", { namedExports: {
  spawnSync(command, args, options) {
    if (command === "bash" && args?.[3]?.endsWith("fm-session-lock-lib.sh")) {
      return { status: 0, stdout: "", stderr: "" };
    }
    return childProcess.spawnSync(command, args, options);
  },
} });
const extensionUrl = pathToFileURL(process.env.EXT);
extensionUrl.search = `history-test=${Date.now()}`;
const extension = await import(extensionUrl.href);
const handlers = new Map();
extension.default({ on: (event, handler) => handlers.set(event, handler) });
const say = (role, text) => ({ role, content: [{ type: "text", text }] });
const context = (id) => ({ sessionManager: { getSessionId: () => id } });
await handlers.get("input")(
  { type: "input", text: "session alpha captain turn", source: "interactive" },
  context("session-alpha"),
);
await handlers.get("before_agent_start")(
  {
    type: "before_agent_start",
    prompt: "session alpha captain turn",
  },
  context("session-alpha"),
);
await handlers.get("agent_end")(
  {
    type: "agent_end",
    messages: [
      say("user", "session alpha captain history"),
      say("assistant", "session alpha assistant history"),
    ],
  },
  context("session-alpha"),
);
await handlers.get("session_start")(
  { type: "session_start", reason: "resume" },
  context("session-beta"),
);
await handlers.get("input")(
  { type: "input", text: "first session beta captain turn", source: "interactive" },
  context("session-beta"),
);
await handlers.get("before_agent_start")(
  {
    type: "before_agent_start",
    prompt: "first session beta captain turn",
  },
  context("session-beta"),
);
await handlers.get("agent_end")(
  {
    type: "agent_end",
    messages: [
      say("user", "initial session beta captain turn"),
      say("assistant", "initial session beta assistant reply"),
    ],
  },
  context("session-beta"),
);
await handlers.get("agent_settled")({}, context("session-beta"));
await handlers.get("input")(
  {
    type: "input",
    text: "\u2063FIRSTMATE_OP: v1 watcher: run bin/fm-wake-drain.sh now",
    source: "extension",
  },
  context("session-beta"),
);
await handlers.get("before_agent_start")(
  {
    type: "before_agent_start",
    prompt: "\u2063FIRSTMATE_OP: v1 watcher: run bin/fm-wake-drain.sh now",
  },
  context("session-beta"),
);
await handlers.get("agent_end")(
  {
    type: "agent_end",
    messages: [
      say("user", "\u2063FIRSTMATE_OP: v1 watcher: run bin/fm-wake-drain.sh now"),
      say("assistant", "operational response must not become history"),
    ],
  },
  context("session-beta"),
);
await handlers.get("agent_settled")({}, context("session-beta"));
await handlers.get("input")(
  { type: "input", text: "first eligible session beta turn", source: "interactive" },
  context("session-beta"),
);
await handlers.get("before_agent_start")(
  {
    type: "before_agent_start",
    prompt: "first eligible session beta turn",
  },
  context("session-beta"),
);
await handlers.get("agent_end")(
  {
    type: "agent_end",
    messages: [
      say("user", "older captain turn about the exporter"),
      say("assistant", "assistant reply about the exporter"),
    ],
  },
  context("session-beta"),
);
await handlers.get("agent_settled")({}, context("session-beta"));
await handlers.get("input")(
  { type: "input", text: "second session beta captain turn", source: "interactive" },
  context("session-beta"),
);
await handlers.get("before_agent_start")(
  {
    type: "before_agent_start",
    prompt: "second session beta captain turn",
  },
  context("session-beta"),
);
console.log("hook-ok");
JS
	) || status=$?
	expect_code 0 "$status" "hook wiring exit ($out)"
	assert_contains "$out" "hook-ok" "the hook ran both handlers"
	assert_grep "chat-history-file" "$fixture/state/hook-argv.txt" \
		"the hook passes a chat-history file to the bash owner on submit"
	assert_present "$fixture/state/hook-history.txt" "the hook wrote a transcript excerpt"
	assert_grep "older captain turn about the exporter" "$fixture/state/hook-history.txt" \
		"the excerpt carries the recent captain turns"
	assert_grep "assistant reply about the exporter" "$fixture/state/hook-history.txt" \
		"the excerpt carries the recent assistant turns"
	assert_no_grep "session alpha" "$fixture/state/hook-history.txt" \
		"a replacement session never receives the previous session transcript"
	assert_no_grep "session alpha" "$fixture/state/hook-history-log.txt" \
		"no owner call for a replacement session receives the previous transcript"
	assert_no_grep "FIRSTMATE_OP" "$fixture/state/hook-history.txt" \
		"the hook drops Firstmate operational injections from the excerpt"
	assert_no_grep "operational response must not become history" "$fixture/state/hook-history-log.txt" \
		"an operational run cannot replace the captain conversation history"
	assert_no_grep "operational response must not become history" "$fixture/state/hook-settle-log.txt" \
		"an operational run cannot replace the session anchors"
	assert_grep "assistant reply about the exporter" "$fixture/state/hook-settle-log.txt" \
		"the next eligible captain run still refreshes the session brief"
	assert_present "$fixture/state/.pi-captain-router-extension-loaded" \
		"the router extension writes its versioned loaded marker"
	assert_grep "sha256:" "$fixture/state/.pi-captain-router-extension-loaded" \
		"the router loaded marker carries the extension version"
	pass "router: the Pi hook keeps bounded history within its context session"
}

test_inert_in_child_worktree() {
	local base="$TMP_ROOT/child-base" root="$TMP_ROOT/child-worktree" out status=0
	fm_git_worktree "$base" "$root" fm/captain-router-child
	mkdir -p "$root/bin" "$root/state"
	: >"$root/AGENTS.md"
	out=$(printf 'anything' | run "$root" --on-submit 2>&1) || status=$?
	expect_code 0 "$status" "child worktree exit"
	[ -z "$out" ] || fail "unmarked child worktree must be silent, got: $out"
	assert_absent "$root/state/captain-router" "child worktree must not create router state"
	pass "router: inert in a child crew/scout worktree"
}

test_marked_secondmate_home_is_active() {
	local base="$TMP_ROOT/sm-base" root="$TMP_ROOT/sm-home" out status=0 fakebin
	fm_git_worktree "$base" "$root" fm/captain-router-sm
	mkdir -p "$root/bin" "$root/state"
	: >"$root/AGENTS.md"
	printf 'captain-router-sm\n' >"$root/.fm-secondmate-home"
	printf 'Do you want me to proceed now?' | run "$root" --on-settle >/dev/null
	fakebin=$(cursor_fixture "$root" secondmate 'verdict=same
target=-
explanation=x')
	out=$(printf 'yes proceed now' |
		run_with_probe "$root" "$fakebin" --on-submit) || status=$?
	expect_code 0 "$status" "secondmate home exit"
	assert_contains "$out" "verdict=same" "a marked secondmate home is an active primary"
	pass "router: a marked secondmate home is treated as a primary"
}

test_gate_agent_is_inert() {
	local root="$TMP_ROOT/gate-env" out status=0
	make_primary "$root"
	out=$(printf 'anything' | env NO_MISTAKES_GATE=1 FM_GATE_REFUSE_BYPASS=0 \
		FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$ROUTER" --on-submit 2>&1) || status=$?
	expect_code 0 "$status" "gate agent exit"
	[ -z "$out" ] || fail "a no-mistakes gate agent must be silent, got: $out"
	assert_absent "$root/state/captain-router" "gate agent must not create router state"
	pass "router: a no-mistakes gate agent is inert"
}

test_bad_usage_exits_two() {
	local root="$TMP_ROOT/bad-usage" status=0
	make_primary "$root"
	printf '' | run "$root" --bogus >/dev/null 2>&1 || status=$?
	expect_code 2 "$status" "invalid mode is a usage error"
	status=0
	printf '' | FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$root" FM_HOME="$root" \
		"$ROUTER" >/dev/null 2>&1 || status=$?
	expect_code 2 "$status" "missing mode is a usage error"
	pass "router: invalid CLI usage exits 2 (only non-fail-open path)"
}

test_help_prints_usage() {
	local out status=0
	out=$("$ROUTER" --help 2>&1) || status=$?
	expect_code 0 "$status" "help exit"
	assert_contains "$out" "Captain-message continuity router" "help prints the header"
	assert_contains "$out" "NOT watcher continuity" "help disambiguates from watcher continuity"
	assert_contains "$out" "reroute" "help mentions reroute verdicts"
	pass "router: --help prints the script header"
}

test_settle_extracts_multiple_anchors
test_settle_writes_session_brief
test_settle_multi_ask_verification_surfaces
test_settle_single_ask_is_silent
test_submit_always_spawns_the_model
test_submit_model_sees_briefs_history_and_message
test_chat_history_is_bounded_and_redacted
test_explanation_recorded_but_never_forwarded
test_submit_model_spawn_failure_fail_open
test_submit_model_timeout_fail_open
test_submit_garbage_verdict_fail_open
test_submit_reroute_target_is_validated
test_submit_new_and_same_targets_are_normalized
test_model_override_keeps_cursor_cli_read_only
test_builtin_default_uses_cursor_cli_read_only
test_submit_prompt_rides_the_file_not_argv
test_submit_dependency_free_timeout_terminates_hung_spawn
test_submit_large_timeout_override_reaches_shared_owner
test_pending_route_publication_failure_falls_back_to_same
test_pi_hook_uses_context_session_ids_without_outer_timeout
test_pi_hook_classifies_queued_input_and_rejects_mixed_runs
test_verdict_is_logged
test_pi_hook_threads_bounded_redacted_history
test_inert_in_child_worktree
test_marked_secondmate_home_is_active
test_gate_agent_is_inert
test_bad_usage_exits_two
test_help_prints_usage
