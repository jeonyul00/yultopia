# test_housekeeping.sh - Task 8: 고아 확인(check-orphan), 14일 정리(cleanup-stale), 시작 전 확인(preflight),
#   버리기(discard)·마무리(finish) 의 실행 중 거부 (+ addendum A–G)
. "$CC_REPO_ROOT/plugins/yultopia/lib/cc/proc.sh"

# ---- 이 파일 전용 도우미 (test_ 로 시작하지 않게) ----
hk_until() {
  local secs="$1" i=0; shift
  until "$@"; do
    [ "$i" -ge $((secs * 10)) ] && return 1
    sleep 0.1; i=$((i+1))
  done
}
hk_codex_recorded() { [ -n "$(state '.running.codex_pid // empty')" ]; }
hk_group_alive() { kill -0 -- "-$1" 2>/dev/null; }
hk_lines() { printf '%s\n' "$1" | wc -l | tr -d ' '; }
hk_json() { printf '%s' "$OUT" | jq -r "$1"; }
hk_iso_ago() { perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time - $ARGV[0]))' "$1"; }
hk_log() { printf "%s" "${FAKE_CODEX_LOG:-$TMP/fake-codex.log}"; }
hk_invocations() { ls "$(hk_log)" 2>/dev/null | grep -c '\.argv$'; }
# state 잠금을 쥐고 값을 그대로 쓴다 (cc_state_update 와 달리 last_activity_at 을 지금으로 바꾸지 않는다)
hk_set_state_locked() { cc_state_lock || { _fail "잠금 실패"; return 1; }; set_state "$1"; cc_state_unlock; }
# 실행 중인 호출의 그룹을 KILL 로 끝낸다 (테스트 정리용, 자기 그룹은 건드리지 않음)
hk_reap() {
  local pg mypg
  pg=${1:-$(state '.running.pgid // empty' 2>/dev/null)}
  case "$pg" in ''|*[!0-9]*|0|1) return 0 ;; esac
  mypg=$(ps -o pgid= -p $$ | tr -d ' ')
  [ "$pg" = "$mypg" ] && return 0
  kill -KILL -- "-$pg" 2>/dev/null
  hk_until 3 eval '! hk_group_alive "$pg"'
  return 0
}
# 끝 상태가 일관적인지: status 파일 == last_call.status, running=null, phase
hk_assert_terminal() {   # <call_id> <status> <phase>
  assert_eq "$(cat "$ACTIVE/calls/$1/status" 2>/dev/null)" "$2" "status 파일"
  assert_eq "$(state .last_call.status)" "$2"
  assert_eq "$(state .last_call.call_id)" "$1"
  assert_eq "$(state .running)" "null"
  assert_eq "$(state .phase)" "$3"
}
# wait 를 백그라운드로 띄운다 (WP = 그 PID). test_wait.sh 의 wt_start_waiter 와 같은 이유로 SIGINT 를 기본값으로 되돌린다
hk_start_waiter() {
  FAKE_CODEX_LOG="${FAKE_CODEX_LOG:-$TMP/fake-codex.log}" \
    perl -e '$SIG{INT} = "DEFAULT"; exec { $ARGV[0] } @ARGV or exit 127' bash "$CC_BIN" wait "$@" \
    > "$TMP/w.out" 2> "$TMP/w.err" &
  WP=$!
}
hk_waiter_registered() { [ "$(state '.waiter.pid // empty')" = "$WP" ]; }
# 감독 프로세스 대역: 새 그룹의 리더로 오래 사는 프로세스를 running 에 기록한다 (state 를 바꾸는 쪽이 없다)
hk_fake_running() {   # <started_at> <last_activity_at>
  local pg id
  pg=$(cc_spawn_group "$TMP/fake-sup.log" perl -e 'sleep 60' "fake-supervisor-$TMP") || return 1
  id=$(cc_proc_identity "$pg") || return 1
  FAKE_SUP_PG=$pg
  mkdir -p "$ACTIVE/calls/1"
  set_state ".calls_total = 1 | .last_activity_at = \"$2\"
    | .running = {call_id: 1, kind: \"plan\", pgid: $pg, supervisor_identity: \"$id\", codex_pid: null,
                  codex_identity: null, started_at: \"$1\", review_tree: null}"
}
# 리더는 끝나고 멤버만 남은 그룹을 만든다 (LEFT_PG = 그룹, LEFT_MEMBER = 남은 멤버)
hk_leftover_group() {
  local ids
  ids=$(perl -MPOSIX -e '
    POSIX::setsid() or die "setsid: $!";
    my $p = fork; die "fork: $!" unless defined $p;
    if ($p == 0) {
      open STDOUT, ">", "/dev/null"; open STDERR, ">", "/dev/null";
      exec "perl", "-e", "sleep 60", "leftover-member-$ENV{TMP}" or POSIX::_exit(1);
    }
    print "$$ $p\n"; exit 0') || return 1
  LEFT_PG=${ids% *}; LEFT_MEMBER=${ids#* }
  hk_until 3 eval '! kill -0 "$LEFT_PG" 2>/dev/null' || return 1
  hk_group_alive "$LEFT_PG"
}
# 가짜 ps: 늘 실패 / 그룹(pgid) 질문에만 실패 (그 밖에는 진짜 /bin/ps)
hk_fake_ps_fail() { mkdir -p "$TMP/bin"; printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/ps"; chmod +x "$TMP/bin/ps"; }
hk_fake_ps_fail_pgid() {
  mkdir -p "$TMP/bin"
  printf '#!/bin/sh\ncase "$*" in *pgid=*) exit 1 ;; esac\nexec /bin/ps "$@"\n' > "$TMP/bin/ps"
  chmod +x "$TMP/bin/ps"
}
hk_source_libs() {
  . "$CC_REPO_ROOT/plugins/yultopia/lib/cc/render.sh"
  . "$CC_REPO_ROOT/plugins/yultopia/lib/cc/call.sh"
  . "$CC_REPO_ROOT/plugins/yultopia/lib/cc/wait.sh"
  . "$CC_REPO_ROOT/plugins/yultopia/lib/cc/housekeeping.sh"
}
hk_stale_iso() { hk_iso_ago $((15 * 86400)); }

# ==== cc_running_state: call·wait 와 같은 판단 (addendum B) ====
test_running_state_agrees_with_call_liveness() {
  hk_source_libs
  start_task
  assert_eq "$(cc_running_state)" "none"
  _cc_call_is_running "$(cat "$ACTIVE/state.json")" && _fail "none 인데 call 이 실행 중으로 봄"
  # alive: 감독 프로세스(대역)가 신원 확인상 살아 있음
  hk_fake_running "$(hk_iso_ago 5)" "$(hk_iso_ago 5)" || _fail "대역 준비 실패"
  assert_eq "$(cc_running_state)" "alive"
  _cc_call_is_running "$(cat "$ACTIVE/state.json")" || _fail "alive 인데 call 이 실행 중 아님으로 봄"
  # uncertain: ps 가 실패해 확인할 수 없음
  hk_fake_ps_fail
  assert_eq "$( export PATH="$TMP/bin:$PATH"; hash -r; cc_running_state )" "uncertain"
  ( export PATH="$TMP/bin:$PATH"; hash -r; _cc_call_is_running "$(cat "$ACTIVE/state.json")" ) \
    || _fail "uncertain 인데 call 이 실행 중 아님으로 봄"
  kill -KILL -- "-$FAKE_SUP_PG" 2>/dev/null
  # uncertain(남은 그룹): 기록된 감독 프로세스·codex 는 확실히 없는데 그룹에 무언가 남음
  hk_leftover_group || _fail "남은 그룹 준비 실패"
  mkdir -p "$ACTIVE/calls/9"
  set_state ".running = {call_id: 9, kind: \"plan\", pgid: $LEFT_PG,
    supervisor_identity: \"Thu Jan  1 00:00:00 2020|bash gone\", codex_pid: null, codex_identity: null,
    started_at: \"$(hk_iso_ago 5)\", review_tree: null}"
  assert_eq "$(cc_running_state)" "uncertain"
  _cc_call_is_running "$(cat "$ACTIVE/state.json")" || _fail "남은 그룹이 있는데 call 이 실행 중 아님으로 봄"
  kill -0 "$LEFT_MEMBER" 2>/dev/null || _fail "확인되지 않은 프로세스를 죽임"
  # dead: 그룹까지 비면 확실히 끝남 → 그 자리에서 state 를 정리한다
  kill -KILL "$LEFT_MEMBER"; hk_until 3 eval '! hk_group_alive "$LEFT_PG"' || _fail "그룹이 끝나지 않음"
  _cc_call_is_running "$(cat "$ACTIVE/state.json")" && _fail "dead 인데 call 이 실행 중으로 봄"
  assert_eq "$(cc_running_state)" "dead"
  hk_assert_terminal 9 interrupted interrupted
  assert_eq "$(cc_running_state)" "none"
}

# ==== check-orphan ====
test_orphan_detected_when_no_waiter() {
  FAKE_CODEX_SEQ=hang; CC_ORPHAN_GRACE_SECS=1; start_task; run_cc call plan; assert_code 0
  hk_until 5 hk_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  cp=$(state .running.codex_pid)
  sleep 2.2
  run_cc check-orphan; assert_code 10
  assert_eq "$OUT" "[cc] 기다리는 대기 명령 없이 Codex가 실행 중입니다 (호출 1, 경과 0분)"
  kill -0 "$cp" 2>/dev/null || _fail "--kill 없이 Codex 를 죽임"
  assert_eq "$(state .running.call_id)" "1"
  hk_reap
}
test_check_orphan_silent_without_orphan() {
  repo=$(make_repo); cd "$repo"
  run_cc check-orphan; assert_code 0; assert_eq "$OUT" ""      # active 없음
  printf 'x\n' | run_cc init
  run_cc check-orphan; assert_code 0; assert_eq "$OUT" ""      # running 없음
  run_cc check-orphan --bogus; assert_code 1
  assert_eq "$(hk_lines "$OUT")" "1"; assert_contains "$OUT" "사용법"
  # 상태 파일을 읽을 수 없거나 경로가 비정상이면 한 줄 오류 (R7)
  a=$(cc_path active)
  cp "$a/state.json" "$TMP/state.bak"; echo '{bad' > "$a/state.json"
  run_cc check-orphan; assert_code 1
  assert_eq "$(hk_lines "$OUT")" "1"; assert_contains "$OUT" "상태 파일을 읽을 수 없어"
  cp "$TMP/state.bak" "$a/state.json"
  mv "$a" "$TMP/elsewhere"; ln -s "$TMP/elsewhere" "$a"
  run_cc check-orphan; assert_code 1
  assert_eq "$(hk_lines "$OUT")" "1"; assert_contains "$OUT" "비정상"
}
test_not_orphan_while_waiter_alive() {
  FAKE_CODEX_SEQ=hang; CC_ORPHAN_GRACE_SECS=1; start_task; run_cc call plan; assert_code 0
  hk_until 5 hk_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  # 대기자는 처음 한 번만 확인 시각을 남기고 30초 잔다: grace(1초)가 지나도 살아 있는 대기자 기록만으로 고아가 아니어야 한다
  CC_POLL_SECS=30 hk_start_waiter --max 20
  hk_until 5 hk_waiter_registered || _fail "waiter 가 등록되지 않음"
  sleep 2.2
  [ "$(cc_age_secs "$(state .waiter_last_seen_at)")" -gt 1 ] || _fail "대기자 확인 시각이 grace 안 (테스트 전제 깨짐)"
  run_cc check-orphan; assert_code 0
  assert_eq "$OUT" ""
  kill -0 "$(state .running.codex_pid)" 2>/dev/null || _fail "Codex 가 죽음"
  kill -TERM "$WP"; wait "$WP"; rc=$?
  assert_eq "$rc" "130"                            # 대기자 중단 → Codex 도 정리됨 (Task 7)
}
test_orphan_grace_counts_from_last_waiter_seen() {
  FAKE_CODEX_SEQ=hang; CC_ORPHAN_GRACE_SECS=2; start_task; run_cc call plan; assert_code 0
  hk_until 5 hk_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  sleep 2.5                                        # 호출 시작부터는 grace 가 지났다
  run_cc wait --max 1; assert_code 2               # 대기자가 잠깐 기다리다 돌아감 → waiter_last_seen_at = 지금
  run_cc check-orphan; assert_code 0               # 마지막 대기자부터는 아직 grace 안
  sleep 3.5
  run_cc check-orphan; assert_code 10
  assert_contains "$OUT" "대기 명령 없이"
  hk_reap
}
test_orphan_ignores_waiter_seen_before_this_call_started() {
  # 앞 호출을 기다리던 대기자의 마지막 시각은 이 호출과 상관없다: 이 호출을 한 번도 기다리지 않았으면 호출 시작부터 센다
  start_task
  hk_fake_running "$(hk_iso_ago 0)" "$(hk_iso_ago 0)" || _fail "대역 준비 실패"
  set_state ".waiter_last_seen_at = \"$(hk_iso_ago 600)\""
  run_cc check-orphan; assert_code 0
  set_state ".running.started_at = \"$(hk_iso_ago 600)\""
  run_cc check-orphan; assert_code 10
  assert_eq "$OUT" "[cc] 기다리는 대기 명령 없이 Codex가 실행 중입니다 (호출 1, 경과 10분)"
  kill -KILL -- "-$FAKE_SUP_PG" 2>/dev/null
}
test_orphan_judges_waiter_record_by_verified_liveness() {
  start_task
  hk_fake_running "$(hk_iso_ago 600)" "$(hk_iso_ago 600)" || _fail "대역 준비 실패"
  bash -c 'exit 0' & dead=$!; wait "$dead"
  perl -e 'sleep 30' "live-waiter-$TMP" & live=$!
  sleep 0.2; lid=$(cc_proc_identity "$live") || _fail "신원을 얻지 못함"
  set_state ".waiter_last_seen_at = \"$(hk_iso_ago 600)\""
  # 확실히 죽은 대기자 기록 → 고아
  set_state ".waiter = {pid: $dead, identity: \"Thu Jan  1 00:00:00 2020|bash gone\", started_at: \"2020-01-01T00:00:00Z\"}"
  run_cc check-orphan; assert_code 10
  # 살아 있는 대기자 → 고아 아님
  set_state ".waiter = {pid: $live, identity: \"$lid\", started_at: \"2020-01-01T00:00:00Z\"}"
  run_cc check-orphan; assert_code 0
  # 신원을 확인할 수 없는(identity null) 살아 있는 대기자 → 있는 것으로 본다
  set_state ".waiter = {pid: $live, identity: null, started_at: \"2020-01-01T00:00:00Z\"}"
  run_cc check-orphan; assert_code 0
  # identity 가 null 이어도 그 PID 가 아예 없으면 확실히 죽은 것
  set_state ".waiter = {pid: $dead, identity: null, started_at: \"2020-01-01T00:00:00Z\"}"
  run_cc check-orphan; assert_code 10
  kill -KILL "$live" 2>/dev/null; kill -KILL -- "-$FAKE_SUP_PG" 2>/dev/null
  return 0
}
test_check_orphan_kill_terminates_group() {
  FAKE_CODEX_SEQ=hang; CC_ORPHAN_GRACE_SECS=1; start_task; run_cc call plan; assert_code 0
  hk_until 5 hk_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  pg=$(state .running.pgid)
  sleep 2.2
  run_cc check-orphan --kill; assert_code 10
  assert_eq "$OUT" "[cc] 남아 있던 Codex를 종료했습니다"
  assert_eq "$ERR" ""
  assert_no_process_matching "fake-codex-hang:$FAKE_CODEX_LOG"
  hk_group_alive "$pg" && _fail "감독 프로세스 그룹이 남아 있음"
  hk_assert_terminal 1 interrupted interrupted
  run_cc check-orphan; assert_code 0; assert_eq "$OUT" ""
  run_cc wait --max 2; assert_code 3                # 끝 상태가 wait 와도 맞는다
}
test_check_orphan_kill_lets_supervisor_finish_with_stubborn_codex() {
  # addendum A: TERM 을 무시하는 codex 라도 감독 프로세스가 스스로 정리·기록을 마치기 전에 KILL 하지 않는다
  FAKE_CODEX_SEQ=hang_stubborn; CC_ORPHAN_GRACE_SECS=1; start_task; run_cc call plan; assert_code 0
  hk_until 5 hk_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  pg=$(state .running.pgid)
  hk_until 5 pgrep -f -- "fake-codex-stubborn:$FAKE_CODEX_LOG" >/dev/null || _fail "가짜 codex 자식이 없음"
  sleep 2.3
  t0=$SECONDS
  run_cc check-orphan --kill; assert_code 10
  [ $((SECONDS - t0)) -le 15 ] || _fail "종료가 너무 오래 걸림 ($((SECONDS - t0))초)"
  assert_eq "$OUT" "[cc] 남아 있던 Codex를 종료했습니다"
  grep -q '끝: interrupted' "$ACTIVE/supervisor.log" || _fail "감독 프로세스가 마무리를 끝내기 전에 KILL 됨"
  assert_no_process_matching "fake-codex-stubborn:$FAKE_CODEX_LOG"
  hk_group_alive "$pg" && _fail "감독 프로세스 그룹이 남아 있음"
  hk_assert_terminal 1 interrupted interrupted
}
test_check_orphan_kill_waits_for_slow_supervisor_finish() {
  # addendum A: 감독 프로세스의 마무리가 늦어도(다른 프로세스가 state 잠금을 4초 쥐고 있음) 그 사이 KILL 하지 않는다
  FAKE_CODEX_SEQ=hang_stubborn; CC_ORPHAN_GRACE_SECS=1; start_task; run_cc call plan; assert_code 0
  hk_until 5 hk_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  pg=$(state .running.pgid)
  sleep 2.3
  ( . "$CC_REPO_ROOT/plugins/yultopia/lib/cc/common.sh"; . "$CC_REPO_ROOT/plugins/yultopia/lib/cc/state.sh"
    sleep 0.8; cc_state_lock || exit 1; sleep 4; cc_state_unlock ) &
  holder=$!
  run_cc check-orphan --kill; assert_code 10
  wait "$holder" || _fail "잠금을 쥐지 못함 (테스트 전제 깨짐)"
  assert_eq "$OUT" "[cc] 남아 있던 Codex를 종료했습니다"
  grep -q '끝: interrupted' "$ACTIVE/supervisor.log" || _fail "감독 프로세스가 마무리를 끝내기 전에 KILL 됨"
  assert_no_process_matching "fake-codex-stubborn:$FAKE_CODEX_LOG"
  hk_group_alive "$pg" && _fail "감독 프로세스 그룹이 남아 있음"
  hk_assert_terminal 1 interrupted interrupted
}
test_check_orphan_kill_changes_nothing_when_unverifiable() {
  # 종료 도우미가 거부(2)하면 아무것도 바꾸지 않고, 안전하게 멈출 수 있는지 확인하지 못했다고 한 줄 (그래도 고아 보고: 10)
  FAKE_CODEX_SEQ=hang; CC_ORPHAN_GRACE_SECS=1; start_task; run_cc call plan; assert_code 0
  hk_until 5 hk_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  pg=$(state .running.pgid)
  sleep 2.2
  hk_fake_ps_fail_pgid
  PATH="$TMP/bin:$PATH" run_cc check-orphan --kill; assert_code 10
  assert_eq "$(hk_lines "$OUT")" "1"; assert_contains "$OUT" "확인하지 못해"
  assert_eq "$(state .running.call_id)" "1"; assert_no_path "$CALL1/status"
  hk_group_alive "$pg" || _fail "확인하지 못한 채 그룹을 죽임"
  hk_reap
}

# ==== 최종 리뷰 Important 1: 사용자가 시킨 종료(check-orphan --kill)는 고아 유예를 기다리지 않는다 ====
test_check_orphan_kill_stops_call_inside_orphan_grace() {
  FAKE_CODEX_SEQ=hang; CC_ORPHAN_GRACE_SECS=60; start_task; run_cc call plan; assert_code 0
  hk_until 5 hk_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  pg=$(state .running.pgid)
  # 알리기만 하는 쪽(평소 check-orphan, 메시지 훅)은 유예를 그대로 지킨다
  run_cc check-orphan; assert_code 0; assert_eq "$OUT" ""
  hook_out=$(printf '{"cwd":"%s"}' "$PWD" | bash "$HOOK" prompt-submit 2>/dev/null)
  assert_eq "$hook_out" ""
  # Esc 로 대기가 끊긴 직후: 사용자가 멈추라고 하면 유예 안이어도 바로 멈춘다
  run_cc check-orphan --kill; assert_code 10
  assert_eq "$OUT" "[cc] 남아 있던 Codex를 종료했습니다"
  assert_no_process_matching "fake-codex-hang:$FAKE_CODEX_LOG"
  hk_group_alive "$pg" && _fail "감독 프로세스 그룹이 남아 있음"
  hk_assert_terminal 1 interrupted interrupted
  # 이제 사용자 말을 전할 수 있다 (예전에는 "이미 실행 중" 으로 막혔다)
  printf '사용자 지시: 방향 바꿔\n' | run_cc put message; assert_code 0
  run_cc call message; assert_code 0
  wait_until_status_file 2 || _fail "calls/2/status 가 생기지 않음"
  assert_eq "$(cat "$ACTIVE/calls/2/status")" "ok"
}
test_check_orphan_kill_inside_grace_lets_discard_proceed() {
  FAKE_CODEX_SEQ=hang; CC_ORPHAN_GRACE_SECS=60; start_task; run_cc call plan; assert_code 0
  hk_until 5 hk_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  run_cc discard; assert_code 6; assert_contains "$OUT" "먼저 종료하세요"
  run_cc check-orphan --kill; assert_code 10
  assert_eq "$OUT" "[cc] 남아 있던 Codex를 종료했습니다"
  run_cc discard; assert_code 0
  assert_no_path "$ACTIVE"
  assert_no_process_matching "fake-codex-hang:$FAKE_CODEX_LOG"
}
test_check_orphan_kill_never_acts_while_waiter_alive() {
  # 유예를 건너뛰어도 다른 조건은 그대로: 살아 있는 대기자가 기다리는 호출은 멈추지 않는다
  FAKE_CODEX_SEQ=hang; CC_ORPHAN_GRACE_SECS=60; start_task; run_cc call plan; assert_code 0
  hk_until 5 hk_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  pg=$(state .running.pgid); cp=$(state .running.codex_pid)
  CC_POLL_SECS=30 hk_start_waiter --max 20
  hk_until 5 hk_waiter_registered || _fail "waiter 가 등록되지 않음"
  run_cc check-orphan --kill; assert_code 0
  assert_eq "$OUT" ""
  kill -0 "$cp" 2>/dev/null || _fail "살아 있는 대기자가 있는데 Codex 를 죽임"
  hk_group_alive "$pg" || _fail "살아 있는 대기자가 있는데 그룹을 죽임"
  assert_eq "$(state .running.call_id)" "1"
  kill -TERM "$WP"; wait "$WP"; rc=$?
  assert_eq "$rc" "130"
}
test_check_orphan_kill_inside_grace_changes_nothing_when_unverifiable() {
  # R8: 확인할 수 없으면(2) 유예를 건너뛰어도 아무것도 바꾸지 않는다
  FAKE_CODEX_SEQ=hang; CC_ORPHAN_GRACE_SECS=60; start_task; run_cc call plan; assert_code 0
  hk_until 5 hk_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  pg=$(state .running.pgid)
  hk_fake_ps_fail_pgid
  PATH="$TMP/bin:$PATH" run_cc check-orphan --kill; assert_code 10
  assert_eq "$(hk_lines "$OUT")" "1"; assert_contains "$OUT" "확인하지 못해"
  assert_eq "$(state .running.call_id)" "1"; assert_no_path "$CALL1/status"
  hk_group_alive "$pg" || _fail "확인하지 못한 채 그룹을 죽임"
  hk_reap
}

# ==== addendum D: 감독 프로세스·codex 는 없는데 확인할 수 없는 것이 그룹에 남은 경우 (막다른 길 없음) ====
test_unverifiable_leftover_group_is_reported_not_killed() {
  FAKE_CODEX_SEQ=hang; start_task; run_cc call plan; assert_code 0
  hk_until 5 hk_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  pg=$(state .running.pgid); cp=$(state .running.codex_pid)
  kill -KILL "$pg" "$cp"                          # 둘 다 기록 없이 사라지고 codex 의 자식만 그룹에 남는다
  hk_until 3 eval '! kill -0 "$pg" 2>/dev/null && ! kill -0 "$cp" 2>/dev/null' || _fail "기록된 프로세스가 끝나지 않음"
  pgrep -f -- "fake-codex-hang:$FAKE_CODEX_LOG" >/dev/null || _fail "그룹에 남은 자식이 없음 (테스트 전제 깨짐)"
  set_state ".running.started_at = \"$(hk_iso_ago 600)\""
  run_cc check-orphan; assert_code 10
  assert_eq "$(hk_lines "$OUT")" "1"
  assert_contains "$OUT" "프로세스 그룹 $pg"
  assert_contains "$OUT" "자동으로 종료하지 않습니다"
  assert_contains "$OUT" "ps -o pid,command -g $pg"
  run_cc check-orphan --kill; assert_code 10       # --kill 이어도 확인되지 않은 것은 죽이지 않는다
  assert_contains "$OUT" "ps -o pid,command -g $pg"
  pgrep -f -- "fake-codex-hang:$FAKE_CODEX_LOG" >/dev/null || _fail "확인되지 않은 프로세스를 죽임"
  run_cc discard; assert_code 6
  assert_eq "$(hk_lines "$OUT")" "1"; assert_contains "$OUT" "$pg"
  run_cc finish; assert_code 6
  assert_contains "$OUT" "$pg"
  assert_file_exists "$ACTIVE/state.json"
  run_cc preflight; assert_code 7
  assert_eq "$(hk_json .code)" "orphan_running"; assert_contains "$(hk_json .message)" "ps -o pid,command -g $pg"
  hk_set_state_locked ".last_activity_at = \"$(hk_stale_iso)\""
  run_cc cleanup-stale; assert_code 0
  assert_eq "$(hk_lines "$OUT")" "1"; assert_contains "$OUT" "$pg"
  assert_file_exists "$ACTIVE/state.json"
  # 그룹이 비면 평소처럼: 죽은 기록은 정리되고 버릴 수 있다
  kill -KILL -- "-$pg" 2>/dev/null; hk_until 3 eval '! hk_group_alive "$pg"' || _fail "그룹이 끝나지 않음"
  run_cc check-orphan; assert_code 0; assert_eq "$OUT" ""
  hk_assert_terminal 1 interrupted interrupted
  run_cc discard; assert_code 0
  assert_no_path "$ACTIVE"
}

# ==== 최종 리뷰 minor e: 그룹 리더 PID 가 "없음" 인지 "다른 프로세스가 씀(재사용)" 인지 나눈다 ====
#   PID 는 같은 번호의 프로세스 그룹이 있는 동안 재사용되지 않는다. 그래서 리더 PID 를 신원이 다른 프로세스가 쓰고 있으면
#   우리 그룹은 이미 끝났다 → 그룹 확인 없이 dead. 리더가 없고 그룹이 비어 있지 않을 때만 남은 그룹(leftover)이다.
test_reused_leader_pid_is_dead_not_leftover() {
  hk_source_libs
  start_task
  # 다른 프로세스가 그 번호로 자기 그룹을 이끌고 있다 (우리 감독 프로세스와 신원이 다름)
  other=$(cc_spawn_group "$TMP/other.log" perl -e 'sleep 60' "unrelated-leader-$TMP") || _fail "대역 준비 실패"
  oid=$(cc_proc_identity "$other") || _fail "신원을 얻지 못함"
  mkdir -p "$ACTIVE/calls/1"
  set_state ".calls_total = 1 | .running = {call_id: 1, kind: \"plan\", pgid: $other,
    supervisor_identity: \"Thu Jan  1 00:00:00 2020|bash /x/cc-codex.sh _supervise 1\", codex_pid: null,
    codex_identity: null, started_at: \"$(hk_iso_ago 600)\", review_tree: null}"
  _cc_call_liveness "$(cat "$ACTIVE/state.json")"
  assert_eq "$_CC_LIVENESS" "dead"
  assert_eq "$_CC_LIVENESS_LEFTOVER" "0"
  # 중단 처리도 같은 판단: 아무 신호도 보내지 않고 "끝남" (0)
  _cc_wait_stop_group "$other" "Thu Jan  1 00:00:00 2020|bash /x/cc-codex.sh _supervise 1" "" ""; r=$?
  assert_eq "$r" "0" "_cc_wait_stop_group"
  # check-orphan 은 남은 그룹으로 알리지 않고 죽은 기록으로 정리한다. 다른 프로세스는 건드리지 않는다
  run_cc check-orphan; assert_code 0; assert_eq "$OUT" ""
  hk_assert_terminal 1 interrupted interrupted
  run_cc discard; assert_code 0
  assert_code_of 0 cc_proc_alive_verified "$other" "$oid"
  kill -KILL -- "-$other" 2>/dev/null
}
test_leader_with_same_command_but_other_start_time_is_not_declared_dead() {
  # 시작 시각만 다르고 명령줄이 같으면(예: 기록한 쪽과 확인하는 쪽의 시간대 차이) 재사용으로 단정하지 않는다:
  #   그 그룹이 살아 있으면 dead 로 지우지 않는다 (예전처럼 그룹을 직접 확인, 확인할 수 없는 것으로 남김)
  hk_source_libs
  start_task
  other=$(cc_spawn_group "$TMP/other.log" perl -e 'sleep 60' "same-cmd-leader-$TMP") || _fail "대역 준비 실패"
  oid=$(cc_proc_identity "$other") || _fail "신원을 얻지 못함"
  mkdir -p "$ACTIVE/calls/1"
  set_state ".calls_total = 1 | .running = {call_id: 1, kind: \"plan\", pgid: $other,
    supervisor_identity: \"Thu Jan  1 00:00:00 2020|${oid#*|}\", codex_pid: null,
    codex_identity: null, started_at: \"$(hk_iso_ago 600)\", review_tree: null}"
  _cc_call_liveness "$(cat "$ACTIVE/state.json")"
  [ "$_CC_LIVENESS" != dead ] || _fail "살아 있는 그룹을 dead 로 봄"
  run_cc discard; assert_code 6
  assert_file_exists "$ACTIVE/state.json"
  assert_code_of 0 cc_proc_alive_verified "$other" "$oid"
  kill -KILL -- "-$other" 2>/dev/null
}
test_absent_leader_with_live_group_stays_leftover() {
  hk_source_libs
  start_task
  hk_leftover_group || _fail "남은 그룹 준비 실패"
  mkdir -p "$ACTIVE/calls/1"
  set_state ".calls_total = 1 | .running = {call_id: 1, kind: \"plan\", pgid: $LEFT_PG,
    supervisor_identity: \"Thu Jan  1 00:00:00 2020|bash /x/cc-codex.sh _supervise 1\", codex_pid: null,
    codex_identity: null, started_at: \"$(hk_iso_ago 600)\", review_tree: null}"
  _cc_call_liveness "$(cat "$ACTIVE/state.json")"
  assert_eq "$_CC_LIVENESS" "uncertain"
  assert_eq "$_CC_LIVENESS_LEFTOVER" "1"
  _cc_wait_stop_group "$LEFT_PG" "Thu Jan  1 00:00:00 2020|bash /x/cc-codex.sh _supervise 1" "" ""; r=$?
  assert_eq "$r" "2" "_cc_wait_stop_group"
  kill -0 "$LEFT_MEMBER" 2>/dev/null || _fail "확인되지 않은 프로세스를 죽임"
  kill -KILL "$LEFT_MEMBER" 2>/dev/null
}

# ==== cleanup-stale (14일, last_activity_at 기준) ====
test_stale_deletes_when_codex_dead() {
  start_task
  set_state ".last_activity_at = \"$(hk_stale_iso)\""
  run_cc cleanup-stale; assert_code 0
  assert_eq "$OUT" "[cc] 오래된 /cc 중단 기록을 정리했습니다"
  assert_no_path "$ACTIVE"
  run_cc cleanup-stale; assert_code 0; assert_eq "$OUT" ""     # 지울 것이 없으면 아무 출력 없음
}
test_stale_deletes_when_recorded_codex_is_certainly_gone() {
  FAKE_CODEX_SEQ=hang; start_task; run_cc call plan; assert_code 0
  hk_until 5 hk_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  pg=$(state .running.pgid)
  kill -KILL -- "-$pg"; hk_until 3 eval '! hk_group_alive "$pg"' || _fail "그룹이 끝나지 않음"
  set_state ".last_activity_at = \"$(hk_stale_iso)\""
  run_cc cleanup-stale; assert_code 0
  assert_eq "$OUT" "[cc] 오래된 /cc 중단 기록을 정리했습니다"
  assert_no_path "$ACTIVE"
}
test_stale_keeps_when_codex_alive() {
  start_task
  hk_fake_running "$(hk_stale_iso)" "$(hk_stale_iso)" || _fail "대역 준비 실패"
  run_cc cleanup-stale; assert_code 0
  assert_eq "$OUT" "[cc] 오래된 /cc 기록이 있지만 Codex가 아직 실행 중이라 지우지 않았습니다"
  assert_file_exists "$ACTIVE/state.json"
  kill -0 "$FAKE_SUP_PG" 2>/dev/null || _fail "프로세스를 죽임"
  kill -KILL -- "-$FAKE_SUP_PG" 2>/dev/null
}
test_stale_rechecks_under_lock_before_deleting() {
  # 처음 볼 때는 실행 중인 호출이 없었지만, 지우기 직전(잠금을 기다리는 사이) 다른 쪽이 호출을 시작했다 → 지우지 않는다
  start_task
  old=$(hk_stale_iso)
  set_state ".last_activity_at = \"$old\""
  pg=$(cc_spawn_group "$TMP/fake-sup.log" perl -e 'sleep 60' "fake-supervisor-$TMP") || _fail "대역 준비 실패"
  id=$(cc_proc_identity "$pg") || _fail "신원을 얻지 못함"
  ( cc_state_lock || exit 1; : > "$TMP/locked"; sleep 1.5
    set_state ".calls_total = 1 | .running = {call_id: 1, kind: \"plan\", pgid: $pg, supervisor_identity: \"$id\",
      codex_pid: null, codex_identity: null, started_at: \"$old\", review_tree: null}"
    cc_state_unlock ) &
  holder=$!
  hk_until 3 test -e "$TMP/locked" || _fail "잠금을 쥐지 못함 (테스트 전제 깨짐)"
  run_cc cleanup-stale; assert_code 0
  wait "$holder"
  assert_eq "$OUT" "[cc] 오래된 /cc 기록이 있지만 Codex가 아직 실행 중이라 지우지 않았습니다"
  assert_file_exists "$ACTIVE/state.json"
  assert_eq "$(state .running.call_id)" "1"
  kill -KILL -- "-$pg" 2>/dev/null
}
test_stale_keeps_when_liveness_uncertain() {
  start_task
  hk_fake_running "$(hk_stale_iso)" "$(hk_stale_iso)" || _fail "대역 준비 실패"
  hk_fake_ps_fail
  PATH="$TMP/bin:$PATH" run_cc cleanup-stale; assert_code 0
  assert_eq "$(hk_lines "$OUT")" "1"; assert_contains "$OUT" "확인할 수 없어 지우지 않았습니다"
  assert_contains "$OUT" "실행 여부"
  assert_file_exists "$ACTIVE/state.json"
  # 판단할 수 없음은 삭제의 근거가 아니다 (R8): 버리기·마무리도 거부한다
  PATH="$TMP/bin:$PATH" run_cc discard; assert_code 6
  assert_eq "$(hk_lines "$OUT")" "1"; assert_contains "$OUT" "확인할 수 없어"
  PATH="$TMP/bin:$PATH" run_cc finish; assert_code 6
  assert_file_exists "$ACTIVE/state.json"
  kill -KILL -- "-$FAKE_SUP_PG" 2>/dev/null
}
test_stale_keeps_when_activity_unreadable() {
  start_task
  for bad in 'del(.last_activity_at)' '.last_activity_at = "어제"' '.last_activity_at = 12345' \
             '.last_activity_at = "2026-13-45T00:00:00Z"'; do
    cp "$ACTIVE/state.json" "$TMP/state.bak"
    set_state "$bad"
    run_cc cleanup-stale; assert_code 0
    assert_eq "$OUT" "[cc] 오래된 /cc 기록 상태를 확인할 수 없어 지우지 않았습니다" "$bad"
    assert_file_exists "$ACTIVE/state.json"
    cp "$TMP/state.bak" "$ACTIVE/state.json"
  done
  echo '{bad' > "$ACTIVE/state.json"
  run_cc cleanup-stale; assert_code 0
  assert_eq "$OUT" "[cc] 오래된 /cc 기록 상태를 확인할 수 없어 지우지 않았습니다"
  assert_file_exists "$ACTIVE/state.json"
  rm -f "$ACTIVE/state.json"
  run_cc cleanup-stale; assert_code 0
  assert_contains "$OUT" "확인할 수 없어"
  assert_file_exists "$ACTIVE/brief.md"
}
test_stale_uses_last_activity_not_mtime() {
  start_task
  find "$ACTIVE" -exec touch -t 202601010000 {} +
  run_cc cleanup-stale; assert_code 0
  assert_eq "$OUT" ""
  assert_file_exists "$ACTIVE/state.json"
  set_state ".last_activity_at = \"$(hk_iso_ago $((13 * 86400)))\""   # 14일 이하
  run_cc cleanup-stale; assert_code 0
  assert_eq "$OUT" ""
  assert_file_exists "$ACTIVE/state.json"
}
test_stale_keeps_when_path_abnormal() {
  start_task
  set_state ".last_activity_at = \"$(hk_stale_iso)\""
  gd=$(git rev-parse --absolute-git-dir)
  mv "$gd/yultopia-cc/active" "$TMP/elsewhere"
  ln -s "$TMP/elsewhere" "$gd/yultopia-cc/active"
  run_cc cleanup-stale; assert_code 0
  assert_eq "$(hk_lines "$OUT")" "1"; assert_contains "$OUT" "지우지 않았습니다"
  [ -L "$gd/yultopia-cc/active" ] || _fail "심볼릭 링크가 사라짐"
  assert_file_exists "$TMP/elsewhere/state.json"
}

# ==== preflight ====
test_preflight_not_git() {
  mkdir -p "$TMP/plain"; cd "$TMP/plain"
  run_cc preflight; assert_code 7
  assert_eq "$(hk_lines "$OUT")" "1"
  assert_eq "$(hk_json .code)" "not_git"; assert_eq "$(hk_json .ok)" "false"
  assert_eq "$(hk_json '.dirty_files | length')" "0"
  assert_eq "$(hk_json .stale_notice)" "null"; assert_eq "$(hk_json .active)" "null"
  assert_contains "$(hk_json .message)" "[cc] "
}
test_preflight_no_jq() {
  repo=$(make_repo); cd "$repo"
  mkdir -p "$TMP/nojq"
  for t in dirname basename git; do ln -s "$(command -v "$t")" "$TMP/nojq/$t"; done
  OUT=$(PATH="$TMP/nojq" /bin/bash "$CC_BIN" preflight 2>/dev/null); rc=$?
  assert_eq "$rc" "7"
  assert_eq "$(hk_lines "$OUT")" "1"
  assert_eq "$(hk_json .code)" "no_jq"; assert_eq "$(hk_json .ok)" "false"
  assert_eq "$(hk_json '.dirty_files | length')" "0"
  assert_eq "$(hk_json .stale_notice)" "null"; assert_eq "$(hk_json .active)" "null"
}
test_preflight_no_codex() {
  repo=$(make_repo); cd "$repo"
  CC_CODEX_BIN="$TMP/no-such-codex" run_cc preflight; assert_code 7
  assert_eq "$(hk_json .code)" "no_codex"; assert_eq "$(hk_json .ok)" "false"
}
test_preflight_not_logged_in() {
  repo=$(make_repo); cd "$repo"
  FAKE_CODEX_LOGIN=fail run_cc preflight; assert_code 7
  assert_eq "$(hk_json .code)" "not_logged_in"; assert_eq "$(hk_json .ok)" "false"
  assert_eq "$(cat "$(hk_log)/login.calls" 2>/dev/null)" "login status"
  assert_eq "$(hk_invocations)" "0"              # 로그인 확인 말고는 codex 를 부르지 않는다
}
test_preflight_ready_and_ignores_gitignored_files() {
  repo=$(make_repo); cd "$repo"
  echo '*.log' > .gitignore; git add .gitignore; git commit -q -m ignore
  echo noise > debug.log
  run_cc preflight; assert_code 0
  assert_eq "$(hk_lines "$OUT")" "1"
  assert_eq "$(hk_json .code)" "ready"; assert_eq "$(hk_json .ok)" "true"
  assert_eq "$(hk_json '.dirty_files | length')" "0"
  assert_eq "$(hk_json .stale_notice)" "null"; assert_eq "$(hk_json .active)" "null"
  assert_eq "$(hk_json '.message | type')" "string"
  assert_eq "$(cat "$(hk_log)/login.calls" 2>/dev/null)" "login status"
  assert_eq "$(hk_invocations)" "0"
}
test_preflight_refuses_dirty_tree_with_files() {
  repo=$(make_repo "my repo 한글"); cd "$repo"
  echo new > a.txt; echo changed >> base.txt; echo x > "새 파일.txt"
  run_cc preflight; assert_code 7
  assert_eq "$(hk_lines "$OUT")" "1"
  assert_eq "$(hk_json .code)" "dirty"; assert_eq "$(hk_json .ok)" "false"
  assert_eq "$(hk_json '.dirty_files | sort | join(",")')" "a.txt,base.txt,새 파일.txt"
  assert_eq "$(hk_json .active)" "null"
  for i in 1 2 3 4 5 6 7 8 9 10; do mkdir -p d; echo "$i" > "d/f$i.txt"; done
  run_cc preflight; assert_code 7
  assert_eq "$(hk_json '.dirty_files | length')" "10"   # 최대 10개만
  assert_contains "$(hk_json .message)" "13"           # 전체 개수는 메시지에
}
test_preflight_reports_active_present() {
  start_task
  run_cc preflight; assert_code 7
  assert_eq "$(hk_lines "$OUT")" "1"
  assert_eq "$(hk_json .code)" "active_present"; assert_eq "$(hk_json .ok)" "false"
  assert_eq "$(hk_json .active.phase)" "planning"
  assert_eq "$(hk_json .active.milestone)" "null"; assert_eq "$(hk_json .active.milestones_total)" "null"
  assert_eq "$(hk_json .active.last_activity_at)" "$(state .last_activity_at)"
  assert_eq "$(hk_json '.active | keys | join(",")')" "last_activity_at,milestone,milestones_total,phase"
  echo '{bad' > "$ACTIVE/state.json"              # 읽을 수 없는 기록도 남아 있다고 알린다 (active 는 null)
  run_cc preflight; assert_code 7
  assert_eq "$(hk_lines "$OUT")" "1"
  assert_eq "$(hk_json .code)" "active_present"; assert_eq "$(hk_json .active)" "null"
  assert_contains "$(hk_json .stale_notice)" "확인할 수 없어"
}
test_preflight_cleans_dead_record_and_reports_active() {
  FAKE_CODEX_SEQ=hang; start_task; run_cc call plan; assert_code 0
  hk_until 5 hk_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  pg=$(state .running.pgid)
  kill -KILL -- "-$pg"; hk_until 3 eval '! hk_group_alive "$pg"' || _fail "그룹이 끝나지 않음"
  run_cc preflight; assert_code 7
  assert_eq "$(hk_json .code)" "active_present"
  assert_eq "$(hk_json .active.phase)" "interrupted"
  hk_assert_terminal 1 interrupted interrupted
}
test_discard_and_finish_delete_unreadable_record() {
  # 사용자가 직접 고른 삭제: 상태 파일을 읽을 수 없으면 지킬 실행 기록도 없으므로 지운다 (막다른 길 없음)
  start_task
  echo '{bad' > "$ACTIVE/state.json"
  run_cc discard; assert_code 0
  assert_no_path "$ACTIVE"
  printf 'x\n' | run_cc init; assert_code 0
  rm -f "$ACTIVE/state.json"
  run_cc finish; assert_code 0
  assert_no_path "$ACTIVE"
}
test_preflight_reports_stale_notice() {
  start_task
  set_state ".last_activity_at = \"$(hk_stale_iso)\""
  run_cc preflight; assert_code 0
  assert_eq "$(hk_json .stale_notice)" "[cc] 오래된 /cc 중단 기록을 정리했습니다"
  assert_eq "$(hk_json .code)" "ready"; assert_eq "$(hk_json .active)" "null"
  assert_no_path "$ACTIVE"
}
test_preflight_reports_orphan_running() {
  FAKE_CODEX_SEQ=hang; CC_ORPHAN_GRACE_SECS=1; start_task; run_cc call plan; assert_code 0
  hk_until 5 hk_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  sleep 2.2
  run_cc preflight; assert_code 7
  assert_eq "$(hk_lines "$OUT")" "1"
  assert_eq "$(hk_json .code)" "orphan_running"
  assert_contains "$(hk_json .message)" "대기 명령 없이"
  assert_eq "$(hk_json .active.phase)" "planning"
  kill -0 "$(state .running.codex_pid)" 2>/dev/null || _fail "preflight 가 Codex 를 죽임"
  hk_reap
}

# ==== discard / finish ====
test_discard_refuses_while_codex_running() {
  FAKE_CODEX_SEQ=hang; start_task; run_cc call plan; assert_code 0
  hk_until 5 hk_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  run_cc discard; assert_code 6
  assert_eq "$OUT" "[cc] Codex가 실행 중입니다. 먼저 종료하세요"
  assert_file_exists "$ACTIVE/state.json"; assert_eq "$(state .running.call_id)" "1"
  run_cc finish; assert_code 6
  assert_eq "$OUT" "[cc] Codex가 실행 중입니다. 먼저 종료하세요"
  assert_file_exists "$ACTIVE/state.json"
  hk_reap
}
test_discard_deletes_idle_task_and_keeps_code() {
  start_task
  echo mine >> base.txt
  run_cc discard; assert_code 0
  assert_eq "$(hk_lines "$OUT")" "1"
  assert_no_path "$ACTIVE"
  assert_eq "$(tail -n 1 base.txt)" "mine"
  run_cc discard; assert_code 0; assert_contains "$OUT" "진행 중인 작업이 없습니다"
}
test_discard_refuses_symlinked_active() {
  start_task
  gd=$(git rev-parse --absolute-git-dir)
  mv "$gd/yultopia-cc/active" "$TMP/elsewhere"
  ln -s "$TMP/elsewhere" "$gd/yultopia-cc/active"
  run_cc discard; assert_code 1
  assert_eq "$(hk_lines "$OUT")" "1"
  [ -L "$gd/yultopia-cc/active" ] || _fail "심볼릭 링크가 사라짐"
  assert_file_exists "$TMP/elsewhere/brief.md"
}
test_only_one_active_after_discard_and_restart() {
  repo=$(make_repo); cd "$repo"
  printf '첫 작업\n' | run_cc init; assert_code 0
  run_cc discard; assert_code 0
  printf '둘째 작업\n' | run_cc init; assert_code 0
  gd=$(git rev-parse --absolute-git-dir)
  assert_eq "$(ls -A "$gd/yultopia-cc")" "active"
  assert_eq "$(cat "$(cc_path brief)")" "둘째 작업"
}

# ==== Task 9 추가 항목 (R23 A–E) ====
# A. 고아·죽은 기록 정리는 14일 시계를 되돌리지 않는다
test_dead_record_cleanup_keeps_last_activity() {
  start_task
  old=$(hk_iso_ago $((13 * 86400)))
  hk_fake_running "$(hk_iso_ago 5)" "$old" || _fail "대역 준비 실패"
  kill -KILL -- "-$FAKE_SUP_PG"; hk_until 3 eval '! hk_group_alive "$FAKE_SUP_PG"' || _fail "그룹이 끝나지 않음"
  run_cc check-orphan; assert_code 0
  assert_eq "$(state .running)" "null"; assert_eq "$(state .phase)" "interrupted"
  assert_eq "$(state .last_activity_at)" "$old" "check-orphan 이 last_activity_at 을 바꿈"
  # preflight 의 정리도 마찬가지
  hk_fake_running "$(hk_iso_ago 5)" "$old" || _fail "대역 준비 실패"
  kill -KILL -- "-$FAKE_SUP_PG"; hk_until 3 eval '! hk_group_alive "$FAKE_SUP_PG"' || _fail "그룹이 끝나지 않음"
  run_cc preflight
  assert_eq "$(state .running)" "null"
  assert_eq "$(state .last_activity_at)" "$old" "preflight 가 last_activity_at 을 바꿈"
}
# B. running 이 객체가 아닌 기록은 discard·finish 가 막다른 길이 되지 않는다
test_discard_and_finish_delete_malformed_running() {
  for bad in '"garbage"' '[]' '5' '{}' '{"call_id":"x"}' '{"call_id":1,"pgid":"abc"}' '{"call_id":1,"pgid":99999}' '{"call_id":1,"pgid":1,"supervisor_identity":"nobar"}' '{"call_id":1,"pgid":0,"supervisor_identity":"a|b"}'; do
    start_task "bad$RANDOM"
    set_state ".running = $bad"
    run_cc discard; assert_code 0
    assert_eq "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "1"
    assert_not_contains "$OUT" "다시 시도"
    assert_no_path "$ACTIVE"
  done
  start_task "bad-finish"
  set_state '.running = "garbage"'
  run_cc finish; assert_code 0
  assert_no_path "$ACTIVE"
}
test_cleanup_stale_never_deletes_malformed_running() {
  start_task
  for bad in '"garbage"' '{"call_id":1,"pgid":"abc"}' '{"call_id":1,"pgid":99999}' '{"call_id":1,"pgid":1,"supervisor_identity":"nobar"}'; do
    set_state ".running = $bad | .last_activity_at = \"$(hk_stale_iso)\""
    run_cc cleanup-stale; assert_code 0
    assert_file_exists "$ACTIVE/state.json"
    assert_contains "$OUT" "지우지 않았습니다"
  done
}
# C. 감독 프로세스만 KILL 된 고아를 check-orphan --kill 이 스스로 마무리한다
test_check_orphan_kill_settles_after_supervisor_sigkill() {
  FAKE_CODEX_SEQ=hang; CC_ORPHAN_GRACE_SECS=1; start_task; run_cc call plan; assert_code 0
  hk_until 5 hk_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  pg=$(state .running.pgid); cp=$(state .running.codex_pid)
  kill -KILL "$pg"; hk_until 3 eval '! kill -0 "$pg" 2>/dev/null' || _fail "감독 프로세스가 끝나지 않음"
  kill -0 "$cp" 2>/dev/null || _fail "codex 가 이미 없음"
  sleep 2.2
  run_cc check-orphan --kill; assert_code 10
  assert_eq "$(hk_lines "$OUT")" "1"
  hk_assert_terminal 1 interrupted interrupted
  hk_until 3 eval '! kill -0 "$cp" 2>/dev/null' || _fail "codex 가 남아 있음"
  hk_until 3 eval '! hk_group_alive "$pg"' || _fail "그룹이 남아 있음"
}
# D. 이름 바꾸기는 새 이름만 한 번 나온다
test_preflight_dirty_rename_lists_new_name_once() {
  repo=$(make_repo "rename repo"); cd "$repo"
  git mv base.txt moved.txt
  run_cc preflight; assert_code 7
  assert_eq "$(hk_json '.dirty_files | join(",")')" "moved.txt"
  assert_contains "$(hk_json .message)" "1개"
}
# E. codex login status 가 멈춰도 preflight 는 멈추지 않는다
test_preflight_login_status_timeout() {
  repo=$(make_repo); cd "$repo"
  FAKE_CODEX_LOGIN=hang; CC_LOGIN_TIMEOUT_SECS=1
  export CC_LOGIN_TIMEOUT_SECS
  t0=$(date +%s)
  run_cc preflight; assert_code 7
  t1=$(date +%s)
  [ $((t1 - t0)) -lt 8 ] || _fail "preflight 가 너무 오래 걸림: $((t1 - t0))초"
  assert_eq "$(hk_lines "$OUT")" "1"
  assert_eq "$(hk_json .code)" "not_logged_in"
  assert_contains "$(hk_json .message)" "시간"
}
# 형식이 틀린 running 기록: preflight 는 버리기만 가능하다고 알리고, call 은 버리기를 안내한다
test_malformed_running_messages_point_to_discard() {
  start_task
  set_state '.running = "garbage"'
  run_cc preflight; assert_code 7
  assert_eq "$(hk_json .code)" "active_present"
  assert_contains "$(hk_json .message)" "버릴 수"
  assert_not_contains "$(hk_json .message)" "이어 하거나"
  run_cc call plan; assert_code 6
  assert_contains "$OUT" "discard"
  assert_not_contains "$OUT" "호출 )"
}
