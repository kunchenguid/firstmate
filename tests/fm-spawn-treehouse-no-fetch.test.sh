#!/usr/bin/env bash
# Regression test for fm-spawn treehouse entry without a fetch.
#
# Fantasy-strategy proves `treehouse get` can spend longer than the 60s entry
# window fetching origin before it ever enters a worktree, so the pane never
# leaves the spawning project and the spawn refuses with an isolation timeout.
# The spawn must enter the isolated copy with `treehouse get --no-fetch`
# instead, because freshen_spawn_worktree_base already owns base freshness
# after entry.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-treehouse-no-fetch)

make_no_fetch_fakebin() {
  local dir=$1 fakebin sendlog
  fakebin=$(fm_fakebin "$dir")
  sendlog="$dir/send-keys.log"
  touch "$sendlog"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *"#{pane_current_path}"*)
    printf '%s\n' "\${FM_FAKE_PANE_PATH:-}"
    exit 0
    ;;
esac
case "\${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
  send-keys)
    printf '%s\n' "\$*" >> "$sendlog"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin|$sendlog"
}

make_no_fetch_case() {
  local name=$1 id=$2 case_dir home proj wt fake_out fakebin sendlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fake_out=$(make_no_fetch_fakebin "$case_dir/fake")
  fakebin=${fake_out%%|*}
  sendlog=${fake_out#*|}
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id" "Exercise no-fetch treehouse entry for $id."
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$sendlog"
}

test_treehouse_entry_skips_fetch() {
  local rec id out status
  id=no-fetch-entry-r1
  rec=$(make_no_fetch_case no-fetch "$id")
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR SENDLOG <<EOF
$rec
EOF
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the isolated worktree"
  assert_grep "treehouse get --no-fetch" "$SENDLOG" \
    "spawn did not enter the isolated copy without fetching"
  pass "treehouse entry skips the fetch so a slow origin cannot exhaust the entry timeout"
}

test_treehouse_entry_skips_fetch

echo "# all fm-spawn-treehouse-no-fetch tests passed"
