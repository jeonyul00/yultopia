# test_call_failures.sh - Task 6: 실패 정책 (빠른 실패 1회 재실행, 형식 재요청 1회, 시간 상한, 연속 반려 상한)
#   + 감독 프로세스·state 안전 보강 (addendum A–I)
. "$CC_REPO_ROOT/plugins/yultopia/lib/cc/proc.sh"

CF_SCHEMA="$CC_REPO_ROOT/plugins/yultopia/lib/cc/pm-output.schema.json"

# ---- 이 파일 전용 도우미 (test_ 로 시작하지 않게) ----
cf_until() {
  local secs="$1" i=0; shift
  until "$@"; do
    [ "$i" -ge $((secs * 10)) ] && return 1
    sleep 0.1; i=$((i+1))
  done
}
cf_codex_recorded() { [ -n "$(state '.running.codex_pid // empty')" ]; }
cf_group_gone() { ! kill -0 -- "-$1" 2>/dev/null; }
cf_pid_gone() { ! kill -0 "$1" 2>/dev/null; }
# 가짜 codex 가 몇 번 실행됐는지
cf_invocations() { ls "$FAKE_CODEX_LOG" 2>/dev/null | grep -c '\.argv$'; }
cf_lines() { printf '%s\n' "$1" | wc -l | tr -d ' '; }
# 실행 중인 호출의 그룹을 KILL 로 끝낸다 (테스트 정리용, 자기 그룹은 건드리지 않음)
cf_reap() {
  local pg mypg
  pg=$(state '.running.pgid // empty' 2>/dev/null)
  case "$pg" in ''|*[!0-9]*|0|1) return 0 ;; esac
  mypg=$(ps -o pgid= -p $$ | tr -d ' ')
  [ "$pg" = "$mypg" ] && return 0
  kill -KILL -- "-$pg" 2>/dev/null
  cf_until 3 cf_group_gone "$pg"
}
# cf_result <verdict> <milestone|null> : 스키마에 맞는 결과 JSON 한 줄
cf_result() {
  jq -cn --arg v "$1" --argjson m "$2" '{
    verdict: $v, summary: "요약", plan: null, milestone: $m,
    instruction: (if $m == null then null else "지시" end),
    findings: (if $v == "reject" then [{file: "a.txt", line: 1, issue: "문제", evidence: "근거"}] else [] end),
    question: (if $v == "ask_user" then "질문" else null end)
  }'
}
cf_assert_failed_state() {   # <status> : 실패로 끝난 호출의 공통 상태
  assert_eq "$(cat "$CALL1/status")" "$1"
  assert_eq "$(state .running)" "null"
  assert_eq "$(state .last_call.status)" "$1"
  assert_eq "$(state .last_call.call_id)" "1"
  assert_eq "$(state .last_call.verdict)" "null"
  assert_eq "$(state .phase)" "failed"
  assert_eq "$(cf_lines "$(state .last_call.message)")" "1"
  assert_contains "$(state .last_call.message)" "[cc] "
}

# ---- 빠른 실패: 같은 인자로 1회 재실행 ----
test_fast_failure_retries_once_then_succeeds() {
  FAKE_CODEX_SEQ=fail_fast,ok; start_task
  run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "status 파일이 생기지 않음"
  assert_eq "$(cat "$CALL1/status")" "ok"
  assert_eq "$(cf_invocations)" "2"
  assert_eq "$(state .calls_total)" "2"
  assert_eq "$(cat "$FAKE_CODEX_LOG/2.argv")" "$(cat "$FAKE_CODEX_LOG/1.argv")"
  cmp -s "$FAKE_CODEX_LOG/2.stdin" "$CALL1/prompt.md" || _fail "재실행 stdin 이 prompt.md 와 다름"
  assert_eq "$(state .running)" "null"; assert_eq "$(state .phase)" "working"
  assert_eq "$(state .last_call.status)" "ok"; assert_eq "$(state .last_call.call_id)" "1"
  assert_eq "$(state .session_id)" "fake-thread-1"
  assert_eq "$(state .tokens.output)" "10"
  # 시도마다 기록이 따로 남는다: 1회차 events.jsonl/stderr.log, 2회차 events-2.jsonl/stderr-2.log
  grep -q '가짜 실행 오류' "$CALL1/stderr.log" || _fail "1회차 stderr 가 stderr.log 에 없음"
  grep -q '"thread.started"' "$CALL1/events-2.jsonl" || _fail "2회차 이벤트가 events-2.jsonl 에 없음"
  # 재실행도 호출 번호를 쓰므로 다음 호출은 3번
  printf '사용자 지시\n' > "$(cc_path message)"
  run_cc call message; assert_code 0; assert_contains "$OUT" "호출 3/"
  wait_until_status_file 3 || _fail "calls/3/status 가 생기지 않음"
  assert_eq "$(cat "$ACTIVE/calls/3/status")" "ok"
}
test_fast_failure_twice_reports_error() {
  FAKE_CODEX_SEQ=fail_fast,fail_fast,ok; start_task
  run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "status 파일이 생기지 않음"
  cf_assert_failed_state error
  assert_contains "$(state .last_call.message)" "실패"
  assert_contains "$(state .last_call.message)" "재시도"
  assert_eq "$(cf_invocations)" "2"
  assert_eq "$(state .calls_total)" "2"
}
test_fast_failure_rerun_of_resume_uses_same_argv() {
  FAKE_CODEX_SEQ=ok,fail_fast,ok; start_task
  run_cc call plan; wait_until_status_file 1
  printf '사용자 지시: 계속\n' > "$(cc_path message)"
  run_cc call message; assert_code 0
  wait_until_status_file 2 || _fail "status 파일이 생기지 않음"
  assert_eq "$(cat "$ACTIVE/calls/2/status")" "ok"
  assert_eq "$(cf_invocations)" "3"
  assert_eq "$(sed -n 2p "$FAKE_CODEX_LOG/3.argv")" "resume"
  assert_eq "$(cat "$FAKE_CODEX_LOG/3.argv")" "$(cat "$FAKE_CODEX_LOG/2.argv")"
  cmp -s "$FAKE_CODEX_LOG/3.stdin" "$FAKE_CODEX_LOG/2.stdin" || _fail "재실행 stdin 이 다름"
  assert_eq "$(state .calls_total)" "3"
}
test_late_failure_is_not_retried() {
  FAKE_CODEX_SEQ=fail_slow,ok; FAKE_CODEX_DELAY=3; CC_FAST_FAIL_SECS=1; start_task
  run_cc call plan; assert_code 0
  wait_until_status_file 1 15 || _fail "status 파일이 생기지 않음"
  cf_assert_failed_state error
  assert_contains "$(state .last_call.message)" "실패"
  assert_eq "$(cf_invocations)" "1"
  assert_eq "$(state .calls_total)" "1"
}
test_failure_that_wrote_a_result_is_not_retried() {
  FAKE_CODEX_SEQ=fail_with_output,ok; start_task
  run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "status 파일이 생기지 않음"
  cf_assert_failed_state error
  assert_eq "$(cf_invocations)" "1"
  assert_eq "$(state .calls_total)" "1"
}
test_fast_failure_retry_respects_max_calls() {
  # Ruling R3: 재실행도 호출 상한 안에서만
  export CC_MAX_CALLS=1
  FAKE_CODEX_SEQ=fail_fast,ok; start_task
  run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "status 파일이 생기지 않음"
  cf_assert_failed_state error
  assert_contains "$(state .last_call.message)" "상한 1회"
  assert_eq "$(cf_invocations)" "1"
  assert_eq "$(state .calls_total)" "1"
}

# ---- 형식 재요청: 세션이 있으면 pm-format-retry.md 로 resume 1회 ----
test_invalid_json_requests_format_once() {
  FAKE_CODEX_SEQ=invalid_json,ok; start_task
  run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "status 파일이 생기지 않음"
  assert_eq "$(cat "$CALL1/status")" "ok"
  assert_eq "$(cf_invocations)" "2"
  want=$(printf '%s\n' exec resume --json -c 'sandbox_mode="read-only"' --output-schema "$CF_SCHEMA" \
    -o "$CALL1/result.json" fake-thread-1 -)
  assert_eq "$(cat "$FAKE_CODEX_LOG/2.argv")" "$want"
  cmp -s "$FAKE_CODEX_LOG/2.stdin" "$TPL_DIR/pm-format-retry.md" || _fail "2회차 stdin 이 pm-format-retry.md 와 다름"
  assert_not_contains "$(cat "$FAKE_CODEX_LOG/2.stdin")" "{{"
  assert_eq "$(state .calls_total)" "2"
  assert_eq "$(state .phase)" "working"; assert_eq "$(state .milestone)" "1"
  assert_eq "$(state .session_id)" "fake-thread-1"
  assert_eq "$(state .last_call.status)" "ok"; assert_eq "$(state .last_call.verdict)" "plan"
  assert_eq "$(state .tokens.output)" "20"     # 두 번의 turn.completed 를 모두 센다
  assert_eq "$(state .tokens.input)" "200"
}
test_invalid_json_twice_reports_invalid_json() {
  FAKE_CODEX_SEQ=invalid_json,invalid_json,ok; start_task
  run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "status 파일이 생기지 않음"
  cf_assert_failed_state invalid_json
  assert_contains "$(state .last_call.message)" "형식"
  assert_eq "$(cf_invocations)" "2"
  assert_eq "$(state .calls_total)" "2"
  assert_eq "$(state .session_id)" "fake-thread-1"
}
test_format_retry_of_message_resumes_known_session() {
  FAKE_CODEX_SEQ=ok,invalid_json,ok; start_task
  run_cc call plan; wait_until_status_file 1
  printf '사용자 지시\n' > "$(cc_path message)"
  run_cc call message; assert_code 0
  wait_until_status_file 2 || _fail "status 파일이 생기지 않음"
  assert_eq "$(cat "$ACTIVE/calls/2/status")" "ok"
  assert_eq "$(cf_invocations)" "3"
  assert_eq "$(sed -n 2p "$FAKE_CODEX_LOG/3.argv")" "resume"
  assert_contains "$(cat "$FAKE_CODEX_LOG/3.argv")" "fake-thread-1"
  cmp -s "$FAKE_CODEX_LOG/3.stdin" "$TPL_DIR/pm-format-retry.md" || _fail "3회차 stdin 이 pm-format-retry.md 와 다름"
  assert_eq "$(state .calls_total)" "3"
}
test_invalid_json_without_session_is_not_retried() {
  FAKE_CODEX_SEQ=invalid_json_no_thread,ok; start_task
  run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "status 파일이 생기지 않음"
  cf_assert_failed_state invalid_json
  assert_contains "$(state .last_call.message)" "형식"
  assert_eq "$(cf_invocations)" "1"
  assert_eq "$(state .calls_total)" "1"
  assert_eq "$(state .session_id)" "null"
}
test_format_retry_respects_max_calls() {
  export CC_MAX_CALLS=1
  FAKE_CODEX_SEQ=invalid_json,ok; start_task
  run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "status 파일이 생기지 않음"
  cf_assert_failed_state invalid_json
  assert_contains "$(state .last_call.message)" "형식"
  assert_contains "$(state .last_call.message)" "상한 1회"
  assert_eq "$(cf_invocations)" "1"
  assert_eq "$(state .calls_total)" "1"
}

# ---- 시간 상한: 감독 프로세스가 직접 끊고 재시도하지 않는다 ----
test_timeout_kills_group_and_does_not_retry() {
  FAKE_CODEX_SEQ=hang,ok; CC_CALL_TIMEOUT_SECS=3; start_task
  t0=$SECONDS
  run_cc call plan; assert_code 0
  cf_until 5 cf_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  pg=$(state .running.pgid)
  wait_until_status_file 1 15 || _fail "status 파일이 생기지 않음"
  [ $((SECONDS - t0)) -ge 3 ] || _fail "시간 상한 전에 끝남 ($((SECONDS - t0))초)"
  cf_assert_failed_state timeout
  assert_contains "$(state .last_call.message)" "시간 초과(3초)"
  assert_contains "$(state .last_call.message)" "자동 재시도하지 않았습니다"
  assert_eq "$(cf_invocations)" "1"
  assert_eq "$(state .calls_total)" "1"
  assert_no_process_matching "fake-codex-hang:$FAKE_CODEX_LOG"     # 가짜 codex 의 자식까지 종료
  cf_until 3 cf_group_gone "$pg" || _fail "감독 프로세스 그룹이 남아 있음"
}
test_timeout_enforced_without_waiter() {
  FAKE_CODEX_SEQ=hang; CC_CALL_TIMEOUT_SECS=2; start_task
  run_cc call plan; assert_code 0
  assert_eq "$(state .waiter)" "null"
  sleep 7                                       # 아무도 기다리거나 확인하지 않는다
  assert_eq "$(cat "$CALL1/status" 2>/dev/null)" "timeout"
  assert_eq "$(state .running)" "null"
  assert_eq "$(state .last_call.status)" "timeout"
  assert_no_process_matching "fake-codex-hang:$FAKE_CODEX_LOG"
  assert_eq "$(cf_invocations)" "1"
}
test_timeout_inside_fast_fail_window_is_not_retried() {
  # Ruling R6: 시간 상한으로 끊긴 호출은 빠른 실패 구간 안이어도 timeout 이고 재시도하지 않는다
  FAKE_CODEX_SEQ=hang,ok; CC_CALL_TIMEOUT_SECS=2; CC_FAST_FAIL_SECS=60; start_task
  run_cc call plan; assert_code 0
  wait_until_status_file 1 15 || _fail "status 파일이 생기지 않음"
  cf_assert_failed_state timeout
  assert_eq "$(cf_invocations)" "1"
  assert_eq "$(state .calls_total)" "1"
}
test_format_retry_gets_its_own_full_deadline() {
  # Ruling R16: 시간 상한은 codex 실행 한 번마다. 1회차가 상한 대부분을 써도 형식 재요청은 새 상한을 받는다
  FAKE_CODEX_SEQ=slow_invalid_json,slow; FAKE_CODEX_DELAY=3; CC_CALL_TIMEOUT_SECS=4; start_task
  run_cc call plan; assert_code 0
  wait_until_status_file 1 20 || _fail "status 파일이 생기지 않음"
  assert_eq "$(cat "$CALL1/status")" "ok"
  assert_eq "$(state .last_call.status)" "ok"
  assert_eq "$(cf_invocations)" "2"
  assert_eq "$(sed -n 2p "$FAKE_CODEX_LOG/2.argv")" "resume"
}
test_hanging_format_retry_times_out_after_its_own_deadline() {
  FAKE_CODEX_SEQ=slow_invalid_json,hang,ok; FAKE_CODEX_DELAY=3; CC_CALL_TIMEOUT_SECS=4; start_task
  t0=$SECONDS
  run_cc call plan; assert_code 0
  wait_until_status_file 1 25 || _fail "status 파일이 생기지 않음"
  # 1회차 약 3초 + 2회차 자기 상한(4초 초과)이 지나야 끝난다
  [ $((SECONDS - t0)) -ge 7 ] || _fail "2회차가 자기 상한 전에 끊김 (전체 $((SECONDS - t0))초)"
  cf_assert_failed_state timeout
  assert_contains "$(state .last_call.message)" "시간 초과(4초)"
  assert_eq "$(cf_invocations)" "2"
  assert_eq "$(state .calls_total)" "2"
  assert_no_process_matching "fake-codex-hang:$FAKE_CODEX_LOG"
}
test_timeout_escalates_to_kill_for_stubborn_codex() {
  # addendum E: TERM 을 무시하는 codex 도 KILL 로 끝내고, 감독 프로세스는 살아서 timeout 을 기록한다
  FAKE_CODEX_SEQ=hang_stubborn; CC_CALL_TIMEOUT_SECS=2; start_task
  run_cc call plan; assert_code 0
  cf_until 5 cf_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  pg=$(state .running.pgid)
  pgrep -f -- "fake-codex-stubborn:$FAKE_CODEX_LOG" >/dev/null || _fail "가짜 codex 자식이 없음"
  wait_until_status_file 1 20 || _fail "status 파일이 생기지 않음"
  cf_assert_failed_state timeout
  assert_no_process_matching "fake-codex-stubborn:$FAKE_CODEX_LOG"
  cf_until 3 cf_group_gone "$pg" || _fail "감독 프로세스 그룹이 남아 있음"
}

# ---- 연속 반려 상한과 ack-rejects ----
test_review_refused_after_three_rejects() {
  start_task
  run_cc call plan; wait_until_status_file 1
  printf '%s' "$REVIEW_REPORT" > "$(cc_path report)"
  FAKE_CODEX_RESULT=$(cf_result reject 1)
  for n in 2 3 4; do
    run_cc call review; assert_code 0
    wait_until_status_file "$n" || _fail "calls/$n/status 가 생기지 않음"
    assert_eq "$(cat "$ACTIVE/calls/$n/status")" "ok"
  done
  assert_eq "$(state .rejects_in_row)" "3"
  run_cc call review; assert_code 6
  assert_eq "$(cf_lines "$OUT")" "1"; assert_contains "$OUT" "연속 반려 3회"
  assert_eq "$(state .calls_total)" "4"
  run_cc ack-rejects; assert_code 0
  assert_eq "$(cf_lines "$OUT")" "1"; assert_contains "$OUT" "[cc] "
  assert_eq "$(state .rejects_in_row)" "0"
  FAKE_CODEX_RESULT=$(cf_result approve 2)
  run_cc call review; assert_code 0
  wait_until_status_file 5 || _fail "calls/5/status 가 생기지 않음"
  assert_eq "$(state .milestone)" "2"
}
test_ack_rejects_without_active_task() {
  repo=$(make_repo); cd "$repo"
  run_cc ack-rejects; assert_code 1
  assert_eq "$(cf_lines "$OUT")" "1"; assert_contains "$OUT" "[cc] "
}

# ---- addendum D: 호출이 끝나면 감독 프로세스 그룹에 아무것도 남지 않는다 ----
test_no_leftover_processes_after_ok_call() {
  FAKE_CODEX_SEQ=ok_leave_child; start_task
  run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "status 파일이 생기지 않음"
  assert_eq "$(cat "$CALL1/status")" "ok"
  left=$(cat "$FAKE_CODEX_LOG/1.leftover" 2>/dev/null)
  [ -n "$left" ] || _fail "가짜 codex 가 남긴 자식 PID 기록이 없음"
  cf_until 2 cf_pid_gone "$left" || _fail "codex 가 남긴 자식이 아직 살아 있음 (pid $left)"
  assert_no_process_matching "fake-codex-leftover:$FAKE_CODEX_LOG"
}

# ---- addendum A: 마무리 중 신호가 더 와도 상태가 남고, status 파일과 state 가 일치한다 ----
test_terminal_state_survives_repeated_signals() {
  FAKE_CODEX_SEQ=hang; start_task
  run_cc call plan; assert_code 0
  cf_until 5 cf_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  pg=$(state .running.pgid)
  i=0
  while kill -0 "$pg" 2>/dev/null && [ "$i" -lt 400 ]; do
    case $((i % 3)) in 0) s=TERM ;; 1) s=INT ;; *) s=HUP ;; esac
    kill -"$s" "$pg" 2>/dev/null
    sleep 0.01; i=$((i + 1))
  done
  wait_until_status_file 1 5 || _fail "status 파일이 생기지 않음"
  assert_eq "$(cat "$CALL1/status")" "interrupted"
  assert_eq "$(state .running)" "null"
  assert_eq "$(state .last_call.status)" "interrupted"
  assert_eq "$(state .phase)" "interrupted"
  cf_until 3 cf_group_gone "$pg" || _fail "그룹이 남아 있음"
  assert_no_process_matching "fake-codex-hang:$FAKE_CODEX_LOG"
}
test_status_file_follows_state_already_recorded_for_call() {
  # 다른 쪽(예: wait 의 중단 처리)이 이미 이 호출을 끝난 것으로 기록했으면 status 파일도 그 값을 쓴다
  FAKE_CODEX_SEQ=slow; FAKE_CODEX_DELAY=3; start_task
  run_cc call plan; assert_code 0
  cf_until 5 cf_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  cc_state_update '.running = null | .phase = "interrupted"
    | .last_call = {call_id: 1, kind: "plan", status: "interrupted", verdict: null, message: "[cc] 중단됨"}' \
    || _fail "state 갱신 실패"
  wait_until_status_file 1 10 || _fail "status 파일이 생기지 않음"
  assert_eq "$(cat "$CALL1/status")" "interrupted"
  assert_eq "$(state .last_call.status)" "interrupted"
  assert_eq "$(state .phase)" "interrupted"
  assert_eq "$(state .tokens.output)" "0"
}

# ---- addendum B: 감독 프로세스는 없지만 그룹에 무언가 살아 있으면 실행 중으로 본다 ----
test_call_refuses_when_dead_supervisor_group_still_has_members() {
  start_task
  ids=$(perl -MPOSIX -e '
    POSIX::setsid() or die "setsid: $!";
    my $p = fork; die "fork: $!" unless defined $p;
    if ($p == 0) {
      open STDOUT, ">", "/dev/null"; open STDERR, ">", "/dev/null";
      exec "perl", "-e", "sleep 60", "orphan-member-$ENV{TMP}" or POSIX::_exit(1);
    }
    print "$$ $p\n"; exit 0')
  pg=${ids% *}; member=${ids#* }
  cf_until 3 cf_pid_gone "$pg" || _fail "그룹 리더가 끝나지 않음"
  kill -0 -- "-$pg" 2>/dev/null || _fail "그룹에 멤버가 없음"
  set_state ".running = {call_id: 9, kind: \"plan\", pgid: $pg,
    supervisor_identity: \"Thu Jan  1 00:00:00 2020|bash gone\", codex_pid: null, codex_identity: null,
    started_at: \"2020-01-01T00:00:00Z\", review_tree: null}"
  run_cc call plan; assert_code 6
  assert_eq "$(cf_lines "$OUT")" "1"; assert_contains "$OUT" "실행 중"
  assert_eq "$(state .calls_total)" "0"
  assert_no_path "$CALL1"
  kill -0 "$member" 2>/dev/null || _fail "확인되지 않은 프로세스를 죽임"
  kill "$member" 2>/dev/null
}

# ---- addendum C: exec 확인이 늦어도 codex 신원 기록을 포기하지 않는다 ----
# (Task 5 의 첫 확인 구간은 ps 호출을 포함해 실제로 7~8초 걸리므로 그보다 늦게 exec 한다)
cf_slow_exec_codex() { sleep 11; exec perl -e 'sleep 1' "slow-exec-codex:$TMP"; }
test_codex_identity_recorded_even_when_exec_is_late() {
  start_task
  . "$CC_REPO_ROOT/plugins/yultopia/lib/cc/render.sh"
  . "$CC_REPO_ROOT/plugins/yultopia/lib/cc/call.sh"
  set_state '.calls_total = 1 | .running = {call_id: 1, kind: "plan", pgid: 1, supervisor_identity: "x|y",
    codex_pid: null, codex_identity: null, started_at: "2026-01-01T00:00:00Z", review_tree: null}'
  _CC_SUP_ID=1; _CC_SUP_ACTIVE="$ACTIVE"; _CC_SUP_DIR="$ACTIVE/calls/1"
  mkdir -p "$_CC_SUP_DIR"; printf '프롬프트\n' > "$_CC_SUP_DIR/prompt.md"
  CC_CODEX_BIN=cf_slow_exec_codex
  _cc_sup_run_codex exec - "$_CC_SUP_DIR/prompt.md" >> "$TMP/sup.log" 2>&1
  assert_contains "$(state '.running.codex_identity // empty')" "slow-exec-codex:$TMP"
  assert_eq "$(state '.running.codex_pid | type')" "number"
}

# ---- addendum G: 손으로 고친 state 의 이상한 카운터 ----
test_call_rejects_non_integer_counters() {
  start_task
  for v in '"x"' '1.5' '-1' 'null' '1e300'; do
    set_state ".calls_total = $v"
    run_cc call plan; assert_code 1
    assert_eq "$(cf_lines "$OUT")" "1" "calls_total=$v"
    assert_contains "$OUT" "상태 파일"
    assert_not_contains "$ERR" "syntax error"
    assert_no_path "$ACTIVE/state.lock"
  done
  set_state '.calls_total = 0 | .session_id = "fake-thread-1"'
  printf '%s' "$REVIEW_REPORT" > "$(cc_path report)"
  for v in '"x"' '2.5' '-3'; do
    set_state ".rejects_in_row = $v"
    run_cc call review; assert_code 1
    assert_eq "$(cf_lines "$OUT")" "1" "rejects_in_row=$v"
    assert_contains "$OUT" "상태 파일"
  done
  assert_eq "$(cf_invocations)" "0"
  [ ! -d "$ACTIVE/calls" ] || assert_eq "$(ls -A "$ACTIVE/calls" | wc -l | tr -d ' ')" "0"
}

# ---- addendum I: 같은 작업에서 동시에 두 번 call ----
test_concurrent_calls_start_exactly_one() {
  FAKE_CODEX_SEQ=hang,hang; start_task
  ( bash "$CC_BIN" call plan > "$TMP/c1.out" 2>/dev/null; echo $? > "$TMP/c1.code" ) &
  ( bash "$CC_BIN" call plan > "$TMP/c2.out" 2>/dev/null; echo $? > "$TMP/c2.code" ) &
  wait
  codes=$(cat "$TMP/c1.code" "$TMP/c2.code" | sort | tr '\n' ' ')
  assert_eq "$codes" "0 6 "
  cf_until 5 cf_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  sleep 1
  assert_eq "$(grep -c '감독 시작' "$ACTIVE/supervisor.log")" "1"
  assert_eq "$(cf_invocations)" "1"
  assert_eq "$(pgrep -f -- "fake-codex-hang:$FAKE_CODEX_LOG" | wc -l | tr -d ' ')" "1"
  assert_eq "$(state .calls_total)" "1"
  cf_reap
}
