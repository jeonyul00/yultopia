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
# cf_want_format_retry <kind> [결과 파일 내용] : 그 결과(기본 "not json")를 받았을 때 감독 프로세스가 보낼 형식 재요청
#   프롬프트를 $TMP/want-retry.md 에 만든다 (Codex 리뷰 4: 무엇이 틀렸는지 이유를 넣는다)
cf_want_format_retry() {
  ( . "$CC_REPO_ROOT/plugins/yultopia/lib/cc/render.sh"; . "$CC_REPO_ROOT/plugins/yultopia/lib/cc/call.sh"
    printf '%s\n' "${2:-not json}" > "$TMP/bad-result.json"
    CC_T_REASON=$(cc_result_problem "$TMP/bad-result.json" "$1"); [ -n "$CC_T_REASON" ] || exit 1
    export CC_T_REASON
    cc_render "$TPL_DIR/pm-format-retry.md" "$TMP/want-retry.md" )
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
  want=$(printf '%s\n' exec resume --json -c 'sandbox_mode="workspace-write"' --output-schema "$CF_SCHEMA" \
    -o "$CALL1/result.json" fake-thread-1 -)
  assert_eq "$(cat "$FAKE_CODEX_LOG/2.argv")" "$want"
  cf_want_format_retry plan && cmp -s "$FAKE_CODEX_LOG/2.stdin" "$TMP/want-retry.md" || _fail "2회차 stdin 이 이유를 넣은 pm-format-retry.md 와 다름"
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
  cf_want_format_retry message && cmp -s "$FAKE_CODEX_LOG/3.stdin" "$TMP/want-retry.md" || _fail "3회차 stdin 이 이유를 넣은 pm-format-retry.md 와 다름"
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
  # wait 명령은 부르지 않는다. 테스트는 status 파일만 지켜본다 (대기자 없음)
  wait_until_status_file 1 10 || _fail "대기자 없이 시간 상한이 지켜지지 않음"
  assert_eq "$(state .waiter)" "null"
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
  #   (각 시도 약 3초 < 5초, 합계 약 6초 > 5초)
  FAKE_CODEX_SEQ=slow_invalid_json,slow; FAKE_CODEX_DELAY=3; CC_CALL_TIMEOUT_SECS=5; start_task
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
  assert_contains "$OUT" "진행 중인 작업이 없습니다"
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
# exec 한 뒤에는 신원이 state 에 기록될 때까지(최대 약 15초) 살아 있는다: 바쁜 기계에서 1초 안에 기록하지 못해
# 기록 전에 끝나 버리는 일이 없도록 (최종 리뷰 minor a). 신원 앞 200자 안에 표시가 들어가도록 스크립트는 파일로 둔다.
cf_slow_exec_codex() { sleep 11; exec perl "$TMP/cf-wait-recorded.pl" "slow-exec-codex:$TMP"; }
test_codex_identity_recorded_even_when_exec_is_late() {
  start_task
  . "$CC_REPO_ROOT/plugins/yultopia/lib/cc/snapshot.sh"   # 감독 프로세스는 codex 실행 전후 작업 트리를 뜬다 (R31/R32)
  . "$CC_REPO_ROOT/plugins/yultopia/lib/cc/render.sh"
  . "$CC_REPO_ROOT/plugins/yultopia/lib/cc/call.sh"
  printf '%s\n' 'my $f = $ENV{CF_STATE_FILE};' \
    'for (1 .. 150) { if (open my $h, "<", $f) { local $/; exit 0 if <$h> =~ /slow-exec-codex/ } select undef, undef, undef, 0.1 }' \
    'exit 0' > "$TMP/cf-wait-recorded.pl"
  export CF_STATE_FILE="$ACTIVE/state.json"
  # 감독 프로세스 대역은 이 테스트 셸이다: running.pgid 를 이 셸($$)로 둔다 (감독 프로세스는 자기 기록만 고친다)
  set_state ".calls_total = 1 | .running = {call_id: 1, kind: \"plan\", pgid: $$, supervisor_identity: \"x|y\",
    codex_pid: null, codex_identity: null, started_at: \"2026-01-01T00:00:00Z\", review_tree: null}"
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

# ---- Task 7 addendum C: 그룹 정리를 할 수 없을 때도 TERM 을 무시하는 codex 를 KILL 까지 한다 ----
test_timeout_fallback_kills_term_ignoring_codex() {
  FAKE_CODEX_SEQ=hang_stubborn; start_task
  . "$CC_REPO_ROOT/plugins/yultopia/lib/cc/snapshot.sh"   # 감독 프로세스는 codex 실행 전후 작업 트리를 뜬다 (R31/R32)
  . "$CC_REPO_ROOT/plugins/yultopia/lib/cc/render.sh"
  . "$CC_REPO_ROOT/plugins/yultopia/lib/cc/call.sh"
  # 테스트 전용 대역: 그룹 정리가 거부된 상황(ps 실패 등)을 만든다. 이 테스트 셸 안에서만 바뀐다
  cc_kill_own_group_members() { return 2; }
  # 감독 프로세스 대역은 이 테스트 셸이다: running.pgid 를 이 셸($$)로 둔다 (감독 프로세스는 자기 기록만 고친다)
  set_state ".calls_total = 1 | .running = {call_id: 1, kind: \"plan\", pgid: $$, supervisor_identity: \"x|y\",
    codex_pid: null, codex_identity: null, started_at: \"2026-01-01T00:00:00Z\", review_tree: null}"
  _CC_SUP_ID=1; _CC_SUP_ACTIVE="$ACTIVE"; _CC_SUP_DIR="$ACTIVE/calls/1"; _CC_SUP_CLAIMED=1; _CC_SUP_TIMED_OUT=0
  mkdir -p "$_CC_SUP_DIR"; printf '프롬프트\n' > "$_CC_SUP_DIR/prompt.md"
  CC_CALL_TIMEOUT_SECS=1; _cc_sup_init_config
  _cc_sup_run_codex exec - "$_CC_SUP_DIR/prompt.md" >> "$TMP/sup.log" 2>&1
  assert_eq "$_CC_SUP_TIMED_OUT" "1"
  cp=$(state '.running.codex_pid // empty')
  [ -n "$cp" ] || _fail "codex_pid 가 기록되지 않음"
  cf_until 3 cf_pid_gone "$cp" || _fail "그룹 정리가 거부되자 TERM 을 무시하는 codex 가 계속 살아 있음 (pid $cp)"
  grep -q '그룹 정리를 하지 못함' "$TMP/sup.log" || _fail "대역이 쓰이지 않음 (테스트 전제 깨짐)"
  pkill -KILL -f -- "fake-codex-stubborn:$FAKE_CODEX_LOG" 2>/dev/null
  [ -n "$cp" ] && kill -KILL "$cp" 2>/dev/null
  return 0
}

# ---- Task 7 addendum D: codex 인자를 못 만들면(아무것도 실행하지 않음) 빠른 실패로 재실행하지 않는다 ----
test_argv_build_failure_is_not_retried() {
  start_task
  set_state '.session_id = "bad session id"'      # resume 인자로 쓸 수 없는 세션 ID
  printf '사용자 지시\n' > "$(cc_path message)"
  run_cc call message; assert_code 0
  wait_until_status_file 1 || _fail "status 파일이 생기지 않음"
  cf_assert_failed_state error
  assert_contains "$(state .last_call.message)" "인자"
  assert_not_contains "$(state .last_call.message)" "재시도"
  assert_eq "$(cf_invocations)" "0"
  assert_eq "$(state .calls_total)" "1"
}

# ---- 최종 리뷰 minor d: 감독 프로세스는 call_id 뿐 아니라 pgid 까지 자기 것인 running 만 고친다 ----
#   (오래된 감독 프로세스가 같은 호출 번호를 쓰는 새 작업의 state 에 쓰지 않도록)
cf_source_call() {
  . "$CC_REPO_ROOT/plugins/yultopia/lib/cc/snapshot.sh"   # 감독 프로세스는 codex 실행 전후 작업 트리를 뜬다 (R31/R32)
  . "$CC_REPO_ROOT/plugins/yultopia/lib/cc/render.sh"
  . "$CC_REPO_ROOT/plugins/yultopia/lib/cc/call.sh"
}
test_supervisor_leaves_same_call_id_with_other_pgid_untouched() {
  start_task; cf_source_call
  other=$(( $$ + 100000 ))
  set_state ".calls_total = 1 | .running = {call_id: 1, kind: \"plan\", pgid: $other, supervisor_identity: \"x|y\",
    codex_pid: null, codex_identity: null, started_at: \"2026-01-01T00:00:00Z\", review_tree: null}"
  before=$(jq -cS 'del(.last_activity_at)' "$ACTIVE/state.json")
  _CC_SUP_ID=1; _CC_SUP_ACTIVE="$ACTIVE"; _CC_SUP_DIR="$ACTIVE/calls/1"; mkdir -p "$_CC_SUP_DIR"
  _cc_sup_init_config; _CC_SUP_ATTEMPT=1
  # codex 신원 기록
  _cc_sup_set_codex_identity 4242 "Thu Jan  1 00:00:00 2020|codex" >/dev/null 2>&1
  assert_eq "$(state .running.codex_pid)" "null" "codex 신원 기록"
  # 재시도 호출 수 더하기
  _cc_sup_next_attempt; rc=$?
  assert_eq "$rc" "2" "재시도 거부 코드"
  assert_eq "$(state .calls_total)" "1"
  # 결과 반영
  printf '%s\n' "$(cf_result approve 1)" > "$_CC_SUP_DIR/result.json"
  _cc_sup_finish ok "" >/dev/null 2>&1
  assert_eq "$(jq -cS 'del(.last_activity_at)' "$ACTIVE/state.json")" "$before" "state 가 바뀜"
  # 같은 기록이 이 셸(pgid=$$)을 가리키면 평소처럼 반영한다
  set_state ".running.pgid = $$"
  _CC_SUP_FINAL=""; _cc_sup_finish ok "" >/dev/null 2>&1
  assert_eq "$(state .running)" "null"
  assert_eq "$(state .last_call.verdict)" "approve"
}
test_running_supervisor_does_not_finish_into_record_with_other_pgid() {
  FAKE_CODEX_SEQ=slow; FAKE_CODEX_DELAY=3; start_task
  run_cc call plan; assert_code 0
  cf_until 5 cf_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  pg=$(state .running.pgid)
  # 실행 중에 running 이 같은 번호의 다른 그룹 기록으로 바뀐다
  cc_state_update ".running.pgid = $(( pg + 100000 ))" || _fail "state 갱신 실패"
  wait_until_status_file 1 10 || _fail "status 파일이 생기지 않음"
  cf_until 5 cf_group_gone "$pg" || _fail "감독 프로세스가 끝나지 않음"
  assert_eq "$(state .running.call_id)" "1"
  assert_eq "$(state .running.pgid)" "$(( pg + 100000 ))"
  assert_eq "$(state .last_call)" "null"
  assert_eq "$(state .tokens.output)" "0"
  assert_eq "$(state .session_id)" "null"
}

# ---- 최종 리뷰 minor g: 호출 폴더를 지우기 전에 calls 나 그 번호 폴더가 심볼릭 링크면 거부한다 ----
test_call_refuses_symlinked_calls_dir() {
  start_task
  mkdir -p "$TMP/elsewhere/1"; printf 'keep\n' > "$TMP/elsewhere/1/keep.txt"
  rm -rf "$ACTIVE/calls"; ln -s "$TMP/elsewhere" "$ACTIVE/calls"
  run_cc call plan; assert_code 1
  assert_eq "$(cf_lines "$OUT")" "1"; assert_contains "$OUT" "비정상"
  assert_file_exists "$TMP/elsewhere/1/keep.txt"
  assert_eq "$(state .calls_total)" "0"; assert_eq "$(state .running)" "null"
  assert_eq "$(cf_invocations)" "0"
}
test_call_refuses_symlinked_call_dir() {
  start_task
  mkdir -p "$TMP/elsewhere"; printf 'keep\n' > "$TMP/elsewhere/keep.txt"
  ln -s "$TMP/elsewhere" "$ACTIVE/calls/1"
  run_cc call plan; assert_code 1
  assert_eq "$(cf_lines "$OUT")" "1"; assert_contains "$OUT" "비정상"
  assert_file_exists "$TMP/elsewhere/keep.txt"
  [ -L "$ACTIVE/calls/1" ] || _fail "심볼릭 링크가 사라짐"
  assert_eq "$(state .calls_total)" "0"; assert_eq "$(cf_invocations)" "0"
}

# ---- Codex 리뷰 4 (R30): 스키마에는 맞지만 절차가 쓸 수 없는 결과는 이유를 알려 한 번 다시 받는다 ----
test_unusable_plan_result_gets_one_retry_that_names_the_problem() {
  FAKE_CODEX_SEQ=ok_unusable,ok; start_task
  run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "status 파일이 생기지 않음"
  assert_eq "$(cat "$CALL1/status")" "ok"
  assert_eq "$(cf_invocations)" "2"
  assert_eq "$(sed -n 2p "$FAKE_CODEX_LOG/2.argv")" "resume"
  retry=$(cat "$FAKE_CODEX_LOG/2.stdin")
  assert_contains "$retry" "마일스톤"
  assert_contains "$retry" "JSON"
  assert_not_contains "$retry" "{{"
  unusable='{"verdict":"plan","summary":"빈 계획","plan":{"overview":"o","milestones":[]},"milestone":null,"instruction":null,"findings":[],"question":null}'
  cf_want_format_retry plan "$unusable" && cmp -s "$FAKE_CODEX_LOG/2.stdin" "$TMP/want-retry.md" || _fail "형식 재요청 프롬프트에 이유가 들어가지 않음"
  assert_eq "$(state .last_call.verdict)" "plan"
  assert_eq "$(state .phase)" "working"; assert_eq "$(state .milestone)" "1"
  assert_eq "$(state .milestones_total)" "2"
}
test_plan_call_answered_with_done_ends_as_invalid_not_done() {
  FAKE_CODEX_RESULT=$(cf_result done null); start_task
  run_cc call plan; assert_code 0
  wait_until_status_file 1 || _fail "status 파일이 생기지 않음"
  cf_assert_failed_state invalid_json
  assert_eq "$(cf_invocations)" "2"
  assert_contains "$(state .last_call.message)" "형식"
  assert_contains "$(state .last_call.message)" "plan"
  assert_eq "$(cf_lines "$(state .last_call.message)")" "1"
  assert_eq "$(state .milestone)" "null"
}
test_review_ask_user_without_question_is_not_accepted() {
  start_task
  run_cc call plan; wait_until_status_file 1 || _fail "계획 호출이 끝나지 않음"
  printf '%s' "$REVIEW_REPORT" > "$(cc_path report)"
  FAKE_CODEX_RESULT=$(cf_result ask_user null | jq -c '.question = null')
  run_cc call review; assert_code 0
  wait_until_status_file 2 || _fail "status 파일이 생기지 않음"
  assert_eq "$(cat "$ACTIVE/calls/2/status")" "invalid_json"
  assert_eq "$(state .last_call.status)" "invalid_json"
  assert_eq "$(state .phase)" "failed"
  assert_contains "$(cat "$FAKE_CODEX_LOG/3.stdin")" "question"
  assert_eq "$(state .milestone)" "1"
}

# ---- Codex 리뷰 1 (R30): 종료를 확인하지 못하면 끝 상태는 기록하되 running(프로세스 기록)은 지우지 않는다 ----
# 가짜 ps: 전체 목록(-A)만 실패 → 감독 프로세스가 자기 그룹을 정리하지 못한다 (codex 하나만 신원 확인 후 끝낸다)
cf_fake_ps_fail_list() {
  mkdir -p "$TMP/bin"
  printf '#!/bin/sh\ncase " $* " in *" -A "*) exit 1 ;; esac\nexec /bin/ps "$@"\n' > "$TMP/bin/ps"
  chmod +x "$TMP/bin/ps"
}
test_timeout_keeps_process_record_when_group_cleanup_is_unconfirmed() {
  FAKE_CODEX_SEQ=hang; CC_CALL_TIMEOUT_SECS=2; CC_ORPHAN_GRACE_SECS=1; start_task
  cf_fake_ps_fail_list
  PATH="$TMP/bin:$PATH" run_cc call plan; assert_code 0
  cf_until 5 cf_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  pg=$(state .running.pgid); cx=$(state .running.codex_pid)
  wait_until_status_file 1 20 || _fail "status 파일이 생기지 않음"
  assert_eq "$(cat "$CALL1/status")" "timeout"
  # 끝 상태(wait 가 돌려줄 결과)는 기록한다
  assert_eq "$(state .last_call.status)" "timeout"; assert_eq "$(state .last_call.call_id)" "1"
  assert_eq "$(state .phase)" "failed"
  assert_contains "$(state .last_call.message)" "시간 초과"
  assert_contains "$(state .last_call.message)" "ps -o pid,command -g $pg"
  assert_contains "$(state .last_call.message)" "다시 확인"      # Codex 리뷰 1차 2: 파일 변경 확인은 끝난 뒤 다시
  assert_eq "$(cf_lines "$(state .last_call.message)")" "1"
  # 프로세스 기록은 남긴다
  assert_eq "$(state .running.call_id)" "1"; assert_eq "$(state .running.pgid)" "$pg"
  assert_eq "$(state .running.codex_pid)" "$cx"
  assert_eq "$(state .running.stop_failed)" "true"
  # 감독 프로세스는 끝나지만, 확인할 수 없는 프로세스(가짜 codex 의 자식)가 그룹에 남는다
  cf_until 8 cf_pid_gone "$pg" || _fail "감독 프로세스가 끝나지 않음"
  pgrep -f -- "fake-codex-hang:$FAKE_CODEX_LOG" >/dev/null || _fail "남은 자식이 없음 (테스트 전제 깨짐)"
  # wait 는 기다리지 않고 기록된 결과를 한 줄로 돌려준다
  t0=$SECONDS
  run_cc wait --max 10; assert_code 3
  [ $((SECONDS - t0)) -lt 5 ] || _fail "wait 가 끝난 호출을 계속 기다림"
  assert_eq "$(cf_lines "$OUT")" "1"; assert_eq "$OUT" "$(state .last_call.message)"
  # 새 호출·버리기·마무리는 거부하고, 고아 확인·훅은 남은 프로세스를 계속 알린다 (아무것도 죽이지 않음)
  run_cc call plan; assert_code 6
  assert_eq "$(cf_lines "$OUT")" "1"; assert_contains "$OUT" "ps -o pid,command -g $pg"
  run_cc discard; assert_code 6; assert_contains "$OUT" "프로세스 그룹 $pg"
  run_cc finish; assert_code 6
  assert_file_exists "$ACTIVE/state.json"
  sleep 2.2
  run_cc check-orphan; assert_code 10; assert_contains "$OUT" "프로세스 그룹 $pg"
  ctx=$(printf '{"cwd":"%s"}' "$PWD" | bash "$HOOK" prompt-submit 2>/dev/null)
  assert_contains "$ctx" "ps -o pid,command -g $pg"
  pgrep -f -- "fake-codex-hang:$FAKE_CODEX_LOG" >/dev/null || _fail "확인되지 않은 프로세스를 죽임"
  assert_eq "$(state .running.stop_failed)" "true"
  # 남은 것이 정말 사라지면 기록만 정리한다: 이미 기록한 끝 상태(timeout)는 그대로 둔다
  pkill -KILL -f -- "fake-codex-hang:$FAKE_CODEX_LOG"
  cf_until 3 cf_group_gone "$pg" || _fail "그룹이 끝나지 않음"
  run_cc check-orphan; assert_code 0
  assert_eq "$(state .running)" "null"
  assert_eq "$(state .last_call.status)" "timeout"; assert_eq "$(state .phase)" "failed"
  assert_contains "$(state .last_call.message)" "바뀐 프로젝트 파일 없음"
  assert_eq "$(cat "$CALL1/status")" "timeout"
  run_cc call plan; assert_code 0
  wait_until_status_file 2 || _fail "다음 호출이 끝나지 않음"
}
# 감독 프로세스 대역(이 테스트 셸)으로 _cc_sup_main 을 돌리되, 그룹 정리 결과만 CF_STOP_RC 로 바꾼다.
#   대역은 실제로 남은 가짜 codex 를 끝내 테스트가 프로세스를 남기지 않게 한다.
cf_sup_standin_run() {   # <stop rc> <timeout|normal>
  CF_STOP_RC=$1
  _cc_sup_stop_group() {
    pkill -KILL -f -- "fake-codex-hang:$FAKE_CODEX_LOG" 2>/dev/null
    [ -n "${1:-}" ] && kill -KILL "$1" 2>/dev/null
    return "$CF_STOP_RC"
  }
  set_state ".calls_total = 1 | .running = {call_id: 1, kind: \"plan\", pgid: $$, supervisor_identity: \"x|y\",
    codex_pid: null, codex_identity: null, started_at: \"2026-01-01T00:00:00Z\", review_tree: null}"
  _CC_SUP_ID=1; _CC_SUP_ACTIVE="$ACTIVE"; _CC_SUP_DIR="$ACTIVE/calls/1"; _CC_SUP_CLAIMED=1
  _CC_SUP_DONE=0; _CC_SUP_SIGNAL=""; _CC_SUP_CODEX_PID=""; _CC_SUP_CODEX_IDENT=""; _CC_SUP_FINAL=""
  _CC_SUP_CODEX_RECORDED=0; _CC_SUP_ATTEMPT=1; _CC_SUP_ATTEMPT_SECS=0; _CC_SUP_T0=""; _CC_SUP_TIMED_OUT=0
  _CC_SUP_REC=""; _CC_SUP_NO_START=0
  _CC_SUP_RUNNING='{"call_id":1,"kind":"plan"}'
  mkdir -p "$_CC_SUP_DIR"; printf '프롬프트\n' > "$_CC_SUP_DIR/prompt.md"
  _cc_sup_init_config
  _cc_sup_main >> "$TMP/sup-$2-$1.log" 2>&1
}
test_supervisor_keeps_process_record_when_stop_is_not_confirmed() {
  for rc in 2 3; do
    for how in timeout normal; do
      (
        FAKE_CODEX_LOG="$TMP/fc-$how-$rc"
        if [ "$how" = timeout ]; then FAKE_CODEX_SEQ=hang; CC_CALL_TIMEOUT_SECS=1; else FAKE_CODEX_SEQ=ok; fi
        start_task "sup-$how-$rc"; cf_source_call
        cf_sup_standin_run "$rc" "$how"
        # Codex 리뷰 1차 (R32) 2: 그룹이 비었는지 확인하지 못하면 결과를 반영하지 않는다 (정상 응답이어도 error)
        want=error; [ "$how" = timeout ] && want=timeout
        assert_eq "$(cat "$CALL1/status" 2>/dev/null)" "$want" "$how/$rc status 파일"
        assert_eq "$(state .last_call.status)" "$want" "$how/$rc last_call"
        assert_eq "$(state .last_call.call_id)" "1"
        assert_contains "$(state .last_call.message)" "ps -o pid,command -g $$"
        assert_eq "$(cf_lines "$(state .last_call.message)")" "1"
        assert_eq "$(state .running.call_id)" "1" "$how/$rc running 이 지워짐"
        assert_eq "$(state .running.pgid)" "$$"
        assert_eq "$(state .running.stop_failed)" "true"
        assert_eq "$(state .last_call.verdict)" "null" "$how/$rc verdict"
        assert_eq "$(state .phase)" "failed" "$how/$rc phase"; assert_eq "$(state .milestone)" "null" "$how/$rc milestone"
        [ -n "$(state '.running.pre_tree // empty')" ] || _fail "$how/$rc: running.pre_tree 가 없음"
        assert_contains "$(state .last_call.message)" "다시 확인"
        [ "$how" = normal ] && assert_contains "$(state .last_call.message)" "결과를 반영하지 않았"
        grep -q '반영하지 못함' "$TMP/sup-$how-$rc.log" && _fail "$how/$rc: 결과 반영을 되풀이함"
        # wait 는 기록된 결과를 곧바로 돌려준다
        run_cc wait --max 5; assert_code 3; assert_eq "$OUT" "$(state .last_call.message)"
        [ "$how" = timeout ] && assert_contains "$OUT" "시간 초과"
        # 이 대역 기록은 확인상 끝난 것(dead)이다: 정리할 때 저장된 pre 로 다시 비교하고(바뀐 것 없음) running 을 지운다.
        #   끝 상태는 그대로 둔다
        run_cc check-orphan; assert_code 0
        assert_eq "$(state .running)" "null"
        assert_eq "$(state .last_call.status)" "$want" "$how/$rc 정리 뒤 끝 상태"
        assert_contains "$(state .last_call.message)" "바뀐 프로젝트 파일 없음"
      )
    done
  done
  return 0
}

# ---- Codex 리뷰 1차 (R32) 3: 실행 전 트리를 running 에 남기지 못하면 codex 를 실행하지 않는다 ----
test_codex_not_started_when_pre_tree_cannot_be_recorded() {
  start_task; cf_source_call
  # running 이 이 감독 프로세스(이 테스트 셸, pgid=$$)를 가리키지 않으면 기록할 수 없다
  set_state ".calls_total = 1 | .running = {call_id: 1, kind: \"plan\", pgid: $(( $$ + 100000 )), supervisor_identity: \"x|y\",
    codex_pid: null, codex_identity: null, started_at: \"2026-01-01T00:00:00Z\", review_tree: null}"
  _CC_SUP_ID=1; _CC_SUP_ACTIVE="$ACTIVE"; _CC_SUP_DIR="$ACTIVE/calls/1"; _CC_SUP_ATTEMPT=1
  mkdir -p "$_CC_SUP_DIR"; printf '프롬프트\n' > "$_CC_SUP_DIR/prompt.md"
  _cc_sup_init_config
  _cc_sup_run_codex exec - "$_CC_SUP_DIR/prompt.md" >> "$TMP/sup.log" 2>&1; rc=$?
  assert_eq "$rc" "125"
  assert_eq "$_CC_SUP_NO_START" "1"
  assert_eq "$(cf_invocations)" "0"
  assert_eq "$(state '.running.pre_tree // "none"')" "none"
  grep -q '기록하지 못함' "$TMP/sup.log" || _fail "기록 실패 로그가 없음"
}
