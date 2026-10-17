# call.sh - Codex 인자 구성, call 명령, 감독 프로세스(_supervise), 결과 검증, 상태 반영.
# source 전용 (bash 3.2 호환). common.sh, state.sh, snapshot.sh, proc.sh, render.sh 뒤에 불러온다.
#
# 흐름
#   call <plan|review|message>  (Claude 가 부르는 셸)
#     1) 거부 조건·입력 파일 확인 → review 면 작업 트리 스냅샷
#     2) state 잠금 안에서: 거부 조건 재확인 → calls/<n>/prompt.md 생성
#        → 감독 프로세스를 새 프로세스 그룹으로 실행 → calls_total=n, running={…, pgid, supervisor_identity} 기록
#           (실행 중 단계: plan → phase=planning, review → phase=reviewing, message 는 그대로)
#        → 한 줄 출력하고 곧바로 끝난다
#   _supervise <n>  (감독 프로세스. 출력은 supervisor.log 로만)
#     1) running 이 자기(call_id=n, pgid=$$)를 가리킬 때까지 기다린다. 끝내 아니면 codex 를 띄우지 않고 끝낸다
#     2) codex 를 같은 그룹의 자식으로 실행 (stdin=prompt.md, stdout=events.jsonl, stderr=stderr.log, 저장소 루트)
#        exec 가 끝난 뒤 codex_pid / codex_identity 기록 (확인될 때까지 감시 반복 안에서 계속 시도)
#     3) 끝날 때까지 감시: CC_POLL_SECS 마다 events.jsonl 이 늘었으면 last_activity_at 갱신.
#        codex 실행 한 번(시도)마다 그 시작부터 CC_CALL_TIMEOUT_SECS 를 넘으면 codex 와 그 자식을 끝내고 timeout
#        (재시도 없음. 재실행·형식 재요청도 각자 새 상한을 받는다: Ruling R16)
#     4) codex 가 끝나면 같은 그룹에 남은 프로세스를 정리한다 (감독 프로세스 자신은 제외)
#     5) 실패 정책 (Task 6). 재시도도 calls_total 에 더하고 CC_MAX_CALLS 를 넘지 않는다 (Ruling R3)
#        - CC_FAST_FAIL_SECS 안에 비정상 종료하고 result 가 없으면 같은 인자로 1회 재실행
#        - result 가 형식에 맞지 않고 세션 ID 를 알면 pm-format-retry.md 로 resume 1회
#        - 시간 상한으로 끊긴 호출은 빠른 실패 구간 안이어도 timeout 이고 재시도하지 않는다 (Ruling R6)
#        - codex 인자를 만들지 못해 아무것도 실행하지 않았으면 다시 해도 같으므로 재실행 없이 error
#        시도마다 기록 파일을 따로 둔다: 1회차 events.jsonl / stderr.log, k회차 events-k.jsonl / stderr-k.log,
#        형식 재요청 프롬프트는 prompt-format-retry.md. result.json 은 시도마다 지우고 같은 경로에 받는다.
#     6) 세션 ID·토큰 추출(모든 시도), result.json 검증, verdict 반영, running=null, last_call 기록 → 마지막에 status 파일
#   running 을 받은 감독 프로세스는 어떻게 끝나든(내부 오류·신호 포함) status 파일과 running=null/last_call 을 남긴다.
#   마무리하는 동안에는 TERM/INT/HUP 을 무시하고, status 파일은 항상 state 가 이 호출에 기록한 값과 같다.

_CC_CALL_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
CC_SCHEMA_FILE="$_CC_CALL_LIB/pm-output.schema.json"
CC_PROMPT_DIR="$_CC_CALL_LIB/prompts"

# ---- 공통 도우미 ----
_cc_jq_get() { printf '%s' "$1" | jq -r "$2" 2>/dev/null; }

_cc_file_size() {
  local s
  s=$(wc -c < "$1" 2>/dev/null) || { echo 0; return 0; }
  echo $((s + 0))
}

# cc_codex_argv <exec|resume> <session_id|-> <call_dir> : codex 인자를 NUL 로 구분해 출력.
#   모델·추론 강도 인자는 절대 넣지 않는다 (사용자 Codex 설정 그대로). 강제하는 것은 읽기 전용 sandbox 뿐.
#   프롬프트는 stdin 으로 받는다(마지막 인자 "-"). resume 에는 -C 가 없으므로 저장소 루트에서 실행한다.
cc_codex_argv() {
  local mode="$1" sid="$2" dir="$3"
  [ -n "$dir" ] || return 1
  case "$mode" in
    exec)
      printf '%s\0' exec --json -s read-only --output-schema "$CC_SCHEMA_FILE" -o "$dir/result.json" - ;;
    resume)
      # 세션 ID 는 옵션으로 읽히지 않는 평범한 식별자여야 한다
      case "$sid" in ''|-*|*[!A-Za-z0-9._:-]*) return 1 ;; esac
      printf '%s\0' exec resume --json -c 'sandbox_mode="read-only"' --output-schema "$CC_SCHEMA_FILE" \
        -o "$dir/result.json" "$sid" - ;;
    *) return 1 ;;
  esac
}

# cc_result_valid <file> : 0 = 상태에 반영할 수 있는 Codex 결과 (Ruling R12)
#   JSON 값 하나, 객체, 스키마 필수 키 모두 있음, verdict 는 enum 안.
#   상태 반영에 직접 쓰는 값만 더 본다: plan 이 null 이 아니면 milestones 배열, verdict plan 은 plan 필수,
#   verdict approve 는 milestone 정수 필수. done/ask_user 는 milestone·instruction 이 null 이어도 되고,
#   approve/reject/plan 은 plan 을 함께 보내도 된다.
cc_result_valid() {
  [ -s "$1" ] || return 1
  jq -e -s '
    length == 1 and (.[0] | type == "object"
      and ((["verdict","summary","plan","milestone","instruction","findings","question"] - keys) == [])
      and (.verdict as $v | ["plan","approve","reject","done","ask_user"] | any(. == $v))
      and (.plan == null or ((.plan | type) == "object" and (.plan.milestones | type) == "array"))
      and (if .verdict == "plan" then .plan != null
           elif .verdict == "approve" then ((.milestone | type) == "number" and .milestone == (.milestone | floor))
           else true end))
  ' "$1" >/dev/null 2>&1
}

# events.jsonl 에서 첫 thread.started 의 thread_id (없으면 빈 출력). 깨진 줄은 건너뛴다.
_cc_events_session() {
  [ -f "$1" ] || return 0
  jq -R -r 'fromjson? | select(type == "object" and .type == "thread.started")
            | .thread_id | select(type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._:-]*$"))' "$1" 2>/dev/null | head -n 1
}

# events.jsonl 의 turn.completed.usage 합계를 "input cached_input output" 한 줄로 (없는 값은 0)
_cc_events_tokens() {
  local out=""
  [ -f "$1" ] && out=$(jq -R -s -r '
    [split("\n")[] | fromjson? | select(type == "object" and .type == "turn.completed")
     | (.usage // {}) | select(type == "object")] as $u
    | def n($k): [$u[] | .[$k] | if type == "number" then . else 0 end] | add // 0;
    "\(n("input_tokens")) \(n("cached_input_tokens")) \(n("output_tokens"))"' "$1" 2>/dev/null)
  case "$out" in *[!0-9.\ e+-]*|'') out="0 0 0" ;; esac
  printf '%s\n' "$out"
}

# ---- call ----
_cc_call_label() {
  case "$1" in
    plan) printf '계획 요청' ;;
    review) printf '검수 요청' ;;
    message) printf '메시지 전달' ;;
  esac
}

# state.json 을 한 줄 JSON 으로 (형식이 이상하면 1)
#   calls_total·rejects_in_row 는 0 이상의 정수여야 한다. 손으로 고친 값(문자열, 소수, 음수, 아주 큰 수)이면
#   셸 산술에서 bash 오류로 죽지 않도록 여기서 거른다 (호출한 쪽이 한 줄 오류를 낸다).
_cc_call_read_state() {
  jq -ce 'def count: type == "number" and . >= 0 and . == floor and . < 1000000000;
          select(type == "object" and (.calls_total | count) and (.rejects_in_row | count))' \
    "$1/state.json" 2>/dev/null
}

# _cc_call_is_running <state-json> : 0 = 실행 중으로 본다(살아 있음 또는 판단 불가) / 1 = 실행 중 아님
#   running 이 null 이면 아님. 하나라도 살아 있거나 판단할 수 없으면 실행 중.
#   기록된 감독 프로세스와 codex(기록돼 있으면)가 둘 다 확실히 끝났어도(없음·PID 재사용) 그 그룹에 무언가
#   (codex 의 자식, 기록 전에 실행된 codex 등)가 남아 있을 수 있다. 그룹에 신호 0 을 보내 확인만 하고
#   (아무것도 보내지 않음), 그룹이 확실히 비었을 때만 낡은 기록으로 본다 (낡은 기록 정리는 Task 8 몫).
#   그룹이 비어 있지 않거나 판단할 수 없으면 실행 중: 남은 것이 사는 동안 두 번째 Codex 를 띄우지 않는다.
#   거부는 안전하다. 이 확인되지 않은 근거로 무언가를 죽이지는 않는다.
_cc_call_is_running() {
  local st="$1" pg sid cp cid r1 r2=1
  [ "$(_cc_jq_get "$st" '.running == null')" = "true" ] && return 1
  pg=$(_cc_jq_get "$st" '.running.pgid // empty | tostring')
  sid=$(_cc_jq_get "$st" '.running.supervisor_identity // empty')
  cp=$(_cc_jq_get "$st" '.running.codex_pid // empty | tostring')
  cid=$(_cc_jq_get "$st" '.running.codex_identity // empty')
  cc_proc_alive_verified "$pg" "$sid"; r1=$?
  if [ -n "$cp" ]; then
    cc_proc_alive_verified "$cp" "$cid"; r2=$?
  fi
  [ "$r1" -eq 1 ] && [ "$r2" -eq 1 ] || return 0
  # r1 이 1 이면 pg 는 형식이 맞는 PID 다 (형식 오류는 2)
  _cc_proc_probe "-$pg"; [ $? -eq 1 ] && return 1
  return 0
}

# _cc_call_refusal <kind> <state-json> : 거부해야 하면 한 줄 출력하고 6 (실행 중·호출 상한·연속 반려 상한),
#   이어 쓸 세션이 없으면 한 줄 출력하고 1 (오류, Ruling R14), 아니면 0
_cc_call_refusal() {
  local kind="$1" st="$2" total rejects
  if _cc_call_is_running "$st"; then
    cc_line "[cc] Codex 호출이 이미 실행 중입니다 (호출 $(_cc_jq_get "$st" '.running.call_id // "?"')). 끝날 때까지 기다리세요."
    return 6
  fi
  total=$(_cc_jq_get "$st" '.calls_total')
  if [ "$total" -ge "$CC_MAX_CALLS" ] 2>/dev/null; then
    cc_line "[cc] Codex 호출 상한 ${CC_MAX_CALLS}회에 도달해 더 호출하지 않았습니다."
    return 6
  fi
  if [ "$kind" = review ]; then
    rejects=$(_cc_jq_get "$st" '.rejects_in_row')
    if [ "$rejects" -ge "$CC_MAX_REJECTS" ] 2>/dev/null; then
      cc_line "[cc] 같은 마일스톤에서 연속 반려 ${CC_MAX_REJECTS}회라 검수를 요청하지 않았습니다."
      return 6
    fi
  fi
  if [ "$kind" != plan ] && [ -z "$(_cc_jq_get "$st" '.session_id // empty')" ]; then
    cc_line "[cc] 이어 쓸 Codex 세션이 없습니다. 먼저 계획을 요청하세요."
    return 1
  fi
  return 0
}

# _cc_call_render <kind> <active> <out> <state-json> <review_tree>
#   파일 내용은 렌더 하는 서브셸에서만 CC_T_* 환경변수로 넘긴다.
_cc_call_render() {
  local kind="$1" a="$2" out="$3" st="$4" rt="$5" v ms mbase tbase
  case "$kind" in
    plan)
      v=$(cat "$a/brief.md") || return 1
      ( export CC_T_BRIEF="$v"; cc_render "$CC_PROMPT_DIR/pm-plan.md" "$out" ) ;;
    review)
      v=$(cat "$a/report.md") || return 1
      ms=$(_cc_jq_get "$st" '.milestone // "?" | tostring')
      tbase=$(_cc_jq_get "$st" '.task_base_tree // empty')
      mbase=$(_cc_jq_get "$st" '.milestone_base_tree // .task_base_tree // empty')
      ( export CC_T_REPORT="$v" CC_T_MILESTONE="$ms" CC_T_MILESTONE_BASE_TREE="$mbase" \
          CC_T_REVIEW_TREE="$rt" CC_T_TASK_BASE_TREE="$tbase" CC_T_VERIFY_DIR="$a/verify"
        cc_render "$CC_PROMPT_DIR/pm-review.md" "$out" ) ;;
    message)
      v=$(cat "$a/message.md") || return 1
      ( export CC_T_MESSAGE="$v"; cc_render "$CC_PROMPT_DIR/pm-message.md" "$out" ) ;;
    *) return 1 ;;
  esac
}

# 잠금을 잡은 상태에서 부른다. 거부 조건 재확인 → 프롬프트 → 감독 프로세스 실행 → running 기록 → 한 줄 출력
_cc_call_start_locked() {
  local kind="$1" a="$2" rt="$3" st n dir pgid ident now
  st=$(_cc_call_read_state "$a") || { cc_line "[cc] 상태 파일을 읽을 수 없습니다."; return 1; }
  _cc_call_refusal "$kind" "$st" || return $?
  n=$(( $(_cc_jq_get "$st" '.calls_total') + 1 ))
  dir="$a/calls/$n"
  # 같은 번호 폴더가 있으면 앞서 실패한 시도의 찌꺼기다 (calls_total 이 늘지 않았으므로 아무도 쓰지 않는다)
  rm -rf "$dir"
  mkdir -p "$dir" || { cc_line "[cc] 호출 폴더를 만들지 못했습니다."; return 1; }
  if [ "$kind" = review ]; then
    mkdir -p "$a/verify" || { rm -rf "$dir"; cc_line "[cc] 검증 출력 폴더를 만들지 못했습니다."; return 1; }
  fi
  _cc_call_render "$kind" "$a" "$dir/prompt.md" "$st" "$rt" || {
    rm -rf "$dir"; cc_line "[cc] Codex 프롬프트를 만들지 못했습니다."; return 1; }
  # 감독 프로세스가 이 호출과 같은 설정값을 쓰도록 넘긴다
  export CC_CALL_TIMEOUT_SECS CC_FAST_FAIL_SECS CC_POLL_SECS CC_MAX_CALLS CC_MAX_REJECTS CC_CODEX_BIN CC_STATE_LOCK_WAIT_SECS
  pgid=$(cc_spawn_group "$a/supervisor.log" bash "$CC_SELF_ABS" _supervise "$n") || {
    rm -rf "$dir"; cc_line "[cc] 감독 프로세스를 시작하지 못했습니다."; return 1; }
  # cc_spawn_group 은 exec 뒤에 돌아오므로 지금 신원이 최종 신원이다.
  # 신원을 못 얻으면 running 을 기록하지 않는다 → 감독 프로세스는 기록을 기다리다 codex 없이 끝난다.
  ident=$(cc_proc_identity "$pgid") || { cc_line "[cc] 감독 프로세스를 확인하지 못했습니다."; return 1; }
  now=$(cc_now_iso)
  if ! cc_state_update '.calls_total = $n
      | .running = {call_id: $n, kind: $kind, pgid: $pg, supervisor_identity: $ident,
                    codex_pid: null, codex_identity: null, started_at: $now,
                    review_tree: (if $rt == "" then null else $rt end)}
      | .phase = (if $kind == "review" then "reviewing" elif $kind == "plan" then "planning" else .phase end)' \
      --argjson n "$n" --arg kind "$kind" --argjson pg "$pgid" --arg ident "$ident" --arg now "$now" --arg rt "$rt"; then
    cc_kill_group_verified "$pgid" "$ident" >/dev/null 2>&1
    cc_line "[cc] 상태 파일을 쓰지 못해 Codex를 호출하지 않았습니다."
    return 1
  fi
  cc_line "[cc] Codex 호출 시작: $(_cc_call_label "$kind") (호출 $n/$CC_MAX_CALLS)"
}

# cc-codex.sh call <plan|review|message>
cc_cmd_call() {
  local kind="${1:-}" a st rt="" rc
  case "$kind" in
    plan|review|message) ;;
    *) cc_line "[cc] 사용법: call <plan|review|message>"; return 1 ;;
  esac
  cc_active_exists || { cc_line "[cc] 진행 중인 작업이 없습니다."; return 1; }
  cc_active_path_safe || { cc_line "[cc] 상태 폴더 경로가 비정상입니다."; return 1; }
  a=$(cc_active_dir) || { cc_line "[cc] git 저장소가 아닙니다."; return 1; }
  st=$(_cc_call_read_state "$a") || { cc_line "[cc] 상태 파일을 읽을 수 없습니다."; return 1; }
  # 잠금 전에 한 번 거른다 (거부될 호출에 스냅샷을 만들지 않도록). 최종 판단은 잠금 안에서 다시 한다.
  _cc_call_refusal "$kind" "$st" || return $?
  case "$kind" in
    plan)    [ -s "$a/brief.md" ]   || { cc_line "[cc] 정리본(brief.md)이 없어 계획을 요청할 수 없습니다."; return 1; } ;;
    review)  [ -s "$a/report.md" ]  || { cc_line "[cc] 구현 보고(report.md)가 없어 검수를 요청할 수 없습니다."; return 1; } ;;
    message) [ -s "$a/message.md" ] || { cc_line "[cc] 전달할 메시지(message.md)가 없습니다."; return 1; } ;;
  esac
  if [ "$kind" = review ]; then
    rt=$(cc_snapshot_tree) && [ -n "$rt" ] || { cc_line "[cc] 작업 트리 스냅샷을 만들지 못했습니다."; return 1; }
  fi
  cc_state_lock || { cc_line "[cc] 상태 파일이 잠겨 있어 Codex를 호출하지 못했습니다."; return 1; }
  _cc_call_start_locked "$kind" "$a" "$rt"
  rc=$?
  cc_state_unlock
  return "$rc"
}

# ---- 감독 프로세스 (_supervise) ----
# 전역: _CC_SUP_ID, _CC_SUP_ACTIVE, _CC_SUP_DIR, _CC_SUP_RUNNING(handshake 때 읽은 running),
#       _CC_SUP_CLAIMED(running 이 이 프로세스를 가리킴), _CC_SUP_DONE(마무리 끝), _CC_SUP_SIGNAL,
#       _CC_SUP_FINAL(state 에 반영한 이 호출의 최종 status),
#       _CC_SUP_CODEX_PID / _CC_SUP_CODEX_IDENT (실행 중인 codex 자식), _CC_SUP_CODEX_RECORDED(state 에 기록함),
#       _CC_SUP_ATTEMPT(지금 몇 번째 시도), _CC_SUP_ATTEMPT_SECS(직전 시도가 걸린 초),
#       _CC_SUP_T0(이번 시도의 codex 시작 시각, $SECONDS), _CC_SUP_TIMED_OUT(시간 상한으로 끊음),
#       _CC_SUP_NO_START(이번 시도에서 codex 인자를 못 만들어 아무것도 실행하지 않음),
#       _CC_SUP_TIMEOUT / _CC_SUP_FAST_FAIL / _CC_SUP_POLL / _CC_SUP_MAX_CALLS (검사한 설정값)

_cc_sup_log() { printf '%s [call %s] %s\n' "$(cc_now_iso)" "${_CC_SUP_ID:-?}" "$*"; }

# _cc_sup_uint <값> <기본값> : 0 이상의 정수(앞자리 0 없음, 9자리 이하)면 그 값, 아니면 기본값
#   설정값이 이상해도 시간 상한 감시가 셸 오류로 꺼지지 않도록 한다.
_cc_sup_uint() {
  case "$1" in
    0) printf '0' ;;
    ''|0*|*[!0-9]*|??????????*) printf '%s' "$2" ;;
    *) printf '%s' "$1" ;;
  esac
}

_cc_sup_init_config() {
  _CC_SUP_TIMEOUT=$(_cc_sup_uint "${CC_CALL_TIMEOUT_SECS:-}" 1200)
  _CC_SUP_FAST_FAIL=$(_cc_sup_uint "${CC_FAST_FAIL_SECS:-}" 60)
  _CC_SUP_POLL=$(_cc_sup_uint "${CC_POLL_SECS:-}" 5)
  _CC_SUP_MAX_CALLS=$(_cc_sup_uint "${CC_MAX_CALLS:-}" 20)
}

# 시도별 기록 파일: 1회차는 Task 5 와 같은 이름, k회차(k≥2)는 이름에 -k 를 붙인다
_cc_sup_events_file() {
  if [ "${1:-1}" -le 1 ]; then printf '%s' "$_CC_SUP_DIR/events.jsonl"; else printf '%s' "$_CC_SUP_DIR/events-$1.jsonl"; fi
}
_cc_sup_stderr_file() {
  if [ "${1:-1}" -le 1 ]; then printf '%s' "$_CC_SUP_DIR/stderr.log"; else printf '%s' "$_CC_SUP_DIR/stderr-$1.log"; fi
}

# running 이 이 감독 프로세스(call_id 와 pgid=$$)로 기록될 때까지 최대 약 10초 기다린다.
# call 은 잠금을 쥔 채 감독 프로세스를 띄우고 곧바로 running 을 쓰므로 보통 바로 맞는다.
_cc_sup_handshake() {
  local i=0 r
  while [ "$i" -lt 100 ]; do
    r=$(jq -c --argjson id "$_CC_SUP_ID" --argjson me "$$" '
          if (.running | type) == "object" and .running.call_id == $id and .running.pgid == $me
          then .running else empty end' "$_CC_SUP_ACTIVE/state.json" 2>/dev/null)
    if [ -n "$r" ]; then
      _CC_SUP_RUNNING=$r
      return 0
    fi
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

# codex_pid / codex_identity 를 state 에 쓴다 (running 이 아직 이 호출일 때만). 0 = 썼거나 쓸 필요 없음
_cc_sup_set_codex_identity() {
  _CC_SUP_CODEX_IDENT="$2"
  cc_state_update 'if (.running != null and .running.call_id == $id)
                   then .running.codex_pid = $pid | .running.codex_identity = $ident else . end' \
    --argjson id "$_CC_SUP_ID" --argjson pid "$1" --arg ident "$2" && return 0
  _cc_sup_log "codex 신원 기록 실패 (다시 시도함)"
  return 1
}

# _cc_sup_try_record_codex <pid> <감독 프로세스 명령줄> : codex 자식이 exec 를 마쳤으면 신원을 기록한다.
#   `&` 로 띄운 직후의 자식은 아직 이 감독 프로세스의 복사본이라 명령줄이 감독 프로세스와 같다.
#   명령줄이 달라졌을 때만 기록한다. 아직이면(또는 기록에 실패하면) 감시 반복에서 다시 부른다 (addendum C).
_cc_sup_try_record_codex() {
  local pid="$1" mine="$2" cur ident
  cur=$(LC_ALL=C ps -ww -o command= -p "$pid" 2>/dev/null) || return 1
  cur=$(_cc_proc_trim "$cur")
  [ -n "$cur" ] && [ "$cur" != "$mine" ] || return 1
  ident=$(cc_proc_identity "$pid") || return 1
  _cc_sup_set_codex_identity "$pid" "$ident" || return 1
  _CC_SUP_CODEX_RECORDED=1
}

# 같은 PID 가 한 번 더 exec 한 경우(예: #!/usr/bin/env node → node) 시작 시각은 같고 명령줄만 바뀐다.
# 그때는 기록한 신원을 새 명령줄로 고친다. 시작 시각이 다르면 다른 프로세스이므로 건드리지 않는다.
_cc_sup_refresh_codex_identity() {
  local pid="$1" cur
  [ "${_CC_SUP_CODEX_RECORDED:-0}" = 1 ] && [ -n "$_CC_SUP_CODEX_IDENT" ] || return 0
  cur=$(cc_proc_identity "$pid") || return 0
  [ "$cur" = "$_CC_SUP_CODEX_IDENT" ] && return 0
  [ "${cur%%|*}" = "${_CC_SUP_CODEX_IDENT%%|*}" ] || return 0
  _cc_sup_set_codex_identity "$pid" "$cur"
}

# 이번 시도의 codex 시작부터 시간 상한을 넘었는가 (상한은 codex 실행 한 번마다, Ruling R16).
# $SECONDS 는 정수 초라서 차이가 상한보다 "커야" 실제로 넘은 것이다.
_cc_sup_deadline_passed() {
  [ -n "${_CC_SUP_T0:-}" ] && [ $((SECONDS - _CC_SUP_T0)) -gt "$_CC_SUP_TIMEOUT" ]
}

# _cc_sup_timeout_message [상한 초] : 기본은 이 감독 프로세스의 상한 (wait 는 설정값을 넘겨 같은 문구를 만든다)
_cc_sup_timeout_message() {
  local t="${1:-$_CC_SUP_TIMEOUT}" label
  if [ "$t" -gt 0 ] && [ $((t % 60)) -eq 0 ]; then label="$((t / 60))분"; else label="${t}초"; fi
  printf '[cc] Codex 시간 초과(%s) — 자동 재시도하지 않았습니다' "$label"
}

# _cc_sup_stop_group [codex_pid] [TERM 뒤 기다릴 초, 기본 3] : codex 와, 같은 그룹에 남은 모든 프로세스를 끝낸다.
#   감독 프로세스 자신은 제외.
#   running 을 받은 감독 프로세스(= cc_spawn_group 으로 띄운 그룹 리더)는 멤버를 하나씩 TERM → KILL 한다
#   (addendum D·E: 자기 그룹 전체 신호는 자신에게도 가므로 쓰지 않는다).
#   그럴 수 없으면(거부: ps 실패, 정리하던 perl 이 신호로 죽음 등) 신원이 확인된 codex 하나에만 TERM 을 보내고,
#   정한 시간 안에 끝나지 않으면 신원을 다시 확인한 뒤 KILL 한다 (Task 7 addendum C: TERM 을 무시하는 codex 가
#   timeout 기록 뒤에도 계속 돌지 않도록). 이때 codex 의 자식은 따로 찾을 수 없다.
#   0 = 그룹에 남은 것 없음 / 2 = 그룹 정리를 하지 못함 (codex 는 끝냈거나 확인할 수 없음) / 3 = KILL 뒤에도 남음
_cc_sup_stop_group() {
  local pid="${1:-}" term="${2:-3}" rc i
  case "$term" in ''|*[!0-9]*) term=3 ;; esac
  if [ "${_CC_SUP_CLAIMED:-0}" = 1 ]; then
    cc_kill_own_group_members "$$" "$term"; rc=$?
    case "$rc" in
      0) return 0 ;;
      3) _cc_sup_log "KILL 뒤에도 그룹에 프로세스가 남아 있음"; return 3 ;;
    esac
    _cc_sup_log "그룹 정리를 하지 못함 (코드 $rc)"
  fi
  [ -n "$pid" ] && [ -n "$_CC_SUP_CODEX_IDENT" ] || return 2
  cc_proc_alive_verified "$pid" "$_CC_SUP_CODEX_IDENT" || return 2
  kill -TERM "$pid" 2>/dev/null
  # codex 는 이 셸의 자식이라 끝나면 bash 가 바로 거둔다: kill -0 이 실패하면 끝난 것
  i=0
  while [ "$i" -lt $((term * 10)) ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  kill -0 "$pid" 2>/dev/null || return 2
  cc_proc_alive_verified "$pid" "$_CC_SUP_CODEX_IDENT" || return 2
  _cc_sup_log "codex 가 TERM 뒤에도 끝나지 않아 KILL"
  kill -KILL "$pid" 2>/dev/null
  i=0
  while [ "$i" -lt 20 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  kill -0 "$pid" 2>/dev/null && { _cc_sup_log "KILL 뒤에도 codex 가 남아 있음"; return 3; }
  return 2
}

# codex 가 끝날 때까지 0.2초 간격으로 확인한다 (bash 가 끝난 자식을 바로 거두므로 kill -0 이 실패하면 끝난 것).
#   - codex 신원이 아직 기록되지 않았으면 매번 기록을 시도한다.
#   - 시간 상한을 넘으면 codex 와 그 자식을 끝내고 돌아온다 (_CC_SUP_TIMED_OUT=1). 이 감시는 감독 프로세스
#     자신이 한다: 기다리는 쪽(wait)이 없어도 상한이 지켜진다 (Task 3 caller note b).
#   - CC_POLL_SECS 마다 이번 시도의 events 파일이 늘었으면 last_activity_at 을 갱신하고 codex 신원을 다시 확인한다.
_cc_sup_watch() {
  local pid="$1" events="$2" mine size last=0 next
  mine=$(_cc_proc_trim "$(LC_ALL=C ps -ww -o command= -p $$ 2>/dev/null)")
  next=$((SECONDS + _CC_SUP_POLL))
  while kill -0 "$pid" 2>/dev/null; do
    [ "${_CC_SUP_CODEX_RECORDED:-0}" = 1 ] || _cc_sup_try_record_codex "$pid" "$mine"
    if _cc_sup_deadline_passed; then
      _CC_SUP_TIMED_OUT=1
      _cc_sup_log "시간 상한(${_CC_SUP_TIMEOUT}초) 초과 → codex 와 그 자식을 끝냄 (재시도 없음)"
      _cc_sup_stop_group "$pid"
      return 0
    fi
    if [ "$SECONDS" -ge "$next" ]; then
      size=$(_cc_file_size "$events")
      if [ "$size" -gt "$last" ]; then
        last=$size
        cc_state_update '.' || _cc_sup_log "활동 시각 갱신 실패"
      fi
      _cc_sup_refresh_codex_identity "$pid"
      next=$((SECONDS + _CC_SUP_POLL))
    fi
    sleep 0.2
  done
}

# _cc_sup_run_codex <exec|resume> <session|-> <prompt_file> : codex 를 한 번 실행하고 끝날 때까지 감시한다.
#   codex 는 이 감독 프로세스와 같은 그룹의 자식이다 (그룹째 종료할 수 있도록). 종료 코드를 돌려준다.
#   기록은 _CC_SUP_ATTEMPT 번째 시도의 events / stderr 파일에 쓴다. 끝나면 같은 그룹에 남은 것을 정리한다.
_cc_sup_run_codex() {
  local mode="$1" session="$2" prompt="$3" x pid rc t_start events errf i=0
  local -a argv
  [ -n "${_CC_SUP_TIMEOUT:-}" ] || _cc_sup_init_config
  : "${_CC_SUP_ATTEMPT:=1}"
  _CC_SUP_NO_START=0
  argv=()
  while IFS= read -r -d '' x; do argv[${#argv[@]}]="$x"; done < <(cc_codex_argv "$mode" "$session" "$_CC_SUP_DIR")
  if [ "${#argv[@]}" -eq 0 ]; then
    # 아무것도 실행하지 않았다: 이 시도의 실행 시간은 0 이고, 호출한 쪽은 재실행하지 않는다 (addendum D)
    _cc_sup_log "codex 인자를 만들지 못함 (mode=$mode)"
    _CC_SUP_NO_START=1; _CC_SUP_ATTEMPT_SECS=0
    return 125
  fi
  events=$(_cc_sup_events_file "$_CC_SUP_ATTEMPT")
  errf=$(_cc_sup_stderr_file "$_CC_SUP_ATTEMPT")
  rm -f "$_CC_SUP_DIR/result.json"
  _CC_SUP_CODEX_IDENT=""; _CC_SUP_CODEX_RECORDED=0
  _cc_sup_log "codex 실행 ($mode, 시도 $_CC_SUP_ATTEMPT)"
  t_start=$SECONDS
  _CC_SUP_T0=$t_start        # 시간 상한은 이 시도의 codex 시작부터 (Ruling R16)
  "$CC_CODEX_BIN" "${argv[@]}" < "$prompt" >> "$events" 2>> "$errf" &
  pid=$!
  _CC_SUP_CODEX_PID=$pid
  _cc_sup_watch "$pid" "$events"
  if [ "${_CC_SUP_TIMED_OUT:-0}" = 1 ]; then
    # 끝낸 codex 를 거둔다. KILL 뒤에도 남아 있으면 기다리지 않는다 (호출은 반드시 끝 상태에 이른다)
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 20 ]; do sleep 0.1; i=$((i + 1)); done
    if kill -0 "$pid" 2>/dev/null; then rc=137; else wait "$pid"; rc=$?; fi
  else
    wait "$pid"
    rc=$?
  fi
  _CC_SUP_ATTEMPT_SECS=$((SECONDS - t_start))
  _CC_SUP_CODEX_PID=""
  _cc_sup_log "codex 종료 (코드 $rc, ${_CC_SUP_ATTEMPT_SECS}초)"
  # codex 가 끝난 뒤에도 같은 그룹에 남은 것(codex 의 자식 등)을 끝낸다 (addendum D). 시간 상한이면 이미 했다.
  [ "${_CC_SUP_TIMED_OUT:-0}" = 1 ] || _cc_sup_stop_group
  return "$rc"
}

# _cc_sup_next_attempt : 재시도 한 번을 호출 수에 더한다 (Ruling R3). 잠금 안에서 확인하고 더한다.
#   0 = calls_total 을 1 늘리고 _CC_SUP_ATTEMPT 를 다음 번호로 / 1 = 호출 상한이라 더하지 않음
#   2 = running 이 더 이상 이 호출이 아니거나 state 를 읽고 쓰지 못함
_cc_sup_next_attempt() {
  local r rc=2
  cc_state_lock || return 2
  r=$(jq -r --argjson id "$_CC_SUP_ID" --argjson max "$_CC_SUP_MAX_CALLS" '
        if (.running | type) == "object" and .running.call_id == $id
           and (.calls_total | type) == "number" and .calls_total >= 0 and .calls_total == (.calls_total | floor)
        then (if .calls_total < $max then "ok" else "cap" end) else "no" end' "$_CC_SUP_ACTIVE/state.json" 2>/dev/null)
  case "$r" in
    ok) _cc_state_update_nolock '.calls_total += 1' && rc=0 ;;
    cap) rc=1 ;;
  esac
  cc_state_unlock
  [ "$rc" -eq 0 ] && _CC_SUP_ATTEMPT=$((_CC_SUP_ATTEMPT + 1))
  return "$rc"
}

# stderr 파일의 마지막 내용 줄 (제어 문자 제거, 200자 이내) 을 ": …" 형태로. 인자 없으면 지금 시도의 파일
_cc_sup_stderr_tail() {
  local l
  l=$(grep -v '^[[:space:]]*$' "$(_cc_sup_stderr_file "${1:-${_CC_SUP_ATTEMPT:-1}}")" 2>/dev/null \
      | tail -n 1 | tr -d '\000-\037' | cut -c1-200)
  [ -n "$l" ] && printf ': %s' "$l"
}

# 모든 시도의 events 에서 세션 ID: 가장 마지막 시도부터 거꾸로 보아 처음 나온 thread.started
#   (빠른 실패 뒤 exec 를 다시 하면 새 세션이 생기므로 결과를 낸 쪽의 세션을 쓴다)
_cc_sup_session_all() {
  local k="${_CC_SUP_ATTEMPT:-1}" s
  while [ "$k" -ge 1 ]; do
    s=$(_cc_events_session "$(_cc_sup_events_file "$k")")
    [ -n "$s" ] && { printf '%s\n' "$s"; return 0; }
    k=$((k - 1))
  done
}

# 모든 시도의 토큰 합계 "input cached_input output" (재시도도 토큰을 쓴다)
_cc_sup_tokens_all() {
  local k=1 lines="" out
  while [ "$k" -le "${_CC_SUP_ATTEMPT:-1}" ]; do
    lines="$lines$(_cc_events_tokens "$(_cc_sup_events_file "$k")")
"
    k=$((k + 1))
  done
  out=$(printf '%s' "$lines" | jq -R -s -r '
    [split("\n")[] | select(length > 0) | split(" ") | map(tonumber? // 0)]
    | if length == 0 then "0 0 0" else (transpose | map(add // 0) | "\(.[0]) \(.[1]) \(.[2])") end' 2>/dev/null)
  case "$out" in *[!0-9.\ e+-]*|'') out="0 0 0" ;; esac
  printf '%s\n' "$out"
}

_cc_sup_write_status() {
  local tmp="$_CC_SUP_DIR/.status.$$"
  { printf '%s\n' "$1" > "$tmp" && mv -f "$tmp" "$_CC_SUP_DIR/status"; } || _cc_sup_log "status 파일을 쓰지 못함"
}

# state 반영 필터. running 이 아직 이 호출일 때만 바꾼다 (그 사이 wait 의 중단 처리 등으로 running 이
# 바뀌었으면 덮어쓰지 않는다). 그래서 같은 호출을 두 번 반영해도 두 번째는 아무것도 바꾸지 않는다(토큰 중복 없음).
_CC_SUP_FINISH_FILTER='
def apply_verdict($r):
  if $r.verdict == "plan" then
    .milestone = 1 | .milestones_total = ($r.plan.milestones | length)
    | .milestone_base_tree = .task_base_tree | .phase = "working"
  elif $r.verdict == "approve" then
    .milestone = $r.milestone
    | .milestone_base_tree = (.running.review_tree // .milestone_base_tree)
    | .rejects_in_row = 0 | .phase = "working"
    | (if $r.plan != null then .milestones_total = ($r.plan.milestones | length) else . end)
  elif $r.verdict == "reject" then
    .rejects_in_row = ((.rejects_in_row // 0) + 1) | .phase = "working"
    | (if $r.plan != null then .milestones_total = ($r.plan.milestones | length) else . end)
  elif $r.verdict == "done" then .phase = "done"
  else .phase = "asking" end;
if (.running != null and .running.call_id == $id) then
    .tokens = {input: ((.tokens.input // 0) + $ti), cached_input: ((.tokens.cached_input // 0) + $tc),
               output: ((.tokens.output // 0) + $to)}
    | (if $sid != "" then .session_id = $sid else . end)
    | (if $st == "ok" then apply_verdict($r[0])
       elif $st == "interrupted" then .phase = "interrupted"
       else .phase = "failed" end)
    | .last_call = {call_id: $id, kind: .running.kind, status: $st,
                    verdict: (if $st == "ok" then $r[0].verdict else null end),
                    message: (if $msg == "" then null else $msg end)}
    | .running = null
  else . end'

# _cc_sup_record_result <st> <msg> <sid> <ti> <tc> <to> <jq 인자...> : 잠금 안에서 결과를 반영하고, 반영한 뒤
#   state 가 이 호출을 어떻게 기록하고 있는지 그 자리에서 읽는다 (addendum A: status 파일은 state 와 같아야 한다).
#   _CC_SUP_REC = 이 호출의 최종 status
#     - running 이 이 호출이 아니고 last_call 이 이 호출이면 → last_call.status (이 반영이든, 먼저 기록한 다른 쪽이든)
#     - state 가 이 호출을 더 이상 추적하지 않으면 → <st>
#   반환 1 = 잠금을 못 잡았거나 반영하지 못해 running 이 아직 이 호출 (다시 시도할 것)
_cc_sup_record_result() {
  local st="$1" msg="$2" sid="$3" ti="$4" tc="$5" to="$6" r
  shift 6
  _CC_SUP_REC=""
  cc_state_lock || return 1
  _cc_state_update_nolock "$_CC_SUP_FINISH_FILTER" --argjson id "$_CC_SUP_ID" --arg st "$st" --arg msg "$msg" \
    --arg sid "$sid" --argjson ti "${ti:-0}" --argjson tc "${tc:-0}" --argjson to "${to:-0}" "$@" \
    || _cc_sup_log "state 반영 실패"
  r=$(jq -r --argjson id "$_CC_SUP_ID" '
        if (.running | type) == "object" and .running.call_id == $id then "@running"
        elif (.last_call | type) == "object" and .last_call.call_id == $id
          and (.last_call.status | type) == "string" and (.last_call.status | test("^[a-z_]+$"))
          then .last_call.status
        else "@other" end' "$_CC_SUP_ACTIVE/state.json" 2>/dev/null)
  cc_state_unlock
  case "$r" in
    ''|@running) return 1 ;;
    @other) _CC_SUP_REC=$st ;;
    *) _CC_SUP_REC=$r ;;
  esac
  return 0
}

# _cc_sup_finish <ok|error|invalid_json|timeout|interrupted> <message> : 세션·토큰·verdict 를 state 에 반영하고
# running=null, last_call 을 기록한 뒤 마지막으로 status 파일을 쓴다.
# (wait 는 status 파일을 보고 state·result 를 읽으므로 state 가 먼저다.)
#   - 시작하자마자 TERM/INT/HUP 을 무시한다. 마무리 도중 신호가 더 와도 끝까지 기록한다 (addendum A).
#   - status 파일에는 state 가 이 호출에 기록한 값을 쓴다 (다른 쪽이 먼저 기록했으면 그 값).
#   - 다시 불리면(_CC_SUP_FINAL 있음) 이미 정한 값을 그대로 쓴다.
_cc_sup_finish() {
  local st="$1" msg="$2" sid ti tc to i
  local -a rarg
  trap '' TERM INT HUP
  if [ -n "${_CC_SUP_FINAL:-}" ]; then
    _cc_sup_write_status "$_CC_SUP_FINAL"
    _CC_SUP_DONE=1
    return 0
  fi
  sid=$(_cc_sup_session_all)
  read -r ti tc to <<EOF
$(_cc_sup_tokens_all)
EOF
  if [ "$st" = ok ]; then rarg=(--slurpfile r "$_CC_SUP_DIR/result.json"); else rarg=(--argjson r '[]'); fi
  _CC_SUP_REC=""
  for i in 1 2 3; do
    _cc_sup_record_result "$st" "$msg" "$sid" "$ti" "$tc" "$to" "${rarg[@]}" && break
    sleep 1
  done
  if [ -z "$_CC_SUP_REC" ]; then
    _cc_sup_log "state 에 결과를 반영하지 못함"
    _CC_SUP_REC=$st
  fi
  _CC_SUP_FINAL=$_CC_SUP_REC
  _cc_sup_write_status "$_CC_SUP_FINAL"
  _CC_SUP_DONE=1
  _cc_sup_log "끝: $_CC_SUP_FINAL"
}

# 신호 처리: 곧바로 TERM/INT/HUP 을 무시로 바꾸고(두 번째 신호가 마무리를 끊지 않도록) 종료한다 → EXIT trap
_cc_sup_on_signal() {
  trap '' TERM INT HUP
  _CC_SUP_SIGNAL=$1
  exit "$2"
}

# 비정상 종료(내부 오류·신호)에도 running 을 받은 호출은 상태를 남긴다: 같은 그룹의 codex 와 그 자식을 끝내고,
# running=null / last_call / status 를 기록한다. 이 동안 TERM/INT/HUP 은 무시한다.
# running 이 이 프로세스를 가리킨 적이 없으면 아무것도 쓰지 않는다 (그 번호는 다른 call 이 다시 쓸 수 있다).
_cc_sup_on_exit() {
  local rc=$? st msg
  trap '' TERM INT HUP
  trap - EXIT
  [ "${_CC_SUP_DONE:-0}" = 1 ] && return 0
  [ "${_CC_SUP_CLAIMED:-0}" = 1 ] || return 0
  if [ "${_CC_SUP_TIMED_OUT:-0}" = 1 ]; then
    st=timeout
    msg=$(_cc_sup_timeout_message)
  elif [ -n "$_CC_SUP_SIGNAL" ]; then
    st=interrupted
    msg="[cc] 감독 프로세스가 종료 신호($_CC_SUP_SIGNAL)를 받아 Codex 호출이 중단됐습니다."
  else
    st=error
    msg="[cc] Codex 감독 프로세스가 예기치 않게 끝났습니다 (코드 $rc)."
  fi
  _cc_sup_log "비정상 종료 → $st"
  # 중단 신호면 멤버도 대개 같은 TERM 을 이미 받았다 (wait 는 그룹 전체에 보낸다). TERM 뒤 1초만 기다리고 KILL 해서
  # 기다리는 쪽(wait)이 KILL 하기 전에 마무리(state·status 기록)를 끝낸다 (Task 7 addendum A)
  if [ -n "$_CC_SUP_SIGNAL" ]; then
    _cc_sup_stop_group "$_CC_SUP_CODEX_PID" 1
  else
    _cc_sup_stop_group "$_CC_SUP_CODEX_PID"
  fi
  _cc_sup_finish "$st" "$msg"
}

_cc_sup_main() {
  local kind session mode root rc prompt known s tail fast_used=0 fmt_used=0
  kind=$(_cc_jq_get "$_CC_SUP_RUNNING" '.kind // empty')
  session=$(jq -r '.session_id // empty' "$_CC_SUP_ACTIVE/state.json" 2>/dev/null)
  case "$kind" in
    plan) mode=exec; session=-; known="" ;;
    review|message)
      mode=resume; known=$session
      [ -n "$session" ] || { _cc_sup_finish error "[cc] 이어 쓸 Codex 세션이 없습니다."; return 0; } ;;
    *) _cc_sup_finish error "[cc] 알 수 없는 호출 종류입니다: ${kind:-(없음)}"; return 0 ;;
  esac
  root=$(git rev-parse --show-toplevel 2>/dev/null) || root=$(jq -r '.repo_root // empty' "$_CC_SUP_ACTIVE/state.json" 2>/dev/null)
  if [ -z "$root" ] || ! cd "$root"; then
    _cc_sup_finish error "[cc] 저장소 루트로 이동하지 못해 Codex를 실행하지 않았습니다."
    return 0
  fi
  prompt="$_CC_SUP_DIR/prompt.md"
  while :; do
    _cc_sup_run_codex "$mode" "$session" "$prompt"
    rc=$?
    # 인자를 만들지 못해 codex 를 실행하지 않았다: 다시 해도 같으므로 호출 번호를 쓰지 않고 끝낸다 (addendum D)
    if [ "${_CC_SUP_NO_START:-0}" = 1 ]; then
      _cc_sup_finish error "[cc] Codex 실행 인자를 만들지 못해 Codex를 실행하지 않았습니다 (세션 ID 형식 확인 필요)."
      return 0
    fi
    # 시간 상한: 빠른 실패 구간 안이어도 timeout, 재시도 없음 (Ruling R6)
    if [ "$_CC_SUP_TIMED_OUT" = 1 ]; then
      _cc_sup_finish timeout "$(_cc_sup_timeout_message)"; return 0
    fi
    if cc_result_valid "$_CC_SUP_DIR/result.json"; then
      _cc_sup_finish ok ""; return 0
    fi
    s=$(_cc_events_session "$(_cc_sup_events_file "$_CC_SUP_ATTEMPT")")
    [ -n "$s" ] && known=$s
    if [ "$rc" -ne 0 ]; then
      tail=$(_cc_sup_stderr_tail)
      # 실행 직후의 분명한 기술적 오류(빠르게 비정상 종료, result 없음)만 같은 인자로 1회 재실행한다
      if [ "$fast_used" = 0 ] && [ "$_CC_SUP_ATTEMPT_SECS" -lt "$_CC_SUP_FAST_FAIL" ] && [ ! -s "$_CC_SUP_DIR/result.json" ]; then
        fast_used=1
        _cc_sup_next_attempt
        case $? in
          0) _cc_sup_log "빠른 실패 → 같은 인자로 1회 재실행"; continue ;;
          1) _cc_sup_finish error "[cc] Codex 실행이 실패했고 호출 상한 ${_CC_SUP_MAX_CALLS}회에 도달해 재시도하지 않았습니다 (종료 코드 $rc)$tail"
             return 0 ;;
        esac
        _cc_sup_finish error "[cc] Codex 실행이 실패했습니다 (종료 코드 $rc)$tail"; return 0
      fi
      if [ "$fast_used" = 1 ]; then
        _cc_sup_finish error "[cc] Codex 실행이 재시도 후에도 실패했습니다 (종료 코드 $rc)$tail"
      else
        _cc_sup_finish error "[cc] Codex 실행이 실패했습니다 (종료 코드 $rc)$tail"
      fi
      return 0
    fi
    # 정상 종료했지만 쓸 수 있는 결과가 아님: 세션을 알면 형식 재요청 1회
    if [ "$fmt_used" = 0 ] && [ -n "$known" ]; then
      fmt_used=1
      if ! cc_render "$CC_PROMPT_DIR/pm-format-retry.md" "$_CC_SUP_DIR/prompt-format-retry.md"; then
        _cc_sup_finish invalid_json "[cc] Codex 응답이 요구한 JSON 형식이 아니고, 형식 재요청 프롬프트를 만들지 못했습니다."
        return 0
      fi
      _cc_sup_next_attempt
      case $? in
        0) mode=resume; session=$known; prompt="$_CC_SUP_DIR/prompt-format-retry.md"
           _cc_sup_log "형식이 맞지 않음 → 같은 세션에 형식 재요청 1회"; continue ;;
        1) _cc_sup_finish invalid_json "[cc] Codex 응답이 요구한 JSON 형식이 아니고, 호출 상한 ${_CC_SUP_MAX_CALLS}회에 도달해 형식 재요청을 하지 않았습니다."
           return 0 ;;
      esac
      _cc_sup_finish invalid_json "[cc] Codex 응답이 요구한 JSON 형식이 아닙니다."; return 0
    fi
    if [ "$fmt_used" = 1 ]; then
      _cc_sup_finish invalid_json "[cc] Codex 응답이 형식 재요청 뒤에도 요구한 JSON 형식이 아닙니다."
    else
      _cc_sup_finish invalid_json "[cc] Codex 응답이 요구한 JSON 형식이 아니고, 이어 쓸 세션을 알 수 없어 형식 재요청을 하지 않았습니다."
    fi
    return 0
  done
}

# cc-codex.sh _supervise <call_id>  (내부용. call 이 cc_spawn_group 으로 띄운다. 출력은 supervisor.log 로만)
cc_cmd_supervise() {
  _CC_SUP_ID="${1:-}"
  _CC_SUP_DONE=0; _CC_SUP_CLAIMED=0; _CC_SUP_SIGNAL=""; _CC_SUP_CODEX_PID=""; _CC_SUP_CODEX_IDENT=""; _CC_SUP_FINAL=""
  _CC_SUP_CODEX_RECORDED=0; _CC_SUP_ATTEMPT=1; _CC_SUP_ATTEMPT_SECS=0; _CC_SUP_T0=""; _CC_SUP_TIMED_OUT=0; _CC_SUP_REC=""
  _CC_SUP_NO_START=0
  _cc_sup_init_config
  case "$_CC_SUP_ID" in ''|0*|*[!0-9]*) _cc_sup_log "잘못된 호출 번호: ${1:-}"; return 1 ;; esac
  _CC_SUP_ACTIVE=$(cc_active_dir) || { _cc_sup_log "git 저장소를 찾지 못함"; return 1; }
  _CC_SUP_DIR="$_CC_SUP_ACTIVE/calls/$_CC_SUP_ID"
  [ -d "$_CC_SUP_DIR" ] || { _cc_sup_log "호출 폴더 없음: $_CC_SUP_DIR"; return 1; }
  trap '_cc_sup_on_exit' EXIT
  trap '_cc_sup_on_signal TERM 143' TERM
  trap '_cc_sup_on_signal INT 130' INT
  trap '_cc_sup_on_signal HUP 129' HUP
  _cc_sup_log "감독 시작 (pid $$)"
  if ! _cc_sup_handshake; then
    _cc_sup_log "running 기록이 이 감독 프로세스를 가리키지 않아 codex 를 실행하지 않고 끝냄"
    return 1
  fi
  _CC_SUP_CLAIMED=1
  _cc_sup_main
  return 0
}
