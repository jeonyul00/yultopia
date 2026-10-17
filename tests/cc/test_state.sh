test_init_creates_active_in_git_dir() {
  repo=$(make_repo "my repo 한글"); cd "$repo"
  printf '목표: 테스트\n' | run_cc init; assert_code 0
  gd=$(git rev-parse --absolute-git-dir)
  assert_file_exists "$gd/yultopia-cc/active/brief.md"
  assert_eq "$(cat "$gd/yultopia-cc/active/brief.md")" "목표: 테스트"
  assert_eq "$(jq -r .phase "$gd/yultopia-cc/active/state.json")" "planning"
  assert_eq "$(jq -r .running "$gd/yultopia-cc/active/state.json")" "null"
  assert_eq "$(git status --porcelain)" ""
}
test_init_refuses_when_active_exists() {
  repo=$(make_repo); cd "$repo"
  printf '첫번째\n' | run_cc init; assert_code 0
  printf '두번째\n' | run_cc init; assert_code 4
  assert_eq "$(cat "$(cc_path brief)")" "첫번째"
}
test_init_outside_git_fails() {
  mkdir -p "$TMP/plain"; cd "$TMP/plain"
  printf 'x\n' | run_cc init; assert_code 1
}
test_git_dir_in_worktree() {
  repo=$(make_repo); cd "$repo"
  git worktree add -q "$TMP/wt" -b wtbranch >/dev/null 2>&1
  cd "$TMP/wt"
  printf '워크트리\n' | run_cc init; assert_code 0
  gd=$(git rev-parse --absolute-git-dir)
  case "$gd" in */.git/worktrees/*) ;; *) _fail "worktree git dir 아님: $gd";; esac
  assert_file_exists "$gd/yultopia-cc/active/brief.md"
  assert_no_path "$(git rev-parse --git-common-dir)/yultopia-cc"
}
test_path_prints_absolute_paths() {
  repo=$(make_repo "my repo 한글"); cd "$repo"
  printf 'x\n' | run_cc init
  gd=$(git rev-parse --absolute-git-dir)
  run_cc path brief; assert_code 0; assert_eq "$OUT" "$gd/yultopia-cc/active/brief.md"
  run_cc path active; assert_eq "$OUT" "$gd/yultopia-cc/active"
  run_cc path report; assert_eq "$OUT" "$gd/yultopia-cc/active/report.md"
  run_cc path message; assert_eq "$OUT" "$gd/yultopia-cc/active/message.md"
  run_cc path verify; assert_eq "$OUT" "$gd/yultopia-cc/active/verify"
  run_cc path bogus; assert_code 1
}
test_delete_refuses_symlinked_active() {
  start_task
  gd=$(git rev-parse --absolute-git-dir)
  mv "$gd/yultopia-cc/active" "$TMP/elsewhere"
  ln -s "$TMP/elsewhere" "$gd/yultopia-cc/active"
  run_cc finish; assert_code 1
  [ -L "$gd/yultopia-cc/active" ] || _fail "심볼릭 링크가 사라짐"
  assert_file_exists "$TMP/elsewhere/brief.md"
}
test_delete_refuses_symlinked_parent() {
  start_task
  gd=$(git rev-parse --absolute-git-dir)
  mv "$gd/yultopia-cc" "$TMP/elsewhere"
  ln -s "$TMP/elsewhere" "$gd/yultopia-cc"
  run_cc finish; assert_code 1
  assert_file_exists "$TMP/elsewhere/active/brief.md"
}
test_finish_deletes_only_active() {
  start_task
  gd=$(git rev-parse --absolute-git-dir)
  echo keep > "$gd/yultopia-cc/other.txt"; echo keep > "$gd/outside.txt"
  run_cc finish; assert_code 0
  assert_no_path "$gd/yultopia-cc/active"
  assert_file_exists "$gd/yultopia-cc/other.txt"
  assert_file_exists "$gd/outside.txt"
}
test_state_update_is_atomic_and_touches_activity() {
  start_task
  set_state '.last_activity_at="2020-01-01T00:00:00Z"'
  cc_state_update '.milestone=1'
  assert_eq "$(state .milestone)" "1"
  age=$(cc_age_secs "$(state .last_activity_at)")
  [ "$age" -lt 5 ] || _fail "last_activity_at 갱신 안 됨 (age=$age)"
  cc_state_update '.phase=$p' --arg p working
  assert_eq "$(state .phase)" "working"
  assert_eq "$(ls -A "$ACTIVE" | grep -c '^\.state\.')" "0"
}
test_status_without_active() {
  repo=$(make_repo); cd "$repo"
  run_cc status; assert_code 5
}
test_status_with_active() {
  start_task
  run_cc status; assert_code 0; assert_contains "$OUT" "planning"
}
test_unknown_subcommand() {
  run_cc bogus; assert_code 1
}

test_init_concurrent_exactly_one_wins() {
  repo=$(make_repo); cd "$repo"
  for round in 1 2 3 4 5; do
    run_cc finish
    ( printf 'A\n' | CC_BIN="$CC_BIN" bash "$CC_BIN" init >/dev/null 2>&1; echo $? > "$TMP/c1" ) &
    ( printf 'B\n' | CC_BIN="$CC_BIN" bash "$CC_BIN" init >/dev/null 2>&1; echo $? > "$TMP/c2" ) &
    wait
    codes=$(sort "$TMP/c1" "$TMP/c2" | tr '\n' ' ')
    assert_eq "$codes" "0 4 " "round $round"
    if [ "$(cat "$TMP/c1")" = 0 ]; then w=A; else w=B; fi
    assert_eq "$(cat "$(cc_path brief)")" "$w" "round $round brief"
  done
}
test_init_failure_cleans_up() {
  repo=$(make_repo); cd "$repo"
  run_cc init < /; assert_code 1
  assert_eq "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "1"
  assert_no_path "$(cc_path active)"
  printf 'ok\n' | run_cc init; assert_code 0
}
test_status_with_corrupt_state() {
  start_task
  echo '{bad' > "$ACTIVE/state.json"
  run_cc status; [ "$CODE" != 0 ] || _fail "status 가 0 으로 끝남"
  assert_eq "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "1"
  assert_not_contains "$OUT" "단계: ,"
  rm -f "$ACTIVE/state.json"
  run_cc status; [ "$CODE" != 0 ] || _fail "status 가 0 으로 끝남(파일 없음)"
}
test_assert_code_survives_cc_path() {
  start_task
  printf 'again\n' | run_cc init
  p=$(cc_path report)
  assert_code 4
  assert_contains "$p" "report.md"
}
test_assert_code_of_run_cc() {
  start_task
  assert_code_of 0 run_cc status
  assert_code_of 4 run_cc init </dev/null
}
test_state_update_rejects_bad_jq_output() {
  start_task
  before=$(cat "$ACTIVE/state.json")
  cc_state_update 'empty' && _fail "empty 출력인데 성공"
  cc_state_update '.a,.b' && _fail "다중 출력인데 성공"
  cc_state_update '1' && _fail "객체가 아닌데 성공"
  assert_eq "$(cat "$ACTIVE/state.json")" "$before"
}
test_defaults_come_from_common() {
  assert_eq "$CC_MAX_CALLS" "20"
  assert_eq "$CC_MAX_REJECTS" "3"
  assert_eq "$CC_STALE_DAYS" "14"
}

# ---- state.json 잠금 (Ruling R11) ----
test_state_update_concurrent_writers_lose_nothing() {
  start_task
  for i in $(seq 1 20); do
    ( cc_state_update ".f$i = $i" || : > "$TMP/.update_failed.$i" ) &
  done
  wait
  for i in $(seq 1 20); do
    assert_eq "$(state ".f$i")" "$i" "f$i"
    assert_no_path "$TMP/.update_failed.$i"
  done
  assert_no_path "$ACTIVE/state.lock"
  assert_eq "$(ls -A "$ACTIVE" | grep -c '^\.state\.')" "0"
}
test_state_update_breaks_lock_of_dead_owner() {
  start_task
  bash -c 'exit 0' & dead=$!; wait "$dead"
  mkdir "$ACTIVE/state.lock"; echo "$dead" > "$ACTIVE/state.lock/owner"
  cc_state_update '.milestone=7' || _fail "죽은 소유자의 잠금을 넘지 못함"
  assert_eq "$(state .milestone)" "7"
  assert_no_path "$ACTIVE/state.lock"
}
test_state_update_keeps_lock_of_live_owner() {
  start_task
  perl -e 'sleep 30' "lock-owner-$TMP" & live=$!
  mkdir "$ACTIVE/state.lock"; echo "$live" > "$ACTIVE/state.lock/owner"
  before=$(cat "$ACTIVE/state.json")
  CC_STATE_LOCK_WAIT_SECS=1 cc_state_update '.milestone=7' 2>/dev/null && _fail "살아 있는 소유자의 잠금을 무시함"
  assert_eq "$(cat "$ACTIVE/state.json")" "$before"
  assert_eq "$(cat "$ACTIVE/state.lock/owner")" "$live"
  kill "$live" 2>/dev/null
}
test_state_update_releases_lock_after_failure() {
  start_task
  cc_state_update 'error("x")' && _fail "실패해야 하는 갱신이 성공"
  assert_no_path "$ACTIVE/state.lock"
  CC_STATE_LOCK_WAIT_SECS=1 cc_state_update '.milestone=3' || _fail "실패 뒤 잠금이 남음"
  assert_eq "$(state .milestone)" "3"
  assert_no_path "$ACTIVE/state.lock"
}
test_state_lock_reclaims_lock_left_by_same_process() {
  # 신호 때문에 잠금을 잡은 기록(깊이)만 잃은 경우: owner 가 자기 PID 면 자기 잠금으로 다시 쓴다
  start_task
  (
    me=$(exec perl -e 'print getppid()')
    mkdir "$ACTIVE/state.lock" && echo "$me" > "$ACTIVE/state.lock/owner"
    CC_STATE_LOCK_WAIT_SECS=1 cc_state_update '.milestone=5'
  ) || _fail "자기 PID 로 남은 잠금을 다시 잡지 못함"
  assert_eq "$(state .milestone)" "5"
  assert_no_path "$ACTIVE/state.lock"
}
