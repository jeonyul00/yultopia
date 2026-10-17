# wait.sh - cc-codex.sh wait [--max SECS]: 실행 중인 Codex 호출이 끝나길 기다리고 한 줄만 돌려준다.
#   중단 신호(INT/TERM/HUP)를 받으면 기다리던 호출의 감독 프로세스 그룹을 검증 후 끝내고 일관된 끝 상태를 남긴다.
# source 전용 (bash 3.2 호환). common.sh, state.sh, proc.sh, call.sh 뒤에 불러온다 (call.sh 의 도우미를 쓴다).
#
# 출력 (stdout 은 언제나 한 줄. Codex 이벤트 로그·중간 메시지는 절대 내보내지 않는다)
#   끝남 ok              → result.json 을 jq -c 한 줄, 0
#   끝남 timeout         → last_call.message (없으면 설정값으로 "[cc] Codex 시간 초과(20분) — 자동 재시도하지 않았습니다"), 3
#   끝남 그 밖(error, invalid_json, interrupted …) → last_call.message, 3
#   --max 초 안에 안 끝남 → "[cc] Codex 실행 중 · 호출 N · 경과 M분 · 마지막 활동 S초 전", 2
#   이 wait 가 INT/TERM/HUP 을 받음 → "[cc] 중단됨: Codex 종료" 등 한 줄, 130 (아래 "중단 처리")
#     130 은 이 wait 자신이 신호를 받았을 때만이다 (Ruling R19). 앞서 기록된 interrupted 나, 이 wait 가 찾아낸
#     "기록 없이 죽은 호출" 을 state 에서 읽어 알릴 때는 3.
#   실행 중인 호출도 끝난 호출도 없음 → "[cc] 기다릴 Codex 호출이 없습니다", 3
#   작업 없음·사용법·상태 파일 오류 → 한 줄, 3
#   이미 끝난 호출을 다시 기다리면 같은 규칙으로 그 결과를 다시 알린다 (몇 번 불러도 같다).
#
# 기다리는 방법
#   기다릴 호출(_CC_WAIT_ID)은 시작할 때 running.call_id 로 정한다 (신호 trap 을 걸기 전).
#   CC_POLL_SECS 마다 calls/<id>/status 를 먼저 보고 state 를 읽는다 (감독 프로세스는 state → status 순서로 쓴다).
#   - running 이 더 이상 이 호출이 아니면 끝난 것: state 의 last_call 로 알린다. status 파일이 없거나 state 와
#     다르면 잠금 안에서 state 값으로 맞춘다 (status 파일 == state).
#     running 이 이 호출이어도 stop_failed (끝 상태는 기록됐지만 종료를 확인하지 못해 프로세스 기록만 남김, R30) 면
#     끝난 것으로 보고 같은 방법으로 알린다 (기다리지 않는다).
#   - running 이 아직 이 호출이면 기록된 감독 프로세스·codex 와 그 그룹이 살아 있는지 본다 (_cc_call_is_running).
#     감독 프로세스·codex 가 둘 다 확실히 없고(R8: "확실히 없음" 만 인정) 그룹도 비었으면 기록 없이 죽은 호출이다.
#     running.call_id 가 맞을 때만 interrupted 로 기록하고 (Task 8 의 dead 정리와 같은 값) status 파일을 state 에서
#     쓴다. 판단 불가거나 그룹에 무언가 남아 있으면 계속 기다린다.
#   - 확인할 때마다 대기자 기록을 살린다 (_cc_wait_heartbeat).
#   - --max 가 차면 상태 한 줄. 잠은 --max 를 넘기지 않게 줄여 잔다 (실제 시각, 밀리초 단위).
#   --max 기본값은 CC_WAIT_MAX_SECS(540), 최대 560: Claude Code Bash 도구 1회 10분 제한 안에서 중단 처리까지 끝나야 한다.
#   잠은 백그라운드 sleep 을 wait 로 기다린다 (신호에 바로 깨도록). 그 sleep 에는 어떤 신호도 보내지 않는다:
#   끝나서 거둬진 뒤에는 PID 가 재사용됐을 수 있기 때문이다. 표준 입출력을 /dev/null 로 두어 남아도 아무것도 붙잡지 않는다.
#
# 대기자 기록 (Task 8 고아 판정: "Codex 는 사는데 살아 있는 대기자가 grace 넘게 없음")
#   시작: waiter = {pid: $$, identity, started_at}.
#   확인할 때마다: waiter_last_seen_at = 지금. waiter 가 비었거나 다른 대기자 기록인데 그 프로세스가 확실히 없으면
#     자기를 다시 기록한다 (동시에 기다리던 다른 wait 가 끝나며 자리를 비운 경우). 그래서 살아 있는 대기자가 있는 동안
#     "대기자 없음" 이 확인 간격보다 오래 이어지지 않는다.
#   끝(EXIT trap 포함): waiter 가 자기 기록이면 null, waiter_last_seen_at = 지금. 쓰기에 실패하면 다음 기회(EXIT trap,
#     신호 처리)에 다시 한다.
#   이 갱신들은 last_activity_at 을 바꾸지 않는다 (상태 줄의 "마지막 활동" 은 Codex 쪽 활동).
#   출력 줄을 쓰기 전에 기록을 지운다 (출력 파이프가 닫혀 있어 쓰다가 죽어도 기록이 남지 않도록).
#
# 중단 처리 (INT/TERM/HUP. addendum A, B, Ruling R20)
#   1) 두 번째 신호가 정리를 끊지 않도록 INT/TERM/HUP 을 무시로 바꾸고, 쥐고 있던 state 잠금이 있으면 놓는다
#      (감독 프로세스의 마무리에 잠금이 필요하므로 잠금을 쥔 채 죽이지 않는다). 쥐지 않았으면 아무것도 하지 않는다.
#   2) 기다리던 호출만 멈춘다. 첫 TERM 은 state 를 다시 읽지 않고, 확인할 때마다 기억해 둔 그 호출의 감독 프로세스
#      (pgid·신원)에 신원 확인 뒤 바로 보낸다 (지연 줄이기). 그 감독 프로세스가 이미 없거나 판단할 수 없으면 그때
#      state 를 읽어, 기다리던 호출이 아직 running 일 때만 멈춘다. 그 사이 끝났거나 다른 호출이 running 이면
#      아무것도 멈추지 않는다 (다른 호출의 감독 프로세스는 신원이 달라 첫 TERM 도 가지 않는다).
#   3) codex 만이 아니라 감독 프로세스 그룹 전체에 신호를 보낸다 (B: codex 만 죽으면 빠른 기술 오류처럼 보여 재실행된다).
#      cc_kill_group_verified <pgid> <감독 프로세스 신원> 100: TERM 뒤 감독 프로세스가 스스로 멤버를 정리하고
#      (중단 경로: 멤버 TERM 3초 + KILL 최대 2초) 상태를 기록하고 끝날 때까지 최대 10초 기다린다.
#      감독 프로세스가 끝났는데 그룹에 남은 것이 있거나 10초가 지나면 그때 그룹에 KILL.
#      감독 프로세스가 이미 없으면 기록된 codex 신원으로 cc_kill_group_via_member.
#   4) 끝냈으면 잠금 안에서: running.call_id 가 아직 이 호출일 때만 interrupted 로 기록하고 (감독 프로세스가 기록 전에
#      끝난 경우), state 가 이 호출에 기록한 값으로 status 파일을 맞춘다. 감독 프로세스가 먼저 기록했으면 그 값을 따른다.
#      KILL 뒤에도 남았으면(3) 끝 상태는 같은 방법으로 기록하되 running 은 stop_failed 로 남긴다 (R30).
#   5) 확인할 수 없어 아무 신호도 보내지 못했으면(R8 의 2, 또는 감독 프로세스·codex 는 없는데 그룹에 확인할 수 없는
#      것이 남음) 상태를 바꾸지 않는다. 호출은 계속되고 Task 8 의 고아 확인이 맡는다.

_CC_WAIT_HARD_MAX=560            # 초. 중단 처리(최대 약 20초)까지 Bash 도구 10분 안에 끝나도록
_CC_WAIT_SUP_GRACE_TENTHS=100    # 중단 때 감독 프로세스가 스스로 정리·기록하고 끝나길 기다리는 시간 (0.1초 단위)
_CC_WAIT_INTERRUPTED_LINE="[cc] 중단됨: Codex 종료"

# 전역: _CC_WAIT_ACTIVE(active 경로), _CC_WAIT_ID(기다리는 호출, 시작할 때 실행 중이던 호출. 없으면 빈 값),
#       _CC_WAIT_REG(대기자 기록: 0 안 함 / 1 기록함·지울 것 / 2 지움), _CC_WAIT_IDENT / _CC_WAIT_STARTED_AT(이 대기자),
#       _CC_WAIT_LINE / _CC_WAIT_CODE(출력할 한 줄과 종료 코드)

# _cc_wait_parse_max [--max SECS] : 쓸 최대 대기 초를 출력. 인자가 잘못됐으면 1
_cc_wait_parse_max() {
  local max
  max=$(_cc_sup_uint "${CC_WAIT_MAX_SECS:-}" 540)
  while [ $# -gt 0 ]; do
    case "$1" in
      --max) [ $# -ge 2 ] || return 1; max="$2"; shift 2 ;;
      *) return 1 ;;
    esac
  done
  case "$max" in ''|*[!0-9]*) return 1 ;; esac
  max="${max#"${max%%[!0]*}"}"              # 앞자리 0 제거 (10진수로 읽도록)
  [ -n "$max" ] || max=0
  [ "${#max}" -le 6 ] || max=$_CC_WAIT_HARD_MAX
  [ "$max" -le "$_CC_WAIT_HARD_MAX" ] || max=$_CC_WAIT_HARD_MAX
  printf '%s\n' "$max"
}

_cc_wait_now_ms() { perl -MTime::HiRes -e 'printf "%d\n", Time::HiRes::time() * 1000'; }

_cc_wait_read_state() { jq -ce 'select(type == "object")' "$_CC_WAIT_ACTIVE/state.json" 2>/dev/null; }

# 이 state(JSON) 의 running 이 호출 <id> 인가
_cc_wait_running_is() {
  [ "$(printf '%s' "$1" | jq -r --argjson id "$2" '(.running | type) == "object" and .running.call_id == $id' 2>/dev/null)" = true ]
}

# _cc_wait_running_cache <state-json> : running 이 기다리는 호출(_CC_WAIT_ID)이면 0. 그때 그 감독 프로세스(그룹 리더)의
#   pgid 와 신원을 _CC_WAIT_C_PG / _CC_WAIT_C_SID 에 기억한다 (jq 한 번). 아니면 1 (기억은 그대로 둔다).
#   중단 신호를 받으면 state 를 다시 읽지 않고 이 값으로 바로 검증된 TERM 을 보낸다 (최종 리뷰 Important 1: 지연 줄이기).
#   같은 호출의 pgid·감독 프로세스 신원은 바뀌지 않으므로 어느 확인 때 기억한 값이든 같다.
#   running.stop_failed 기록(끝 상태는 기록됐고 프로세스 기록만 남음, R30)은 끝난 호출이다: 1 (기다리지 않는다).
_cc_wait_running_cache() {
  local out yes="" pg="" sid=""
  out=$(printf '%s' "$1" | jq -r --argjson id "$_CC_WAIT_ID" '
      if (.running | type) == "object" and .running.call_id == $id and .running.stop_failed != true
      then "yes", (.running.pgid // "" | tostring), (.running.supervisor_identity // "" | tostring)
      else "no" end' 2>/dev/null)
  { IFS= read -r yes; IFS= read -r pg; IFS= read -r sid; } <<EOF
$out
EOF
  [ "$yes" = yes ] || return 1
  _CC_WAIT_C_PG=$pg; _CC_WAIT_C_SID=$sid
  return 0
}

# 잠금 안에서 state 를 고친다. last_activity_at 은 그대로 둔다 (대기자 기록 전용: 대기자는 Codex 활동이 아니다)
_cc_wait_update_keep_activity() {
  local filter="$1" tmp rc=1
  shift
  cc_state_lock || return 1
  if tmp=$(mktemp "$_CC_WAIT_ACTIVE/.state.XXXXXX"); then
    if jq "$@" "$filter" "$_CC_WAIT_ACTIVE/state.json" > "$tmp" 2>/dev/null \
       && jq -es -e 'length == 1 and (.[0] | type == "object")' "$tmp" >/dev/null 2>&1 \
       && mv "$tmp" "$_CC_WAIT_ACTIVE/state.json"; then
      rc=0
    else
      rm -f "$tmp"
    fi
  fi
  cc_state_unlock
  return "$rc"
}

_cc_wait_register() {
  _CC_WAIT_IDENT=$(cc_proc_identity $$) || _CC_WAIT_IDENT=""
  _CC_WAIT_STARTED_AT=$(cc_now_iso)
  _CC_WAIT_REG=1
  _cc_wait_update_keep_activity \
    '.waiter = {pid: $pid, identity: (if $ident == "" then null else $ident end), started_at: $now}' \
    --argjson pid "$$" --arg ident "$_CC_WAIT_IDENT" --arg now "$_CC_WAIT_STARTED_AT" \
    || cc_err "[cc] 대기자 기록을 남기지 못했습니다"
}

# 끝날 때 한 번: 자기 기록이면 waiter=null, waiter_last_seen_at=지금. 쓰기에 성공한 뒤에야 "지움" 으로 표시한다
# (쓰는 도중 신호가 오거나 잠금을 못 잡으면 신호 처리·EXIT trap 이 다시 한다)
_cc_wait_unregister() {
  [ "${_CC_WAIT_REG:-0}" = 1 ] || return 0
  if _cc_wait_update_keep_activity \
       '(if (.waiter | type) == "object" and .waiter.pid == $pid then .waiter = null else . end)
        | .waiter_last_seen_at = $now' \
       --argjson pid "$$" --arg now "$(cc_now_iso)"; then
    _CC_WAIT_REG=2
  else
    cc_err "[cc] 대기자 기록을 지우지 못했습니다"
  fi
}

# _cc_wait_heartbeat <state-json> <id> : 기다리는 동안 확인할 때마다 (잠금 안에서, last_activity_at 은 그대로)
#   - waiter_last_seen_at = 지금: 살아 있는 대기자가 있는 동안 "대기자 없음" 이 확인 간격보다 오래 이어지지 않는다.
#   - waiter 가 비었거나, 다른 대기자 기록인데 그 프로세스가 확실히 없으면(cc_proc_alive_verified → 1) 자기를 다시
#     기록한다. 살아 있거나 판단할 수 없는 다른 대기자의 기록은 그대로 둔다. 확인한 뒤 그 자리가 바뀌었으면 쓰지 않는다.
#   running 이 아직 이 호출일 때만 바꾼다.
_cc_wait_heartbeat() {
  local st="$1" id="$2" old take=0
  old=$(printf '%s' "$st" | jq -r 'if (.waiter | type) == "object" then (.waiter.pid | tostring) else "" end' 2>/dev/null)
  if [ -z "$old" ]; then
    take=1
  elif [ "$old" != "$$" ]; then
    cc_proc_alive_verified "$old" "$(_cc_jq_get "$st" '.waiter.identity // empty')"
    [ $? -eq 1 ] && take=1
  fi
  _cc_wait_update_keep_activity '
    if (.running | type) == "object" and .running.call_id == $id then
      .waiter_last_seen_at = $now
      | (if $take == 1
            and (if (.waiter | type) == "object" then (.waiter.pid | tostring) == $old else $old == "" end)
         then .waiter = {pid: $pid, identity: (if $ident == "" then null else $ident end), started_at: $started}
         else . end)
    else . end' \
    --argjson id "$id" --argjson take "$take" --arg old "$old" --argjson pid "$$" \
    --arg ident "$_CC_WAIT_IDENT" --arg started "$_CC_WAIT_STARTED_AT" --arg now "$(cc_now_iso)" \
    || cc_err "[cc] 대기자 확인 시각을 기록하지 못했습니다"
}

# _cc_wait_settle <id> [<status> <message> [keep]] : 잠금 안에서 호출 <id> 의 끝 상태를 정리한다.
#   - status 를 주면 running 이 아직 이 호출일 때만 바꾼다. 감독 프로세스가 먼저 끝 상태를 기록했으면 그것을 따른다.
#       keep 없음 = 그 호출의 프로세스가 사라진 것을 확인함 (검증된 종료 0, 또는 dead):
#         끝 상태가 없으면 그 값으로 끝낸다 (running=null, last_call, phase).
#         이미 끝 상태가 기록된 stop_failed 기록이면 running 만 지운다 (끝 상태·메시지는 그대로, R30).
#       keep = 종료를 확인하지 못함 (KILL 뒤에도 남음 3, R30): 끝 상태가 없으면 그 값으로 기록하되 running 은 지우지 않고
#         stop_failed 로 표시한다 (pgid·신원 그대로 → 훅·고아 확인·preflight·버리기·정리가 계속 본다). 이미 stop_failed 면 그대로.
#   - 그 뒤 state 가 이 호출에 기록한 status 를 읽어, status 파일이 없거나 다르면 그 값으로 쓴다 (status 파일 == state).
#   stdout: state 가 기록한 이 호출의 status, 0. 아직 끝 상태 없이 실행 중으로 기록돼 있거나 기록이 없거나 잠금 실패면 출력 없이 1
# 끝 상태를 쓰는 함수. 기본은 last_activity_at 을 지금으로 바꾼다. 죽은 기록 정리(housekeeping 의 _cc_hk_running_state)만
# _cc_wait_update_keep_activity 로 바꿔 14일 시계를 되돌리지 않는다. check-orphan --kill (사용자가 시킨 종료)은 갱신한다.
_CC_WAIT_SETTLE_WRITER=_cc_state_update_nolock
_cc_wait_settle() {
  local id="$1" st="${2:-}" msg="${3:-}" keep=0 final dir cur rc=1
  [ "${4:-}" = keep ] && keep=1
  cc_state_lock || return 1
  if [ -n "$st" ]; then
    $_CC_WAIT_SETTLE_WRITER '
      if (.running | type) == "object" and .running.call_id == $id then
        if .running.stop_failed == true then
          (if $keep == 1 then . else .running = null end)
        else
          .last_call = {call_id: $id, kind: .running.kind, status: $st, verdict: null,
                        message: (if $msg == "" then null else $msg end)}
          | .phase = (if $st == "interrupted" then "interrupted" else "failed" end)
          | (if $keep == 1 then .running.stop_failed = true else .running = null end)
        end
      else . end' --argjson id "$id" --arg st "$st" --arg msg "$msg" --argjson keep "$keep" \
      || cc_err "[cc] 호출 $id 의 끝 상태를 기록하지 못했습니다"
  fi
  final=$(jq -r --argjson id "$id" '
      if (.running | type) == "object" and .running.call_id == $id and .running.stop_failed != true then empty
      elif (.last_call | type) == "object" and .last_call.call_id == $id
           and (.last_call.status | type) == "string" and (.last_call.status | test("^[a-z_]+$"))
        then .last_call.status
      else empty end' "$_CC_WAIT_ACTIVE/state.json" 2>/dev/null)
  if [ -n "$final" ]; then
    dir="$_CC_WAIT_ACTIVE/calls/$id"
    if [ -d "$dir" ]; then
      cur=$(cat "$dir/status" 2>/dev/null)
      if [ "$cur" != "$final" ]; then
        { printf '%s\n' "$final" > "$dir/.status.wait.$$" && mv -f "$dir/.status.wait.$$" "$dir/status"; } \
          || cc_err "[cc] 호출 $id 의 status 파일을 쓰지 못했습니다"
      fi
    fi
    printf '%s\n' "$final"
    rc=0
  fi
  cc_state_unlock
  return "$rc"
}

# _cc_wait_report <id> <status> : 끝난 호출의 결과 한 줄과 종료 코드를 _CC_WAIT_LINE / _CC_WAIT_CODE 에 둔다
_cc_wait_report() {
  local id="$1" st="$2" msg json
  msg=$(jq -r --argjson id "$id" '
      if (.last_call | type) == "object" and .last_call.call_id == $id and (.last_call.message | type) == "string"
      then .last_call.message | gsub("\\p{Cc}+"; " ") else empty end' "$_CC_WAIT_ACTIVE/state.json" 2>/dev/null)
  case "$st" in
    ok)
      if json=$(jq -ce -s 'if length == 1 and (.[0] | type) == "object" then .[0] else error("not one object") end' \
                  "$_CC_WAIT_ACTIVE/calls/$id/result.json" 2>/dev/null) && [ -n "$json" ]; then
        _CC_WAIT_LINE=$json; _CC_WAIT_CODE=0
      else
        _CC_WAIT_LINE="[cc] Codex 결과 파일을 읽을 수 없습니다 (호출 $id)."; _CC_WAIT_CODE=3
      fi ;;
    interrupted)
      # state 에서 읽은 결과다: 이 wait 가 신호를 받은 것이 아니므로 3 (Ruling R19)
      _CC_WAIT_LINE=${msg:-$_CC_WAIT_INTERRUPTED_LINE}; _CC_WAIT_CODE=3 ;;
    timeout)
      [ -n "$msg" ] || msg=$(_cc_sup_timeout_message "$(_cc_sup_uint "${CC_CALL_TIMEOUT_SECS:-}" 1200)")
      _CC_WAIT_LINE=$msg; _CC_WAIT_CODE=3 ;;
    *)
      [ -n "$msg" ] || msg="[cc] Codex 호출이 실패했습니다 (호출 $id, 상태 $st)."
      _CC_WAIT_LINE=$msg; _CC_WAIT_CODE=3 ;;
  esac
}

# _cc_wait_conclude <id> : 끝난 호출을 정리(status 파일 맞추기)하고 결과를 알린다
_cc_wait_conclude() {
  local id="$1" final
  final=$(_cc_wait_settle "$id")
  if [ -z "$final" ]; then
    # state 에서 이 호출의 끝 기록을 읽지 못했다 (잠금 실패 등): status 파일이라도 본다
    final=$(cat "$_CC_WAIT_ACTIVE/calls/$id/status" 2>/dev/null)
    case "$final" in
      ''|*[!a-z_]*) _CC_WAIT_LINE="[cc] Codex 호출 $id 의 결과를 확인할 수 없습니다."; _CC_WAIT_CODE=3; return ;;
    esac
  fi
  _cc_wait_report "$id" "$final"
}

# 진행 중 상태 한 줄 (state JSON 에서). 경과 = running.started_at 부터, 마지막 활동 = last_activity_at 부터
_cc_wait_progress() {
  local line
  line=$(printf '%s' "$1" | jq -r '
      def ago($t): ((try (now - ($t | fromdateiso8601)) catch null)
                    | if . == null then null elif . < 0 then 0 else floor end);
      (ago(.running.started_at)) as $e | (ago(.last_activity_at)) as $a
      | "[cc] Codex 실행 중 · 호출 \(.running.call_id // "?") · 경과 \(if $e == null then "?" else ($e / 60 | floor) end)분 · 마지막 활동 \(if $a == null then "?" else $a end)초 전"' 2>/dev/null)
  [ -n "$line" ] || line="[cc] Codex 실행 중"
  _CC_WAIT_LINE=$line; _CC_WAIT_CODE=2
}

# 신호에 바로 깨도록 잠은 백그라운드로 자고 wait 로 기다린다 (포그라운드 sleep 이면 trap 이 잠이 끝날 때까지 밀린다).
# 이 sleep 의 PID 는 기억하지 않고 어떤 신호도 보내지 않는다 (끝나서 거둬진 뒤에는 그 PID 가 재사용됐을 수 있다).
# 중단돼 남더라도 표준 입출력이 /dev/null 이라 아무것도 붙잡지 않고, 확인 간격 안에 저절로 끝난다.
_cc_wait_sleep_ms() {
  local p
  sleep "$(printf '%d.%03d' $(($1 / 1000)) $(($1 % 1000)))" </dev/null >/dev/null 2>&1 &
  p=$!
  wait "$p" 2>/dev/null
}

_cc_wait_run() {
  local max="$1" poll_ms deadline st id sf has i n now
  poll_ms=$(( $(_cc_sup_uint "${CC_POLL_SECS:-}" 5) * 1000 ))
  [ "$poll_ms" -ge 1000 ] || poll_ms=1000
  deadline=$(( $(_cc_wait_now_ms) + max * 1000 ))
  id=$_CC_WAIT_ID
  if [ -z "$id" ]; then
    # 시작할 때 실행 중인 호출이 없었다: 마지막으로 끝난 호출을 알린다
    st=$(_cc_wait_read_state) || { _CC_WAIT_LINE="[cc] 상태 파일을 읽을 수 없습니다."; _CC_WAIT_CODE=3; return; }
    id=$(printf '%s' "$st" | jq -r 'if (.last_call | type) == "object" then .last_call.call_id else empty end | tostring' 2>/dev/null)
    case "$id" in
      '') _CC_WAIT_LINE="[cc] 기다릴 Codex 호출이 없습니다"; _CC_WAIT_CODE=3 ;;
      0*|*[!0-9]*|??????????*) _CC_WAIT_LINE="[cc] 상태 파일의 호출 기록이 올바르지 않습니다."; _CC_WAIT_CODE=3 ;;
      *) _cc_wait_conclude "$id" ;;
    esac
    return
  fi
  sf="$_CC_WAIT_ACTIVE/calls/$id/status"
  while :; do
    has=0; [ -s "$sf" ] && has=1
    st=$(_cc_wait_read_state) || { _CC_WAIT_LINE="[cc] 상태 파일을 읽을 수 없습니다."; _CC_WAIT_CODE=3; return; }
    if ! _cc_wait_running_cache "$st"; then
      # state 상 끝났다. 감독 프로세스는 state 다음에 status 파일을 쓰므로 잠깐(최대 2초) 기다린 뒤 맞춘다
      if [ "$has" = 0 ]; then
        i=0; while [ ! -s "$sf" ] && [ "$i" -lt 20 ]; do sleep 0.1; i=$((i + 1)); done
      fi
      _cc_wait_conclude "$id"; return
    fi
    if ! _cc_call_is_running "$st"; then
      # 감독 프로세스·codex 가 확실히 없고 그룹도 비었는데 running 이 남아 있다: 기록 없이 죽은 호출을 끝없이 기다리지 않는다
      _cc_wait_settle "$id" interrupted \
        "[cc] Codex 감독 프로세스가 결과를 남기지 않고 끝나 호출 $id 을(를) 중단됨으로 기록했습니다." >/dev/null
      _cc_wait_conclude "$id"; return
    fi
    _cc_wait_heartbeat "$st" "$id"
    now=$(_cc_wait_now_ms)
    [ "$now" -lt "$deadline" ] || { _cc_wait_progress "$st"; return; }
    n=$((deadline - now)); [ "$n" -le "$poll_ms" ] || n=$poll_ms
    _cc_wait_sleep_ms "$n"
  done
}

# _cc_wait_stop_group <pgid> <감독 프로세스 신원> <codex_pid> <codex 신원>
#   0 = 그룹을 끝냈거나, 감독 프로세스·codex 가 확실히 없고 그룹도 비었음 /
#   2 = 확인할 수 없어 아무 신호도 보내지 않음 (그룹에 확인할 수 없는 것이 남은 경우 포함) / 3 = KILL 뒤에도 남음
_cc_wait_stop_group() {
  local pg="$1" sid="$2" cp="$3" cid="$4" r r2=1
  cc_kill_group_verified "$pg" "$sid" "$_CC_WAIT_SUP_GRACE_TENTHS"; r=$?
  case "$r" in 0|3) return "$r" ;; esac
  # 감독 프로세스(리더)를 확인할 수 없다 (1 = 이미 없음·우리 것 아님, 2 = 판단 불가): 기록된 codex 로 그룹을 확인한다
  if [ -n "$cp" ]; then
    cc_kill_group_via_member "$cp" "$cid" "$pg"; r2=$?
    case "$r2" in 0|3) return "$r2" ;; esac
  fi
  # 감독 프로세스도 codex 도 확실히 없을 때 그룹까지 비었으면 끝난 것. 그룹에 무언가 남아 있으면(codex 의 자식 등)
  # 우리 것인지 확인할 수 없으므로 신호 없이 2 (신호 0 으로 있는지만 본다).
  # 감독 프로세스 PID 를 신원이 다른 프로세스가 쓰고 있으면(재사용) 우리 그룹은 이미 끝났다: 그룹을 보지 않고 0
  # (_cc_call_liveness 와 같은 판단, 최종 리뷰 minor e. 그 번호의 그룹이 있다면 그 다른 프로세스의 것이다)
  if [ "$r" -eq 1 ] && [ "$r2" -eq 1 ]; then
    cc_proc_alive_detail "$pg" "$sid"; [ $? -eq 4 ] && return 0
    _cc_proc_probe "-$pg"; [ $? -eq 1 ] && return 0
  fi
  return 2
}

_cc_wait_interrupt() {
  local st id pg sid cp cid r=2
  _CC_WAIT_CODE=130
  id=$_CC_WAIT_ID
  if [ -z "$id" ]; then
    _CC_WAIT_LINE="[cc] 중단됨: 기다리던 Codex 호출은 없었습니다"; return 0
  fi
  # 빠른 길: 마지막 확인 때 기억한 감독 프로세스(그룹 리더)에 state 를 다시 읽지 않고 바로 검증된 TERM.
  #   신원·그룹 소속 확인은 cc_kill_group_verified 가 그대로 한다: 그 사이 감독 프로세스가 끝났거나 PID 가
  #   재사용됐으면 아무 신호도 보내지 않는다(1). 마무리 중인 감독 프로세스는 TERM 을 무시하고 스스로 끝나며,
  #   그 결과는 아래 정리(_cc_wait_settle)가 state 에서 그대로 읽는다.
  if [ -n "${_CC_WAIT_C_PG:-}" ]; then
    cc_kill_group_verified "$_CC_WAIT_C_PG" "$_CC_WAIT_C_SID" "$_CC_WAIT_SUP_GRACE_TENTHS"; r=$?
  fi
  case "$r" in
    0|3) _cc_wait_interrupt_conclude "$id" "$r"; return 0 ;;
  esac
  # 느린 길 (감독 프로세스가 이미 없거나 판단할 수 없음): 지금 state 로 다시 판단한다
  st=$(_cc_wait_read_state)
  if ! _cc_wait_running_is "$st" "$id"; then
    # 기다리던 호출은 이미 끝났다 (다른 호출이 running 이어도 그것은 멈추지 않는다)
    _cc_wait_interrupt_conclude "$id" done
    return 0
  fi
  pg=$(_cc_jq_get "$st" '.running.pgid // empty | tostring')
  sid=$(_cc_jq_get "$st" '.running.supervisor_identity // empty')
  cp=$(_cc_jq_get "$st" '.running.codex_pid // empty | tostring')
  cid=$(_cc_jq_get "$st" '.running.codex_identity // empty')
  _cc_wait_stop_group "$pg" "$sid" "$cp" "$cid"; r=$?
  _cc_wait_interrupt_conclude "$id" "$r"
}

# _cc_wait_interrupt_conclude <id> <0|3|2|done> : 중단 처리 결과를 state·status 파일에 맞추고 알릴 한 줄을 정한다
#   0 끝냈음 / 3 KILL 뒤에도 남음 / done 신호 전에 이미 끝나 있었음 / 그 밖(2) 확인할 수 없어 아무것도 바꾸지 않음
_cc_wait_interrupt_conclude() {
  local id="$1" r="$2" final="" i
  case "$r" in
    done)
      final=$(_cc_wait_settle "$id")
      _CC_WAIT_LINE="[cc] 중단됨: Codex 호출 $id 은(는) 중단 전에 이미 끝나 있었습니다 (${final:-결과 확인 불가})" ;;
    0)
      for i in 1 2 3; do
        final=$(_cc_wait_settle "$id" interrupted "$_CC_WAIT_INTERRUPTED_LINE") && break
        sleep 1
      done
      if [ -z "$final" ] || [ "$final" = interrupted ]; then
        _CC_WAIT_LINE=$_CC_WAIT_INTERRUPTED_LINE
      else
        _CC_WAIT_LINE="[cc] 중단됨: Codex 호출 $id 은(는) 중단 전에 이미 끝나 있었습니다 ($final)"
      fi ;;
    3)
      # 종료를 확인하지 못했다: 끝 상태는 기록하되 프로세스 기록(running)은 남긴다 (R30)
      _cc_wait_settle "$id" interrupted "[cc] 중단됨: 일부 Codex 프로세스가 KILL 뒤에도 남아 있습니다 (호출 $id)." keep >/dev/null
      _CC_WAIT_LINE="[cc] 중단됨: 일부 Codex 프로세스가 KILL 뒤에도 남아 있습니다 (호출 $id)" ;;
    *)
      _CC_WAIT_LINE="[cc] 중단됨: Codex 종료를 확인하지 못해 상태를 바꾸지 않았습니다 (호출 $id)" ;;
  esac
}

# 지금 이 코드를 실행하는 셸이 스크립트의 본 셸($$)인가. 바로 띄운 perl 의 부모로 확인한다
# (bash 3.2 의 $$ 는 서브셸에서도 본 셸 PID 다). 확인할 수 없으면 본 셸로 본다 (정리를 건너뛰지 않도록).
_cc_wait_in_main_shell() {
  perl -e 'exit(getppid() == $ARGV[0] ? 0 : 1)' -- "$$" 2>/dev/null
  [ $? -ne 1 ]
}

# state 잠금의 owner 가 이 셸($$)인가 (bash 내장 read 만 쓴다). 잠금 owner 는 잠금을 잡은 셸의 PID 다 (state.sh)
#   잠금 자리나 owner 가 심볼릭 링크면 따라가 읽지 않는다 (Codex 리뷰 2)
_cc_wait_owns_lock() {
  local o="" d="$_CC_WAIT_ACTIVE/state.lock" f="$_CC_WAIT_ACTIVE/state.lock/owner"
  [ -n "${_CC_WAIT_ACTIVE:-}" ] && [ ! -L "$d" ] && [ -d "$d" ] && [ ! -L "$f" ] && [ -f "$f" ] || return 1
  IFS= read -r o < "$f" 2>/dev/null
  [ "$o" = "$$" ]
}

_cc_wait_on_signal() {
  trap '' INT TERM HUP
  # bash 3.2 는 신호가 막 도착했을 때 만들어진 $(...) 자식에서도 이 trap 을 실행한다 (대기 중이던 trap 을 물려받음).
  # 그 자식은 아무것도 하지 않고 조용히 끝난다. 본 셸도 같은 신호를 받아 두었으므로 자식이 끝나면 본 셸이 처리한다.
  _cc_wait_in_main_shell || exit 130
  # 이 셸이 state 잠금을 쥐고 있었을 때만 놓는다 (감독 프로세스의 마무리에 잠금이 필요하다).
  #   쥐었는지는 깊이 기록과 잠금 owner 파일로 본다 (프로세스를 띄우지 않는다): 잠금을 잡은 직후 깊이를 적기 전에
  #   신호가 오면 깊이는 0 이지만 owner 는 이 셸이다. 쥐지 않았으면 아무것도 하지 않고 곧바로 TERM 으로 간다.
  if [ "${_CC_STATE_LOCK_DEPTH:-0}" -gt 0 ] || _cc_wait_owns_lock; then
    _CC_STATE_LOCK_DEPTH=1; cc_state_unlock 2>/dev/null
  fi
  _cc_wait_interrupt
  _cc_wait_unregister
  cc_line "$_CC_WAIT_LINE"
  exit 130
}

_cc_wait_on_exit() {
  _cc_wait_unregister
}

# cc-codex.sh wait [--max SECS]
cc_cmd_wait() {
  local max st
  _CC_WAIT_REG=0; _CC_WAIT_ID=""; _CC_WAIT_IDENT=""; _CC_WAIT_STARTED_AT=""; _CC_WAIT_LINE=""; _CC_WAIT_CODE=3
  _CC_WAIT_C_PG=""; _CC_WAIT_C_SID=""
  max=$(_cc_wait_parse_max "$@") || { cc_line "[cc] 사용법: wait [--max SECS]"; return 3; }
  cc_active_exists || { cc_line "[cc] 진행 중인 작업이 없습니다."; return 3; }
  cc_active_path_safe || { cc_line "[cc] 상태 폴더 경로가 비정상입니다."; return 3; }
  _CC_WAIT_ACTIVE=$(cc_active_dir) || { cc_line "[cc] git 저장소가 아닙니다."; return 3; }
  st=$(_cc_wait_read_state) || { cc_line "[cc] 상태 파일을 읽을 수 없습니다."; return 3; }
  # 기다릴 호출은 신호 trap 을 걸기 전에 정한다: 중단 처리는 이 호출만 멈춘다 (Task 7 리뷰 3)
  _CC_WAIT_ID=$(printf '%s' "$st" | jq -r 'if (.running | type) == "object" then (.running.call_id | tostring) else empty end' 2>/dev/null)
  case "$_CC_WAIT_ID" in
    0*|*[!0-9]*|??????????*) cc_line "[cc] 상태 파일의 호출 기록이 올바르지 않습니다."; return 3 ;;
  esac
  # 첫 확인 전에 신호가 와도 바로 TERM 을 보낼 수 있게 감독 프로세스를 기억해 둔다
  [ -n "$_CC_WAIT_ID" ] && _cc_wait_running_cache "$st"
  trap '_cc_wait_on_signal' INT TERM HUP
  trap '_cc_wait_on_exit' EXIT
  _cc_wait_register
  _cc_wait_run "$max"
  _cc_wait_unregister
  cc_line "$_CC_WAIT_LINE"
  return "$_CC_WAIT_CODE"
}
