#!/bin/bash
# smoke-real-codex.sh - Task 12: 실제 Codex CLI 로 /yultopia:cc 를 한 번 돌려 보는 smoke test (사람이 직접 실행).
#
#   bash tests/cc/smoke-real-codex.sh
#
# - 자동 테스트 러너(tests/cc/run.sh)는 test_*.sh 만 돌리므로 이 파일은 섞이지 않는다.
# - 실제 codex 를 사용자 설정 그대로 부른다. 모델·추론 강도 인자는 없다 (cc-codex.sh 가 만드는 인자 그대로).
#   사용자 설정에 따라 호출 한 번이 몇 분 걸릴 수 있다.
# - Codex 실행은 최대 3회: CC_MAX_CALLS=3 으로 돌려 재시도·형식 재요청까지 합쳐도 3회를 넘지 않는다.
#   단계마다 호출 수가 단계 번호와 같아야 하고(재시도가 끼면 FAIL), 첫 FAIL 이 나온 단계에서 멈춘다.
# - 새로 만든 임시 저장소에서만 실행하고 끝나면 지운다. Codex 자체 기록(~/.codex)은 지우지 않는다
#   (이 smoke 세션의 rollout 파일에서 턴별 sandbox 설정과 파일 크기만 읽는다).
#
# 세 단계 (Codex 실행 한 번씩)
#   1 세션 시작: init → call plan → wait. 세션 ID, 스키마 키, verdict plan, 토큰, 이벤트 이름·usage 모양, 인자
#   2 같은 세션 재개 + 프로젝트 파일 수정 없음 (R31/R32: Codex 는 workspace-write 로 명령을 직접 실행한다):
#     put message → call message → wait. resume 인자(workspace-write)·세션 ID, 기억(마일스톤 개수),
#     프로젝트 파일이 바뀌지 않음(codex_modified 아님, git status 깨끗함), rollout 의 턴별 sandbox(workspace-write)
#   3 중단: put message(오래 걸릴 요청) → call message → wait 를 백그라운드로 → 20초 뒤 SIGINT →
#     wait 130, 감독 프로세스·codex·그룹·자손 없음, last_call.status=interrupted, running=null, status 파일 == state
#
# 출력: "PASS|FAIL|INCONCLUSIVE|SKIP <단계>: <근거>" 줄, 참고 정보는 "INFO" 줄, 마지막 줄은 요약.
#   FAIL 이 하나라도 있으면 종료 코드 1.
#
# 환경변수
#   CC_SMOKE_BASE       임시 저장소를 만들 폴더 (기본 ${TMPDIR:-/tmp})
#   CC_SMOKE_SAVE_DIR   주면 지우기 전에 상태 폴더(이벤트 로그·결과·감독 로그)를 이 폴더에 복사한다 (조사용)
#   CC_SMOKE_CODEX_BIN  이 스크립트 자체를 점검할 때만: 실제 codex 대신 쓸 실행 파일 (예: tests/cc/fake-codex)

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd "$HERE/../.." && pwd -P)
CC="$ROOT/plugins/yultopia/bin/cc-codex.sh"

# 설정값은 실제 기본값으로 (바깥에 남은 테스트용 짧은 값이 섞이지 않게). 호출 상한만 3.
unset CC_CALL_TIMEOUT_SECS CC_FAST_FAIL_SECS CC_WAIT_MAX_SECS CC_POLL_SECS CC_ORPHAN_GRACE_SECS \
      CC_ORPHAN_MINUTES CC_STALE_DAYS CC_MAX_REJECTS CC_STATE_LOCK_WAIT_SECS CC_LOGIN_TIMEOUT_SECS
export CC_MAX_CALLS=3
export CC_CODEX_BIN="${CC_SMOKE_CODEX_BIN:-codex}"
. "$ROOT/plugins/yultopia/lib/cc/common.sh"
. "$ROOT/plugins/yultopia/lib/cc/proc.sh"

BRIEF='README.md 에 한 줄 추가하는 작업. 마일스톤 1개.'
MSG2='직전 계획의 마일스톤 개수를 summary 에 숫자로 적어라. 그리고 셸에서 `git status --short` 를 실행해 보고 결과를 summary 에 적어라. 프로젝트 파일은 만들거나 고치지 마라. verdict 는 approve, milestone 은 현재 번호.'
MSG3='저장소의 모든 파일을 한 줄씩 아주 자세히 설명하고 개선점을 최대한 많이 적어라'
TAB=$(printf '\t')

N_PASS=0; N_FAIL=0; N_INC=0; N_SKIP=0
WORK=""; REPO=""; ACTIVE=""; WP=""; SID=""; MS_COUNT=""; LEFTOVERS=""; CLEANED=0

# ---- 출력 ----
report() {   # <PASS|FAIL|INCONCLUSIVE|SKIP> <단계> <근거…>
  local r="$1" s="$2"
  shift 2
  printf '%s %s: %s\n' "$r" "$s" "$(printf '%s' "$*" | tr '\r\n' '  ')"
  case "$r" in
    PASS) N_PASS=$((N_PASS + 1)) ;;
    FAIL) N_FAIL=$((N_FAIL + 1)) ;;
    INCONCLUSIVE) N_INC=$((N_INC + 1)) ;;
    SKIP) N_SKIP=$((N_SKIP + 1)) ;;
  esac
}
info() { printf 'INFO %s %s\n' "$(date +%H:%M:%S)" "$(printf '%s' "$*" | tr '\r\n' '  ')"; }

st() { jq -r "$1" "$ACTIVE/state.json" 2>/dev/null; }
now_ms() { perl -MTime::HiRes -e 'printf "%d\n", Time::HiRes::time() * 1000'; }
count_lines() { printf '%s\n' "$1" | grep -c .; }
# 감독 로그의 "codex 실행 (" 줄 수 = 실제로 codex 를 띄운 횟수 (재시도 포함)
launches() {
  local n=""
  [ -n "$ACTIVE" ] && n=$(grep -c 'codex 실행 (' "$ACTIVE/supervisor.log" 2>/dev/null)
  printf '%s\n' "${n:-0}"
}
one_json_line() {   # 값이 한 줄이고 JSON 객체 하나인가
  [ "$(printf '%s\n' "$1" | wc -l | tr -d ' ')" = 1 ] \
    && printf '%s' "$1" | jq -e -s 'length == 1 and (.[0] | type) == "object"' >/dev/null 2>&1
}

# ---- 이벤트 로그 (codex --json) ----
ev_types() {
  jq -R -r 'fromjson? | select(type == "object") | (.type // "(type 없음)") | tostring' "$1" 2>/dev/null \
    | sort | uniq -c | awk '{ printf "%s×%s ", $2, $1 }'
}
ev_item_types() {
  jq -R -r 'fromjson? | select(type == "object" and .type == "item.completed") | (.item.type // "?") | tostring' "$1" 2>/dev/null \
    | sort | uniq -c | awk '{ printf "%s×%s ", $2, $1 }'
}
ev_usage() {
  jq -R -c 'fromjson? | select(type == "object" and .type == "turn.completed") | .usage' "$1" 2>/dev/null | tr '\n' ' '
}
ev_usage_shape() {
  jq -R -c 'fromjson? | select(type == "object" and .type == "turn.completed") | .usage
            | if type == "object" then with_entries(.value |= type) else type end' "$1" 2>/dev/null | head -n 1
}
ev_usage_sum() {   # "input cached_input output"
  jq -R -s -r '[split("\n")[] | fromjson? | select(type == "object" and .type == "turn.completed") | .usage | select(type == "object")]
    | "\(map(.input_tokens // 0) | add // 0) \(map(.cached_input_tokens // 0) | add // 0) \(map(.output_tokens // 0) | add // 0)"' \
    "$1" 2>/dev/null
}
ev_thread_id() {
  jq -R -r 'fromjson? | select(type == "object" and .type == "thread.started") | .thread_id | select(type == "string")' "$1" 2>/dev/null \
    | head -n 1
}
# 코드가 기대하는 모양: thread.started(thread_id 문자열), turn.completed(usage 의 세 값이 숫자)
ev_shape_ok() {
  jq -R -s -e '[split("\n")[] | fromjson? | select(type == "object")] as $e
    | ($e | any(.type == "thread.started" and (.thread_id | type) == "string"))
      and ($e | any(.type == "turn.completed" and (.usage | type) == "object"
                    and (.usage.input_tokens | type) == "number" and (.usage.cached_input_tokens | type) == "number"
                    and (.usage.output_tokens | type) == "number"))' "$1" >/dev/null 2>&1
}
# Codex 가 실행한 명령(command_execution 항목) 목록. 참고 정보로만 보여준다 (code mode 로 실행한 명령은 여기 나오지 않는다)
ev_commands() {
  jq -R -r 'fromjson? | select(type == "object" and .type == "item.completed" and ((.item.type // "") == "command_execution"))
    | .item | "\(.command | tostring | gsub("[\\r\\n\\t]+"; " ") | .[0:120]) → exit_code=\(.exit_code // "null")"' \
    "$1" 2>/dev/null | tr '\n' ';'
}
stderr_tail() {   # <호출 번호>
  local f="$ACTIVE/calls/$1/stderr.log" n
  [ -f "$f" ] || { printf '(파일 없음)'; return; }
  n=$(grep -c . "$f" 2>/dev/null)
  printf '%s줄 · 마지막: %s' "${n:-0}" "$(grep -v '^[[:space:]]*$' "$f" | tail -n 3 | tr '\n' '|' | cut -c1-500)"
}
sup_log() {   # <호출 번호> : 감독 로그에서 그 호출 줄
  grep "\[call $1\]" "$ACTIVE/supervisor.log" 2>/dev/null | sed 's/^[^ ]* //' | tr '\n' '|' | cut -c1-600
}

# ---- Codex 자체 기록 (읽기만): 이 smoke 세션의 rollout 파일 ----
rollout_files() {
  local home="${CODEX_HOME:-$HOME/.codex}"
  case "$1" in ''|*[!A-Za-z0-9._:-]*) return 0 ;; esac
  [ -d "$home/sessions" ] || return 0
  find "$home/sessions" -type f -name "*$1*.jsonl" 2>/dev/null | sort
}
rollout_policies() {   # 턴마다 "sandbox/approval"
  local f
  rollout_files "$1" | while IFS= read -r f; do
    jq -r 'select(.type == "turn_context") | .payload
           | "\(.sandbox_policy | if type == "object" then (.type // tostring) else tostring end)/\(.approval_policy // "?" | tostring)"' \
      "$f" 2>/dev/null
  done | tr '\n' ' '
}
rollout_bytes() {
  local f s t=0
  while IFS= read -r f; do
    s=$(wc -c < "$f" 2>/dev/null)
    t=$((t + ${s:-0}))
  done < <(rollout_files "$1")
  printf '%s\n' "$t"
}

# ---- 프로세스 ----
# <리더 pid> : 그 프로세스와 자손, 그리고 같은 그룹 멤버. 한 줄에 "pid<TAB>pgid<TAB>lstart<TAB>command".
#   감독 프로세스가 직접 잠깐씩 띄우는 도우미(sleep, ps, jq, perl …)는 뺀다. codex 아래 자손은 이름과 상관없이 모두 남긴다.
proc_tree() {
  local pid ppid pg ls cmd
  LC_ALL=C ps -A -o pid=,ppid=,pgid= 2>/dev/null | awk -v root="$1" '
    { p[NR] = $1; pp[NR] = $2; g[NR] = $3 }
    END {
      want[root] = 1; ch = 1
      while (ch) { ch = 0; for (i = 1; i <= NR; i++) if (!(p[i] in want) && (pp[i] in want)) { want[p[i]] = 1; ch = 1 } }
      for (i = 1; i <= NR; i++) if ((p[i] in want) || g[i] == root) print p[i], pp[i], g[i]
    }' | while read -r pid ppid pg; do
      ls=$(LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null) || continue
      cmd=$(LC_ALL=C ps -ww -o command= -p "$pid" 2>/dev/null) || continue
      cmd=$(_cc_proc_trim "$cmd")
      [ "$ppid" = "$1" ] && case "$cmd" in
        sleep\ *|ps\ *|jq\ *|perl\ *|date\ *|cat\ *|wc\ *|tr\ *|cut\ *|grep\ *|head\ *|tail\ *|mktemp\ *|mv\ *|rm\ *|awk\ *|sed\ *|git\ *) continue ;;
      esac
      printf '%s\t%s\t%s\t%s\n' "$pid" "$pg" "$(_cc_proc_trim "$ls")" "$cmd"
    done
}
# 목록 중 아직 같은 프로세스(시작 시각·명령줄이 같음)로 살아 있는 줄
still_alive() {
  local pid pg ls cmd cls ccmd
  while IFS="$TAB" read -r pid pg ls cmd; do
    [ -n "$pid" ] || continue
    cls=$(LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null) || continue
    ccmd=$(LC_ALL=C ps -ww -o command= -p "$pid" 2>/dev/null) || continue
    [ "$(_cc_proc_trim "$cls")" = "$ls" ] && [ "$(_cc_proc_trim "$ccmd")" = "$cmd" ] \
      && printf '%s\t%s\t%s\t%s\n' "$pid" "$pg" "$ls" "$cmd"
  done <<EOF
$1
EOF
}
tree_brief() {   # 목록을 "pid(pgid) 명령…; " 한 줄로
  local pid pg ls cmd
  printf '%s\n' "$1" | while IFS="$TAB" read -r pid pg ls cmd; do
    [ -n "$pid" ] && printf '%s(pgid %s) %s; ' "$pid" "$pg" "$(printf '%s' "$cmd" | cut -c1-120)"
  done
}
show_tree() {   # <제목> <목록> <리더 pgid>
  local pid pg ls cmd other
  other=$(printf '%s\n' "$2" | awk -F "$TAB" -v g="$3" 'NF && $2 != g' | grep -c .)
  info "$1: $(count_lines "$2")개 (그룹 $3 밖: ${other}개)"
  printf '%s\n' "$2" | while IFS="$TAB" read -r pid pg ls cmd; do
    [ -n "$pid" ] && info "  pid=$pid pgid=$pg $(printf '%s' "$cmd" | cut -c1-170)"
  done
}

# ---- 호출 ----
# 감독 프로세스가 codex 를 띄워 신원을 state 에 기록할 때까지 기다리고(최대 30초) 전체 인자를 ps 로 읽는다.
#   (state 의 신원은 200자로 잘리므로 인자는 ps -ww 로 직접 읽는다)
#   R_PGID, R_SUP_IDENT, R_CODEX_PID, R_CODEX_IDENT, R_ARGV
capture_running() {
  local i=0
  R_PGID=$(st '.running.pgid // empty'); R_SUP_IDENT=$(st '.running.supervisor_identity // empty')
  R_CODEX_PID=""; R_CODEX_IDENT=""; R_ARGV=""
  while [ "$i" -lt 300 ]; do
    R_CODEX_PID=$(st '.running.codex_pid // empty')
    [ -n "$R_CODEX_PID" ] && break
    [ "$(st '.running == null')" = true ] && break
    sleep 0.1; i=$((i + 1))
  done
  [ -n "$R_CODEX_PID" ] || return 1
  R_CODEX_IDENT=$(st '.running.codex_identity // empty')
  R_ARGV=$(ps -ww -o command= -p "$R_CODEX_PID" 2>/dev/null)
  return 0
}

start_call() {   # <kind> <단계 번호> : CALL_T0, R_*
  local kind="$1" n="$2" line rc
  CALL_T0=$SECONDS
  line=$(bash "$CC" call "$kind" 2>"$WORK/call.err"); rc=$?
  info "call $kind → 코드 $rc: $line"
  if [ "$rc" -ne 0 ]; then
    report FAIL "step$n.call" "call $kind 가 시작되지 않음 (코드 $rc): $line $(cat "$WORK/call.err" 2>/dev/null)"
    return 1
  fi
  if capture_running; then
    info "감독 프로세스 pgid=$R_PGID · codex pid=$R_CODEX_PID"
    info "codex 인자(ps): $R_ARGV"
  else
    info "codex 신원을 30초 안에 잡지 못함 (이미 끝났을 수 있음)"
  fi
  return 0
}

# 호출 시작 후 <초> 까지 기다렸다가(아직 실행 중일 때만) 감독 프로세스 아래 프로세스를 적어 둔다 → SNAP
snapshot_tree() {
  SNAP=""
  [ -n "$R_PGID" ] || return 0
  while [ $((SECONDS - CALL_T0)) -lt "$1" ] && [ "$(st '.running != null')" = true ]; do sleep 1; done
  if [ "$(st '.running != null')" != true ]; then
    info "프로세스 목록: 호출이 이미 끝나 적지 못함"
    return 0
  fi
  SNAP=$(proc_tree "$R_PGID")
  show_tree "실행 중 프로세스 (호출 시작 +$((SECONDS - CALL_T0))초)" "$SNAP" "$R_PGID"
}

# 끝날 때까지 wait --max 540 을 되풀이한다 (2 = 아직 실행 중). → WAIT_OUT, WAIT_RC, T_CALL
wait_loop() {
  local i=0
  while :; do
    WAIT_OUT=$(bash "$CC" wait --max 540 2>"$WORK/wait.err"); WAIT_RC=$?
    [ -s "$WORK/wait.err" ] && info "wait stderr: $(cat "$WORK/wait.err")"
    [ "$WAIT_RC" -eq 2 ] || break
    info "아직 실행 중: $WAIT_OUT"
    i=$((i + 1))
    [ "$i" -lt 6 ] || break
  done
  T_CALL=$((SECONDS - CALL_T0))
}

# 정상으로 끝난 호출 뒤 실행 중에 적어 둔 프로세스가 남았는가 (최대 5초 기다림)
check_leftovers() {   # <단계> <목록>
  local step="$1" snap="$2" left i=0
  if [ -z "$snap" ]; then
    report INCONCLUSIVE "$step.leftovers" "실행 중 프로세스 목록을 적지 못해 확인하지 못함"
    return 0
  fi
  while :; do
    left=$(still_alive "$snap")
    [ -z "$left" ] && break
    [ "$i" -ge 50 ] && break
    sleep 0.1; i=$((i + 1))
  done
  if [ -z "$left" ]; then
    report PASS "$step.leftovers" "실행 중에 적어 둔 프로세스 $(count_lines "$snap")개가 모두 끝남"
  else
    LEFTOVERS="$LEFTOVERS$left
"
    report FAIL "$step.leftovers" "호출이 끝난 뒤 5초가 지나도 남은 프로세스: $(tree_brief "$left")"
  fi
}

# 단계 공통: 호출 수 확인 (재시도가 끼면 FAIL)
check_calls() {   # <단계> <기대 횟수>
  local calls n
  calls=$(st '.calls_total // empty'); n=$(launches)
  if [ "$calls" = "$2" ] && [ "$n" = "$2" ]; then
    report PASS "$1.calls" "calls_total=$calls, codex 실행 ${n}회 (재시도·형식 재요청 없음)"
  else
    report FAIL "$1.calls" "calls_total=$calls, codex 실행 ${n}회 — 기대 $2 (재시도 또는 형식 재요청이 일어남: $(sup_log "${2}"))"
  fi
}

# 호출 기록 출력 (단계 공통)
show_call_evidence() {   # <호출 번호>
  local ev="$ACTIVE/calls/$1/events.jsonl" f
  info "호출 $1: ${T_CALL}초, wait 코드 $WAIT_RC"
  info "이벤트 type: $(ev_types "$ev")"
  info "item.completed 의 item.type: $(ev_item_types "$ev")"
  info "turn.completed.usage: $(ev_usage "$ev") (모양 $(ev_usage_shape "$ev"))"
  info "stderr.log: $(stderr_tail "$1")"
  # 재시도·형식 재요청이 있었으면 그 시도의 기록도 (events-k.jsonl / stderr-k.log)
  for f in "$ACTIVE/calls/$1"/events-*.jsonl "$ACTIVE/calls/$1"/stderr-*.log; do
    [ -f "$f" ] || continue
    case "$f" in
      *.jsonl) info "$(basename "$f") type: $(ev_types "$f")" ;;
      *) info "$(basename "$f"): $(grep -v '^[[:space:]]*$' "$f" | tail -n 3 | tr '\n' '|' | cut -c1-500)" ;;
    esac
  done
  info "감독 로그: $(sup_log "$1")"
}

# ---- 단계 1: 세션 시작 ----
step1() {
  local out rc f0 ev missing verdict ev_sid sum ti tc to
  f0=$N_FAIL
  out=$(printf '%s\n' "$BRIEF" | bash "$CC" init 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then report FAIL step1.init "init 코드 $rc: $out"; return 1; fi
  ACTIVE=$(bash "$CC" path active 2>/dev/null)
  info "init: $out"
  start_call plan 1 || return 1
  snapshot_tree 15
  SNAP1=$SNAP
  wait_loop
  ev="$ACTIVE/calls/1/events.jsonl"
  show_call_evidence 1

  if [ "$WAIT_RC" -eq 0 ] && one_json_line "$WAIT_OUT"; then
    report PASS step1.result "wait 코드 0, 결과 JSON 한 줄 (${T_CALL}초)"
  else
    report FAIL step1.result "wait 코드 $WAIT_RC: $WAIT_OUT · last_call=$(st '.last_call | tostring') · stderr: $(stderr_tail 1)"
    check_calls step1 1
    return 1
  fi
  check_calls step1 1

  missing=$(printf '%s' "$WAIT_OUT" | jq -r '["verdict","summary","plan","milestone","instruction","findings","question"] - keys | join(",")' 2>/dev/null)
  verdict=$(printf '%s' "$WAIT_OUT" | jq -r '.verdict' 2>/dev/null)
  MS_COUNT=$(printf '%s' "$WAIT_OUT" | jq -r 'if (.plan.milestones | type) == "array" then (.plan.milestones | length) else empty end' 2>/dev/null)
  info "summary: $(printf '%s' "$WAIT_OUT" | jq -r '.summary' 2>/dev/null)"
  info "plan.overview: $(printf '%s' "$WAIT_OUT" | jq -r '.plan.overview // "null"' 2>/dev/null)"
  info "plan.milestones: $(printf '%s' "$WAIT_OUT" | jq -r '[.plan.milestones[]? | "\(.id). \(.title)"] | join(" / ")' 2>/dev/null)"
  if [ -z "$missing" ] && [ "$verdict" = plan ] && [ -n "$MS_COUNT" ]; then
    report PASS step1.schema "스키마 키 7개 모두 있음, verdict=plan, 마일스톤 ${MS_COUNT}개 (최상위 \"\$schema\" 키가 있는 스키마 파일을 --output-schema 로 넘겼고 Codex 가 받아들임)"
  else
    report FAIL step1.schema "빠진 키=[${missing}] verdict=$verdict 마일스톤=${MS_COUNT:-없음}"
  fi

  SID=$(st '.session_id // empty')
  ev_sid=$(ev_thread_id "$ev")
  if [ -n "$SID" ] && [ "$SID" = "$ev_sid" ]; then
    report PASS step1.session "session_id=$SID (thread.started.thread_id 와 같음)"
  else
    report FAIL step1.session "state.session_id=[$SID] thread.started.thread_id=[$ev_sid]"
  fi

  if ev_shape_ok "$ev"; then
    report PASS step1.events "코드가 기대하는 이벤트 있음: thread.started(thread_id), turn.completed(usage 세 값 숫자). 실제 type: $(ev_types "$ev")· usage 모양 $(ev_usage_shape "$ev")"
  else
    report FAIL step1.events "코드가 기대하는 thread.started/turn.completed 모양이 아님. 실제 type: $(ev_types "$ev")· usage 모양: $(ev_usage_shape "$ev")"
  fi

  sum=$(ev_usage_sum "$ev")
  read -r ti tc to <<EOF
$(st '"\(.tokens.input) \(.tokens.cached_input) \(.tokens.output)"')
EOF
  if [ "${to:-0}" -gt 0 ] 2>/dev/null && [ "${ti:-0}" -gt 0 ] 2>/dev/null && [ "$ti $tc $to" = "$sum" ]; then
    report PASS step1.tokens "state.tokens 입력 $ti (캐시 $tc) · 출력 $to = 이벤트 usage 합계"
  else
    report FAIL step1.tokens "state.tokens=[$ti $tc $to] 이벤트 usage 합계=[$sum]"
  fi

  if [ -z "$R_ARGV" ]; then
    report INCONCLUSIVE step1.argv "실행 중 codex 인자를 잡지 못함"
  elif case "$R_ARGV" in *"exec --json -s workspace-write --output-schema "*" -o "*" -") true ;; *) false ;; esac \
       && ! case " $R_ARGV " in *" -m "*|*" --model"*|*model_reasoning_effort*|*"model="*) true ;; *) false ;; esac; then
    report PASS step1.argv "exec --json -s workspace-write --output-schema … -o … - (모델·추론 강도 인자 없음)"
  else
    report FAIL step1.argv "기대와 다른 인자: $R_ARGV"
  fi

  check_leftovers step1 "$SNAP1"
  [ "$N_FAIL" -eq "$f0" ]
}

# ---- 단계 2: 같은 세션 재개 + 프로젝트 파일 수정 없음 ----
step2() {
  local out rc f0 ev summary verdict pol last_pol porcelain sid_now lc_status
  f0=$N_FAIL
  out=$(printf '%s\n' "$MSG2" | bash "$CC" put message 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then report FAIL step2.put "put message 코드 $rc: $out"; return 1; fi
  start_call message 2 || return 1
  if [ -z "$R_ARGV" ]; then
    report INCONCLUSIVE step2.argv "실행 중 codex 인자를 잡지 못함"
  elif case "$R_ARGV" in *"exec resume --json -c sandbox_mode=\"workspace-write\" --output-schema "*" -o "*" $SID -") true ;; *) false ;; esac \
       && ! case " $R_ARGV " in *" -m "*|*" --model"*|*model_reasoning_effort*|*"model="*) true ;; *) false ;; esac; then
    report PASS step2.argv "exec resume --json -c sandbox_mode=\"workspace-write\" --output-schema … -o … $SID - (같은 세션 ID, 모델 인자 없음)"
  else
    report FAIL step2.argv "기대와 다른 인자 (세션 $SID): $R_ARGV"
  fi
  snapshot_tree 15
  SNAP2=$SNAP
  wait_loop
  ev="$ACTIVE/calls/2/events.jsonl"
  show_call_evidence 2

  if [ "$WAIT_RC" -eq 0 ] && one_json_line "$WAIT_OUT"; then
    report PASS step2.result "wait 코드 0, 결과 JSON 한 줄 (${T_CALL}초)"
  else
    report FAIL step2.result "wait 코드 $WAIT_RC: $WAIT_OUT · last_call=$(st '.last_call | tostring') · stderr: $(stderr_tail 2)"
    check_calls step2 2
    return 1
  fi
  check_calls step2 2

  sid_now=$(st '.session_id // empty')
  if [ "$sid_now" = "$SID" ]; then
    report PASS step2.session "session_id 그대로 $SID (재개 이벤트 thread.started: $(ev_thread_id "$ev"))"
  else
    report FAIL step2.session "session_id 가 바뀜: $SID → $sid_now"
  fi

  summary=$(printf '%s' "$WAIT_OUT" | jq -r '.summary' 2>/dev/null)
  verdict=$(printf '%s' "$WAIT_OUT" | jq -r '"\(.verdict) (milestone \(.milestone))"' 2>/dev/null)
  info "verdict: $verdict"
  info "summary: $summary"
  if [ -z "$MS_COUNT" ]; then
    report INCONCLUSIVE step2.memory "1단계 마일스톤 개수를 몰라 확인하지 못함 · summary: $summary"
  elif printf '%s' "$summary" | grep -Eq "(^|[^0-9])$MS_COUNT ?개|개수[^0-9]{0,12}$MS_COUNT([^0-9]|$)"; then
    report PASS step2.memory "summary 에 직전 계획의 마일스톤 개수 ${MS_COUNT} 이(가) 있음 (사람이 위 summary 로 확인)"
  else
    report INCONCLUSIVE step2.memory "summary 에서 '${MS_COUNT}개' 형태를 찾지 못함 — 위 summary 를 사람이 판단"
  fi

  # R32: Codex 는 workspace-write 로 명령을 직접 실행하지만 프로젝트 파일은 바꾸지 않아야 한다
  #   (바꿨으면 감독 프로세스가 호출을 codex_modified 로 끝낸다. git status 로도 직접 확인한다)
  lc_status=$(st '.last_call.status // empty')
  porcelain=$(git -C "$REPO" status --porcelain 2>&1)
  if [ "$lc_status" != codex_modified ] && [ -z "$porcelain" ]; then
    report PASS step2.no-project-change "프로젝트 파일이 바뀌지 않음 (last_call.status=$lc_status, codex_modified 아님, git status 깨끗함)"
  else
    report FAIL step2.no-project-change "Codex 실행 중에 프로젝트 파일이 바뀜: last_call.status=$lc_status · message=$(st '.last_call.message // ""') · git status: $porcelain"
  fi
  info "Codex 가 실행한 명령(이벤트): $(ev_commands "$ev")"

  pol=$(rollout_policies "$SID")
  last_pol=$(printf '%s' "$pol" | awk '{ print $NF }')
  if [ -z "$pol" ]; then
    report INCONCLUSIVE step2.sandbox-config "이 세션의 rollout 파일(${CODEX_HOME:-$HOME/.codex}/sessions/…${SID}….jsonl)을 찾지 못함"
  else
    case "$last_pol" in
      workspace-write/*) report PASS step2.sandbox-config "rollout 의 턴별 sandbox/approval: $pol(재개한 마지막 턴도 workspace-write)" ;;
      *) report FAIL step2.sandbox-config "재개한 턴의 sandbox 가 workspace-write 가 아님. 턴별 sandbox/approval: $pol" ;;
    esac
  fi

  check_leftovers step2 "$SNAP2"
  [ "$N_FAIL" -eq "$f0" ]
}

# ---- 단계 3: 중단 ----
step3() {
  local out rc f0 i t_int el pre left late sup cdx grp hits b1 b2 line errl
  f0=$N_FAIL
  out=$(printf '%s\n' "$MSG3" | bash "$CC" put message 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then report FAIL step3.put "put message 코드 $rc: $out"; return 1; fi
  start_call message 3 || return 1
  # 실제 Claude Code 처럼 call 직후 wait 를 띄운다. 비대화형 bash 의 & 작업은 SIGINT 를 무시한 채 시작하므로
  # perl 로 SIGINT 를 기본값으로 되돌려 실행한다 (tests/cc/test_wait.sh 의 wt_start_waiter 와 같은 방법).
  perl -e '$SIG{INT} = "DEFAULT"; exec { $ARGV[0] } @ARGV or exit 127' bash "$CC" wait --max 300 \
    > "$WORK/w3.out" 2> "$WORK/w3.err" &
  WP=$!
  i=0
  while [ "$(st '.waiter.pid // empty')" != "$WP" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  info "wait 백그라운드 pid=$WP, state.waiter.pid=$(st '.waiter.pid // "null"')"
  while [ $((SECONDS - CALL_T0)) -lt 20 ]; do sleep 1; done

  R_CODEX_IDENT=$(st '.running.codex_identity // empty')
  if [ "$(st '.running.call_id // empty')" != 3 ] || [ -z "$R_CODEX_PID" ] \
     || ! cc_proc_alive_verified "$R_CODEX_PID" "$R_CODEX_IDENT"; then
    report INCONCLUSIVE step3.interrupt "중단 신호를 보내기 전에 호출이 끝났거나 codex 를 확인하지 못함 (running=$(st '.running | tostring'), last_call=$(st '.last_call | tostring')) — Codex 를 더 부르지 않음"
    i=0; while kill -0 "$WP" 2>/dev/null && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
    return 0
  fi
  info "중단 직전: codex pid=$R_CODEX_PID 실행 중 (호출 시작 +$((SECONDS - CALL_T0))초), 이벤트 type: $(ev_types "$ACTIVE/calls/3/events.jsonl")"
  pre=$(proc_tree "$R_PGID")
  show_tree "중단 직전 프로세스" "$pre" "$R_PGID"
  b1=$(rollout_bytes "$SID")

  t_int=$(now_ms)
  kill -INT "$WP"
  i=0; while kill -0 "$WP" 2>/dev/null && [ "$i" -lt 150 ]; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$WP" 2>/dev/null; then
    report FAIL step3.wait-exit "SIGINT 뒤 15초가 지나도 wait 가 끝나지 않음 (출력: $(cat "$WORK/w3.out" 2>/dev/null))"
    return 1
  fi
  wait "$WP"; rc=$?
  el=$(( $(now_ms) - t_int ))
  WP=""
  # wait 가 돌아온 바로 그때 확인한다 (기다리지 않음)
  cc_proc_alive_verified "$R_PGID" "$R_SUP_IDENT"; sup=$?
  cc_proc_alive_verified "$R_CODEX_PID" "$R_CODEX_IDENT"; cdx=$?
  _cc_proc_probe "-$R_PGID"; grp=$?
  hits=$(pgrep -f -- "$WORK" 2>/dev/null | tr '\n' ' ')
  left=$(still_alive "$pre")
  line=$(cat "$WORK/w3.out" 2>/dev/null); errl=$(cat "$WORK/w3.err" 2>/dev/null)

  if [ "$rc" -eq 130 ] && [ "$line" = "[cc] 중단됨: Codex 종료" ] && [ -z "$errl" ] && [ "$el" -le 15000 ]; then
    report PASS step3.wait-exit "SIGINT 뒤 ${el}ms 만에 wait 종료 코드 130, 출력 \"$line\""
  else
    report FAIL step3.wait-exit "종료 코드 $rc, ${el}ms, 출력 [$line], stderr [$errl]"
  fi

  if [ "$sup" -eq 1 ] && [ "$cdx" -eq 1 ] && [ "$grp" -eq 1 ]; then
    report PASS step3.group-gone "wait 가 돌아온 때 감독 프로세스($R_PGID)·codex($R_CODEX_PID) 없음, 그룹 $R_PGID 비었음"
  else
    report FAIL step3.group-gone "남아 있음: 감독 프로세스 확인 $sup, codex 확인 $cdx, 그룹 확인 $grp (0=있음 1=없음 2=판단 불가) · $(tree_brief "$(proc_tree "$R_PGID")")"
  fi

  if [ -z "$hits" ]; then
    report PASS step3.ps "명령줄에 임시 저장소 경로가 든 프로세스 없음 (pgrep -f)"
  else
    report FAIL step3.ps "임시 저장소 경로가 든 프로세스가 남음: $hits $(for i in $hits; do ps -ww -o pid=,pgid=,command= -p "$i" 2>/dev/null; done | tr '\n' ';' | cut -c1-400)"
  fi

  if [ -z "$left" ]; then
    report PASS step3.descendants "중단 직전에 적어 둔 감독 프로세스·codex 와 그 자손 $(count_lines "$pre")개가 모두 없음"
  else
    sleep 5
    late=$(still_alive "$left")
    if [ -z "$late" ]; then
      report PASS step3.descendants "그룹 밖 자손 $(count_lines "$left")개가 wait 종료 직후엔 남아 있었으나 5초 안에 끝남: $(tree_brief "$left")"
    else
      LEFTOVERS="$LEFTOVERS$late
"
      report FAIL step3.descendants "5초 뒤에도 남은 자손: $(tree_brief "$late")"
    fi
  fi

  info "state: last_call=$(st '.last_call | tostring') running=$(st '.running | tostring') phase=$(st .phase) waiter=$(st '.waiter | tostring')"
  if [ "$(st '.last_call.call_id')" = 3 ] && [ "$(st '.last_call.status')" = interrupted ] && [ "$(st '.running')" = null ] \
     && [ "$(st '.phase')" = interrupted ] && [ "$(cat "$ACTIVE/calls/3/status" 2>/dev/null)" = interrupted ] \
     && [ "$(st '.waiter')" = null ]; then
    report PASS step3.state "last_call={call 3, interrupted}, running=null, phase=interrupted, waiter=null, status 파일=interrupted (== state)"
  else
    report FAIL step3.state "last_call=$(st '.last_call | tostring') running=$(st '.running | tostring') phase=$(st .phase) waiter=$(st '.waiter | tostring') status 파일=$(cat "$ACTIVE/calls/3/status" 2>/dev/null)"
  fi

  check_calls step3 3

  # 중단된 턴이 다른 곳(예: 공유 app-server)에서 계속 돌면 이 세션의 rollout 파일이 계속 커진다
  if [ "$b1" -eq 0 ]; then
    report INCONCLUSIVE step3.no-background-turn "이 세션의 rollout 파일을 찾지 못함"
  else
    b1=$(rollout_bytes "$SID"); sleep 10; b2=$(rollout_bytes "$SID")
    if [ "$b2" -eq "$b1" ]; then
      report PASS step3.no-background-turn "중단 뒤 10초 동안 이 세션의 rollout 파일 크기 그대로 ($b1 바이트)"
    else
      report FAIL step3.no-background-turn "중단 뒤에도 rollout 파일이 커짐: $b1 → $b2 바이트 (턴이 다른 프로세스에서 계속될 수 있음)"
    fi
  fi
  info "rollout 턴별 sandbox/approval: $(rollout_policies "$SID")"
  [ "$N_FAIL" -eq "$f0" ]
}

# ---- 준비·정리 ----
setup() {
  local base bin
  bin=$(command -v "$CC_CODEX_BIN" 2>/dev/null) || { report FAIL setup "codex 실행 파일을 찾지 못함: $CC_CODEX_BIN"; return 1; }
  base="${CC_SMOKE_BASE:-${TMPDIR:-/tmp}}"
  base="${base%/}"
  WORK=$(mktemp -d "$base/cc-smoke.XXXXXX") || { report FAIL setup "임시 폴더를 만들지 못함: $base"; WORK=""; return 1; }
  WORK=$(cd -P "$WORK" && pwd -P)
  REPO="$WORK/smoke repo 한글"
  info "codex: $bin → $(perl -MCwd -e 'print Cwd::abs_path($ARGV[0])' "$bin" 2>/dev/null)${CC_SMOKE_CODEX_BIN:+ (CC_SMOKE_CODEX_BIN: 실제 codex 가 아님)}"
  info "설정: CC_MAX_CALLS=$CC_MAX_CALLS, 그 밖은 기본값 (시간 상한 ${CC_CALL_TIMEOUT_SECS}초, 빠른 실패 ${CC_FAST_FAIL_SECS}초, 확인 간격 ${CC_POLL_SECS}초). 모델·추론 강도 인자 없음"
  info "임시 저장소: $REPO"
  mkdir -p "$REPO" && (
    cd "$REPO" && git init -q . && git config user.name smoke && git config user.email smoke@example.com \
      && git config commit.gpgsign false \
      && printf '# smoke\n\ncc smoke test 용 임시 저장소입니다.\n' > README.md \
      && git add README.md && git commit -q -m init
  ) >/dev/null 2>&1 || { report FAIL setup "임시 git 저장소를 만들지 못함"; return 1; }
  cd "$REPO" || { report FAIL setup "임시 저장소로 이동하지 못함"; return 1; }
}

# 남은 호출·프로세스를 끝내고 (필요하면 기록을 복사한 뒤) 임시 저장소를 지운다
cleanup() {
  local pg sid cp cid r pid pg2 ls cmd
  [ "$CLEANED" = 1 ] && return 0
  CLEANED=1
  if [ -n "$WP" ] && kill -0 "$WP" 2>/dev/null; then
    kill -TERM "$WP" 2>/dev/null
    info "정리: 백그라운드 wait($WP)에 TERM"
    sleep 3
  fi
  if [ -n "$ACTIVE" ] && [ -f "$ACTIVE/state.json" ] && [ "$(st '.running != null')" = true ]; then
    pg=$(st '.running.pgid // empty'); sid=$(st '.running.supervisor_identity // empty')
    cp=$(st '.running.codex_pid // empty'); cid=$(st '.running.codex_identity // empty')
    cc_kill_group_verified "$pg" "$sid" 100 >/dev/null 2>&1; r=$?
    if [ "$r" -ne 0 ] && [ -n "$cp" ]; then cc_kill_group_via_member "$cp" "$cid" "$pg" >/dev/null 2>&1; r=$?; fi
    info "정리: 남은 호출의 그룹 $pg 종료 (코드 $r, 0=끝냄)"
  fi
  if [ -n "$LEFTOVERS" ]; then
    printf '%s\n' "$(still_alive "$LEFTOVERS")" | while IFS="$TAB" read -r pid pg2 ls cmd; do
      [ -n "$pid" ] || continue
      kill -TERM "$pid" 2>/dev/null && info "정리: 남은 프로세스 $pid 에 TERM ($(printf '%s' "$cmd" | cut -c1-100))"
    done
  fi
  if [ -n "${CC_SMOKE_SAVE_DIR:-}" ] && [ -n "$ACTIVE" ] && [ -d "$ACTIVE" ]; then
    mkdir -p "$CC_SMOKE_SAVE_DIR" && cp -R "$ACTIVE" "$CC_SMOKE_SAVE_DIR/active" 2>/dev/null \
      && { cp "$WORK"/w3.* "$CC_SMOKE_SAVE_DIR/" 2>/dev/null; info "상태 폴더 복사: $CC_SMOKE_SAVE_DIR/active"; }
  fi
  cd / || true
  case "$WORK" in
    */cc-smoke.*) rm -rf "$WORK" && info "임시 저장소 삭제: $WORK" ;;
  esac
}
trap 'cleanup' EXIT
trap 'exit 130' INT TERM HUP

main() {
  info "실제 Codex smoke test 시작 (Codex 실행 최대 ${CC_MAX_CALLS}회)"
  setup || return 0
  if step1; then
    if step2; then
      step3
    else
      report SKIP step3 "앞 단계 FAIL — Codex 를 더 부르지 않음"
    fi
  else
    report SKIP step2 "앞 단계 FAIL — Codex 를 더 부르지 않음"
    report SKIP step3 "앞 단계 FAIL — Codex 를 더 부르지 않음"
  fi
}

main
LAUNCHES=$(launches)
CALLS=$( [ -n "$ACTIVE" ] && st '.calls_total // 0' )
cleanup
echo "요약: PASS $N_PASS · FAIL $N_FAIL · INCONCLUSIVE $N_INC · SKIP $N_SKIP · Codex 실행 ${LAUNCHES}회 (감독 로그 기준, calls_total=${CALLS:-0}, 상한 $CC_MAX_CALLS)"
[ "$N_FAIL" -eq 0 ]
