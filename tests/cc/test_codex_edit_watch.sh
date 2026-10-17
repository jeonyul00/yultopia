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
ew_kill_supervisor_group_after_edit() {   # FAKE_CODEX_SEQ=edit_tracked:hang 호출을 기록 없이 죽인다 → pg
  run_cc call plan; assert_code 0
  ew_until 5 ew_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  ew_until 5 ew_base_edited || _fail "가짜 codex 가 파일을 고치지 않음 (테스트 전제 깨짐)"
  pg=$(state .running.pgid)
  kill -KILL -- "-$pg" 2>/dev/null
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
  assert_eq "$(state .last_call.status)" "codex_modified"
  assert_eq "$(state .running.stop_failed)" "true"
  first_post=$(state .last_call.post_tree)
  assert_contains "$(state .last_call.message)" "새 파일.txt"
  assert_not_contains "$(state .last_call.message)" "base.txt"
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
  [ "$(state .last_call.post_tree)" != "$first_post" ] || _fail "post_tree 가 최종 값으로 바뀌지 않음"
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
test_already_modified_stop_failed_keeps_evidence_when_final_check_fails() {
  ew_modified_then_late_edit 3
  # 마지막 스냅샷이 실패하면: 앞서 찾은 변경(codex_modified, 그 파일·트리)과 확인 실패를 한 줄에 함께 남긴다
  mkdir -p "$TMP/gitbin"
  printf '#!/bin/sh\n[ "$1" = write-tree ] && exit 1\nexec "%s" "$@"\n' "$(command -v git)" > "$TMP/gitbin/git"
  chmod +x "$TMP/gitbin/git"
  PATH="$TMP/gitbin:$PATH" run_cc wait --max 5; assert_code 3
  assert_eq "$(ew_lines "$OUT")" "1"
  assert_eq "$(state .last_call.status)" "codex_modified"
  assert_eq "$(state .last_call.post_tree)" "$first_post"
  msg=$(state .last_call.message)
  assert_eq "$(ew_lines "$msg")" "1"
  assert_contains "$msg" "Codex가 프로젝트 파일을 바꿨습니다"
  assert_contains "$msg" "새 파일.txt"
  assert_contains "$msg" "실행 뒤 작업 트리를 확인하지 못해"
  assert_eq "$OUT" "$msg"
  assert_eq "$(state .running)" "null"
  assert_eq "$(state .phase)" "failed"
}
test_already_modified_stop_failed_keeps_evidence_when_nothing_more_changed() {
  FAKE_CODEX_SEQ=new_file:ok; start_task
  ew_fake_ps_fail_list
  PATH="$TMP/bin:$PATH" run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  assert_eq "$(state .last_call.status)" "codex_modified"; assert_eq "$(state .running.stop_failed)" "true"
  first_post=$(state .last_call.post_tree)
  run_cc check-orphan; assert_code 0
  # 다시 비교했고 더 바뀐 것이 없다: 앞서 찾은 증거(상태·트리·파일)는 그대로
  ew_assert_modified 1 "새 파일.txt"
  assert_eq "$(state .last_call.post_tree)" "$first_post"
  assert_contains "$(state .last_call.message)" "추가로 바뀐 파일 없음"
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
  assert_contains "$(state .last_call.message)" "추가로 바뀐 파일 없음"
  ew_assert_final_line
}
test_final_recheck_line_has_no_pending_text_when_tree_back_to_pre() {
  FAKE_CODEX_SEQ=new_file+late_remove_new:ok; FAKE_CODEX_LATE_SECS=3; start_task
  ew_fake_ps_fail_list
  PATH="$TMP/bin:$PATH" run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  late=$(cat "$FAKE_CODEX_LOG/1.late" 2>/dev/null)
  assert_eq "$(state .last_call.status)" "codex_modified"
  first_post=$(state .last_call.post_tree)
  ew_until 15 ew_pid_gone "$late" || _fail "늦게 지우는 자식이 끝나지 않음"
  assert_no_path "새 파일.txt"
  run_cc wait --max 5; assert_code 3
  # 앞서 찾은 증거는 그대로 (상태·트리·파일), 최종 결과(지금은 실행 전과 같음)만 붙는다
  ew_assert_modified 1 "새 파일.txt"
  assert_eq "$(state .last_call.post_tree)" "$first_post"
  assert_contains "$(state .last_call.message)" "실행 전과 같음"
  ew_assert_final_line
}
test_final_recheck_line_has_no_pending_text_when_final_check_fails() {
  ew_modified_then_late_edit 3
  mkdir -p "$TMP/gitbin"
  printf '#!/bin/sh\n[ "$1" = write-tree ] && exit 1\nexec "%s" "$@"\n' "$(command -v git)" > "$TMP/gitbin/git"
  chmod +x "$TMP/gitbin/git"
  PATH="$TMP/gitbin:$PATH" run_cc wait --max 5; assert_code 3
  assert_eq "$(state .last_call.status)" "codex_modified"
  assert_eq "$(state .last_call.post_tree)" "$first_post"
  assert_contains "$(state .last_call.message)" "새 파일.txt"
  assert_contains "$(state .last_call.message)" "실행 뒤 작업 트리를 확인하지 못해"
  assert_contains "$(state .last_call.message)" "git diff $(state .last_call.pre_tree) $first_post"
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
  assert_contains "$notice" "새 파일.txt"
  assert_contains "$notice" "실행 뒤 작업 트리를 확인하지 못해"
  assert_file_exists "$ACTIVE/state.json"
  assert_eq "$(state .last_call.status)" "codex_modified"
  assert_eq "$(state .last_call.post_tree)" "$first_post"
  assert_eq "$(state .last_activity_at)" "$old"
}
test_preflight_still_auto_deletes_old_record_when_nothing_new() {
  FAKE_CODEX_SEQ=new_file:ok; start_task
  ew_fake_ps_fail_list
  PATH="$TMP/bin:$PATH" run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  set_state ".last_activity_at = \"$(ew_iso_days_ago 15)\""
  run_cc preflight
  assert_eq "$(printf '%s' "$OUT" | jq -r '.stale_notice // empty')" "[cc] 오래된 /cc 중단 기록을 정리했습니다"
  assert_no_path "$ACTIVE"
  assert_file_exists "새 파일.txt"
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
  assert_contains "$(state .last_call.message)" "실행 뒤 작업 트리를 확인하지 못해"
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
