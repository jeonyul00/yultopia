# test_codex_edit_watch.sh - R31/R32: Codex 는 쓰기 sandbox(workspace-write)로 테스트를 직접 돌린다.
#   감독 프로세스는 codex 를 실행할 때마다(첫 실행·빠른 실패 재실행·형식 재요청) 실행 전후 작업 트리를 비교해,
#   git 이 무시하지 않는 파일이 바뀌었으면 호출을 codex_modified 로 끝낸다 (되돌리지 않음, 결과 반영 없음, 재시도 없음).
. "$CC_REPO_ROOT/plugins/yultopia/lib/cc/proc.sh"

# ---- 이 파일 전용 도우미 (test_ 로 시작하지 않게) ----
ew_until() {
  local secs="$1" i=0; shift
  until "$@"; do
    [ "$i" -ge $((secs * 10)) ] && return 1
    sleep 0.1; i=$((i+1))
  done
}
ew_invocations() { ls "$FAKE_CODEX_LOG" 2>/dev/null | grep -c '\.argv$'; }
ew_lines() { printf '%s\n' "$1" | wc -l | tr -d ' '; }
ew_codex_recorded() { [ -n "$(state '.running.codex_pid // empty')" ]; }
ew_group_alive() { kill -0 -- "-$1" 2>/dev/null; }
ew_base_edited() { grep -q 'codex edit' base.txt 2>/dev/null; }
ew_tree_now() { GIT_INDEX_FILE="$TMP/expect.index" sh -c 'git read-tree HEAD && git add -A && git write-tree'; }
# ew_fake_git <조건 셸 식> : write-tree 를 조건이 참일 때만 실패시키는 가짜 git 을 $TMP/bin 에 둔다
ew_fake_git() {
  local real
  real=$(command -v git)
  mkdir -p "$TMP/bin"
  printf '#!/bin/sh\nif [ "$1" = write-tree ] && %s; then exit 1; fi\nexec "%s" "$@"\n' "$1" "$real" > "$TMP/bin/git"
  chmod +x "$TMP/bin/git"
}
# ew_assert_modified <call_id> <파일…> : codex_modified 로 끝난 호출의 공통 상태와 메시지
ew_assert_modified() {
  local id="$1" f msg pre post names
  shift
  assert_eq "$(cat "$ACTIVE/calls/$id/status" 2>/dev/null)" "codex_modified" "status 파일"
  assert_eq "$(state .last_call.status)" "codex_modified"
  assert_eq "$(state .last_call.call_id)" "$id"
  assert_eq "$(state .last_call.verdict)" "null"
  assert_eq "$(state .phase)" "failed"
  assert_eq "$(state .running)" "null"
  msg=$(state .last_call.message)
  assert_eq "$(ew_lines "$msg")" "1"
  assert_contains "$msg" "[cc] Codex가 프로젝트 파일을 바꿨습니다(되돌리지 않음)"
  assert_contains "$msg" "Codex 실행 중에 바뀐 파일"
  pre=$(state '.last_call.pre_tree // empty'); post=$(state '.last_call.post_tree // empty')
  { [ -n "$pre" ] && [ -n "$post" ] && [ "$pre" != "$post" ]; } || _fail "pre/post tree 기록이 없음: [$pre] [$post]"
  assert_contains "$msg" "git diff $pre $post"
  names=$(git -c core.quotePath=false diff --no-renames --name-only "$pre" "$post" 2>/dev/null)
  for f in "$@"; do
    assert_contains "$msg" "$f"
    printf '%s\n' "$names" | grep -qxF -- "$f" || _fail "git diff pre post 에 [$f] 없음: $names"
  done
}
# wait 를 백그라운드로 띄운다 (test_wait.sh 의 wt_start_waiter 와 같은 방법: SIGINT 를 기본값으로 되돌려 실행)
ew_start_waiter() {
  FAKE_CODEX_LOG="${FAKE_CODEX_LOG:-$TMP/fake-codex.log}" \
    perl -e '$SIG{INT} = "DEFAULT"; exec { $ARGV[0] } @ARGV or exit 127' bash "$CC_BIN" wait "$@" \
    > "$TMP/w.out" 2> "$TMP/w.err" &
  WP=$!
}
ew_waiter_registered() { [ "$(state '.waiter.pid // empty')" = "$WP" ]; }

# ---- 바뀐 파일이 있으면 멈춘다 (추적 파일 수정, 새 파일) ----
test_tracked_edit_by_codex_stops_call_without_revert() {
  FAKE_CODEX_SEQ=edit_tracked:ok; start_task
  run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  ew_assert_modified 1 base.txt
  # 되돌리지 않는다
  assert_contains "$(cat base.txt)" "codex edit"
  # 결과(계획)는 반영하지 않고, 재시도·형식 재요청도 하지 않는다
  assert_eq "$(state .milestone)" "null"; assert_eq "$(state .milestones_total)" "null"
  assert_eq "$(ew_invocations)" "1"; assert_eq "$(state .calls_total)" "1"
  # 사용자의 스테이징은 그대로
  assert_eq "$(git diff --cached --name-only)" ""
  # wait 는 그 한 줄을 3 으로 돌려준다
  run_cc wait --max 5; assert_code 3
  assert_eq "$(ew_lines "$OUT")" "1"
  assert_eq "$OUT" "$(state .last_call.message)"
  # 실행 중인 호출이 없으므로 사용자가 정하면 다시 부를 수 있다
  run_cc status; assert_contains "$OUT" "failed"
}
test_new_untracked_file_by_codex_stops_call() {
  FAKE_CODEX_SEQ=new_file:ok; start_task
  run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  ew_assert_modified 1 "새 파일.txt"
  assert_file_exists "새 파일.txt"
  assert_eq "$(state .milestone)" "null"
  assert_eq "$(ew_invocations)" "1"
}
test_ignored_only_writes_are_allowed() {
  start_task
  printf 'codex-cache/\n' > .gitignore; git add .gitignore; git commit -qm ignore-cache
  FAKE_CODEX_SEQ=ignored_only:ok
  run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  assert_eq "$(cat "$CALL1/status")" "ok"
  assert_eq "$(state .last_call.status)" "ok"; assert_eq "$(state .last_call.verdict)" "plan"
  assert_eq "$(state .milestone)" "1"; assert_eq "$(state .phase)" "working"
  assert_eq "$(state '.last_call | has("pre_tree")')" "false"
  assert_file_exists codex-cache/out.log
  run_cc wait --max 5; assert_code 0
  assert_eq "$(printf '%s' "$OUT" | jq -r .verdict)" "plan"
}
test_many_changed_files_are_listed_up_to_ten() {
  FAKE_CODEX_SEQ=many_files:ok; start_task
  run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  ew_assert_modified 1 many/f01.txt many/f05.txt many/f10.txt
  msg=$(state .last_call.message)
  assert_not_contains "$msg" "many/f11.txt"; assert_not_contains "$msg" "many/f12.txt"
  assert_contains "$msg" "(외 2개)"
}

# ---- 모든 codex 실행마다 감시한다 (첫 실행, 빠른 실패 재실행, 형식 재요청) ----
test_edit_with_fast_failure_is_not_rerun() {
  FAKE_CODEX_SEQ=edit_tracked:fail_fast,ok; start_task
  run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  ew_assert_modified 1 base.txt
  assert_eq "$(ew_invocations)" "1"; assert_eq "$(state .calls_total)" "1"
}
test_edit_with_invalid_answer_gets_no_format_retry() {
  FAKE_CODEX_SEQ=edit_tracked:invalid_json,ok; start_task
  run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  ew_assert_modified 1 base.txt
  assert_eq "$(ew_invocations)" "1"; assert_eq "$(state .calls_total)" "1"
}
test_edit_during_fast_fail_rerun_is_caught() {
  FAKE_CODEX_SEQ=fail_fast,edit_tracked:ok; start_task
  run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  ew_assert_modified 1 base.txt
  assert_eq "$(ew_invocations)" "2"; assert_eq "$(state .calls_total)" "2"
  assert_eq "$(state .milestone)" "null"
}
test_edit_during_format_retry_is_caught() {
  FAKE_CODEX_SEQ=invalid_json,new_file:ok; start_task
  run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  ew_assert_modified 1 "새 파일.txt"
  assert_eq "$(ew_invocations)" "2"; assert_eq "$(state .calls_total)" "2"
  assert_eq "$(sed -n 2p "$FAKE_CODEX_LOG/2.argv")" "resume"
  assert_eq "$(state .milestone)" "null"
}
test_review_lists_only_files_changed_while_codex_ran() {
  FAKE_CODEX_SEQ=ok,edit_tracked:ok; start_task
  run_cc call plan; wait_until_status_file 1 || _fail "계획 호출이 끝나지 않음"
  mkdir -p src; echo a > src/a.txt              # Claude 의 작업 (Codex 실행 전의 변경)
  want_pre=$(ew_tree_now)
  printf '%s' "$REVIEW_REPORT" > "$(cc_path report)"
  set_state '.rejects_in_row = 1'
  FAKE_CODEX_RESULT='{"verdict":"approve","summary":"s","plan":null,"milestone":2,"instruction":"다음","findings":[],"question":null}'
  run_cc call review; assert_code 0
  wait_until_status_file 2 || _fail "calls/2/status 가 생기지 않음"
  ew_assert_modified 2 base.txt
  assert_not_contains "$(state .last_call.message)" "src/a.txt"
  assert_eq "$(state .last_call.pre_tree)" "$want_pre"
  assert_eq "$(state .last_call.kind)" "review"
  # 검수 결과(approve)는 반영하지 않는다
  assert_eq "$(state .milestone)" "1"; assert_eq "$(state .rejects_in_row)" "1"
  assert_eq "$(state .milestone_base_tree)" "$(state .task_base_tree)"
  assert_eq "$(cat src/a.txt)" "a"
}

# ---- 시간 상한·중단으로 끊긴 실행도 끝난 뒤에 비교한다 ----
test_timeout_with_edit_reports_codex_modified() {
  FAKE_CODEX_SEQ=edit_tracked:hang,ok; CC_CALL_TIMEOUT_SECS=2; start_task
  run_cc call plan; assert_code 0
  wait_until_status_file 1 15 || _fail "calls/1/status 가 생기지 않음"
  ew_assert_modified 1 base.txt
  assert_eq "$(ew_invocations)" "1"
  assert_no_process_matching "fake-codex-hang:$FAKE_CODEX_LOG"
}
test_interrupted_wait_reports_codex_edit() {
  FAKE_CODEX_SEQ=edit_tracked:hang; start_task
  run_cc call plan; assert_code 0
  ew_until 5 ew_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  ew_until 5 ew_base_edited || _fail "가짜 codex 가 파일을 고치지 않음 (테스트 전제 깨짐)"
  pg=$(state .running.pgid)
  ew_start_waiter --max 60
  ew_until 5 ew_waiter_registered || _fail "waiter 가 등록되지 않음"
  kill -TERM "$WP"; wait "$WP"; rc=$?
  assert_eq "$rc" "130"
  out=$(cat "$TMP/w.out")
  assert_eq "$(ew_lines "$out")" "1"
  assert_contains "$out" "[cc] 중단됨"
  assert_contains "$out" "Codex가 프로젝트 파일을 바꿨습니다"
  assert_contains "$out" "base.txt"
  assert_not_contains "$out" "이미 끝나 있었습니다"
  assert_eq "$(cat "$TMP/w.err")" "" "중단 경로의 stderr"
  ew_assert_modified 1 base.txt
  assert_no_process_matching "fake-codex-hang:$FAKE_CODEX_LOG"
  ew_group_alive "$pg" && _fail "감독 프로세스 그룹이 남아 있음"
  assert_contains "$(cat base.txt)" "codex edit"
}
test_check_orphan_kill_reports_codex_edit() {
  FAKE_CODEX_SEQ=edit_tracked:hang; start_task
  run_cc call plan; assert_code 0
  ew_until 5 ew_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  ew_until 5 ew_base_edited || _fail "가짜 codex 가 파일을 고치지 않음 (테스트 전제 깨짐)"
  pg=$(state .running.pgid)
  run_cc check-orphan --kill; assert_code 10
  assert_eq "$(ew_lines "$OUT")" "1"
  assert_contains "$OUT" "Codex가 프로젝트 파일을 바꿨습니다"
  assert_not_contains "$OUT" "이미 끝나 있었습니다"
  ew_assert_modified 1 base.txt
  assert_no_process_matching "fake-codex-hang:$FAKE_CODEX_LOG"
  ew_group_alive "$pg" && _fail "감독 프로세스 그룹이 남아 있음"
  assert_contains "$(cat base.txt)" "codex edit"
}

# ---- 스냅샷을 뜰 수 없으면 확인할 수 없다: 실행하지 않거나, 결과를 반영하지 않는다 ----
test_pre_snapshot_failure_does_not_start_codex() {
  start_task
  ew_fake_git true
  PATH="$TMP/bin:$PATH" run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  assert_eq "$(cat "$CALL1/status")" "error"
  assert_eq "$(state .last_call.status)" "error"; assert_eq "$(state .last_call.verdict)" "null"
  assert_eq "$(state .phase)" "failed"; assert_eq "$(state .running)" "null"
  msg=$(state .last_call.message)
  assert_eq "$(ew_lines "$msg")" "1"
  assert_contains "$msg" "스냅샷"
  assert_contains "$msg" "실행하지 않았습니다"
  assert_eq "$(ew_invocations)" "0"
  assert_eq "$(state .milestone)" "null"
}
test_post_snapshot_failure_does_not_apply_result() {
  start_task
  ew_fake_git "[ -e \"$FAKE_CODEX_LOG/snapfail\" ]"
  FAKE_CODEX_SEQ=snapfail:ok
  PATH="$TMP/bin:$PATH" run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  assert_file_exists "$FAKE_CODEX_LOG/snapfail"
  assert_eq "$(cat "$CALL1/status")" "error"
  assert_eq "$(state .last_call.status)" "error"; assert_eq "$(state .last_call.verdict)" "null"
  assert_eq "$(state .phase)" "failed"; assert_eq "$(state .running)" "null"
  msg=$(state .last_call.message)
  assert_eq "$(ew_lines "$msg")" "1"
  assert_contains "$msg" "작업 트리를 확인하지 못해"
  assert_contains "$msg" "프로젝트 파일"
  pre=$(state '.last_call.pre_tree // empty')
  [ -n "$pre" ] || _fail "실행 전 트리가 기록되지 않음"
  assert_contains "$msg" "git diff $pre"
  assert_eq "$(state '.last_call.post_tree // empty')" ""
  # 결과(계획)를 반영하지 않고 재시도하지 않는다
  assert_eq "$(state .milestone)" "null"
  assert_eq "$(ew_invocations)" "1"; assert_eq "$(state .calls_total)" "1"
  PATH="$TMP/bin:$PATH" run_cc wait --max 5; assert_code 3
  assert_eq "$OUT" "$msg"
}

# ---- 실제 Codex smoke test 의 기대값 (실행하지 않고 내용만 확인) ----
test_smoke_script_expects_workspace_write_and_no_project_change() {
  f="$CC_REPO_ROOT/tests/cc/smoke-real-codex.sh"
  bash -n "$f" || _fail "smoke 스크립트 문법 오류"
  s=$(cat "$f")
  assert_contains "$s" 'exec --json -s workspace-write --output-schema '
  assert_contains "$s" 'exec resume --json -c sandbox_mode=\"workspace-write\" --output-schema '
  assert_not_contains "$s" "read-only"
  assert_not_contains "$s" "touch cc-smoke-write-test"
  assert_contains "$s" "codex_modified"
  assert_contains "$s" "step2.no-project-change"
}

# ==== Codex 리뷰 1차 (R32) ====
ew_pid_gone() { ! kill -0 "$1" 2>/dev/null; }
ew_fake_ps_fail_list() {   # 전체 목록(-A)만 실패하는 가짜 ps: 감독 프로세스가 자기 그룹을 정리했는지 확인하지 못한다
  mkdir -p "$TMP/bin"
  printf '#!/bin/sh\ncase " $* " in *" -A "*) exit 1 ;; esac\nexec /bin/ps "$@"\n' > "$TMP/bin/ps"
  chmod +x "$TMP/bin/ps"
}
# ew_fake_git_slow : 표시($FAKE_CODEX_LOG/slowsnap)가 있으면 write-tree 를 15초 끈다 (감독 프로세스의 실행 뒤 스냅샷이
#   중단 처리의 유예 10초를 넘기게 한다). 실패시키지는 않는다
ew_fake_git_slow() {
  local real
  real=$(command -v git)
  mkdir -p "$TMP/bin"
  printf '#!/bin/sh\nif [ "$1" = write-tree ] && [ -e "%s/slowsnap" ]; then sleep 15; fi\nexec "%s" "$@"\n' "$FAKE_CODEX_LOG" "$real" > "$TMP/bin/git"
  chmod +x "$TMP/bin/git"
}
ew_assert_uncheck_error() {   # <call_id> : 실행 뒤 스냅샷 실패 → error, failed, verdict null, 확인 실패 문구
  local msg
  assert_eq "$(cat "$ACTIVE/calls/$1/status" 2>/dev/null)" "error" "status 파일"
  assert_eq "$(state .last_call.status)" "error"; assert_eq "$(state .last_call.call_id)" "$1"
  assert_eq "$(state .last_call.verdict)" "null"; assert_eq "$(state .phase)" "failed"
  msg=$(state .last_call.message)
  assert_eq "$(ew_lines "$msg")" "1"
  assert_contains "$msg" "실행 뒤 작업 트리를 확인하지 못해"
  assert_contains "$msg" "git diff $(state '.last_call.pre_tree // "?"')"
}

# ---- 1: 하위 모듈 안의 수정도 잡는다 ----
test_edit_inside_submodule_stops_call() {
  start_task
  src="$TMP/subsrc"; mkdir -p "$src"
  ( cd "$src" && git init -q . && git config user.name t && git config user.email t@example.com \
      && git config commit.gpgsign false && echo s > s.txt && git add s.txt && git commit -q -m s ) >/dev/null 2>&1
  git -c protocol.file.allow=always submodule add -q "$src" sub >/dev/null 2>&1 && git commit -q -m sub \
    || { _fail "하위 모듈을 만들지 못함 (테스트 전제)"; return 1; }
  FAKE_CODEX_SEQ=edit_submodule:ok
  run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  ew_assert_modified 1 sub
  assert_contains "$(cat sub/s.txt)" "codex edit"
  assert_eq "$(state .milestone)" "null"
}

# ---- 2: 그룹이 비었는지 확인하지 못하면 그 순간 같아도 결과를 반영하지 않고, 확실히 끝난 뒤 다시 비교한다 ----
test_unconfirmed_stop_does_not_apply_result_and_rechecks_later() {
  FAKE_CODEX_SEQ=late_edit:ok; FAKE_CODEX_LATE_SECS=4; start_task
  ew_fake_ps_fail_list
  PATH="$TMP/bin:$PATH" run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  late=$(cat "$FAKE_CODEX_LOG/1.late" 2>/dev/null)
  kill -0 "$late" 2>/dev/null || _fail "늦게 쓰는 자식이 벌써 끝남 (테스트 전제 깨짐)"
  assert_eq "$(cat "$CALL1/status")" "error"
  assert_eq "$(state .last_call.status)" "error"; assert_eq "$(state .last_call.verdict)" "null"
  assert_eq "$(state .phase)" "failed"; assert_eq "$(state .milestone)" "null"
  assert_eq "$(state .running.stop_failed)" "true"
  [ -n "$(state '.running.pre_tree // empty')" ] || _fail "running.pre_tree 가 없음"
  msg=$(state .last_call.message)
  assert_eq "$(ew_lines "$msg")" "1"
  assert_contains "$msg" "결과를 반영하지 않았"
  assert_contains "$msg" "다시 확인"
  assert_contains "$msg" "ps -o pid,command -g"
  run_cc wait --max 5; assert_code 3; assert_eq "$OUT" "$msg"
  # 남은 자식이 추적 파일을 쓰고 끝난다
  ew_until 15 ew_pid_gone "$late" || _fail "늦게 쓰는 자식이 끝나지 않음"
  assert_contains "$(cat base.txt)" "late edit"
  # 그룹이 사라진 것을 확인한 다음 wait 가 저장된 pre 로 다시 비교한다
  run_cc wait --max 5; assert_code 3
  assert_eq "$(ew_lines "$OUT")" "1"
  assert_contains "$OUT" "Codex가 프로젝트 파일을 바꿨습니다"
  assert_contains "$OUT" "base.txt"
  ew_assert_modified 1 base.txt
  assert_contains "$(cat base.txt)" "late edit"
}
test_unconfirmed_stop_recheck_by_check_orphan() {
  FAKE_CODEX_SEQ=late_edit:ok; FAKE_CODEX_LATE_SECS=3; start_task
  ew_fake_ps_fail_list
  PATH="$TMP/bin:$PATH" run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  late=$(cat "$FAKE_CODEX_LOG/1.late" 2>/dev/null)
  assert_eq "$(state .last_call.status)" "error"
  ew_until 15 ew_pid_gone "$late" || _fail "늦게 쓰는 자식이 끝나지 않음"
  run_cc check-orphan; assert_code 0
  ew_assert_modified 1 base.txt
}

# ---- 3: 실행 전 트리를 codex 실행 전에 running 에 남기고, 감독 프로세스가 기록 없이 죽어도 비교한다 ----
test_pre_tree_is_recorded_in_running_before_codex_starts() {
  FAKE_CODEX_SEQ=hang; start_task
  want=$(ew_tree_now)
  run_cc call plan; assert_code 0
  ew_until 5 ew_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  assert_eq "$(state '.running.pre_tree // empty')" "$want"
  pg=$(state .running.pgid); kill -KILL -- "-$pg" 2>/dev/null
  return 0
}
# ew_kill_group_without_lock <pg> : 테스트가 띄운 감독 프로세스 그룹을 KILL 한다. state 잠금을 쥔 순간에 죽이면 주인 없는
#   잠금이 남아 뒤에 잠금을 쥐는 시험이 흔들리므로, 그룹을 STOP 으로 멈춘 상태에서 잠금이 없을 때 죽인다 (있으면 잠깐 풀어 준다)
ew_kill_group_without_lock() {
  local i=0
  while :; do
    kill -STOP -- "-$1" 2>/dev/null
    [ -d "$ACTIVE/state.lock" ] || break
    kill -CONT -- "-$1" 2>/dev/null
    i=$((i + 1)); [ "$i" -ge 100 ] && break
    sleep 0.05
  done
  kill -KILL -- "-$1" 2>/dev/null
}
ew_kill_supervisor_group_after_edit() {   # FAKE_CODEX_SEQ=edit_tracked:hang 호출을 기록 없이 죽인다 → pg
  run_cc call plan; assert_code 0
  ew_until 5 ew_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  ew_until 5 ew_base_edited || _fail "가짜 codex 가 파일을 고치지 않음 (테스트 전제 깨짐)"
  pg=$(state .running.pgid)
  ew_kill_group_without_lock "$pg"
  ew_until 5 eval '! ew_group_alive "$pg"' || _fail "그룹이 끝나지 않음"
  assert_eq "$(state .running.call_id)" "1" "기록 없이 죽은 호출 (테스트 전제)"
}
test_dead_supervisor_without_record_is_rechecked_by_wait() {
  FAKE_CODEX_SEQ=edit_tracked:hang; start_task
  ew_kill_supervisor_group_after_edit
  # 훅은 그대로 빠르다: 스냅샷을 뜨지 않고 이 기록을 정리하지도 않는다
  ctx=$(printf '{"cwd":"%s"}' "$PWD" | bash "$HOOK" prompt-submit 2>/dev/null)
  assert_eq "$ctx" ""
  assert_eq "$(state .running.call_id)" "1" "훅이 기록을 정리함"
  run_cc wait --max 5; assert_code 3
  assert_eq "$(ew_lines "$OUT")" "1"
  assert_contains "$OUT" "Codex가 프로젝트 파일을 바꿨습니다"
  ew_assert_modified 1 base.txt
}
test_dead_supervisor_without_record_is_rechecked_by_check_orphan() {
  FAKE_CODEX_SEQ=edit_tracked:hang; start_task
  ew_kill_supervisor_group_after_edit
  run_cc check-orphan; assert_code 0
  ew_assert_modified 1 base.txt
}
test_dead_supervisor_without_record_is_rechecked_before_next_call() {
  FAKE_CODEX_SEQ=edit_tracked:hang,ok; start_task
  ew_kill_supervisor_group_after_edit
  # 새 호출로 덮어쓰기 전에 비교하고, 바뀌었으면 알리고 거부한다
  run_cc call plan; assert_code 6
  assert_eq "$(ew_lines "$OUT")" "1"
  assert_contains "$OUT" "Codex가 프로젝트 파일을 바꿨습니다"
  ew_assert_modified 1 base.txt
  assert_eq "$(state .calls_total)" "1"; assert_no_path "$ACTIVE/calls/2"
  # 정리된 뒤에는 (사용자가 정하면) 다시 부를 수 있다
  run_cc call plan; assert_code 0
  wait_until_status_file 2 || _fail "다음 호출이 끝나지 않음"
}
test_slow_post_snapshot_past_grace_is_rechecked_by_wait() {
  start_task; ew_fake_git_slow
  FAKE_CODEX_SEQ=slowsnap+edit_tracked:hang
  PATH="$TMP/bin:$PATH" run_cc call plan; assert_code 0
  ew_until 5 ew_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  ew_until 5 ew_base_edited || _fail "가짜 codex 가 파일을 고치지 않음 (테스트 전제 깨짐)"
  pg=$(state .running.pgid)
  ew_start_waiter --max 60
  ew_until 5 ew_waiter_registered || _fail "waiter 가 등록되지 않음"
  kill -TERM "$WP"; wait "$WP"; rc=$?
  assert_eq "$rc" "130"
  out=$(cat "$TMP/w.out")
  assert_eq "$(ew_lines "$out")" "1"
  assert_contains "$out" "[cc] 중단됨"
  assert_contains "$out" "Codex가 프로젝트 파일을 바꿨습니다"
  grep -q '끝: ' "$ACTIVE/supervisor.log" && _fail "감독 프로세스가 기록을 마침 (유예 안에 끝나 테스트 전제 깨짐)"
  ew_assert_modified 1 base.txt
  ew_group_alive "$pg" && _fail "감독 프로세스 그룹이 남아 있음"
  return 0
}
test_slow_post_snapshot_past_grace_is_rechecked_by_check_orphan_kill() {
  start_task; ew_fake_git_slow
  FAKE_CODEX_SEQ=slowsnap+edit_tracked:hang
  PATH="$TMP/bin:$PATH" run_cc call plan; assert_code 0
  ew_until 5 ew_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  ew_until 5 ew_base_edited || _fail "가짜 codex 가 파일을 고치지 않음 (테스트 전제 깨짐)"
  pg=$(state .running.pgid)
  run_cc check-orphan --kill; assert_code 10
  assert_eq "$(ew_lines "$OUT")" "1"
  assert_contains "$OUT" "Codex가 프로젝트 파일을 바꿨습니다"
  grep -q '끝: ' "$ACTIVE/supervisor.log" && _fail "감독 프로세스가 기록을 마침 (유예 안에 끝나 테스트 전제 깨짐)"
  ew_assert_modified 1 base.txt
  ew_group_alive "$pg" && _fail "감독 프로세스 그룹이 남아 있음"
  return 0
}

# ---- 4: 실행 뒤 스냅샷 실패는 끝난 원인과 상관없이 error·failed·verdict null ----
test_post_snapshot_failure_on_timeout_is_error() {
  start_task
  ew_fake_git "[ -e \"$FAKE_CODEX_LOG/snapfail\" ]"
  FAKE_CODEX_SEQ=snapfail:hang; CC_CALL_TIMEOUT_SECS=2
  PATH="$TMP/bin:$PATH" run_cc call plan; assert_code 0
  wait_until_status_file 1 15 || _fail "calls/1/status 가 생기지 않음"
  ew_assert_uncheck_error 1
  assert_contains "$(state .last_call.message)" "시간 초과"
}
test_post_snapshot_failure_on_wait_interrupt_is_error() {
  start_task
  ew_fake_git "[ -e \"$FAKE_CODEX_LOG/snapfail\" ]"
  FAKE_CODEX_SEQ=snapfail:hang
  PATH="$TMP/bin:$PATH" run_cc call plan; assert_code 0
  ew_until 5 ew_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  ew_until 5 eval '[ -e "$FAKE_CODEX_LOG/snapfail" ]' || _fail "표시가 생기지 않음"
  ew_start_waiter --max 60
  ew_until 5 ew_waiter_registered || _fail "waiter 가 등록되지 않음"
  kill -TERM "$WP"; wait "$WP"; rc=$?
  assert_eq "$rc" "130"
  out=$(cat "$TMP/w.out")
  assert_eq "$(ew_lines "$out")" "1"
  assert_contains "$out" "[cc] 중단됨"
  assert_contains "$out" "실행 뒤 작업 트리를 확인하지 못해"
  assert_not_contains "$out" "이미 끝나 있었습니다"
  ew_assert_uncheck_error 1
}
test_post_snapshot_failure_on_orphan_kill_is_error() {
  start_task
  ew_fake_git "[ -e \"$FAKE_CODEX_LOG/snapfail\" ]"
  FAKE_CODEX_SEQ=snapfail:hang
  PATH="$TMP/bin:$PATH" run_cc call plan; assert_code 0
  ew_until 5 ew_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  ew_until 5 eval '[ -e "$FAKE_CODEX_LOG/snapfail" ]' || _fail "표시가 생기지 않음"
  run_cc check-orphan --kill; assert_code 10
  assert_eq "$(ew_lines "$OUT")" "1"
  assert_contains "$OUT" "실행 뒤 작업 트리를 확인하지 못해"
  assert_not_contains "$OUT" "이미 끝나 있었습니다"
  ew_assert_uncheck_error 1
}

# ==== Codex 리뷰 2차 (R32): 이미 codex_modified 인 stop_failed 기록도 그룹이 사라진 뒤 최종 트리로 다시 비교한다 ====
# 첫 비교에서 "새 파일.txt" 를 찾고(codex_modified, 종료 확인 못 함), 남은 자식이 나중에 base.txt 를 고친다
ew_modified_then_late_edit() {
  FAKE_CODEX_SEQ=new_file+late_edit:ok; FAKE_CODEX_LATE_SECS=${1:-4}; start_task
  ew_fake_ps_fail_list
  PATH="$TMP/bin:$PATH" run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  late=$(cat "$FAKE_CODEX_LOG/1.late" 2>/dev/null)
  kill -0 "$late" 2>/dev/null || _fail "늦게 쓰는 자식이 벌써 끝남 (테스트 전제 깨짐)"
  # 종료를 확인하지 못했으므로 감독 프로세스는 실행 뒤 비교(git)를 하지 않고 미룬다 (Codex 보안 검수 1차 3): 결과 반영 없음
  assert_eq "$(state .last_call.status)" "error"
  assert_eq "$(state .running.stop_failed)" "true"
  assert_eq "$(state '.last_call.post_tree // empty')" ""
  first_post=""
  assert_contains "$(state .last_call.message)" "결과를 반영하지 않았"
  assert_contains "$(state .last_call.message)" "다시 확인합니다"     # 남은 프로세스가 끝난 뒤 다시 비교한다고 알린다
  ew_until 15 ew_pid_gone "$late" || _fail "늦게 쓰는 자식이 끝나지 않음"
  assert_contains "$(cat base.txt)" "late edit"
}
test_already_modified_stop_failed_call_is_rechecked_with_final_tree() {
  ew_modified_then_late_edit 4
  run_cc wait --max 5; assert_code 3
  assert_eq "$(ew_lines "$OUT")" "1"
  assert_contains "$OUT" "새 파일.txt"; assert_contains "$OUT" "base.txt"
  # 최종 post_tree 로 갱신: 두 경로 모두
  ew_assert_modified 1 "새 파일.txt" base.txt
  assert_eq "$(state .running)" "null"
}
test_already_modified_stop_failed_call_rechecked_by_check_orphan_and_call() {
  ew_modified_then_late_edit 3
  # 다음 call 도 덮어쓰기 전에 다시 비교하고, 새로 알게 된 것을 알리며 거부한다
  run_cc call plan; assert_code 6
  assert_eq "$(ew_lines "$OUT")" "1"
  assert_contains "$OUT" "base.txt"
  ew_assert_modified 1 "새 파일.txt" base.txt
  assert_eq "$(state .calls_total)" "1"
}
test_unconfirmed_stop_final_check_failure_is_one_line_error() {
  ew_modified_then_late_edit 3
  # 그룹이 사라진 뒤의 최종 스냅샷이 실패하면: 결과를 반영하지 않은 채 확인 실패를 한 줄로 (한 번만) 남긴다
  mkdir -p "$TMP/gitbin"
  printf '#!/bin/sh\n[ "$1" = write-tree ] && exit 1\nexec "%s" "$@"\n' "$(command -v git)" > "$TMP/gitbin/git"
  chmod +x "$TMP/gitbin/git"
  PATH="$TMP/gitbin:$PATH" run_cc wait --max 5; assert_code 3
  assert_eq "$(ew_lines "$OUT")" "1"
  assert_eq "$(state .last_call.status)" "error"
  msg=$(state .last_call.message)
  assert_eq "$(ew_lines "$msg")" "1"
  assert_contains "$msg" "결과를 반영하지 않았"
  assert_eq "$(printf '%s' "$msg" | grep -o '실행 뒤 작업 트리를 확인하지 못해' | wc -l | tr -d ' ')" "1"
  assert_eq "$OUT" "$msg"
  assert_eq "$(state .running)" "null"
  assert_eq "$(state .phase)" "failed"
}
test_unconfirmed_stop_change_is_found_by_check_orphan_after_group_is_gone() {
  FAKE_CODEX_SEQ=new_file:ok; start_task
  ew_fake_ps_fail_list
  PATH="$TMP/bin:$PATH" run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  assert_eq "$(state .last_call.status)" "error"; assert_eq "$(state .running.stop_failed)" "true"
  # 그룹이 사라진 것을 확인한 check-orphan 이 처음으로 비교해 찾는다
  run_cc check-orphan; assert_code 0
  ew_assert_modified 1 "새 파일.txt"
}

# ==== Codex 리뷰 3차 (R32) 1: 최종 다시 비교 뒤에는 "다시 확인합니다"·종료 미확인 경고·ps 안내가 남지 않는다 ====
# ew_assert_final_line : 최종 기록의 한 줄에 앞으로 다시 확인한다는 말이 없고, 다시 wait 해도 같은 한 줄(더 약속하지 않음)
ew_assert_final_line() {
  local msg
  msg=$(state .last_call.message)
  assert_eq "$(ew_lines "$msg")" "1"
  assert_not_contains "$msg" "다시 확인합니다"
  assert_not_contains "$msg" "프로세스가 끝났는지 확인하지 못했습니다"
  assert_not_contains "$msg" "ps -o pid,command"
  assert_eq "$(state .running)" "null"
  run_cc wait --max 5; assert_code 3
  assert_eq "$OUT" "$msg" "다시 wait"
  assert_not_contains "$OUT" "다시 확인합니다"
}
test_final_recheck_line_has_no_pending_text_when_tree_changed_again() {
  ew_modified_then_late_edit 3
  run_cc wait --max 5; assert_code 3
  ew_assert_modified 1 "새 파일.txt" base.txt
  ew_assert_final_line
}
test_final_recheck_line_has_no_pending_text_when_nothing_more_changed() {
  FAKE_CODEX_SEQ=new_file:ok; start_task
  ew_fake_ps_fail_list
  PATH="$TMP/bin:$PATH" run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  assert_contains "$(state .last_call.message)" "다시 확인합니다"
  run_cc wait --max 5; assert_code 3
  ew_assert_modified 1 "새 파일.txt"
  ew_assert_final_line
}
test_final_recheck_line_has_no_pending_text_when_tree_back_to_pre() {
  FAKE_CODEX_SEQ=new_file+late_remove_new:ok; FAKE_CODEX_LATE_SECS=3; start_task
  ew_fake_ps_fail_list
  PATH="$TMP/bin:$PATH" run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  late=$(cat "$FAKE_CODEX_LOG/1.late" 2>/dev/null)
  assert_eq "$(state .last_call.status)" "error"      # 종료를 확인하지 못해 비교하지 않았다 (Codex 보안 검수 1차 3)
  ew_until 15 ew_pid_gone "$late" || _fail "늦게 지우는 자식이 끝나지 않음"
  assert_no_path "새 파일.txt"
  run_cc wait --max 5; assert_code 3
  # 그룹이 사라진 뒤 처음 비교하면 실행 전과 같다 (그 사이 잠깐 생겼다 사라진 파일은 볼 수 없다: 비교를 미룬 대가)
  assert_eq "$(state .last_call.status)" "error"
  assert_contains "$(state .last_call.message)" "바뀐 프로젝트 파일 없음"
  ew_assert_final_line
}
test_final_recheck_line_has_no_pending_text_when_final_check_fails() {
  ew_modified_then_late_edit 3
  mkdir -p "$TMP/gitbin"
  printf '#!/bin/sh\n[ "$1" = write-tree ] && exit 1\nexec "%s" "$@"\n' "$(command -v git)" > "$TMP/gitbin/git"
  chmod +x "$TMP/gitbin/git"
  PATH="$TMP/gitbin:$PATH" run_cc wait --max 5; assert_code 3
  assert_eq "$(state .last_call.status)" "error"
  assert_contains "$(state .last_call.message)" "실행 뒤 작업 트리를 확인하지 못해"
  assert_contains "$(state .last_call.message)" "git diff $(state .last_call.pre_tree)"
  ew_assert_final_line
}
test_final_recheck_of_unapplied_result_has_no_pending_text() {
  # 결과를 반영하지 않은 stop_failed 기록(바뀐 것 없음)도 최종 정리 뒤에는 앞으로 다시 확인한다는 말이 없다
  FAKE_CODEX_SEQ=ok; start_task
  ew_fake_ps_fail_list
  PATH="$TMP/bin:$PATH" run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  assert_eq "$(state .last_call.status)" "error"
  assert_contains "$(state .last_call.message)" "다시 확인합니다"
  run_cc wait --max 5; assert_code 3
  assert_eq "$(state .last_call.status)" "error"
  assert_contains "$(state .last_call.message)" "결과를 반영하지 않았"
  assert_contains "$(state .last_call.message)" "바뀐 프로젝트 파일 없음"
  ew_assert_final_line
}

# ==== Codex 리뷰 3차 (R32) 2: 14일 넘은 기록도 자동으로 지우기 전에 최종 다시 비교한다 (preflight) ====
ew_iso_days_ago() { perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time - $ARGV[0] * 86400))' "$1"; }
test_preflight_rechecks_old_modified_record_before_auto_delete() {
  ew_modified_then_late_edit 3
  old=$(ew_iso_days_ago 15); set_state ".last_activity_at = \"$old\""
  run_cc preflight; assert_code 7
  assert_eq "$(ew_lines "$OUT")" "1"
  notice=$(printf '%s' "$OUT" | jq -r '.stale_notice // empty')
  assert_eq "$(ew_lines "$notice")" "1"
  assert_contains "$notice" "Codex가 프로젝트 파일을 바꿨습니다"
  assert_contains "$notice" "base.txt"; assert_contains "$notice" "새 파일.txt"
  assert_eq "$(printf '%s' "$OUT" | jq -r .code)" "active_present"
  # 이번에는 지우지 않는다. 다시 비교한 결과를 남기고, 14일 시계는 되돌리지 않는다
  assert_file_exists "$ACTIVE/state.json"
  ew_assert_modified 1 "새 파일.txt" base.txt
  assert_eq "$(state .last_activity_at)" "$old"
  assert_eq "$notice" "$(state .last_call.message)"
}
test_preflight_keeps_old_record_when_final_check_fails() {
  ew_modified_then_late_edit 3
  old=$(ew_iso_days_ago 15); set_state ".last_activity_at = \"$old\""
  mkdir -p "$TMP/gitbin"
  printf '#!/bin/sh\n[ "$1" = write-tree ] && exit 1\nexec "%s" "$@"\n' "$(command -v git)" > "$TMP/gitbin/git"
  chmod +x "$TMP/gitbin/git"
  PATH="$TMP/gitbin:$PATH" run_cc preflight; assert_code 7
  notice=$(printf '%s' "$OUT" | jq -r '.stale_notice // empty')
  assert_eq "$(ew_lines "$notice")" "1"
  assert_contains "$notice" "실행 뒤 작업 트리를 확인하지 못해"
  assert_file_exists "$ACTIVE/state.json"
  assert_eq "$(state .last_call.status)" "error"
  assert_eq "$(state '.last_call.post_tree // empty')" ""
  assert_eq "$(state .last_activity_at)" "$old"
}
test_preflight_still_auto_deletes_old_record_when_nothing_new() {
  FAKE_CODEX_SEQ=ok; start_task      # 종료를 확인하지 못한 호출, 바뀐 것 없음 (그룹이 사라진 뒤 비교해도 새로 알릴 것이 없다)
  ew_fake_ps_fail_list
  PATH="$TMP/bin:$PATH" run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  set_state ".last_activity_at = \"$(ew_iso_days_ago 15)\""
  run_cc preflight
  assert_eq "$(printf '%s' "$OUT" | jq -r '.stale_notice // empty')" "[cc] 오래된 /cc 중단 기록을 정리했습니다"
  assert_no_path "$ACTIVE"
}
test_session_start_hook_stays_snapshot_free_for_old_records() {
  # 세션 시작 훅은 스냅샷을 뜨지 않는다: 지금처럼 오래된 끝난 기록을 정리만 한다 (git write-tree 를 부르지 않음)
  FAKE_CODEX_SEQ=new_file:ok; start_task
  ew_fake_ps_fail_list
  PATH="$TMP/bin:$PATH" run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  set_state ".last_activity_at = \"$(ew_iso_days_ago 15)\""
  mkdir -p "$TMP/spybin"
  printf '#!/bin/sh\n[ "$1" = write-tree ] && : > "%s/write-tree.called"\nexec "%s" "$@"\n' "$TMP" "$(command -v git)" > "$TMP/spybin/git"
  chmod +x "$TMP/spybin/git"
  out=$(printf '{"cwd":"%s"}' "$PWD" | PATH="$TMP/spybin:$PATH" bash "$HOOK" session-start 2>/dev/null)
  assert_contains "$out" "정리했습니다"
  assert_no_path "$TMP/write-tree.called"
}

# ==== Codex 리뷰 4차 (R32) 1: 최종 비교 결과를 state 에 기록하지 못하면 새 호출도 자동 삭제도 하지 않는다 ====
# ew_hold_lock_then_release <초> : 살아 있는 프로세스가 state 잠금을 쥐고 있다가 <초> 뒤에 놓는다 (첫 정리 시도 동안만 잠김)
ew_hold_lock_then_release() {
  sleep 100 & holder=$!
  mkdir "$ACTIVE/state.lock" && printf '%s\n' "$holder" > "$ACTIVE/state.lock/owner"
  ( sleep "$1"; rm -rf "$ACTIVE/state.lock"; kill "$holder" 2>/dev/null ) &
  releaser=$!
}
test_call_refuses_when_final_recheck_cannot_be_recorded() {
  export CC_STATE_LOCK_WAIT_SECS=3
  FAKE_CODEX_SEQ=edit_tracked:hang,ok; start_task
  ew_kill_supervisor_group_after_edit
  pre=$(state .running.pre_tree)
  # 첫 정리(잠금 대기 3초)는 실패하고, 5초 뒤 잠금이 풀린다: 그 뒤의 call 자체 잠금은 잡을 수 있는 시점
  ew_hold_lock_then_release 5
  run_cc call plan; rc=$CODE
  wait "$releaser" 2>/dev/null
  assert_eq "$rc" "1"
  assert_eq "$(ew_lines "$OUT")" "1"
  assert_contains "$OUT" "최종 비교 결과를"
  # 새 호출을 하지 않았고, 이전 호출의 실행 전 트리는 그대로 남아 있다
  assert_eq "$(state .calls_total)" "1"; assert_no_path "$ACTIVE/calls/2"
  assert_eq "$(state .running.call_id)" "1"; assert_eq "$(state .running.pre_tree)" "$pre"
  assert_eq "$(ew_invocations)" "1"
  # 잠금이 풀린 뒤에는 정리하며 비교한 결과를 알린다
  run_cc call plan; assert_code 6
  assert_contains "$OUT" "Codex가 프로젝트 파일을 바꿨습니다"
  ew_assert_modified 1 base.txt
}
test_preflight_keeps_old_record_when_final_recheck_cannot_be_recorded() {
  export CC_STATE_LOCK_WAIT_SECS=3
  FAKE_CODEX_SEQ=edit_tracked:hang; start_task
  ew_kill_supervisor_group_after_edit
  set_state ".last_activity_at = \"$(ew_iso_days_ago 15)\""
  ew_hold_lock_then_release 5
  run_cc preflight
  wait "$releaser" 2>/dev/null
  notice=$(printf '%s' "$OUT" | jq -r '.stale_notice // empty')
  assert_eq "$(ew_lines "$notice")" "1"
  assert_contains "$notice" "최종 비교 결과를 기록하지 못해 지우지 않았습니다"
  # 지우지 않았다 (이전 호출의 기록은 남아 있다)
  assert_file_exists "$ACTIVE/state.json"
  assert_contains "$(cat base.txt)" "codex edit"
}

# ==== Codex 리뷰 4차 (R32) 2: 처음 스냅샷이 실패했어도 최종 다시 비교가 되면 확인 실패 문구는 남지 않는다 ====
ew_snapfail_unconfirmed_stop() {   # 첫 실행 뒤 스냅샷 실패 + 종료 확인 못 함 (가짜 ps 는 -A 만 실패, 가짜 git 은 표시가 있으면 write-tree 실패)
  FAKE_CODEX_SEQ=snapfail:ok; start_task
  ew_fake_ps_fail_list
  ew_fake_git "[ -e \"$FAKE_CODEX_LOG/snapfail\" ]"
  PATH="$TMP/bin:$PATH" run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  assert_eq "$(state .last_call.status)" "error"; assert_eq "$(state .running.stop_failed)" "true"
  # 종료를 확인하지 못했으므로 실행 뒤 스냅샷 자체를 하지 않았다 (Codex 보안 검수 1차 3)
  assert_contains "$(state .last_call.message)" "결과를 반영하지 않았"
  assert_not_contains "$(state .last_call.message)" "실행 뒤 작업 트리를 확인하지 못해"
}
test_final_recheck_success_drops_earlier_check_failure() {
  ew_snapfail_unconfirmed_stop
  run_cc wait --max 5; assert_code 3
  msg=$(state .last_call.message)
  assert_contains "$msg" "바뀐 프로젝트 파일 없음"
  assert_not_contains "$msg" "작업 트리를 확인하지 못해"
  assert_eq "$(state .last_call.status)" "error"; assert_eq "$(state .last_call.verdict)" "null"
  ew_assert_final_line
}
test_final_recheck_success_with_change_drops_earlier_check_failure() {
  ew_snapfail_unconfirmed_stop
  echo "late" > late.txt          # 그 뒤(남은 프로세스가 끝나기 전) 바뀐 파일
  run_cc wait --max 5; assert_code 3
  assert_not_contains "$(state .last_call.message)" "작업 트리를 확인하지 못해"
  ew_assert_modified 1 late.txt
  ew_assert_final_line
}
test_final_recheck_failure_keeps_check_failure_once() {
  ew_snapfail_unconfirmed_stop
  PATH="$TMP/bin:$PATH" run_cc wait --max 5; assert_code 3
  msg=$(state .last_call.message)
  assert_eq "$(printf '%s' "$msg" | grep -o '실행 뒤 작업 트리를 확인하지 못해' | wc -l | tr -d ' ')" "1"
  assert_eq "$(state .last_call.status)" "error"
  ew_assert_final_line
}

# ==== 2026-10-18 보안 수정 R33: Codex 가 만든 중첩 저장소·git 설정으로 /cc 가 git 을 실행하지 않는다 ====
# 가짜 codex 의 악성 설정은 git 이 실행하면 $FAKE_CODEX_LOG/marker.* 를 만든다 (= sandbox 밖에서 명령이 실행됨)
ew_no_evil_markers() {
  assert_no_path "$FAKE_CODEX_LOG/marker.fsmonitor"
  assert_no_path "$FAKE_CODEX_LOG/marker.filter"
}
# ew_assert_gitcfg_stop <call_id> <파일…> : git 설정이 바뀌어 실행 뒤 작업 트리 비교(git 명령)를 하지 않고 멈춘 호출
ew_assert_gitcfg_stop() {
  local id="$1" f msg
  shift
  assert_eq "$(cat "$ACTIVE/calls/$id/status" 2>/dev/null)" "codex_modified" "status 파일"
  assert_eq "$(state .last_call.status)" "codex_modified"; assert_eq "$(state .last_call.call_id)" "$id"
  assert_eq "$(state .last_call.verdict)" "null"; assert_eq "$(state .phase)" "failed"
  assert_eq "$(state .running)" "null"
  msg=$(state .last_call.message)
  assert_eq "$(ew_lines "$msg")" "1"
  assert_contains "$msg" "[cc] Codex가 git 설정을 바꿨습니다(되돌리지 않음)"
  assert_contains "$msg" "git 명령"
  [ -n "$(state '.last_call.pre_tree // empty')" ] || _fail "실행 전 트리가 기록되지 않음"
  assert_eq "$(state '.last_call.post_tree // empty')" "" "실행 뒤 스냅샷을 뜨면 안 됨"
  for f in "$@"; do
    assert_contains "$msg" "$f"
    state '.last_call.gitcfg_changed.shown[]' | grep -qxF -- "$f" || _fail "gitcfg_changed 에 [$f] 없음"
  done
}
test_new_nested_repo_with_malicious_config_stops_call_without_running_it() {
  FAKE_CODEX_SEQ=nested_evil:ok; start_task
  run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  ew_no_evil_markers
  ew_assert_modified 1 evil
  assert_eq "$(state .milestone)" "null"; assert_eq "$(ew_invocations)" "1"
  assert_file_exists evil/.git
}
test_new_nested_repo_without_commit_stops_call() {
  FAKE_CODEX_SEQ=nested_evil_empty:ok; start_task
  run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  ew_no_evil_markers
  ew_assert_modified 1 evil
}
test_top_level_git_config_change_stops_call_before_post_snapshot() {
  FAKE_CODEX_SEQ=gitcfg_evil:ok; start_task
  run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  ew_no_evil_markers
  ew_assert_gitcfg_stop 1 .git/config
  assert_eq "$(state .milestone)" "null"; assert_eq "$(ew_invocations)" "1"; assert_eq "$(state .calls_total)" "1"
  # 되돌리지 않는다
  grep -q fsmonitor .git/config || _fail ".git/config 가 되돌려짐"
  run_cc wait --max 5; assert_code 3
  assert_eq "$OUT" "$(state .last_call.message)"
  ew_no_evil_markers
}
test_git_config_include_target_change_stops_call() {
  start_task
  git config include.path ../cc-local.gitconfig
  FAKE_CODEX_SEQ=gitcfg_include:ok
  run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  ew_no_evil_markers
  ew_assert_gitcfg_stop 1 cc-local.gitconfig
}
ew_gitcfg_applied() { grep -q fsmonitor .git/config 2>/dev/null; }
test_git_config_change_found_by_deferred_recheck_runs_no_git() {
  # 감독 프로세스가 기록 없이 죽은 호출: 나중에 다시 비교하는 쪽(wait)도 git 설정부터 확인하고 git 을 실행하지 않는다
  FAKE_CODEX_SEQ=gitcfg_evil:hang; start_task
  run_cc call plan; assert_code 0
  ew_until 5 ew_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  ew_until 5 ew_gitcfg_applied || _fail "가짜 codex 가 설정을 바꾸지 않음 (테스트 전제 깨짐)"
  [ -n "$(state '.running.pre_gitcfg // empty')" ] || _fail "running.pre_gitcfg 가 없음"
  pg=$(state .running.pgid)
  ew_kill_group_without_lock "$pg"
  ew_until 5 eval '! ew_group_alive "$pg"' || _fail "그룹이 끝나지 않음"
  run_cc wait --max 5; assert_code 3
  assert_eq "$(ew_lines "$OUT")" "1"
  assert_contains "$OUT" "Codex가 git 설정을 바꿨습니다"
  ew_no_evil_markers
  ew_assert_gitcfg_stop 1 .git/config
}

# ==== R34: git 이 무시하는 비밀·설정 파일과 의존성 폴더도 감시한다 ====
ew_ignored_fixture() {
  printf '.env\nnode_modules/\ndist/\n.cache/\n' > .gitignore; git add .gitignore; git commit -qm ignore
  printf 'SECRET=1\n' > .env
  mkdir -p node_modules/pkg; printf 'module.exports = 1\n' > node_modules/pkg/index.js
}
# ew_assert_ignored_modified <call_id> <파일…> : 감시 대상 무시 파일만 바뀌어 멈춘 호출 (작업 트리 스냅샷은 같음)
ew_assert_ignored_modified() {
  local id="$1" f msg pre post
  shift
  assert_eq "$(cat "$ACTIVE/calls/$id/status" 2>/dev/null)" "codex_modified" "status 파일"
  assert_eq "$(state .last_call.status)" "codex_modified"; assert_eq "$(state .last_call.call_id)" "$id"
  assert_eq "$(state .last_call.verdict)" "null"; assert_eq "$(state .phase)" "failed"
  assert_eq "$(state .running)" "null"
  msg=$(state .last_call.message)
  assert_eq "$(ew_lines "$msg")" "1"
  assert_contains "$msg" "[cc] Codex가 프로젝트 파일을 바꿨습니다(되돌리지 않음)"
  assert_contains "$msg" "git이 무시하는 감시 대상"
  pre=$(state '.last_call.pre_tree // empty'); post=$(state '.last_call.post_tree // empty')
  { [ -n "$pre" ] && [ "$pre" = "$post" ]; } || _fail "pre/post tree: [$pre] [$post]"
  assert_contains "$msg" "git diff $pre $post"
  for f in "$@"; do
    assert_contains "$msg" "$f"
    state '.last_call.ignored_changed.shown[]' | grep -qxF -- "$f" || _fail "ignored_changed 에 [$f] 없음"
  done
}
test_ignored_env_change_by_codex_stops_call() {
  start_task; ew_ignored_fixture
  FAKE_CODEX_SEQ=edit_env:ok
  run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  ew_assert_ignored_modified 1 .env
  assert_contains "$(cat .env)" "CODEX=1"
  assert_eq "$(state .milestone)" "null"; assert_eq "$(ew_invocations)" "1"
  # 감시하느라 내용을 객체 저장소에 쓰지 않는다
  git cat-file -e "$(git hash-object --no-filters .env)" 2>/dev/null && _fail ".env 내용이 객체 저장소에 쓰임"
  run_cc wait --max 5; assert_code 3
  assert_eq "$OUT" "$(state .last_call.message)"
}
test_ignored_node_modules_change_by_codex_stops_call() {
  start_task; ew_ignored_fixture
  FAKE_CODEX_SEQ=edit_node_module:ok
  run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  ew_assert_ignored_modified 1 node_modules/pkg/index.js
  git cat-file -e "$(git hash-object --no-filters node_modules/pkg/index.js)" 2>/dev/null && _fail "내용이 객체 저장소에 쓰임"
  return 0
}
test_new_file_in_node_modules_by_codex_stops_call() {
  start_task; ew_ignored_fixture
  FAKE_CODEX_SEQ=new_node_module_file:ok
  run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  ew_assert_ignored_modified 1 node_modules/pkg/new.js
}
test_ignored_build_and_cache_output_is_still_allowed() {
  start_task; ew_ignored_fixture
  FAKE_CODEX_SEQ=ignored_build_cache:ok
  run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  assert_eq "$(cat "$CALL1/status")" "ok"
  assert_eq "$(state .last_call.status)" "ok"; assert_eq "$(state .milestone)" "1"
  assert_file_exists dist/app.js; assert_file_exists .cache/c.txt
}
test_tracked_and_ignored_changes_are_both_listed() {
  start_task; ew_ignored_fixture
  FAKE_CODEX_SEQ=edit_tracked+edit_env:ok
  run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  ew_assert_modified 1 base.txt
  msg=$(state .last_call.message)
  assert_contains "$msg" "git이 무시하는 감시 대상"
  assert_contains "$msg" ".env"
  assert_eq "$(state '.last_call.ignored_changed.total')" "1"
}
ew_env_edited() { grep -q CODEX=1 .env 2>/dev/null; }
test_ignored_change_found_by_deferred_recheck() {
  start_task; ew_ignored_fixture
  FAKE_CODEX_SEQ=edit_env:hang
  run_cc call plan; assert_code 0
  ew_until 5 ew_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  ew_until 5 ew_env_edited || _fail "가짜 codex 가 .env 를 고치지 않음 (테스트 전제 깨짐)"
  [ -n "$(state '.running.pre_ignored // empty')" ] || _fail "running.pre_ignored 가 없음"
  pg=$(state .running.pgid)
  ew_kill_group_without_lock "$pg"
  ew_until 5 eval '! ew_group_alive "$pg"' || _fail "그룹이 끝나지 않음"
  run_cc wait --max 5; assert_code 3
  assert_eq "$(ew_lines "$OUT")" "1"
  assert_contains "$OUT" ".env"
  ew_assert_ignored_modified 1 .env
}

# ==== R33 후속: git 설정이 바뀐 채로는 다음 git 명령을 실행하지 않는다 ====
# ew_gitcfg_stop_first_call : (FAKE_CODEX_SEQ 첫 모드가 gitcfg_evil:…) 호출 1 을 git 설정 변경으로 멈추게 한다. 원본 설정은 $TMP/config.orig
ew_gitcfg_stop_first_call() {
  cp .git/config "$TMP/config.orig"
  run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  ew_assert_gitcfg_stop 1 .git/config
}
ew_assert_tamper_line() {   # <한 줄> : 아직 바뀐 git 설정 때문에 git 을 돌리지 않았다는 줄
  assert_eq "$(ew_lines "$1")" "1"
  assert_contains "$1" "Codex가 git 설정을 바꿨습니다"
  assert_contains "$1" ".git/config"
  assert_contains "$1" "discard"
}
test_call_refuses_while_git_config_still_differs_and_resumes_after_restore() {
  FAKE_CODEX_SEQ=gitcfg_evil:ok,ok; start_task
  ew_gitcfg_stop_first_call
  # 바뀐 파일과 기준 지문을 active 와 따로 격리 기록에 남긴다
  jq -r '.changed.shown[]' "$(ew_quarantine_file)" 2>/dev/null | grep -qxF .git/config || _fail "격리 기록에 .git/config 없음"
  assert_eq "$(jq -r '.baseline | type' "$(ew_quarantine_file)" 2>/dev/null)" "object"
  # 어느 종류의 call 도 git 을 돌리지 않고 거부한다 (review 의 검수 스냅샷도 뜨지 않는다)
  printf '%s' "$REVIEW_REPORT" > "$(cc_path report)"; printf '사용자 말\n' > "$(cc_path message)"
  for kind in plan review message; do
    run_cc call "$kind"; assert_code 6
    ew_assert_tamper_line "$OUT"
    ew_no_evil_markers
  done
  assert_eq "$(state .calls_total)" "1"; assert_no_path "$ACTIVE/calls/2"; assert_eq "$(ew_invocations)" "1"
  # 설정만 되돌려도 실행 뒤 프로젝트 파일 비교가 끝나지 않았으므로 자동으로 풀지 않는다. 사용자가 확인했다고 명시해
  # 격리 기록을 지운 뒤에만 이어 간다.
  cp "$TMP/config.orig" .git/config
  run_cc call plan; assert_code 6
  ew_assert_unverified_line "$OUT"
  assert_file_exists "$(ew_quarantine_file)"
  run_cc release-quarantine; assert_code 0
  run_cc call plan; assert_code 0
  wait_until_status_file 2 || _fail "되돌린 뒤의 호출이 끝나지 않음"
  assert_eq "$(state .last_call.status)" "ok"
  assert_no_path "$(ew_quarantine_file)"
  ew_no_evil_markers
}
test_tamper_found_by_deferred_recheck_blocks_next_call() {
  # 기록 없이 죽은 호출을 wait 가 다시 비교하다 찾은 git 설정 변경도 기록하고, 다음 call 을 막는다
  FAKE_CODEX_SEQ=gitcfg_evil:hang; start_task
  run_cc call plan; assert_code 0
  ew_until 5 ew_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  ew_until 5 ew_gitcfg_applied || _fail "가짜 codex 가 설정을 바꾸지 않음 (테스트 전제 깨짐)"
  pg=$(state .running.pgid); ew_kill_group_without_lock "$pg"
  ew_until 5 eval '! ew_group_alive "$pg"' || _fail "그룹이 끝나지 않음"
  run_cc wait --max 5; assert_code 3
  assert_contains "$OUT" "Codex가 git 설정을 바꿨습니다"
  jq -r '.changed.shown[]' "$(ew_quarantine_file)" 2>/dev/null | grep -qxF .git/config || _fail "격리 기록이 남지 않음"
  run_cc call plan; assert_code 6
  ew_assert_tamper_line "$OUT"
  ew_no_evil_markers
}
test_tamper_found_when_call_settles_dead_record_blocks_following_calls() {
  FAKE_CODEX_SEQ=gitcfg_evil:hang,ok; start_task
  run_cc call plan; assert_code 0
  ew_until 5 ew_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  ew_until 5 ew_gitcfg_applied || _fail "가짜 codex 가 설정을 바꾸지 않음 (테스트 전제 깨짐)"
  pg=$(state .running.pgid); ew_kill_group_without_lock "$pg"
  ew_until 5 eval '! ew_group_alive "$pg"' || _fail "그룹이 끝나지 않음"
  # 새 call 이 끝난 기록을 정리하며 찾고 (6), 그 뒤의 call 도 계속 막는다
  run_cc call plan; assert_code 6
  assert_contains "$OUT" "Codex가 git 설정을 바꿨습니다"
  run_cc call plan; assert_code 6
  ew_assert_tamper_line "$OUT"
  assert_eq "$(state .calls_total)" "1"; assert_eq "$(ew_invocations)" "1"
  ew_no_evil_markers
}
test_preflight_cleanup_and_hook_keep_record_while_git_config_differs() {
  FAKE_CODEX_SEQ=gitcfg_evil:ok; start_task
  ew_gitcfg_stop_first_call
  q=$(ew_quarantine_file)
  set_state ".last_activity_at = \"$(ew_iso_days_ago 15)\""
  run_cc preflight; assert_code 7
  assert_eq "$(printf '%s' "$OUT" | jq -r .code)" "git_config_changed"
  ew_assert_tamper_line "$(printf '%s' "$OUT" | jq -r .message)"
  assert_file_exists "$ACTIVE/state.json"
  run_cc cleanup-stale; assert_code 0
  ew_assert_tamper_line "$OUT"
  assert_file_exists "$ACTIVE/state.json"
  # 세션 시작 훅은 지문을 계산하지 않고 git 도 부르지 않는다 (격리 기록이 있으면 경로도 git 없이 찾는다). 오래된 active 를 지워도
  #   격리 기록은 따로 남는다
  ew_git_spy "$TMP/spy.calls"
  printf '{"cwd":"%s"}' "$PWD" | PATH="$TMP/spy:$PATH" bash "$HOOK" session-start >/dev/null 2>&1
  assert_eq "$(cat "$TMP/spy.calls" 2>/dev/null)" "" "훅의 git 호출"
  assert_file_exists "$q"
  ew_no_evil_markers
  # 설정을 되돌려도 자동으로 풀지 않는다. 사용자가 확인해 명시적으로 푼 뒤 정리한다.
  cp "$TMP/config.orig" .git/config
  run_cc cleanup-stale; assert_code 0
  ew_assert_unverified_line "$OUT"
  assert_file_exists "$q"
  run_cc release-quarantine; assert_code 0
  run_cc cleanup-stale; assert_code 0
  assert_no_path "$q"
  assert_no_path "$ACTIVE/state.json"
}
test_discard_and_finish_work_while_git_config_differs() {
  FAKE_CODEX_SEQ=gitcfg_evil:ok; start_task
  ew_gitcfg_stop_first_call
  run_cc discard; assert_code 0
  assert_eq "$(ew_lines "$OUT")" "1"
  assert_contains "$OUT" "작업 기록을 버렸습니다"
  assert_contains "$OUT" ".git/config"
  assert_no_path "$ACTIVE"
  ew_no_evil_markers
}
test_finish_works_while_git_config_differs() {
  FAKE_CODEX_SEQ=gitcfg_evil:ok; start_task
  ew_gitcfg_stop_first_call
  run_cc finish; assert_code 0
  assert_eq "$(ew_lines "$OUT")" "1"
  assert_contains "$OUT" "마무리"
  assert_contains "$OUT" ".git/config"
  assert_no_path "$ACTIVE"
  ew_no_evil_markers
}

# ==== R34 후속 (사용자 결정): node_modules/.cache/ 와 node_modules/.vite/ 도구 캐시는 감시하지 않는다 ====
test_node_modules_tool_caches_are_allowed() {
  start_task; ew_ignored_fixture
  FAKE_CODEX_SEQ=node_module_tool_caches:ok
  run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  assert_eq "$(cat "$CALL1/status")" "ok"
  assert_eq "$(state .last_call.status)" "ok"; assert_eq "$(state .milestone)" "1"
  assert_file_exists node_modules/.vite/deps/d.js
}
test_node_modules_cache_and_package_write_lists_only_package() {
  start_task; ew_ignored_fixture
  FAKE_CODEX_SEQ=node_module_tool_caches+edit_node_module:ok
  run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  ew_assert_ignored_modified 1 node_modules/pkg/index.js
  assert_eq "$(state '.last_call.ignored_changed.total')" "1"
  assert_not_contains "$(state .last_call.message)" "node_modules/.cache"
  assert_not_contains "$(state .last_call.message)" "node_modules/.vite"
}

# ==== Codex 보안 검수 1차 ====
# ew_git_spy <기록 파일> : 모든 git 호출의 인자를 한 줄씩 남기고 진짜 git 을 부르는 가짜 git 을 $TMP/spy 에 둔다
ew_git_spy() {
  mkdir -p "$TMP/spy"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nexec "%s" "$@"\n' "$1" "$(command -v git)" > "$TMP/spy/git"
  chmod +x "$TMP/spy/git"
}
# ew_quarantine_file : 이 저장소의 외부 격리 기록 (Codex 보안 검수 2차, R36: $CLAUDE_PLUGIN_DATA/cc/quarantine/<작업 트리 실제 경로의 sha256>.json)
ew_repo_root() { cd -P "${ACTIVE%/.git/yultopia-cc/active}" 2>/dev/null && pwd -P; }
ew_quarantine_file() {
  printf '%s/cc/quarantine/%s.json' "$CLAUDE_PLUGIN_DATA" "$(perl -MDigest::SHA=sha256_hex -e 'print sha256_hex($ARGV[0])' "$(ew_repo_root)")"
}
# ---- 1: 격리 기록은 active 와 따로 남아 discard·finish 뒤에도 새 preflight·init 을 막는다 (격리 중에는 git 을 하나도 부르지 않는다) ----
test_quarantine_survives_discard_and_blocks_new_preflight_and_init_without_git() {
  FAKE_CODEX_SEQ=gitcfg_evil:ok; start_task
  ew_gitcfg_stop_first_call
  q=$(ew_quarantine_file)
  assert_file_exists "$q"
  jq -r '.changed.shown[]' "$q" 2>/dev/null | grep -qxF .git/config || _fail "격리 기록에 .git/config 없음"
  assert_eq "$(jq -r '.baseline | type' "$q" 2>/dev/null)" "object"
  ew_git_spy "$TMP/spy.calls"
  PATH="$TMP/spy:$PATH" run_cc call plan; assert_code 6
  ew_assert_tamper_line "$OUT"
  PATH="$TMP/spy:$PATH" run_cc wait --max 2; assert_code 3
  PATH="$TMP/spy:$PATH" run_cc check-orphan; assert_code 0
  PATH="$TMP/spy:$PATH" run_cc status; assert_code 0
  PATH="$TMP/spy:$PATH" run_cc discard; assert_code 0
  assert_eq "$(ew_lines "$OUT")" "1"
  assert_contains "$OUT" "작업 기록을 버렸습니다"; assert_contains "$OUT" ".git/config"
  assert_no_path "$ACTIVE"; assert_file_exists "$q"
  PATH="$TMP/spy:$PATH" run_cc preflight; assert_code 7
  assert_eq "$(printf '%s' "$OUT" | jq -r .code)" "git_config_changed"
  ew_assert_tamper_line "$(printf '%s' "$OUT" | jq -r .message)"
  printf '목표\n' | PATH="$TMP/spy:$PATH" run_cc init; cc_last
  assert_eq "$CODE" "1"; ew_assert_tamper_line "$OUT"
  assert_no_path "$ACTIVE"
  PATH="$TMP/spy:$PATH" run_cc cleanup-stale; assert_code 0
  ew_assert_tamper_line "$OUT"
  assert_eq "$(cat "$TMP/spy.calls" 2>/dev/null)" "" "격리 중의 git 호출"
  ew_no_evil_markers
  # 설정을 되돌린 것만으로는 풀리지 않는다. 사용자가 확인해 명시적으로 기록을 지운 뒤 진행한다.
  cp "$TMP/config.orig" .git/config; rm -f .gitattributes
  run_cc preflight; assert_code 7
  assert_file_exists "$q"
  run_cc release-quarantine; assert_code 0
  run_cc preflight; assert_code 0
  assert_eq "$(printf '%s' "$OUT" | jq -r .code)" "ready"
  assert_no_path "$q"
  printf '목표\n' | run_cc init; cc_last; assert_eq "$CODE" "0"
  ew_no_evil_markers
}
test_quarantine_survives_finish_and_blocks_new_init() {
  # 작업 트리는 깨끗하게 두고 filter 속성을 .git/info/attributes 에 둔다: 새 init 이 스냅샷까지 가면 filter 가 돈다
  FAKE_CODEX_SEQ=gitcfg_evil_info:ok; start_task
  ew_gitcfg_stop_first_call
  q=$(ew_quarantine_file)
  ew_git_spy "$TMP/spy.calls"
  PATH="$TMP/spy:$PATH" run_cc finish; assert_code 0
  assert_contains "$OUT" "마무리"; assert_contains "$OUT" ".git/config"
  assert_no_path "$ACTIVE"; assert_file_exists "$q"
  printf '목표\n' | PATH="$TMP/spy:$PATH" run_cc init; cc_last
  assert_eq "$CODE" "1"; ew_assert_tamper_line "$OUT"
  assert_eq "$(cat "$TMP/spy.calls" 2>/dev/null)" "" "격리 중의 git 호출"
  ew_no_evil_markers
  cp "$TMP/config.orig" .git/config; rm -f .git/info/attributes
  printf '목표\n' | run_cc init; cc_last; assert_eq "$CODE" "1"
  assert_file_exists "$q"
  run_cc release-quarantine; assert_code 0
  printf '목표\n' | run_cc init; cc_last; assert_eq "$CODE" "0"
  assert_no_path "$q"
}

# git 설정과 감시 대상 무시 파일을 함께 바꾼 뒤 설정만 되돌려도, post 비교를 끝내지 못한 기록은 자동 해제하지 않는다.
test_restored_git_config_does_not_auto_release_unchecked_ignored_changes() {
  start_task; ew_ignored_fixture
  FAKE_CODEX_SEQ=gitcfg_evil+edit_node_module:ok
  ew_gitcfg_stop_first_call
  q=$(ew_quarantine_file)
  assert_contains "$(cat node_modules/pkg/index.js)" "codex"
  run_cc finish; assert_code 0
  assert_no_path "$ACTIVE"; assert_file_exists "$q"
  cp "$TMP/config.orig" .git/config; rm -f .gitattributes
  run_cc preflight; assert_code 7
  assert_eq "$(printf '%s' "$OUT" | jq -r .code)" "git_config_changed"
  ew_assert_unverified_line "$(printf '%s' "$OUT" | jq -r .message)"
  assert_file_exists "$q"
  assert_contains "$(cat node_modules/pkg/index.js)" "codex"
}
# ---- 2: 하위 모듈의 .git 을 .git/modules 아래 새 git 디렉터리로 돌려도 그 안에서 git 을 돌리지 않는다 ----
ew_add_submodule() {   # <sub 원본에 더할 .gitignore 내용 (없으면 빈 값)>
  local src="$TMP/subsrc"
  mkdir -p "$src"
  ( cd "$src" && git init -q . && git config user.name t && git config user.email t@example.com \
      && git config commit.gpgsign false && echo s > s.txt && git add s.txt && git commit -q -m s \
      && if [ -n "$1" ]; then printf '%s' "$1" > .gitignore && git add .gitignore && git commit -q -m ign; fi ) >/dev/null 2>&1
  git -c protocol.file.allow=always submodule add -q "$src" sub >/dev/null 2>&1 && git commit -q -m sub
}
test_submodule_redirect_into_modules_subdir_stops_call_without_running_git_there() {
  start_task
  ew_add_submodule "" || { _fail "하위 모듈을 만들지 못함 (테스트 전제)"; return 1; }
  FAKE_CODEX_SEQ=submodule_redirect_evil:ok
  run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  ew_no_evil_markers
  ew_assert_modified 1 sub
  assert_eq "$(state '.running')" "null"
  assert_eq "$(state .milestone)" "null"
}
# ---- 3: 종료를 확인하지 못했으면 실행 뒤 스냅샷·diff 를 하지 않는다 (그룹이 사라진 것을 확인한 쪽이 나중에 비교) ----
test_unconfirmed_stop_runs_no_git_after_codex_and_compares_once_group_is_gone() {
  FAKE_CODEX_SEQ=mark_ran+late_edit:ok; FAKE_CODEX_LATE_SECS=4; start_task
  ew_fake_ps_fail_list
  printf '#!/bin/sh\n[ -e "%s/codex.ran" ] && printf "%%s\\n" "$*" >> "%s/post-git.calls"\nexec "%s" "$@"\n' \
    "$FAKE_CODEX_LOG" "$TMP" "$(command -v git)" > "$TMP/bin/git"
  chmod +x "$TMP/bin/git"
  PATH="$TMP/bin:$PATH" run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  late=$(cat "$FAKE_CODEX_LOG/1.late" 2>/dev/null)
  kill -0 "$late" 2>/dev/null || _fail "늦게 쓰는 자식이 벌써 끝남 (테스트 전제 깨짐)"
  assert_eq "$(state .running.stop_failed)" "true"
  assert_eq "$(state .last_call.status)" "error"; assert_eq "$(state .last_call.verdict)" "null"
  assert_eq "$(state .milestone)" "null"
  assert_contains "$(state .last_call.message)" "결과를 반영하지 않았"
  assert_contains "$(state .last_call.message)" "다시 확인합니다"
  [ -n "$(state '.running.pre_tree // empty')" ] && [ "$(state '.running.pre_gitcfg | type')" = object ] \
    || _fail "다시 비교할 실행 전 기록이 running 에 없음"
  assert_eq "$(cat "$TMP/post-git.calls" 2>/dev/null)" "" "종료를 확인하지 못한 뒤의 git 호출"
  ew_until 15 ew_pid_gone "$late" || _fail "늦게 쓰는 자식이 끝나지 않음"
  run_cc wait --max 5; assert_code 3
  assert_contains "$OUT" "base.txt"
  ew_assert_modified 1 base.txt
}
# ---- 4: 하위 모듈 안의 무시된 중요 파일도 감시한다 ----
test_ignored_env_in_submodule_change_stops_call() {
  start_task
  ew_add_submodule $'.env\nnode_modules/\n' || { _fail "하위 모듈을 만들지 못함 (테스트 전제)"; return 1; }
  printf 'S=1\n' > sub/.env
  FAKE_CODEX_SEQ=edit_submodule_env:ok
  run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  ew_assert_ignored_modified 1 sub/.env
}
# ---- 5: git 설정 무결성을 확인하지 못한 경우(지문 없는 이전 기록, 확인 오류)는 git 을 돌리지 않고 그렇다고 알린다 ----
ew_assert_unverified_line() {   # <한 줄>
  assert_eq "$(ew_lines "$1")" "1"
  assert_contains "$1" "git 설정 무결성을 확인하지 못해"
  assert_not_contains "$1" "git diff"
  assert_not_contains "$1" "작업 트리를 확인하지 못해"
}
test_record_without_fingerprint_runs_no_git_and_says_integrity_unverified() {
  FAKE_CODEX_SEQ=edit_tracked:hang; start_task
  ew_kill_supervisor_group_after_edit
  set_state 'del(.running.pre_gitcfg)'
  ew_git_spy "$TMP/spy.calls"
  PATH="$TMP/spy:$PATH" run_cc wait --max 5; assert_code 3
  ew_assert_unverified_line "$OUT"
  assert_eq "$(state .last_call.status)" "error"; assert_eq "$(state .last_call.gitcfg_unverified)" "true"
  assert_eq "$(state .running)" "null"
  assert_eq "$(grep -v '^rev-parse ' "$TMP/spy.calls" 2>/dev/null)" "" "경로 찾기 말고 다른 git 호출"
  # (Codex 보안 검수 2차 2) 지문 없는 기록도 기준 없는 unverified 격리 기록으로 남아, 사용자가 확인해 지우기 전까지 모든 새 명령이
  #   git 을 한 번도 부르지 않는다 (discard·finish 뒤에도)
  q=$(ew_quarantine_file)
  assert_eq "$(jq -r .state "$q" 2>/dev/null)" "unverified"
  assert_eq "$(jq -r .baseline "$q" 2>/dev/null)" "null"
  : > "$TMP/spy.calls"
  PATH="$TMP/spy:$PATH" run_cc call plan; assert_code 6
  ew_assert_unverified_line "$OUT"
  printf '목표\n' | PATH="$TMP/spy:$PATH" run_cc init; cc_last; assert_eq "$CODE" "1"
  PATH="$TMP/spy:$PATH" run_cc preflight; assert_code 7
  assert_eq "$(printf '%s' "$OUT" | jq -r .code)" "git_config_changed"
  PATH="$TMP/spy:$PATH" run_cc cleanup-stale; assert_code 0
  PATH="$TMP/spy:$PATH" run_cc discard; assert_code 0
  assert_no_path "$ACTIVE"; assert_file_exists "$q"
  PATH="$TMP/spy:$PATH" run_cc preflight; assert_code 7
  assert_eq "$(cat "$TMP/spy.calls" 2>/dev/null)" "" "격리 중의 git 호출"
  # 사용자가 git 설정을 확인했다고 할 때만 Claude 가 지운다: 그 뒤에는 그대로 진행한다
  PATH="$TMP/spy:$PATH" run_cc release-quarantine; assert_code 0
  assert_eq "$(ew_lines "$OUT")" "1"
  assert_no_path "$q"
  assert_eq "$(cat "$TMP/spy.calls" 2>/dev/null)" "" "release-quarantine 의 git 호출"
  # 이제 평소처럼 진행한다 (여기서는 앞서 Codex 가 고친 base.txt 때문에 dirty)
  run_cc preflight; assert_code 7
  assert_eq "$(printf '%s' "$OUT" | jq -r .code)" "dirty"
  assert_contains "$(printf '%s' "$OUT" | jq -r '.dirty_files | join(",")')" "base.txt"
}
test_fingerprint_verify_error_runs_no_git_and_blocks_until_checked() {
  FAKE_CODEX_SEQ=edit_tracked:hang; start_task
  ew_kill_supervisor_group_after_edit
  set_state '.running.pre_gitcfg = {"v": 1}'
  # 외부 armed 기록(신뢰할 수 있는 기준)이 없는 이전 기록이라고 본다: 그 기준이 있으면 그것으로 확인해 그대로 진행한다
  rm -f "$(ew_quarantine_file)"
  ew_git_spy "$TMP/spy.calls"
  PATH="$TMP/spy:$PATH" run_cc wait --max 5; assert_code 3
  ew_assert_unverified_line "$OUT"
  assert_eq "$(state .last_call.gitcfg_unverified)" "true"
  assert_eq "$(grep -v '^rev-parse ' "$TMP/spy.calls" 2>/dev/null)" "" "경로 찾기 말고 다른 git 호출"
  # 확인하지 못한 기준을 격리 기록으로 남겨, 다음 call 도 git 없이 막는다
  assert_file_exists "$(ew_quarantine_file)"
  : > "$TMP/spy.calls"
  PATH="$TMP/spy:$PATH" run_cc call plan; assert_code 6
  ew_assert_unverified_line "$OUT"
  assert_eq "$(cat "$TMP/spy.calls")" "" "격리 중의 git 호출"
}

# ==== Codex 보안 검수 2차 (R36): 격리 기록은 저장소 밖(Claude 쪽 상태 폴더)에, Codex 를 띄우기 전에 armed 로 남긴다 ====
ew_qdir() { printf '%s/cc/quarantine' "$CLAUDE_PLUGIN_DATA"; }
ew_q_records() { ls "$(ew_qdir)" 2>/dev/null | grep -c '\.json$'; }
# ew_assert_blocked_without_git : 다음 call·init·preflight·cleanup-stale 이 git 을 한 번도 부르지 않고 거부하며 악성 marker 도 없다
ew_assert_blocked_without_git() {
  ew_git_spy "$TMP/spy.calls"
  PATH="$TMP/spy:$PATH" run_cc call plan; assert_code 6
  assert_contains "$OUT" "git 명령을 실행하지 않았고"
  printf '목표\n' | PATH="$TMP/spy:$PATH" run_cc init; cc_last; assert_eq "$CODE" "1"
  PATH="$TMP/spy:$PATH" run_cc preflight; assert_code 7
  assert_eq "$(printf '%s' "$OUT" | jq -r .code)" "git_config_changed"
  PATH="$TMP/spy:$PATH" run_cc cleanup-stale; assert_code 0
  assert_contains "$OUT" "git 명령을 실행하지 않았고"
  assert_eq "$(cat "$TMP/spy.calls" 2>/dev/null)" "" "격리 중의 git 호출"
  ew_no_evil_markers
}
# ew_run_until_supervisor_gone : call plan 을 하고 감독 프로세스 그룹이 끝날 때까지 기다린다 (.git 이 바뀌어 status 파일을 못 볼 때)
ew_run_until_supervisor_gone() {
  run_cc call plan; assert_code 0
  pg=$(state .running.pgid)
  ew_until 20 eval '! ew_group_alive "$pg"' || _fail "감독 프로세스가 끝나지 않음"
}
test_gitdir_swapped_to_gitfile_keeps_blocking_without_git() {
  FAKE_CODEX_SEQ=gitdir_swap_gitfile:ok; start_task
  q=$(ew_quarantine_file)
  ew_run_until_supervisor_gone
  [ -f .git ] || { _fail ".git 이 gitfile 로 바뀌지 않음 (테스트 전제)"; return 1; }
  assert_file_exists "$q"
  assert_eq "$(jq -r .state "$q" 2>/dev/null)" "tampered"
  ew_assert_blocked_without_git
}
test_gitdir_swapped_to_symlink_writes_nothing_outside_and_blocks() {
  FAKE_CODEX_SEQ=gitdir_swap_symlink:ok; start_task
  q=$(ew_quarantine_file)
  ew_run_until_supervisor_gone
  [ -L .git ] || { _fail ".git 이 링크로 바뀌지 않음 (테스트 전제)"; return 1; }
  # 링크를 따라 저장소 밖(악성 gitdir)에 아무것도 쓰지 않는다
  assert_no_path "$FAKE_CODEX_LOG/evilgit/yultopia-cc"
  assert_file_exists "$q"
  assert_eq "$(jq -r .state "$q" 2>/dev/null)" "tampered"
  ew_assert_blocked_without_git
  assert_no_path "$FAKE_CODEX_LOG/evilgit/yultopia-cc"
}
test_quarantine_write_failure_after_tamper_still_blocks() {
  # 바뀐 설정을 찾았을 때 격리 기록을 고쳐 쓰지 못해도, 실행 전에 남긴 armed 기록으로 계속 막는다 (fail closed)
  FAKE_CODEX_SEQ=gitcfg_evil+qwrite_fail:ok; start_task
  q=$(ew_quarantine_file)
  run_cc call plan; assert_code 0
  wait_until_status_file 1 15 || _fail "calls/1/status 가 생기지 않음"
  assert_file_exists "$q"
  ew_assert_blocked_without_git
  chmod 755 "$(ew_qdir)" .git/yultopia-cc 2>/dev/null
}
test_arm_write_failure_does_not_start_codex() {
  start_task
  mkdir -p "$(ew_qdir)" && chmod 555 "$(ew_qdir)"
  run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  chmod 755 "$(ew_qdir)"
  assert_eq "$(cat "$CALL1/status")" "error"
  assert_contains "$(state .last_call.message)" "격리 기록"
  assert_eq "$(ew_invocations)" "0"
}
test_armed_record_exists_while_codex_runs_and_is_released_after_verified_finish() {
  FAKE_CODEX_SEQ=hang,ok; start_task
  q=$(ew_quarantine_file)
  run_cc call plan; assert_code 0
  ew_until 5 ew_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  assert_eq "$(jq -r .state "$q" 2>/dev/null)" "armed"
  assert_eq "$(jq -r '.baseline | type' "$q" 2>/dev/null)" "object"
  assert_eq "$(jq -r .repo "$q" 2>/dev/null)" "$(ew_repo_root)"
  # 기록 없이 죽어도 armed 는 남고, 그룹이 사라진 것을 확인한 쪽이 비교를 마친 뒤에야 지운다
  pg=$(state .running.pgid); ew_kill_group_without_lock "$pg"
  ew_until 5 eval '! ew_group_alive "$pg"' || _fail "그룹이 끝나지 않음"
  assert_file_exists "$q"
  run_cc wait --max 5; assert_code 3
  assert_no_path "$q"
  # 정상 호출은 끝나면 기록을 남기지 않는다 (쌓이지 않음)
  run_cc call plan; assert_code 0
  wait_until_status_file 2 || _fail "calls/2/status 가 생기지 않음"
  assert_eq "$(cat "$ACTIVE/calls/2/status")" "ok"
  assert_eq "$(ew_q_records)" "0"
}
test_hooks_do_not_create_plugin_data_dir() {
  start_task
  rm -rf "$CLAUDE_PLUGIN_DATA"
  printf '{"cwd":"%s"}' "$PWD" | bash "$HOOK" session-start >/dev/null 2>&1
  printf '{"cwd":"%s"}' "$PWD" | bash "$HOOK" prompt-submit >/dev/null 2>&1
  assert_no_path "$CLAUDE_PLUGIN_DATA"
}
