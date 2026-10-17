# test_wait.sh - Task 7: wait (한 줄 상태 또는 최종 JSON) 와 중단 신호 처리 (+ addendum A, B)
. "$CC_REPO_ROOT/plugins/yultopia/lib/cc/proc.sh"

# ---- 이 파일 전용 도우미 (test_ 로 시작하지 않게) ----
wt_until() {
  local secs="$1" i=0; shift
  until "$@"; do
    [ "$i" -ge $((secs * 10)) ] && return 1
    sleep 0.1; i=$((i+1))
  done
}
wt_codex_recorded() { [ -n "$(state '.running.codex_pid // empty')" ]; }
wt_group_alive() { kill -0 -- "-$1" 2>/dev/null; }
wt_invocations() { ls "$FAKE_CODEX_LOG" 2>/dev/null | grep -c '\.argv$'; }
wt_lines() { printf '%s\n' "$1" | wc -l | tr -d ' '; }
wt_ms() { perl -MTime::HiRes -e 'printf "%d\n", Time::HiRes::time() * 1000'; }
# wait 를 백그라운드로 띄운다 (WP = 그 PID, 출력은 $TMP/w.out).
#   비대화형 bash 의 `&` 작업은 SIGINT 를 무시한 채 시작하고, 시작할 때 무시된 신호는 trap 으로 되살릴 수 없다.
#   실제 Claude Code 는 대기 명령을 포그라운드로 돌리므로, 같은 조건이 되도록 perl 로 SIGINT 를 기본값으로 되돌려 실행한다.
#   WT_WAITER_PATH 를 주면 그 PATH 로 실행한다 (가짜 ps 등). WT_OUT 을 주면 출력 파일 이름 앞부분 (기본 w)
wt_start_waiter() {
  local o="${WT_OUT:-w}"
  FAKE_CODEX_LOG="${FAKE_CODEX_LOG:-$TMP/fake-codex.log}" PATH="${WT_WAITER_PATH:-$PATH}" \
    perl -e '$SIG{INT} = "DEFAULT"; exec { $ARGV[0] } @ARGV or exit 127' bash "$CC_BIN" wait "$@" \
    > "$TMP/$o.out" 2> "$TMP/$o.err" &
  WP=$!
}
wt_waiter_registered() { [ "$(state '.waiter.pid // empty')" = "$WP" ]; }
# 실행 중인 호출의 그룹을 KILL 로 끝낸다 (테스트 정리용, 자기 그룹은 건드리지 않음)
wt_reap() {
  local pg mypg
  pg=$(state '.running.pgid // empty' 2>/dev/null)
  case "$pg" in ''|*[!0-9]*|0|1) return 0 ;; esac
  mypg=$(ps -o pgid= -p $$ | tr -d ' ')
  [ "$pg" = "$mypg" ] && return 0
  kill -KILL -- "-$pg" 2>/dev/null
  wt_until 3 eval '! wt_group_alive "$pg"'
}
# 끝 상태가 일관적인지: status 파일 == last_call.status, running=null, phase
wt_assert_terminal() {   # <call_id> <status> <phase>
  assert_eq "$(cat "$ACTIVE/calls/$1/status" 2>/dev/null)" "$2" "status 파일"
  assert_eq "$(state .last_call.status)" "$2"
  assert_eq "$(state .last_call.call_id)" "$1"
  assert_eq "$(state .running)" "null"
  assert_eq "$(state .phase)" "$3"
}
# 감독 프로세스 대역: 새 그룹의 리더로 오래 사는 프로세스를 띄워 running 에 기록한다 (state 를 바꾸는 쪽이 없다)
wt_fake_running() {   # <started_at> <last_activity_at>
  local pg id
  pg=$(cc_spawn_group "$TMP/fake-sup.log" perl -e 'sleep 60' "fake-supervisor-$TMP") || return 1
  id=$(cc_proc_identity "$pg") || return 1
  FAKE_SUP_PG=$pg
  mkdir -p "$ACTIVE/calls/1"
  set_state ".calls_total = 1 | .last_activity_at = \"$2\"
    | .running = {call_id: 1, kind: \"plan\", pgid: $pg, supervisor_identity: \"$id\", codex_pid: null,
                  codex_identity: null, started_at: \"$1\", review_tree: null}"
}
wt_iso_ago() { perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time - $ARGV[0]))' "$1"; }

# ---- 결과 한 줄 ----
test_wait_returns_single_json_line_on_success() {
  start_task; run_cc call plan; assert_code 0
  run_cc wait --max 20; assert_code 0
  assert_eq "$ERR" "" "ok 경로의 stderr"
  assert_eq "$(wt_lines "$OUT")" "1"
  assert_eq "$(printf '%s' "$OUT" | jq -r .verdict)" "plan"
  assert_eq "$OUT" "$(jq -c . "$CALL1/result.json")"
}
test_wait_after_completion_is_idempotent() {
  start_task; run_cc call plan; run_cc wait --max 20; assert_code 0
  first=$OUT
  run_cc wait --max 20; assert_code 0
  assert_eq "$OUT" "$first"
  run_cc wait; assert_code 0
  assert_eq "$OUT" "$first"
}
test_wait_returns_promptly_when_call_finishes() {
  FAKE_CODEX_SEQ=slow; FAKE_CODEX_DELAY=2; start_task; run_cc call plan
  t0=$SECONDS
  run_cc wait --max 20; assert_code 0
  [ $((SECONDS - t0)) -le 8 ] || _fail "호출이 끝났는데 늦게 돌아옴 ($((SECONDS - t0))초)"
  assert_eq "$(printf '%s' "$OUT" | jq -r .verdict)" "plan"
}
test_wait_never_prints_event_log() {
  FAKE_CODEX_SEQ=slow; FAKE_CODEX_DELAY=3; start_task; run_cc call plan
  run_cc wait --max 20; assert_code 0
  assert_eq "$(wt_lines "$OUT")" "1"
  assert_not_contains "$OUT" "thread.started"
  assert_not_contains "$OUT" "turn.completed"
  assert_not_contains "$OUT" "item.completed"
  grep -q '"item.completed"' "$CALL1/events.jsonl" || _fail "이벤트가 events.jsonl 에 기록되지 않음"
}

# ---- 아직 실행 중: 상태 한 줄, 2 ----
test_wait_returns_status_line_when_still_running() {
  FAKE_CODEX_SEQ=slow; FAKE_CODEX_DELAY=10; start_task; run_cc call plan
  t0=$SECONDS
  run_cc wait --max 2; assert_code 2
  el=$((SECONDS - t0))
  assert_eq "$ERR" "" "진행 중 경로의 stderr"
  [ "$el" -ge 2 ] && [ "$el" -le 6 ] || _fail "--max 2 인데 ${el}초 만에 돌아옴"
  assert_eq "$(wt_lines "$OUT")" "1"
  printf '%s\n' "$OUT" | grep -Eq '^\[cc\] Codex 실행 중 · 호출 1 · 경과 0분 · 마지막 활동 [0-9]+초 전$' \
    || _fail "상태 줄 형식이 다름: [$OUT]"
  assert_not_contains "$OUT" "item.completed"
  assert_eq "$(state .running.call_id)" "1"      # 기다리기만 하고 아무것도 끝내지 않는다
  wt_reap
}
test_status_line_reports_elapsed_and_codex_activity_not_waiter() {
  start_task
  wt_fake_running "$(wt_iso_ago 200)" "$(wt_iso_ago 125)" || _fail "대역 준비 실패"
  run_cc wait --max 0; assert_code 2
  printf '%s\n' "$OUT" | grep -Eq '^\[cc\] Codex 실행 중 · 호출 1 · 경과 3분 · 마지막 활동 1[23][0-9]초 전$' \
    || _fail "경과·마지막 활동이 다름 (대기자 등록이 활동 시각을 바꾸면 안 됨): [$OUT]"
  kill -KILL -- "-$FAKE_SUP_PG" 2>/dev/null
}
test_wait_max_is_not_extended_by_poll_interval() {
  start_task
  wt_fake_running "$(wt_iso_ago 5)" "$(wt_iso_ago 5)" || _fail "대역 준비 실패"
  t0=$SECONDS
  CC_POLL_SECS=5 run_cc wait --max 1; assert_code 2
  [ $((SECONDS - t0)) -le 3 ] || _fail "--max 1 인데 $((SECONDS - t0))초 걸림 (확인 간격 5초를 다 잠)"
  kill -KILL -- "-$FAKE_SUP_PG" 2>/dev/null
}
test_wait_max_is_capped_below_bash_tool_limit() {
  . "$CC_REPO_ROOT/plugins/yultopia/lib/cc/render.sh"
  . "$CC_REPO_ROOT/plugins/yultopia/lib/cc/call.sh"
  . "$CC_REPO_ROOT/plugins/yultopia/lib/cc/wait.sh"
  assert_eq "$(_cc_wait_parse_max --max 9999)" "560"
  assert_eq "$(_cc_wait_parse_max --max 30)" "30"
  assert_eq "$(_cc_wait_parse_max --max 0)" "0"
  assert_eq "$(_cc_wait_parse_max --max 007)" "7"
  assert_eq "$(CC_WAIT_MAX_SECS=540 _cc_wait_parse_max)" "540"
  assert_eq "$(CC_WAIT_MAX_SECS=99999 _cc_wait_parse_max)" "560"
  assert_eq "$(CC_WAIT_MAX_SECS=abc _cc_wait_parse_max)" "540"
  _cc_wait_parse_max --max abc >/dev/null && _fail "잘못된 --max 를 받음"
  _cc_wait_parse_max --max >/dev/null && _fail "값 없는 --max 를 받음"
  _cc_wait_parse_max --bogus >/dev/null && _fail "모르는 인자를 받음"
  return 0
}

# ---- 실패로 끝난 호출: 한 줄, 3 ----
test_wait_reports_timeout_line() {
  FAKE_CODEX_SEQ=hang; CC_CALL_TIMEOUT_SECS=2; start_task; run_cc call plan
  run_cc wait --max 20; assert_code 3
  assert_eq "$OUT" "[cc] Codex 시간 초과(2초) — 자동 재시도하지 않았습니다"
  assert_no_process_matching "fake-codex-hang:$FAKE_CODEX_LOG"
}
test_wait_timeout_line_uses_minutes_from_config() {
  start_task
  set_state '.calls_total = 1 | .phase = "failed"
    | .last_call = {call_id: 1, kind: "plan", status: "timeout", verdict: null, message: null}'
  CC_CALL_TIMEOUT_SECS=1200 run_cc wait; assert_code 3
  assert_eq "$OUT" "[cc] Codex 시간 초과(20분) — 자동 재시도하지 않았습니다"
}
test_wait_reports_error_line_from_last_call() {
  FAKE_CODEX_SEQ=fail_fast,fail_fast; start_task; run_cc call plan
  run_cc wait --max 20; assert_code 3
  assert_eq "$(wt_lines "$OUT")" "1"
  assert_eq "$OUT" "$(state .last_call.message)"
  assert_contains "$OUT" "실패"
}
test_wait_reports_invalid_json_line() {
  FAKE_CODEX_SEQ=invalid_json,invalid_json; start_task; run_cc call plan
  run_cc wait --max 20; assert_code 3
  assert_eq "$(wt_lines "$OUT")" "1"
  assert_contains "$OUT" "형식"
  assert_not_contains "$OUT" "not json"
}
test_wait_without_any_call() {
  start_task
  run_cc wait --max 5; assert_code 3
  assert_eq "$OUT" "[cc] 기다릴 Codex 호출이 없습니다"
}
test_wait_without_active_task() {
  repo=$(make_repo); cd "$repo"
  run_cc wait --max 1; assert_code 3
  assert_eq "$(wt_lines "$OUT")" "1"; assert_contains "$OUT" "진행 중인 작업이 없습니다"
}
test_wait_rejects_bad_arguments() {
  start_task
  run_cc wait --max abc; assert_code 3
  assert_eq "$(wt_lines "$OUT")" "1"; assert_contains "$OUT" "사용법"
}

# ---- 대기자 기록 (Task 8 고아 판정용) ----
test_wait_records_waiter_last_seen() {
  FAKE_CODEX_SEQ=slow; FAKE_CODEX_DELAY=3; start_task; run_cc call plan
  wt_start_waiter --max 20
  wt_until 5 wt_waiter_registered || _fail "waiter 가 등록되지 않음"
  assert_contains "$(state .waiter.identity)" "cc-codex.sh wait"
  assert_code_of 0 cc_proc_alive_verified "$WP" "$(state .waiter.identity)"
  state .waiter.started_at | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
    || _fail "started_at 형식이 다름: $(state .waiter.started_at)"
  wait "$WP"; rc=$?
  assert_eq "$rc" "0"
  assert_eq "$(state .waiter)" "null"
  seen=$(state .waiter_last_seen_at)
  [ "$(cc_age_secs "$seen")" -le 3 ] || _fail "waiter_last_seen_at 이 최근이 아님: $seen"
}
test_wait_leaves_other_waiter_registration_alone() {
  # 대기 중에 살아 있는 다른 대기자가 자기를 기록했다면, 확인할 때도 끝날 때도 그 기록은 지우지 않는다
  #   (신원이 맞지 않는 기록은 "확실히 없음" 이라 다시 차지한다: test_concurrent_waiters_never_look_absent)
  start_task
  wt_fake_running "$(wt_iso_ago 5)" "$(wt_iso_ago 5)" || _fail "대역 준비 실패"
  perl -e 'sleep 30' "other-waiter-$TMP" & other=$!
  sleep 0.2; oid=$(cc_proc_identity "$other") || _fail "다른 대기자 신원을 얻지 못함"
  wt_start_waiter --max 3
  wt_until 5 wt_waiter_registered || _fail "waiter 가 등록되지 않음"
  cc_state_update '.waiter = {pid: $p, identity: $i, started_at: "2026-01-01T00:00:00Z"}' \
    --argjson p "$other" --arg i "$oid" || _fail "state 갱신 실패"
  wait "$WP"
  assert_eq "$(state .waiter.pid)" "$other"
  [ "$(state .waiter_last_seen_at)" != "null" ] || _fail "waiter_last_seen_at 이 기록되지 않음"
  kill -KILL "$other" 2>/dev/null; kill -KILL -- "-$FAKE_SUP_PG" 2>/dev/null
  return 0
}

# ---- 중단 신호: Codex 그룹까지 끝내고 일관된 끝 상태 ----
test_sigterm_to_wait_kills_codex_group() {
  FAKE_CODEX_SEQ=hang; start_task; run_cc call plan; assert_code 0
  wt_until 5 wt_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  pg=$(state .running.pgid)
  wt_start_waiter --max 60
  wt_until 5 wt_waiter_registered || _fail "waiter 가 등록되지 않음"
  kill -TERM "$WP"; wait "$WP"; rc=$?
  assert_eq "$rc" "130"
  assert_eq "$(cat "$TMP/w.out")" "[cc] 중단됨: Codex 종료"
  assert_eq "$(cat "$TMP/w.err")" "" "중단 경로의 stderr"
  # wait 가 돌아온 그 순간 이미 아무것도 남아 있지 않아야 한다 (기다리지 않고 바로 확인)
  assert_no_process_matching "fake-codex-hang:$FAKE_CODEX_LOG"
  wt_group_alive "$pg" && _fail "감독 프로세스 그룹이 남아 있음"
  wt_assert_terminal 1 interrupted interrupted
  assert_eq "$(state .waiter)" "null"
}
test_sigint_to_wait_kills_codex_group() {
  FAKE_CODEX_SEQ=hang; start_task; run_cc call plan; assert_code 0
  wt_until 5 wt_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  pg=$(state .running.pgid)
  wt_start_waiter --max 60
  wt_until 5 wt_waiter_registered || _fail "waiter 가 등록되지 않음"
  kill -INT "$WP"; wait "$WP"; rc=$?
  assert_eq "$rc" "130"
  assert_eq "$(cat "$TMP/w.out")" "[cc] 중단됨: Codex 종료"
  assert_no_process_matching "fake-codex-hang:$FAKE_CODEX_LOG"
  wt_group_alive "$pg" && _fail "감독 프로세스 그룹이 남아 있음"
  wt_assert_terminal 1 interrupted interrupted
}
test_interrupt_right_after_call_start() {
  # codex 신원이 기록되기 전(감독 프로세스 handshake 중일 수도 있음)에 중단해도 같은 결과
  FAKE_CODEX_SEQ=hang; start_task; run_cc call plan; assert_code 0
  pg=$(state .running.pgid)
  wt_start_waiter --max 60
  wt_until 5 wt_waiter_registered || _fail "waiter 가 등록되지 않음"
  kill -TERM "$WP"; wait "$WP"; rc=$?
  assert_eq "$rc" "130"
  assert_no_process_matching "fake-codex-hang:$FAKE_CODEX_LOG"
  wt_group_alive "$pg" && _fail "감독 프로세스 그룹이 남아 있음"
  wt_assert_terminal 1 interrupted interrupted
}
test_interrupt_never_causes_fast_fail_rerun() {
  # addendum B: 중단은 감독 프로세스 그룹 전체에 보낸다. codex 만 죽으면 "빠른 기술 오류" 로 보여 재실행된다
  FAKE_CODEX_SEQ=hang,ok; CC_FAST_FAIL_SECS=60; start_task; run_cc call plan; assert_code 0
  wt_until 5 wt_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  wt_start_waiter --max 60
  wt_until 5 wt_waiter_registered || _fail "waiter 가 등록되지 않음"
  kill -TERM "$WP"; wait "$WP"; rc=$?
  assert_eq "$rc" "130"
  sleep 1.5                                    # 재실행이 일어난다면 이 사이에 두 번째 codex 가 기록된다
  assert_eq "$(wt_invocations)" "1"
  assert_eq "$(state .calls_total)" "1"
  wt_assert_terminal 1 interrupted interrupted
}
test_interrupt_with_term_ignoring_codex_ends_consistently() {
  # addendum A: TERM 을 무시하는 codex 라도 감독 프로세스가 정리·기록을 마치기 전에 KILL 하지 않는다.
  #   wait 가 돌아오면 status 파일 == state, codex 와 그 자식은 모두 없음
  FAKE_CODEX_SEQ=hang_stubborn; start_task; run_cc call plan; assert_code 0
  wt_until 5 wt_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  pg=$(state .running.pgid)
  wt_until 5 pgrep -f -- "fake-codex-stubborn:$FAKE_CODEX_LOG" >/dev/null || _fail "가짜 codex 자식이 없음"
  wt_start_waiter --max 60
  wt_until 5 wt_waiter_registered || _fail "waiter 가 등록되지 않음"
  t0=$SECONDS
  kill -TERM "$WP"; wait "$WP"; rc=$?
  [ $((SECONDS - t0)) -le 15 ] || _fail "중단 처리가 너무 오래 걸림 ($((SECONDS - t0))초)"
  assert_eq "$rc" "130"
  assert_eq "$(cat "$TMP/w.out")" "[cc] 중단됨: Codex 종료"
  assert_no_process_matching "fake-codex-stubborn:$FAKE_CODEX_LOG"
  wt_group_alive "$pg" && _fail "감독 프로세스 그룹이 남아 있음"
  wt_assert_terminal 1 interrupted interrupted
  grep -q '끝: interrupted' "$ACTIVE/supervisor.log" || _fail "감독 프로세스가 마무리를 끝내기 전에 죽음"
}
test_interrupt_waits_for_slow_supervisor_finish() {
  # addendum A: 감독 프로세스의 마무리가 늦어도(여기서는 다른 프로세스가 state 잠금을 4초 쥐고 있음) wait 는
  #   그 사이 KILL 하지 않는다. 감독 프로세스가 직접 끝 상태를 기록하고 끝난 뒤에 돌아온다
  FAKE_CODEX_SEQ=hang_stubborn; start_task; run_cc call plan; assert_code 0
  wt_until 5 wt_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  pg=$(state .running.pgid)
  wt_start_waiter --max 60
  wt_until 5 wt_waiter_registered || _fail "waiter 가 등록되지 않음"
  bash -c '. "$1/plugins/yultopia/lib/cc/common.sh"; . "$1/plugins/yultopia/lib/cc/state.sh"
           cc_state_lock || exit 1; sleep "$2"; cc_state_unlock' _ "$CC_REPO_ROOT" 4 &
  holder=$!
  wt_until 3 test -d "$ACTIVE/state.lock" || _fail "잠금을 쥐지 못함 (테스트 전제 깨짐)"
  kill -TERM "$WP"; wait "$WP"; rc=$?
  wait "$holder"
  assert_eq "$rc" "130"
  assert_eq "$(cat "$TMP/w.out")" "[cc] 중단됨: Codex 종료"
  grep -q '끝: interrupted' "$ACTIVE/supervisor.log" || _fail "감독 프로세스가 마무리를 끝내기 전에 KILL 됨"
  assert_no_process_matching "fake-codex-stubborn:$FAKE_CODEX_LOG"
  wt_group_alive "$pg" && _fail "감독 프로세스 그룹이 남아 있음"
  wt_assert_terminal 1 interrupted interrupted
}
test_interrupt_records_state_itself_when_supervisor_is_gone() {
  # addendum A: 감독 프로세스가 기록 없이 사라졌고 codex 만 그룹에 남은 경우 → codex 신원으로 그룹을 끝내고
  #   running.call_id 가 맞을 때만 wait 가 직접 interrupted 를 기록하고 status 파일을 state 에서 쓴다
  FAKE_CODEX_SEQ=hang; start_task; run_cc call plan; assert_code 0
  wt_until 5 wt_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  pg=$(state .running.pgid); cp=$(state .running.codex_pid)
  kill -KILL "$pg"                              # 감독 프로세스만 기록 없이 죽는다
  wt_until 3 eval '! kill -0 "$pg" 2>/dev/null' || _fail "감독 프로세스가 끝나지 않음"
  kill -0 "$cp" 2>/dev/null || _fail "codex 가 같이 죽음 (테스트 전제 깨짐)"
  wt_start_waiter --max 60
  wt_until 5 wt_waiter_registered || _fail "waiter 가 등록되지 않음"
  kill -TERM "$WP"; wait "$WP"; rc=$?
  assert_eq "$rc" "130"
  assert_eq "$(cat "$TMP/w.out")" "[cc] 중단됨: Codex 종료"
  assert_no_process_matching "fake-codex-hang:$FAKE_CODEX_LOG"
  wt_group_alive "$pg" && _fail "codex 그룹이 남아 있음"
  wt_assert_terminal 1 interrupted interrupted
}
test_wait_after_interrupt_reports_interrupted() {
  FAKE_CODEX_SEQ=hang; start_task; run_cc call plan
  wt_until 5 wt_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  wt_start_waiter --max 60
  wt_until 5 wt_waiter_registered || _fail "waiter 가 등록되지 않음"
  kill -TERM "$WP"; wait "$WP"
  # Ruling R19: 130 은 이 wait 자신이 신호를 받았을 때만. 앞서 기록된 interrupted 를 읽어 알릴 때는 3
  run_cc wait --max 5; assert_code 3
  assert_eq "$(wt_lines "$OUT")" "1"
  assert_eq "$OUT" "$(state .last_call.message)"
}

# ---- 기록 없이 죽은 호출을 끝없이 기다리지 않는다 ----
test_wait_records_dead_call_instead_of_waiting_forever() {
  FAKE_CODEX_SEQ=hang; start_task; run_cc call plan; assert_code 0
  wt_until 5 wt_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  pg=$(state .running.pgid)
  kill -KILL -- "-$pg"                          # 감독 프로세스와 codex 모두 기록 없이 사라짐
  wt_until 3 eval '! wt_group_alive "$pg"' || _fail "그룹이 끝나지 않음"
  [ ! -e "$CALL1/status" ] || _fail "status 파일이 이미 있음 (테스트 전제 깨짐)"
  t0=$SECONDS
  run_cc wait --max 20; assert_code 3          # Ruling R19: 이 wait 는 신호를 받지 않았다
  [ $((SECONDS - t0)) -le 5 ] || _fail "죽은 호출을 $((SECONDS - t0))초 기다림"
  assert_eq "$(wt_lines "$OUT")" "1"; assert_contains "$OUT" "[cc] "
  wt_assert_terminal 1 interrupted interrupted
  assert_eq "$OUT" "$(state .last_call.message)"
}
test_wait_does_not_record_while_codex_alive_without_supervisor() {
  # 감독 프로세스만 죽고 codex 가 살아 있으면 "확실히 끝남" 이 아니다 → 기록하지 않고 상태 줄
  FAKE_CODEX_SEQ=hang; start_task; run_cc call plan; assert_code 0
  wt_until 5 wt_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  pg=$(state .running.pgid)
  kill -KILL "$pg"
  wt_until 3 eval '! kill -0 "$pg" 2>/dev/null' || _fail "감독 프로세스가 끝나지 않음"
  run_cc wait --max 2; assert_code 2
  assert_contains "$OUT" "Codex 실행 중"
  assert_eq "$(state .running.call_id)" "1"
  assert_no_path "$CALL1/status"
  wt_reap
}

# ==== Task 7 리뷰 수정 ====
wt_source_libs() {
  . "$CC_REPO_ROOT/plugins/yultopia/lib/cc/render.sh"
  . "$CC_REPO_ROOT/plugins/yultopia/lib/cc/call.sh"
  . "$CC_REPO_ROOT/plugins/yultopia/lib/cc/wait.sh"
}
# Task 8 고아 규칙 흉내: (waiter 없음 또는 확실히 죽음) 이고 (waiter_last_seen_at, 없으면 running.started_at) 부터
#   grace 초를 넘겼으면 참
wt_orphan_like() {
  local grace="$1" wp wid base
  wp=$(state '.waiter.pid // empty'); wid=$(state '.waiter.identity // empty')
  if [ -n "$wp" ]; then cc_proc_alive_verified "$wp" "$wid"; [ $? -eq 1 ] || return 1; fi
  base=$(state '.waiter_last_seen_at // .running.started_at')
  [ "$(cc_age_secs "$base")" -gt "$grace" ]
}

# 리뷰 1: 기억해 둔 PID 에 나중에 신호를 보내지 않는다 (그 sleep 은 이미 거둬져 PID 가 재사용됐을 수 있다)
# 스크립트의 최상위 셸(본 셸)에서 wait 라이브러리를 불러 코드를 실행한다: wt_lib_shell '<코드>' [인자...] ($1… 로 받음)
wt_lib_shell() {
  local code="$1"; shift
  bash -c '. "$0/plugins/yultopia/lib/cc/common.sh"; . "$0/plugins/yultopia/lib/cc/state.sh"
           . "$0/plugins/yultopia/lib/cc/proc.sh"; . "$0/plugins/yultopia/lib/cc/render.sh"
           . "$0/plugins/yultopia/lib/cc/call.sh"; . "$0/plugins/yultopia/lib/cc/wait.sh"
           '"$code" "$CC_REPO_ROOT" "$@"
}
test_wait_never_signals_a_remembered_sleep_pid() {
  perl -e 'sleep 30' "unrelated-$TMP" & other=$!     # 재사용된 PID 를 가진 남의 프로세스 역할
  wt_lib_shell '_CC_WAIT_SLEEP_PID=$1; _CC_WAIT_REG=0; _cc_wait_on_exit' "$other" >/dev/null 2>&1
  sleep 0.3
  kill -0 "$other" 2>/dev/null || _fail "EXIT 처리가 기억해 둔 PID 에 신호를 보냄"
  wt_lib_shell '_CC_WAIT_SLEEP_PID=$1; _CC_WAIT_REG=0
    _cc_wait_interrupt() { _CC_WAIT_LINE="x"; }    # 신호 처리 경로에서 중단 처리만 대역으로
    trap "_cc_wait_on_exit" EXIT
    _cc_wait_on_signal' "$other" >/dev/null 2>&1
  sleep 0.3
  kill -0 "$other" 2>/dev/null || _fail "신호 처리(그리고 그 뒤 EXIT 처리)가 기억해 둔 PID 에 신호를 보냄"
  kill -KILL "$other" 2>/dev/null
  return 0
}
# bash 3.2 는 신호가 막 도착했을 때 만들어진 $(...) 자식에서도 그 trap 을 실행한다 (자식은 대기 중이던 trap 을 물려받음).
# 정리는 본 셸만 한다: 자식에서는 아무것도 하지 않고 조용히 끝나고, 본 셸이 자기 몫의 trap 으로 처리한다
test_signal_handler_does_nothing_inside_a_subshell() {
  wt_lib_shell 'ran_file=$1; sub_file=$2
    _cc_wait_interrupt() { echo ran >> "$ran_file"; _CC_WAIT_LINE="한 줄"; }
    _cc_wait_unregister() { :; }
    out=$(_cc_wait_on_signal); rc=$?
    printf "%s|%s\n" "$rc" "$out" > "$sub_file"
    _cc_wait_on_signal' "$TMP/ran" "$TMP/sub" > "$TMP/main.out" 2>/dev/null
  rc=$?
  assert_eq "$(cat "$TMP/sub")" "130|" "자식(\$(...))에서 중단 처리를 하거나 출력함"
  assert_eq "$(grep -c ran "$TMP/ran" 2>/dev/null)" "1" "중단 처리는 본 셸에서 한 번만"
  assert_eq "$rc" "130"
  assert_eq "$(cat "$TMP/main.out")" "한 줄"
}

# 리뷰 2: 동시에 기다리는 둘 중 하나가 끝나도 살아 있는 대기자가 "없음" 으로 보이지 않는다
test_concurrent_waiters_never_look_absent() {
  start_task
  wt_fake_running "$(wt_iso_ago 0)" "$(wt_iso_ago 0)" || _fail "대역 준비 실패"
  WT_OUT=a wt_start_waiter --max 25; A=$WP
  wt_until 5 wt_waiter_registered || _fail "A 가 등록되지 않음"
  WT_OUT=b wt_start_waiter --max 2; B=$WP
  wt_until 5 wt_waiter_registered || _fail "B 가 등록되지 않음"
  i=0
  while [ "$i" -lt 35 ]; do                      # B 가 끝나고(약 2초) 그 뒤 A 만 기다리는 동안 계속 본다
    if wt_orphan_like 3; then _fail "A 가 기다리는 중인데 고아 조건이 참: waiter=$(state .waiter) seen=$(state .waiter_last_seen_at)"; break; fi
    sleep 0.2; i=$((i + 1))
  done
  wait "$B"
  kill -0 "$A" 2>/dev/null || _fail "A 가 일찍 끝남 (테스트 전제 깨짐)"
  WP=$A; wt_until 3 wt_waiter_registered || _fail "B 가 끝난 뒤 A 가 다시 기록되지 않음: $(state .waiter)"
  assert_eq "$(cat "$TMP/b.err")" ""
  kill -TERM "$A"; wait "$A"
  kill -KILL -- "-$FAKE_SUP_PG" 2>/dev/null
  return 0
}

# 리뷰 3: 중단은 이 wait 가 기다리던 호출만 멈춘다
test_interrupt_only_stops_the_call_it_waited_for() {
  start_task
  wt_fake_running "$(wt_iso_ago 0)" "$(wt_iso_ago 0)" || _fail "대역 준비 실패"
  CC_POLL_SECS=30                                # 첫 확인 뒤 오래 잔다
  wt_start_waiter --max 60
  wt_until 5 wt_waiter_registered || _fail "waiter 가 등록되지 않음"
  sleep 1.5
  # 기다리던 호출 1 은 끝났고 그 사이 다른 호출 2 가 실행 중이 됐다
  pg2=$(cc_spawn_group "$TMP/fake-sup2.log" perl -e 'sleep 60' "fake-supervisor2-$TMP"); id2=$(cc_proc_identity "$pg2")
  mkdir -p "$ACTIVE/calls/2"
  cc_state_update '.calls_total = 2
    | .last_call = {call_id: 1, kind: "plan", status: "error", verdict: null, message: "[cc] 끝남"}
    | .running = {call_id: 2, kind: "message", pgid: $pg, supervisor_identity: $id, codex_pid: null,
                  codex_identity: null, started_at: $now, review_tree: null}' \
    --argjson pg "$pg2" --arg id "$id2" --arg now "$(cc_now_iso)" || _fail "state 갱신 실패"
  kill -TERM "$WP"; wait "$WP"; rc=$?
  assert_eq "$rc" "130"
  assert_eq "$(wt_lines "$(cat "$TMP/w.out")")" "1"
  kill -0 "$pg2" 2>/dev/null || _fail "기다리지 않던 호출 2 의 감독 프로세스를 죽임"
  assert_eq "$(state .running.call_id)" "2"
  assert_eq "$(state .last_call.call_id)" "1"
  assert_no_path "$ACTIVE/calls/2/status"
  kill -KILL -- "-$pg2" 2>/dev/null; kill -KILL -- "-$FAKE_SUP_PG" 2>/dev/null
  return 0
}

# 리뷰 4: 기록된 감독 프로세스·codex 는 없어도 그룹에 남은 것이 살아 있으면 "확실히 끝남" 이 아니다
test_dead_supervisor_and_codex_with_live_group_leftover_is_not_dead() {
  FAKE_CODEX_SEQ=hang; start_task; run_cc call plan; assert_code 0
  wt_until 5 wt_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  pg=$(state .running.pgid); cp=$(state .running.codex_pid)
  kill -KILL "$pg" "$cp"                         # 둘 다 기록 없이 사라지고 codex 의 자식만 그룹에 남는다
  wt_until 3 eval '! kill -0 "$pg" 2>/dev/null && ! kill -0 "$cp" 2>/dev/null' || _fail "기록된 프로세스가 끝나지 않음"
  pgrep -f -- "fake-codex-hang:$FAKE_CODEX_LOG" >/dev/null || _fail "그룹에 남은 자식이 없음 (테스트 전제 깨짐)"
  wt_group_alive "$pg" || _fail "그룹이 비어 있음 (테스트 전제 깨짐)"
  run_cc wait --max 2; assert_code 2              # 끝났다고 기록하지 않고 상태 줄
  assert_eq "$(state .running.call_id)" "1"; assert_no_path "$CALL1/status"
  run_cc call plan; assert_code 6                 # 남은 것이 사는 동안 두 번째 Codex 를 띄우지 않는다
  assert_contains "$OUT" "실행 중"; assert_eq "$(state .calls_total)" "1"
  # 중단: 확인할 수 있는 프로세스가 없다 → 아무 신호도 보내지 않고 상태도 바꾸지 않는다 (rc=2 경로)
  wt_start_waiter --max 60
  wt_until 5 wt_waiter_registered || _fail "waiter 가 등록되지 않음"
  kill -TERM "$WP"; wait "$WP"; rc=$?
  assert_eq "$rc" "130"
  assert_eq "$(wt_lines "$(cat "$TMP/w.out")")" "1"; assert_contains "$(cat "$TMP/w.out")" "확인하지 못해"
  assert_eq "$(state .running.call_id)" "1"; assert_no_path "$CALL1/status"
  pgrep -f -- "fake-codex-hang:$FAKE_CODEX_LOG" >/dev/null || _fail "확인되지 않은 프로세스를 죽임"
  kill -KILL -- "-$pg" 2>/dev/null
  return 0
}

# 리뷰 5: 기록 해제 쓰기가 실패하면(신호·잠금 실패) 다음 기회에 다시 해제한다
test_unregister_is_retried_when_its_write_failed() {
  wt_source_libs
  ( _CC_WAIT_REG=1
    _cc_wait_update_keep_activity() { echo try >> "$TMP/tries"; return 1; }
    _cc_wait_unregister; _cc_wait_unregister ) >/dev/null 2>&1
  assert_eq "$(wc -l < "$TMP/tries" 2>/dev/null | tr -d ' ')" "2" "해제 쓰기가 실패했는데 다시 시도하지 않음"
}

# 리뷰 6 (Ruling R20): HUP 도 TERM 처럼 처리한다
test_sighup_to_wait_kills_codex_group() {
  FAKE_CODEX_SEQ=hang; start_task; run_cc call plan; assert_code 0
  wt_until 5 wt_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  pg=$(state .running.pgid)
  wt_start_waiter --max 60
  wt_until 5 wt_waiter_registered || _fail "waiter 가 등록되지 않음"
  kill -HUP "$WP"; wait "$WP"; rc=$?
  assert_eq "$rc" "130"
  assert_eq "$(cat "$TMP/w.out")" "[cc] 중단됨: Codex 종료"
  assert_no_process_matching "fake-codex-hang:$FAKE_CODEX_LOG"
  wt_group_alive "$pg" && _fail "감독 프로세스 그룹이 남아 있음"
  wt_assert_terminal 1 interrupted interrupted
}

# 리뷰 8: 그 밖의 경로
test_interrupt_before_codex_is_recorded() {
  start_task
  wt_fake_running "$(wt_iso_ago 0)" "$(wt_iso_ago 0)" || _fail "대역 준비 실패"   # codex_pid 는 null
  wt_start_waiter --max 60
  wt_until 5 wt_waiter_registered || _fail "waiter 가 등록되지 않음"
  kill -TERM "$WP"; wait "$WP"; rc=$?
  assert_eq "$rc" "130"
  assert_eq "$(cat "$TMP/w.out")" "[cc] 중단됨: Codex 종료"
  assert_eq "$(cat "$TMP/w.err")" ""
  wt_group_alive "$FAKE_SUP_PG" && _fail "감독 프로세스 그룹이 남아 있음"
  wt_assert_terminal 1 interrupted interrupted
}
test_interrupt_changes_nothing_when_processes_cannot_be_verified() {
  FAKE_CODEX_SEQ=hang; start_task; run_cc call plan; assert_code 0
  wt_until 5 wt_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  pg=$(state .running.pgid)
  mkdir -p "$TMP/bin"; printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/ps"; chmod +x "$TMP/bin/ps"   # 늘 실패하는 ps
  WT_WAITER_PATH="$TMP/bin:$PATH" wt_start_waiter --max 60
  wt_until 5 wt_waiter_registered || _fail "waiter 가 등록되지 않음"
  kill -TERM "$WP"; wait "$WP"; rc=$?
  assert_eq "$rc" "130"
  assert_eq "$(wt_lines "$(cat "$TMP/w.out")")" "1"; assert_contains "$(cat "$TMP/w.out")" "확인하지 못해"
  assert_eq "$(state .running.call_id)" "1"; assert_no_path "$CALL1/status"
  wt_group_alive "$pg" || _fail "확인하지 못한 채 그룹을 죽임"
  wt_reap
}
test_waiter_killed_during_interrupt_still_leaves_consistent_state() {
  FAKE_CODEX_SEQ=hang_stubborn; start_task; run_cc call plan; assert_code 0
  wt_until 5 wt_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  pg=$(state .running.pgid)
  wt_start_waiter --max 60
  wt_until 5 wt_waiter_registered || _fail "waiter 가 등록되지 않음"
  kill -TERM "$WP"; sleep 0.4; kill -KILL "$WP"; wait "$WP"
  wait_until_status_file 1 10 || _fail "status 파일이 생기지 않음"
  wt_until 5 eval '! wt_group_alive "$pg"' || _fail "감독 프로세스 그룹이 남아 있음"
  assert_no_process_matching "fake-codex-stubborn:$FAKE_CODEX_LOG"
  wt_assert_terminal 1 interrupted interrupted
  w=$(state '.waiter.pid // empty')
  [ -z "$w" ] || ! kill -0 "$w" 2>/dev/null || _fail "살아 있는 대기자 기록이 남음 ($w)"
}
