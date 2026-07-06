#!/usr/bin/env bash
# Behavior tests for the cursor (Cursor CLI, cursor-agent) harness adapter.
#
# These drive fm-spawn through meta writing and launch construction with a fake
# tmux pane and a real isolated git worktree, capturing the literal launch
# command sent with `tmux send-keys -l`, then assert the launch line, the folded
# model/effort slug, the per-worktree .cursor/hooks.json turn-end hook, and
# fm-harness.sh detection. The turn-end mechanism itself was verified live
# (cursor-agent 2026.07.01); these pin the wiring firstmate generates.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-cursor-harness)

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin launchlog id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="cursor-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog|$id"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG ID <<EOF
$1
EOF
}

run_cursor_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 launchlog=$5 id=$6
  shift 6
  : > "$launchlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" "$@" 2>&1
}

test_cursor_launch_template_folds_model_and_effort() {
  local rec out status launch
  rec=$(make_spawn_case launch-fold)
  read_case_record "$rec"

  out=$(run_cursor_spawn "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$ID" \
    cursor --model claude-opus-4-8 --effort high)
  status=$?
  expect_code 0 "$status" "cursor spawn with model and effort should succeed"
  assert_contains "$out" "spawned $ID harness=cursor" "spawn did not report cursor harness"
  assert_grep "harness=cursor" "$HOME_DIR/state/$ID.meta" "meta missing harness=cursor"
  assert_grep "model=claude-opus-4-8" "$HOME_DIR/state/$ID.meta" "meta missing model"
  assert_grep "effort=high" "$HOME_DIR/state/$ID.meta" "meta missing effort"

  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "cursor-agent --force --model 'claude-opus-4-8-high' \"\$(cat " \
    "cursor launch did not fold effort into the --model slug"
  assert_not_contains "$launch" "--effort" "cursor launch must not emit a standalone --effort flag"
  assert_not_contains "$launch" "[effort=" "cursor launch must not use the rejected bracket effort syntax"
  pass "cursor launch folds effort into the --model slug as a suffix"
}

test_cursor_base_slug_without_effort() {
  local rec out status launch
  rec=$(make_spawn_case launch-base)
  read_case_record "$rec"

  out=$(run_cursor_spawn "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$ID" \
    cursor --model composer-2.5)
  status=$?
  expect_code 0 "$status" "cursor spawn with a base slug and no effort should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "cursor-agent --force --model 'composer-2.5' \"\$(cat " \
    "cursor launch did not pass the bare base slug when no effort was requested"
  assert_not_contains "$launch" "composer-2.5-" "cursor launch must not append an effort suffix without an effort"
  pass "cursor passes the bare base slug when no effort is requested"
}

test_cursor_no_model_omits_flag() {
  local rec out status launch
  rec=$(make_spawn_case launch-nomodel)
  read_case_record "$rec"

  out=$(run_cursor_spawn "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$ID" cursor)
  status=$?
  expect_code 0 "$status" "cursor spawn without a model should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "cursor-agent --force \"\$(cat " \
    "cursor launch without a model should omit --model entirely"
  assert_not_contains "$launch" "--model" "cursor launch must omit --model when none is requested"
  pass "cursor omits --model when no model is requested (uses cursor's own default)"
}

test_cursor_installs_project_stop_hook() {
  local rec out status hooks
  rec=$(make_spawn_case hook-install)
  read_case_record "$rec"

  out=$(run_cursor_spawn "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$ID" cursor)
  status=$?
  expect_code 0 "$status" "cursor spawn should succeed"

  hooks="$WT_DIR/.cursor/hooks.json"
  assert_present "$hooks" "cursor per-worktree hooks.json was not installed"
  # A "stop" command that touches this task's turn-end file.
  assert_grep '"stop"' "$hooks" "cursor hooks.json is missing the stop event"
  # State path is pwd -P resolved (macOS symlinks), so match the task-specific
  # turn-end basename rather than the full home-relative path.
  assert_grep "$ID.turn-ended" "$hooks" "cursor stop hook does not touch the task turn-end file"
  # jq must parse it (valid JSON) and the stop command must be the touch.
  if command -v jq >/dev/null 2>&1; then
    jq -e '.hooks.stop[0].command | test("^touch ")' "$hooks" >/dev/null \
      || fail "cursor stop hook command is not a touch of the turn-end file"
  fi
  # Kept out of git's view via info/exclude, so it never dirties the worktree.
  # A linked worktree's .git is a pointer file, so resolve the exclude path via git.
  local excl
  excl=$(git -C "$WT_DIR" rev-parse --git-path info/exclude)
  assert_grep '.cursor/hooks.json' "$excl" "cursor hooks.json was not git-excluded"
  git -C "$WT_DIR" status --porcelain > "$CASE_DIR/status.txt"
  assert_no_grep '.cursor/hooks.json' "$CASE_DIR/status.txt" "excluded cursor hooks.json still shows as dirty"
  pass "cursor installs a git-excluded per-worktree stop turn-end hook"
}

test_cursor_merges_existing_project_hooks() {
  local rec out status hooks
  rec=$(make_spawn_case hook-merge)
  read_case_record "$rec"
  command -v jq >/dev/null 2>&1 || { pass "cursor hook merge skipped (jq unavailable)"; return; }

  # A project that already ships its own .cursor/hooks.json with an unrelated hook.
  mkdir -p "$WT_DIR/.cursor"
  printf '{"version":1,"hooks":{"afterFileEdit":[{"command":"./format.sh"}]}}\n' \
    > "$WT_DIR/.cursor/hooks.json"

  out=$(run_cursor_spawn "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$ID" cursor)
  status=$?
  expect_code 0 "$status" "cursor spawn should succeed against an existing hooks.json"

  hooks="$WT_DIR/.cursor/hooks.json"
  jq -e '.hooks.afterFileEdit[0].command == "./format.sh"' "$hooks" >/dev/null \
    || fail "cursor merge clobbered the project's existing hook"
  jq -e '.hooks.stop[0].command | test("turn-ended")' "$hooks" >/dev/null \
    || fail "cursor merge did not add the firstmate stop turn-end hook"
  pass "cursor merges its stop hook into an existing project hooks.json instead of clobbering it"
}

test_cursor_teardown_is_clean() {
  local rec out status
  rec=$(make_spawn_case teardown)
  read_case_record "$rec"

  out=$(run_cursor_spawn "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$ID" cursor)
  status=$?
  expect_code 0 "$status" "cursor spawn should succeed before teardown"
  assert_present "$WT_DIR/.cursor/hooks.json" "cursor hook missing before teardown"

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    PATH="$FAKEBIN_DIR:$PATH" "$TEARDOWN" "$ID" --force >/dev/null 2>&1 \
    || fail "cursor teardown failed"
  assert_absent "$HOME_DIR/state/$ID.meta" "cursor meta survived teardown"
  pass "cursor worktree tears down cleanly (the excluded hook never blocks the dirty check)"
}

test_fm_harness_detects_cursor_env_marker() {
  local out
  # env -u clears the runner's own harness markers (this suite may run under any
  # harness) so only the CURSOR_AGENT marker under test decides the result.
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT CURSOR_AGENT=1 "$HARNESS")
  [ "$out" = cursor ] || fail "fm-harness.sh did not detect cursor from CURSOR_AGENT=1 (got '$out')"
  pass "fm-harness.sh detects cursor from the CURSOR_AGENT env marker"
}

test_fm_harness_detects_cursor_ancestry() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/ancestry-fake")
  # A node interpreter whose args carry the cursor-agent bundle path.
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/opt/node/bin/node'; exit 0 ;;
  *"args="*) printf '%s\n' 'node /Users/x/.local/share/cursor-agent/versions/2026.07.01/index.js worker-server'; exit 0 ;;
  *"ppid="*) printf '%s\n' '1'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u CURSOR_AGENT \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = cursor ] || fail "fm-harness.sh did not detect cursor from cursor-agent ancestry (got '$out')"
  pass "fm-harness.sh detects cursor from the cursor-agent process ancestry"
}

test_cursor_launch_template_folds_model_and_effort
test_cursor_base_slug_without_effort
test_cursor_no_model_omits_flag
test_cursor_installs_project_stop_hook
test_cursor_merges_existing_project_hooks
test_cursor_teardown_is_clean
test_fm_harness_detects_cursor_env_marker
test_fm_harness_detects_cursor_ancestry

echo "# all fm-cursor-harness tests passed"
