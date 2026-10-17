# call.sh - Codex 인자 구성, call 명령, 감독 프로세스(_supervise), 결과 검증, 상태 반영.
# source 전용 (bash 3.2 호환). common.sh, state.sh, snapshot.sh, proc.sh, render.sh 뒤에 불러온다.
#
# 흐름
#   call <plan|review|message>  (Claude 가 부르는 셸)
#     1) 거부 조건·입력 파일 확인 → review 면 작업 트리 스냅샷 (done 뒤의 message 도: 새 마일스톤의 기준)
#     2) state 잠금 안에서: 거부 조건 재확인 → calls/<n>/prompt.md 생성
#        → 감독 프로세스를 새 프로세스 그룹으로 실행 → calls_total=n, running={…, pgid, supervisor_identity} 기록
#           (실행 중 단계: plan → phase=planning, review → phase=reviewing, message 는 그대로)
#        → 한 줄 출력하고 곧바로 끝난다
#   _supervise <n> <active>  (감독 프로세스. 출력은 supervisor.log 로만. <active> 는 명령줄 표시용, 아래 cc_cmd_supervise)
#     1) running 이 자기(call_id=n, pgid=$$)를 가리킬 때까지 기다린다. 끝내 아니면 codex 를 띄우지 않고 끝낸다
#     2) codex 를 같은 그룹의 자식으로 실행 (stdin=prompt.md, stdout=events.jsonl, stderr=stderr.log, 저장소 루트)
#        exec 가 끝난 뒤 codex_pid / codex_identity 기록 (확인될 때까지 감시 반복 안에서 계속 시도)
#     3) 끝날 때까지 감시: CC_POLL_SECS 마다 events.jsonl 이 늘었으면 last_activity_at 갱신.
#        codex 실행 한 번(시도)마다 그 시작부터 CC_CALL_TIMEOUT_SECS 를 넘으면 codex 와 그 자식을 끝내고 timeout
#        (재시도 없음. 재실행·형식 재요청도 각자 새 상한을 받는다: Ruling R16)
#     4) codex 가 끝나면 같은 그룹에 남은 프로세스를 정리한다 (감독 프로세스 자신은 제외)
#     5) 실패 정책 (Task 6). 재시도도 calls_total 에 더하고 CC_MAX_CALLS 를 넘지 않는다 (Ruling R3)
#        - CC_FAST_FAIL_SECS 안에 비정상 종료하고 result 가 없으면 같은 인자로 1회 재실행
#        - result 가 형식에 맞지 않거나 호출 종류에 맞게 쓸 수 없고(cc_result_problem) 세션 ID 를 알면
#          그 이유를 넣은 pm-format-retry.md 로 resume 1회
#        - 시간 상한으로 끊긴 호출은 빠른 실패 구간 안이어도 timeout 이고 재시도하지 않는다 (Ruling R6)
#        - codex 인자를 만들지 못해 아무것도 실행하지 않았으면 다시 해도 같으므로 재실행 없이 error
#        시도마다 기록 파일을 따로 둔다: 1회차 events.jsonl / stderr.log, k회차 events-k.jsonl / stderr-k.log,
#        형식 재요청 프롬프트는 prompt-format-retry.md. result.json 은 시도마다 지우고 같은 경로에 받는다.
#     6) 세션 ID·토큰 추출(모든 시도), result.json 검증, verdict 반영, running=null, last_call 기록 → 마지막에 status 파일
#   running 을 받은 감독 프로세스는 어떻게 끝나든(내부 오류·신호 포함) status 파일과 running=null/last_call 을 남긴다.
#   마무리하는 동안에는 TERM/INT/HUP 을 무시하고, status 파일은 항상 state 가 이 호출에 기록한 값과 같다.
#   종료를 확인하지 못한 호출 (Codex 리뷰 1, R30): 마지막 그룹 정리가 "남은 것 없음"(0)을 확인하지 못했으면
#     (2 판단 불가, 3 KILL 뒤에도 남음) 끝 상태(last_call·phase·status 파일)는 똑같이 기록하되 running 은 지우지 않고
#     running.stop_failed = true 로 남긴다 (pgid·감독 프로세스·codex 의 PID 와 신원 그대로). 그래서 call·wait·고아 확인·훅·
#     preflight·버리기·마무리·14일 정리가 계속 이 기록으로 살아 있음·판단 불가·남은 그룹을 본다. 정말 사라진 것(dead)이
#     확인되면 죽은 기록 정리가 running 만 지운다 (끝 상태는 그대로. wait.sh 의 _cc_wait_settle).
#     wait 는 stop_failed 기록을 "끝난 호출" 로 보고 기록된 결과를 곧바로 돌려준다. call 은 이 기록이 dead 가 될 때까지 거부한다.
#   Codex 의 프로젝트 파일 수정 감시 (R31/R32): Codex 는 workspace-write 로 돈다 (테스트를 직접 돌리도록).
#     codex 를 실행할 때마다(첫 실행·빠른 실패 재실행·형식 재요청) 실행 직전에 작업 트리 스냅샷(pre)을 뜨고, codex 가 끝나고
#     그룹을 정리한 뒤(정상 종료·실패·시간 상한·중단 신호 모두) 다시 뜬다(post). 스냅샷은 추적 파일 + 무시되지 않은 새 파일이다
#     (git 이 무시하는 캐시·빌드 결과물은 바뀌어도 된다).
#     - pre != post → 끝 상태 codex_modified (재시도·형식 재요청 없음, result 를 state 에 반영하지 않음, phase=failed).
#       last_call.message 는 바뀐 파일(최대 10개, git diff --name-only pre post)과 확인 명령을 담은 한 줄,
#       last_call.pre_tree / post_tree 에 두 트리를 남긴다. 아무것도 되돌리거나 지우지 않는다.
#       Codex 실행 중에 사용자가 고친 파일도 같이 잡힌다 (그래서 메시지는 "Codex 실행 중에 바뀐 파일" 이라고 쓴다).
#     - pre 를 뜨지 못함 → codex 를 실행하지 않고 error. post 를 뜨지 못함 → 끝난 원인(정상·시간 상한·중단 신호)과 상관없이
#       결과를 반영하지 않고 error (확인할 수 없음. Codex 리뷰 1차 4).
#     - pre 는 codex 를 띄우기 전에 running.pre_tree 로 state 에 남긴다 (못 남기면 실행하지 않음). 감독 프로세스가 끝 상태 없이
#       죽어도 그룹이 사라진 것을 확인한 쪽(wait·check-orphan·preflight·call)이 이것으로 다시 비교한다 (Codex 리뷰 1차 3, wait.sh).
#     - 그룹이 비었음을 확인하지 못했으면(stop_failed) 그 순간 같아도 안전하다고 보지 않는다: 결과를 반영하지 않고(정상
#       응답이어도 error) 재시도도 하지 않는다. 그룹이 확실히 사라진 뒤 위와 같이 다시 비교한다 (Codex 리뷰 1차 2).
#     - 하위 모듈 안의 변경도 잡힌다 (snapshot.sh, Codex 리뷰 1차 1).

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
#   모델·추론 강도 인자는 절대 넣지 않는다 (사용자 Codex 설정 그대로). 강제하는 것은 sandbox 뿐:
#   Codex 가 실제 프로젝트에서 테스트·빌드·린트를 직접 돌리도록 workspace-write (R31). 네트워크 설정은 덮어쓰지 않는다
#   (Codex 기본값: 막힘). Codex 가 프로젝트 파일을 바꾸는지는 감독 프로세스가 실행 전후 작업 트리로 확인한다 (R32).
#   프롬프트는 stdin 으로 받는다(마지막 인자 "-"). resume 에는 -C 가 없으므로 저장소 루트에서 실행한다.
cc_codex_argv() {
  local mode="$1" sid="$2" dir="$3"
  [ -n "$dir" ] || return 1
  case "$mode" in
    exec)
      printf '%s\0' exec --json -s workspace-write --output-schema "$CC_SCHEMA_FILE" -o "$dir/result.json" - ;;
    resume)
      # 세션 ID 는 옵션으로 읽히지 않는 평범한 식별자여야 한다
      case "$sid" in ''|-*|*[!A-Za-z0-9._:-]*) return 1 ;; esac
      printf '%s\0' exec resume --json -c 'sandbox_mode="workspace-write"' --output-schema "$CC_SCHEMA_FILE" \
        -o "$dir/result.json" "$sid" - ;;
    *) return 1 ;;
  esac
}

# cc_result_problem <file> [kind] : Codex 결과를 상태에 반영할 수 없는 이유를 한 줄로 출력하고 1. 쓸 수 있으면 출력 없이 0.
#   이유는 형식 재요청 프롬프트({{REASON}})와 실패 메시지에 그대로 들어간다 (결과 파일 내용은 넣지 않는다).
#   공통 (Ruling R12·R13): JSON 값 하나, 객체, 스키마 필수 키 모두 있음, verdict 는 enum 안, plan 이 null 이 아니면
#     milestones 배열, verdict plan 은 plan 필수, verdict approve 는 milestone 정수 필수, verdict ask_user 는 비어 있지 않은
#     question 필수. done 은 milestone·instruction 이 null 이어도 되고, approve/reject/plan 은 plan 을 함께 보내도 된다.
#   호출 종류별 (Codex 리뷰 4, R30): SKILL 절차가 다음에 할 일(지시·질문)이 있는 결과만 받는다.
#     plan    : verdict plan(마일스톤 1개 이상, 비어 있지 않은 instruction, milestone 1 또는 null) 또는 ask_user 만
#     review  : approve(비어 있지 않은 instruction), reject(비어 있지 않은 instruction), done, ask_user. plan 은 받지 않는다
#     message : approve(비어 있지 않은 instruction), plan(마일스톤 1개 이상 + instruction), ask_user.
#               done·reject 는 R27 대로 받는다 (반영할 때 검수 결과로 세지 않는다)
#   kind 를 주지 않으면 공통 조건만 본다.
cc_result_problem() {
  local f="$1" kind="${2:-}" why
  if [ ! -s "$f" ]; then
    printf '%s\n' "결과 JSON 이 비어 있습니다 (스키마에 맞는 JSON 객체 하나를 출력해야 합니다)"
    return 1
  fi
  why=$(jq -r -s --arg kind "$kind" '
    def text: type == "string" and test("\\S");
    def keys_needed: ["verdict","summary","plan","milestone","instruction","findings","question"];
    if length != 1 or (.[0] | type) != "object" then "JSON 객체 하나가 아닙니다"
    else .[0] |
      if (keys_needed - keys) != [] then "필수 필드가 빠졌습니다: \((keys_needed - keys) | join(", "))"
      elif (.verdict as $v | ["plan","approve","reject","done","ask_user"] | any(. == $v)) | not
        then "verdict 는 plan, approve, reject, done, ask_user 중 하나여야 합니다"
      elif .plan != null and ((.plan | type) != "object" or (.plan.milestones | type) != "array")
        then "plan 은 null 이거나 milestones 배열을 가진 객체여야 합니다"
      elif .verdict == "plan" and .plan == null then "verdict \"plan\" 인데 plan 이 null 입니다"
      elif .verdict == "approve" and ((.milestone | type) != "number" or .milestone != (.milestone | floor))
        then "verdict \"approve\" 인데 milestone 이 정수가 아닙니다"
      elif .verdict == "ask_user" and (.question | text | not)
        then "verdict \"ask_user\" 인데 사용자에게 물을 question 이 비어 있습니다"
      elif $kind == "plan" and .verdict != "plan" and .verdict != "ask_user"
        then "계획 요청에는 verdict \"plan\" (물어볼 것이 있으면 \"ask_user\") 만 쓸 수 있습니다 (받은 verdict: \"\(.verdict)\")"
      elif $kind == "review" and .verdict == "plan"
        then "검수 요청에는 verdict \"plan\" 을 쓸 수 없습니다 (approve, reject, done, ask_user 중 하나. 계획이 바뀌면 plan 필드에 담으세요)"
      elif ($kind == "plan" or $kind == "message") and .verdict == "plan" and (.plan.milestones | length) == 0
        then "verdict \"plan\" 인데 plan.milestones 에 마일스톤이 하나도 없습니다"
      elif ($kind == "plan" or $kind == "message") and .verdict == "plan" and (.instruction | text | not)
        then "verdict \"plan\" 인데 1번 마일스톤의 작업 지시(instruction)가 비어 있습니다"
      elif $kind == "plan" and .verdict == "plan" and .milestone != null and .milestone != 1
        then "계획의 milestone 은 1 이어야 합니다"
      elif ($kind == "review" or $kind == "message") and .verdict == "approve" and (.instruction | text | not)
        then "verdict \"approve\" 인데 다음 작업 지시(instruction)가 비어 있습니다"
      elif $kind == "review" and .verdict == "reject" and (.instruction | text | not)
        then "verdict \"reject\" 인데 보완 지시(instruction)가 비어 있습니다"
      else "" end
    end' "$f" 2>/dev/null) || why="JSON 으로 읽을 수 없습니다 (스키마에 맞는 JSON 객체 하나만 출력해야 합니다)"
  [ -z "$why" ] && return 0
  # 이유는 위의 고정 문구뿐이다 (verdict 는 enum 안인 것을 확인한 뒤에만 넣는다): 언제나 한 줄
  printf '%s\n' "$why"
  return 1
}

# cc_result_valid <file> [kind] : 0 = 상태에 반영할 수 있는 Codex 결과 (cc_result_problem 이 이유를 내지 않음)
cc_result_valid() { cc_result_problem "$1" "${2:-}" >/dev/null; }

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

# _cc_call_liveness <state-json> : 기록된 호출이 아직 돌 수 있는지 네 가지로 나눈다.
#   call·wait·check-orphan·cleanup-stale·discard·finish·preflight 가 모두 이 하나로 판단한다 (Task 8 addendum B).
#   _CC_LIVENESS = none      running 이 null (실행 중인 호출이 없다고 명시돼 있음)
#                | alive     기록된 감독 프로세스나 codex 중 하나라도 신원 확인상 살아 있음
#                | dead      둘 다 확실히 없고(R8 의 1: 없음·PID 재사용) 그 그룹도 확실히 비었음.
#                            감독 프로세스(그룹 리더) PID 를 신원이 다른 프로세스가 쓰고 있으면 그룹을 보지 않고 비었다고 본다:
#                            PID 는 같은 번호의 그룹이 있는 동안 재사용되지 않으므로 우리 그룹은 이미 끝났다 (그 번호의 그룹이
#                            지금 있다면 그 다른 프로세스의 것이다. 최종 리뷰 minor e)
#                | uncertain 그 밖: ps 실패, 기록 형식 오류, 또는 리더가 없는데 그룹이 비어 있지 않거나 판단 불가
#   _CC_LIVENESS_LEFTOVER = 1 : uncertain 중 "감독 프로세스·codex 는 확실히 없는데 그룹에 무언가 남아 있음"
#     (codex 의 자식, 기록 전에 실행된 codex 등. 우리 것인지 확인할 수 없으므로 죽이지 않는다: R8)
#   _CC_LIVENESS_PGID = 기록된 pgid (형식 확인 전 값)
#   그룹은 신호 0 으로 있는지만 본다 (아무것도 보내지 않음). $(...) 안에서 부르면 결과 변수가 사라진다.
#   running.stop_failed (종료를 확인하지 못해 끝 상태만 기록하고 남긴 기록, R30) 도 똑같이 나눈다.
_cc_call_liveness() {
  local st="$1" pg sid cp cid r1 r2=1 reused=0
  _CC_LIVENESS=uncertain; _CC_LIVENESS_LEFTOVER=0; _CC_LIVENESS_PGID=""
  if [ "$(_cc_jq_get "$st" '.running == null')" = "true" ]; then
    _CC_LIVENESS=none; return 0
  fi
  pg=$(_cc_jq_get "$st" '.running.pgid // empty | tostring')
  sid=$(_cc_jq_get "$st" '.running.supervisor_identity // empty')
  cp=$(_cc_jq_get "$st" '.running.codex_pid // empty | tostring')
  cid=$(_cc_jq_get "$st" '.running.codex_identity // empty')
  _CC_LIVENESS_PGID=$pg
  cc_proc_alive_detail "$pg" "$sid"; r1=$?
  [ "$r1" -eq 4 ] && { r1=1; reused=1; }
  if [ -n "$cp" ]; then
    cc_proc_alive_verified "$cp" "$cid"; r2=$?
  fi
  if [ "$r1" -eq 0 ] || [ "$r2" -eq 0 ]; then
    _CC_LIVENESS=alive; return 0
  fi
  if [ "$r1" -eq 1 ] && [ "$r2" -eq 1 ]; then
    # 리더 PID 를 다른 프로세스가 쓴다 = 우리 그룹은 이미 끝났다 (그룹 확인은 그 다른 프로세스의 그룹을 볼 뿐이다)
    if [ "$reused" = 1 ]; then
      _CC_LIVENESS=dead; return 0
    fi
    # r1 이 1 이면 pg 는 형식이 맞는 PID 다 (형식 오류는 2)
    _cc_proc_probe "-$pg"
    case $? in
      1) _CC_LIVENESS=dead ;;
      0) _CC_LIVENESS_LEFTOVER=1 ;;
    esac
  fi
  return 0
}

# _cc_call_is_running <state-json> : 0 = 실행 중으로 본다(alive 또는 uncertain) / 1 = 실행 중 아님(none 또는 dead)
#   기록된 감독 프로세스와 codex 가 둘 다 확실히 끝났어도 그룹에 무언가 남아 있으면 실행 중: 남은 것이 사는 동안
#   두 번째 Codex 를 띄우지 않는다. 거부는 안전하다. 이 확인되지 않은 근거로 무언가를 죽이지는 않는다.
_cc_call_is_running() {
  _cc_call_liveness "$1"
  case "$_CC_LIVENESS" in
    none|dead) return 1 ;;
  esac
  return 0
}

# running 기록이 온전한가: null 이거나, 양의 정수 pgid 와 "|" 를 가진 감독 프로세스 신원 문자열을 가진 객체.
# 아니면 실행 여부를 영원히 확인할 수 없는 깨진 기록이다 (discard·finish 만 이것을 근거로 지운다).
_CC_RUNNING_OK_FILTER='.running == null or ((.running | type) == "object" and ((.running.pgid | type) == "number") and (.running.pgid >= 1) and (.running.pgid == (.running.pgid | floor)) and ((.running.supervisor_identity | type) == "string") and (.running.supervisor_identity | contains("|")))'
_cc_running_wellformed() { [ "$(_cc_jq_get "$1" "$_CC_RUNNING_OK_FILTER")" = true ]; }

# _cc_call_refusal <kind> <state-json> : 거부해야 하면 한 줄 출력하고 6 (실행 중·호출 상한·연속 반려 상한),
#   이어 쓸 세션이 없으면 한 줄 출력하고 1 (오류, Ruling R14), 아니면 0
_cc_call_refusal() {
  local kind="$1" st="$2" total rejects pg
  if _cc_call_is_running "$st"; then
    if ! _cc_running_wellformed "$st"; then
      cc_line "[cc] 이전 호출 기록이 깨져 있어 Codex 실행 여부를 확인할 수 없습니다. discard 로 기록을 버린 뒤 다시 시작하세요."
      return 6
    fi
    if [ "$(_cc_jq_get "$st" '.running.stop_failed == true')" = true ]; then
      # 끝 상태는 기록됐지만 그 프로세스가 끝났는지 확인하지 못했다 (R30): 남은 것이 있는 동안 두 번째 Codex 를 띄우지 않는다.
      #   (형식 확인을 통과했으므로 pgid 는 양의 정수다)
      pg=$(_cc_jq_get "$st" '.running.pgid | tostring')
      cc_line "[cc] 이전 Codex 호출 $(_cc_jq_get "$st" '.running.call_id // "?"') 의 프로세스가 끝났는지 확인하지 못해 새로 호출하지 않았습니다 (프로세스 그룹 $pg. 확인: ps -o pid,command -g $pg)"
      return 6
    fi
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
  local kind="$1" a="$2" out="$3" st="$4" rt="$5" v ms mbase tbase ph
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
      ms=$(_cc_jq_get "$st" '.milestone // "?" | tostring')
      ph=$(_cc_jq_get "$st" '.phase // "?" | tostring')
      ( export CC_T_MESSAGE="$v" CC_T_MILESTONE="$ms" CC_T_PHASE="$ph"
        cc_render "$CC_PROMPT_DIR/pm-message.md" "$out" ) ;;
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
  # calls 나 그 번호 폴더가 심볼릭 링크면 active 밖을 지우거나 쓰게 되므로 거부한다 (최종 리뷰 minor g)
  if [ -L "$a/calls" ] || [ -L "$dir" ]; then
    cc_line "[cc] 호출 기록 폴더 경로가 비정상이라 Codex를 호출하지 않았습니다."
    return 1
  fi
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
  # 두 번째 인자(active 경로)는 쓰지 않지만 명령줄에 남긴다: state 를 읽을 수 없을 때 버리기·마무리가 이 작업의
  #   감독 프로세스를 명령줄로 찾는다 (codex 는 -o <active>/calls/<n>/result.json 으로 찾는다. R30)
  pgid=$(cc_spawn_group "$a/supervisor.log" bash "$CC_SELF_ABS" _supervise "$n" "$a") || {
    rm -rf "$dir"; cc_line "[cc] 감독 프로세스를 시작하지 못했습니다."; return 1; }
  # cc_spawn_group 은 exec 뒤에 돌아오므로 지금 신원이 최종 신원이다.
  # 신원을 못 얻으면 running 을 기록하지 않는다 → 감독 프로세스는 기록을 기다리다 codex 없이 끝난다.
  ident=$(cc_proc_identity "$pgid") || { cc_line "[cc] 감독 프로세스를 확인하지 못했습니다."; return 1; }
  now=$(cc_now_iso)
  # review_tree = 검수할 작업 트리 (review). done 뒤의 message 는 그때의 트리를 next_base_tree 로 둔다
  #   (추가 수정 요구 = 새 마일스톤의 기준. 감독 프로세스가 결과를 반영할 때 milestone_base_tree 로 쓴다)
  if ! cc_state_update '.calls_total = $n
      | .running = ({call_id: $n, kind: $kind, pgid: $pg, supervisor_identity: $ident,
                    codex_pid: null, codex_identity: null, started_at: $now,
                    review_tree: (if $kind == "review" and $rt != "" then $rt else null end)}
                    + (if $kind == "message" and $rt != "" and .phase == "done" then {next_base_tree: $rt} else {} end))
      | .phase = (if $kind == "review" then "reviewing" elif $kind == "plan" then "planning" else .phase end)' \
      --argjson n "$n" --arg kind "$kind" --argjson pg "$pgid" --arg ident "$ident" --arg now "$now" --arg rt "$rt"; then
    cc_kill_group_verified "$pgid" "$ident" >/dev/null 2>&1
    cc_line "[cc] 상태 파일을 쓰지 못해 Codex를 호출하지 않았습니다."
    return 1
  fi
  cc_line "[cc] Codex 호출 시작: $(_cc_call_label "$kind") (호출 $n/$CC_MAX_CALLS)"
}

# _cc_call_settle_dead_record <active> <state-json> : 확실히 끝난(dead) 이전 호출 기록에 실행 전 트리(running.pre_tree)가
#   있고 아직 다시 비교하지 않았으면, 새 호출로 덮어쓰기 전에 정리하며 다시 비교한다 (Codex 리뷰 1차 2·3. wait.sh 의
#   _cc_wait_settle → _cc_edit_recheck_prepare). 그 결과 Codex 가 프로젝트 파일을 바꿨거나 확인하지 못했으면 그 한 줄을
#   출력하고 6 (사용자가 알 때까지 새 호출을 하지 않는다. 기록은 정리됐으므로 다음 call 은 그대로 된다). 아니면 0.
_cc_call_settle_dead_record() {
  local a="$1" st="$2" id
  _cc_call_liveness "$st"
  [ "$_CC_LIVENESS" = dead ] || return 0
  id=$(_cc_jq_get "$st" 'if (.running | type) == "object" then (.running.call_id // empty | tostring) else empty end')
  case "$id" in ''|0*|*[!0-9]*|??????????*) return 0 ;; esac
  _CC_WAIT_ACTIVE=$a
  if ! _cc_edit_settle_dead "$id"; then
    # 최종 비교 결과를 기록하지 못했다: 이 기록(실행 전 트리)을 새 호출로 덮어쓰지 않는다 (Codex 리뷰 4차 1)
    cc_line "[cc] 끝난 이전 Codex 호출 $id 의 최종 비교 결과를 상태 파일에 기록하지 못해 새로 호출하지 않았습니다. 잠시 뒤 다시 시도하세요."
    return 1
  fi
  [ -n "$_CC_EDIT_NEW_LINE" ] || return 0
  cc_line "$_CC_EDIT_NEW_LINE"
  return 6
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
  # 끝난 이전 호출 기록을 덮어쓰기 전에 Codex 의 파일 수정을 다시 비교한다 (Codex 리뷰 1차 2·3)
  _cc_call_settle_dead_record "$a" "$st" || return $?
  st=$(_cc_call_read_state "$a") || { cc_line "[cc] 상태 파일을 읽을 수 없습니다."; return 1; }
  # 잠금 전에 한 번 거른다 (거부될 호출에 스냅샷을 만들지 않도록). 최종 판단은 잠금 안에서 다시 한다.
  _cc_call_refusal "$kind" "$st" || return $?
  case "$kind" in
    plan)    [ -s "$a/brief.md" ]   || { cc_line "[cc] 정리본(brief.md)이 없어 계획을 요청할 수 없습니다."; return 1; } ;;
    review)  [ -s "$a/report.md" ]  || { cc_line "[cc] 구현 보고(report.md)가 없어 검수를 요청할 수 없습니다."; return 1; } ;;
    message) [ -s "$a/message.md" ] || { cc_line "[cc] 전달할 메시지(message.md)가 없습니다."; return 1; } ;;
  esac
  # review: 검수할 작업 트리. done 뒤의 message(추가 수정 요구, 스펙 3-5 의 5): 새 마일스톤의 기준이 될 지금 트리
  if [ "$kind" = review ] || { [ "$kind" = message ] && [ "$(_cc_jq_get "$st" '.phase')" = done ]; }; then
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
#       _CC_SUP_STOP_FAILED(마지막 그룹 정리가 "남은 것 없음" 을 확인하지 못함 → running 을 stop_failed 로 남김, R30),
#       _CC_SUP_EDIT(이번 시도의 프로젝트 파일 수정 감시, R32: none 실행 안 함 / nopre 실행 전 스냅샷 실패라 실행 안 함 /
#         pending 실행함·아직 비교 안 함 / same 바뀐 것 없음 / modified 바뀜 / unknown 실행 뒤 스냅샷 실패),
#       _CC_SUP_PRE_TREE / _CC_SUP_POST_TREE (이번 시도의 실행 전후 작업 트리),
#       _CC_SUP_LC_PRE / _CC_SUP_LC_POST (last_call.pre_tree / post_tree 로 남길 값. 비어 있으면 남기지 않음),
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

# codex_pid / codex_identity 를 state 에 쓴다 (running 이 아직 이 호출이고 그 pgid 가 이 감독 프로세스일 때만:
#   최종 리뷰 minor d. 같은 호출 번호를 쓰는 다른 기록에는 쓰지 않는다). 0 = 썼거나 쓸 필요 없음
_cc_sup_set_codex_identity() {
  _CC_SUP_CODEX_IDENT="$2"
  cc_state_update 'if ((.running | type) == "object" and .running.call_id == $id and .running.pgid == $me)
                   then .running.codex_pid = $pid | .running.codex_identity = $ident else . end' \
    --argjson id "$_CC_SUP_ID" --argjson me "$$" --argjson pid "$1" --arg ident "$2" && return 0
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

# _cc_sup_stop_and_note [codex_pid] : _cc_sup_stop_group 을 부르고 그 결과를 _CC_SUP_STOP_FAILED 에 남긴다 (R30).
#   0(그룹에 남은 것 없음을 확인)이면 0, 그 밖(2 확인 못 함, 3 KILL 뒤에도 남음)이면 1. 마지막 정리 결과가 기준이다:
#   나중 정리가 0 이면 그룹 전체가 빈 것을 확인한 것이므로 앞의 실패도 풀린다. 마무리(_cc_sup_finish)가 이 값으로
#   running 을 지울지(0) 남길지(1) 정한다.
_cc_sup_stop_and_note() {
  _cc_sup_stop_group "$@"
  if [ $? -eq 0 ]; then
    _CC_SUP_STOP_FAILED=0
  else
    _CC_SUP_STOP_FAILED=1
    _cc_sup_log "그룹이 비었음을 확인하지 못함 → 끝 상태를 기록해도 running 기록은 남김"
  fi
}

# ---- 프로젝트 파일 수정 감시 (R31/R32) ----
# _cc_sup_edit_check : 이번 시도의 codex 가 끝나고 그룹을 정리한 뒤 작업 트리를 다시 떠서 실행 전(_CC_SUP_PRE_TREE)과 비교한다.
#   _CC_SUP_EDIT 이 pending(실행함, 아직 비교 안 함)이나 unknown(앞서 스냅샷 실패: 중단 신호로 git 이 끊긴 경우 등)일 때만
#   한다 → same | modified | unknown. 이미 정해졌으면(same·modified) 다시 하지 않는다. 아무것도 되돌리거나 지우지 않는다.
_cc_sup_edit_check() {
  local post
  case "${_CC_SUP_EDIT:-none}" in pending|unknown) ;; *) return 0 ;; esac
  post=$(cc_snapshot_tree) || post=""
  if [ -z "$post" ]; then
    _CC_SUP_EDIT=unknown; _CC_SUP_POST_TREE=""
    _cc_sup_log "실행 뒤 작업 트리 스냅샷 실패 → Codex 가 파일을 바꿨는지 확인할 수 없음"
    return 0
  fi
  _CC_SUP_POST_TREE=$post
  if [ "$post" = "$_CC_SUP_PRE_TREE" ]; then
    _CC_SUP_EDIT=same
  else
    _CC_SUP_EDIT=modified
    _cc_sup_log "Codex 실행 중에 작업 트리가 바뀜 ($_CC_SUP_PRE_TREE → $post). 되돌리지 않음"
  fi
}

# _cc_edit_modified_message <pre> <post> : codex_modified 의 한 줄. 바뀐 파일 최대 10개 (git diff --name-only pre post) 와 확인 명령.
#   경로는 core.quotePath=false 로 한글을 그대로 쓰되, 제어 문자·따옴표가 든 경로는 git 이 한 줄로 따옴표 처리한다.
#   하위 모듈 안의 변경은 하위 모듈 경로로 나온다 (snapshot.sh). Codex 실행 중에 사용자가 고친 파일도 잡히므로
#   "Codex 실행 중에 바뀐 파일" 이라고 쓴다. 감독 프로세스와, 끝 상태 없이 끝난 호출을 다시 비교하는 쪽(wait.sh)이 함께 쓴다.
_cc_edit_modified_message() {
  local pre="$1" post="$2" names total shown more=""
  names=$(git -c core.quotePath=false --no-pager diff --no-ext-diff --no-renames --name-only "$pre" "$post" -- 2>/dev/null \
          | grep -v '^$')
  total=$(printf '%s\n' "$names" | grep -c .)
  shown=$(printf '%s\n' "$names" | grep . | head -n 10 | awk 'NR > 1 { printf ", " } { printf "%s", $0 }')
  [ "${total:-0}" -gt 10 ] && more=" … (외 $((total - 10))개)"
  [ -n "$shown" ] || shown="(목록을 읽지 못함)"
  printf '[cc] Codex가 프로젝트 파일을 바꿨습니다(되돌리지 않음) — Codex 실행 중에 바뀐 파일: %s%s · 확인: git diff %s %s' \
    "$shown" "$more" "$pre" "$post"
}

# _cc_edit_uncheck_note <pre> : 실행 뒤 스냅샷을 뜨지 못했을 때 메시지에 붙이는 말 (확인할 수 없음. 실행 전 트리와 지금을 비교하는 명령)
#   wait.sh 의 _CC_WAIT_UNCHECK_MARK 가 이 문구의 앞부분을 찾는다
_cc_edit_uncheck_note() {
  printf '실행 뒤 작업 트리를 확인하지 못해 Codex가 프로젝트 파일을 바꿨는지 알 수 없습니다 (확인: git diff %s)' "$1"
}

# _cc_edit_pending_note : 종료를 확인하지 못해(R30) 파일 변경 비교를 끝내지 못했을 때 붙이는 말 (Codex 리뷰 1차 2).
#   그룹이 확실히 사라진 것을 확인하는 쪽(wait·check-orphan·preflight·call)이 running.pre_tree 로 다시 비교한다 (wait.sh)
_cc_edit_pending_note() {
  printf '프로젝트 파일 변경은 남은 Codex 프로세스가 끝난 뒤 다시 확인합니다'
}

# _cc_sup_record_pre <tree> : 이번 시도의 실행 전 트리를 codex 를 띄우기 전에 running.pre_tree 로 남긴다 (Codex 리뷰 1차 3).
#   감독 프로세스가 기록 없이 죽어도(중단 처리의 유예를 넘겨 KILL 등) wait·check-orphan 이 이것으로 비교한다.
#   running 이 아직 이 호출(call_id 와 pgid=$$)이고 stop_failed 가 아닐 때만 쓴다 (잠금 안에서 임시 파일 + mv). 못 쓰면 1
_cc_sup_record_pre() {
  cc_state_update 'if ((.running | type) == "object" and .running.call_id == $id and .running.pgid == $me
                       and .running.stop_failed != true)
                   then .running.pre_tree = $pre else error("not this call") end' \
    --argjson id "$_CC_SUP_ID" --argjson me "$$" --arg pre "$1"
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
      _cc_sup_stop_and_note "$pid"
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
#   실행 직전과 (그룹을 정리한) 뒤에 작업 트리를 떠서 비교한다 (R32): 결과는 _CC_SUP_EDIT (same | modified | unknown).
#   실행 전 스냅샷을 뜨지 못하면 codex 를 실행하지 않는다 (_CC_SUP_EDIT=nopre, _CC_SUP_NO_START=1)
_cc_sup_run_codex() {
  local mode="$1" session="$2" prompt="$3" x pid rc t_start events errf i=0
  local -a argv
  [ -n "${_CC_SUP_TIMEOUT:-}" ] || _cc_sup_init_config
  : "${_CC_SUP_ATTEMPT:=1}"
  _CC_SUP_NO_START=0
  _CC_SUP_EDIT=none; _CC_SUP_PRE_TREE=""; _CC_SUP_POST_TREE=""
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
  # 실행 전 작업 트리 (R32). 뜨지 못하면 Codex 가 파일을 바꾸는지 확인할 수 없으므로 실행하지 않는다 (재실행도 없음)
  _CC_SUP_PRE_TREE=$(cc_snapshot_tree) || _CC_SUP_PRE_TREE=""
  if [ -z "$_CC_SUP_PRE_TREE" ]; then
    _cc_sup_log "실행 전 작업 트리 스냅샷 실패 → codex 를 실행하지 않음"
    _CC_SUP_EDIT=nopre; _CC_SUP_NO_START=1; _CC_SUP_ATTEMPT_SECS=0
    return 125
  fi
  # 실행 전 트리를 codex 를 띄우기 전에 state(running.pre_tree)에 남긴다. 이 감독 프로세스가 기록 없이 죽어도
  #   wait·check-orphan 이 비교할 수 있도록 (Codex 리뷰 1차 3). 남기지 못하면 실행하지 않는다
  if ! _cc_sup_record_pre "$_CC_SUP_PRE_TREE"; then
    _cc_sup_log "실행 전 작업 트리를 state 에 기록하지 못함 → codex 를 실행하지 않음"
    _CC_SUP_EDIT=norecord; _CC_SUP_NO_START=1; _CC_SUP_ATTEMPT_SECS=0
    return 125
  fi
  _cc_sup_log "codex 실행 ($mode, 시도 $_CC_SUP_ATTEMPT)"
  t_start=$SECONDS
  _CC_SUP_T0=$t_start        # 시간 상한은 이 시도의 codex 시작부터 (Ruling R16)
  # 실행하기 전에 표시한다: 바로 뒤에 신호가 와도 마무리(_cc_sup_on_exit)가 실행 뒤 비교를 한다
  _CC_SUP_EDIT=pending
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
  [ "${_CC_SUP_TIMED_OUT:-0}" = 1 ] || _cc_sup_stop_and_note
  # 그룹을 정리한 뒤 실행 전 트리와 비교한다 (R32. 어떻게 끝났든: 정상·실패·시간 상한)
  _cc_sup_edit_check
  return "$rc"
}

# _cc_sup_next_attempt : 재시도 한 번을 호출 수에 더한다 (Ruling R3). 잠금 안에서 확인하고 더한다.
#   0 = calls_total 을 1 늘리고 _CC_SUP_ATTEMPT 를 다음 번호로 / 1 = 호출 상한이라 더하지 않음
#   2 = running 이 더 이상 이 호출(call_id 와 pgid=$$)이 아니거나 state 를 읽고 쓰지 못함
_cc_sup_next_attempt() {
  local r rc=2
  cc_state_lock || return 2
  r=$(jq -r --argjson id "$_CC_SUP_ID" --argjson me "$$" --argjson max "$_CC_SUP_MAX_CALLS" '
        if (.running | type) == "object" and .running.call_id == $id and .running.pgid == $me
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

# state 반영 필터. running 이 아직 이 호출(call_id 와 pgid = 이 감독 프로세스 $me)일 때만 바꾼다 (그 사이 wait 의
# 중단 처리 등으로 running 이 바뀌었거나, 같은 호출 번호를 쓰는 다른 감독 프로세스의 기록이면 덮어쓰지 않는다: 최종 리뷰
# minor d). 그래서 같은 호출을 두 번 반영해도 두 번째는 아무것도 바꾸지 않는다(토큰 중복 없음).
# $keep = 1 (그룹이 비었음을 확인하지 못함, R30): 끝 상태는 똑같이 기록하고 running 은 지우지 않고 stop_failed 로 표시한다.
#   이미 stop_failed 인 기록(끝 상태가 기록됨)은 다시 바꾸지 않는다.
# $pre / $post 가 비어 있지 않으면 last_call.pre_tree / post_tree 로 남긴다 (R32: codex_modified, 실행 뒤 확인 불가).
#   codex_modified 는 ok 가 아니므로 result 를 반영하지 않고 phase=failed 다.
# Ruling R27: 마일스톤을 승인·반려하는 것은 review 호출의 결과뿐이다. message 호출(사용자 말·Claude 반대 의견 전달)은
# diff 를 검수하지 않으므로 그 결과는 "이어가기" 다:
#   - approve: 마일스톤 번호·milestone_base_tree·rejects_in_row 를 그대로 둔다 (Codex 가 다른 번호를 말해도 지금
#     마일스톤을 유지하고 다음 review 가 정한다). 아직 마일스톤이 없을 때(계획 호출이 세션만 남기고 실패)만 Codex 번호를 쓴다.
#   - reject: 연속 반려로 세지 않는다.
#   - done: 작업 완료가 아니다 (검수하지 않았다) → phase working (최종 리뷰 minor b. SKILL 은 이어가기로 다룬다).
#   - plan 이 함께 오면 milestones_total 만 갱신. plan·ask_user verdict 는 review 와 같다.
# done 뒤의 message (running.next_base_tree 있음 = 추가 수정 요구, 스펙 3-5 의 5, 최종 리뷰 minor c): plan 이 아닌 모든 verdict 는
#   새 마일스톤을 연다. milestone = Codex 가 준 번호가 지금보다 크면 그 번호, 아니면 지금 + 1. milestone_base_tree =
#   메시지 호출 때의 작업 트리 (다음 검수가 새 작업만 diff 하도록), rejects_in_row = 0, milestones_total 은 모자라면 늘린다.
#   ask_user 면 phase asking (질문에 답한 뒤에도 같은 새 마일스톤·기준), 그 밖에는 working.
_CC_SUP_FINISH_FILTER='
def after_done($r):
  (.milestone // 0) as $cur
  | .milestone = (if ($r.milestone | type) == "number" and $r.milestone > $cur then $r.milestone else $cur + 1 end)
  | .milestone_base_tree = .running.next_base_tree
  | .rejects_in_row = 0
  | (if $r.plan != null then .milestones_total = ($r.plan.milestones | length) else . end)
  | (if (.milestones_total | type) == "number" and .milestones_total >= .milestone then . else .milestones_total = .milestone end)
  | .phase = (if $r.verdict == "ask_user" then "asking" else "working" end);
def apply_verdict($r; $kind):
  if $r.verdict == "plan" then
    .milestone = 1 | .milestones_total = ($r.plan.milestones | length)
    | .milestone_base_tree = .task_base_tree | .phase = "working"
  elif $kind == "message" and (.running.next_base_tree | type) == "string" then after_done($r)
  elif $r.verdict == "approve" and $kind == "message" then
    .milestone = (.milestone // $r.milestone) | .phase = "working"
    | (if $r.plan != null then .milestones_total = ($r.plan.milestones | length) else . end)
  elif $r.verdict == "approve" then
    .milestone = $r.milestone
    | .milestone_base_tree = (.running.review_tree // .milestone_base_tree)
    | .rejects_in_row = 0 | .phase = "working"
    | (if $r.plan != null then .milestones_total = ($r.plan.milestones | length) else . end)
  elif $r.verdict == "reject" then
    (if $kind == "message" then . else .rejects_in_row = ((.rejects_in_row // 0) + 1) end) | .phase = "working"
    | (if $r.plan != null then .milestones_total = ($r.plan.milestones | length) else . end)
  elif $r.verdict == "done" then .phase = (if $kind == "message" then "working" else "done" end)
  else .phase = "asking" end;
if ((.running | type) == "object" and .running.call_id == $id and .running.pgid == $me
    and .running.stop_failed != true) then
    .tokens = {input: ((.tokens.input // 0) + $ti), cached_input: ((.tokens.cached_input // 0) + $tc),
               output: ((.tokens.output // 0) + $to)}
    | (if $sid != "" then .session_id = $sid else . end)
    | (if $st == "ok" then apply_verdict($r[0]; (.running.kind // ""))
       elif $st == "interrupted" then .phase = "interrupted"
       else .phase = "failed" end)
    | .last_call = ({call_id: $id, kind: .running.kind, status: $st,
                     verdict: (if $st == "ok" then $r[0].verdict else null end),
                     message: (if $msg == "" then null else $msg end)}
                    + (if $pre != "" then {pre_tree: $pre} else {} end)
                    + (if $post != "" then {post_tree: $post} else {} end))
    | (if $keep == 1 then .running.stop_failed = true else .running = null end)
  else . end'

# _cc_sup_record_result <st> <msg> <sid> <ti> <tc> <to> <keep 0|1> <jq 인자...> : 잠금 안에서 결과를 반영하고, 반영한 뒤
#   state 가 이 호출을 어떻게 기록하고 있는지 그 자리에서 읽는다 (addendum A: status 파일은 state 와 같아야 한다).
#   _CC_SUP_REC = 이 호출의 최종 status
#     - running 이 이 호출이 아니고 last_call 이 이 호출이면 → last_call.status (이 반영이든, 먼저 기록한 다른 쪽이든)
#     - running 이 이 호출의 stop_failed 기록이고 last_call 이 이 호출이면 → last_call.status (R30)
#     - state 가 이 호출을 더 이상 추적하지 않거나, running 이 같은 번호의 다른 감독 프로세스 기록이면 → <st>
#   반환 1 = 잠금을 못 잡았거나 반영하지 못해 running 이 아직 끝 상태 없는 이 호출(call_id·pgid 모두) (다시 시도할 것)
_cc_sup_record_result() {
  local st="$1" msg="$2" sid="$3" ti="$4" tc="$5" to="$6" keep="$7" r
  shift 7
  _CC_SUP_REC=""
  cc_state_lock || return 1
  _cc_state_update_nolock "$_CC_SUP_FINISH_FILTER" --argjson id "$_CC_SUP_ID" --argjson me "$$" --arg st "$st" --arg msg "$msg" \
    --arg sid "$sid" --argjson ti "${ti:-0}" --argjson tc "${tc:-0}" --argjson to "${to:-0}" --argjson keep "${keep:-0}" "$@" \
    || _cc_sup_log "state 반영 실패"
  r=$(jq -r --argjson id "$_CC_SUP_ID" --argjson me "$$" '
        def mine: (.running | type) == "object" and .running.call_id == $id and .running.pgid == $me;
        def last_ok: (.last_call | type) == "object" and .last_call.call_id == $id
          and (.last_call.status | type) == "string" and (.last_call.status | test("^[a-z_]+$"));
        if mine and .running.stop_failed != true then "@running"
        elif mine and last_ok then .last_call.status
        elif (.running | type) == "object" and .running.call_id == $id then "@other"
        elif last_ok then .last_call.status
        else "@other" end' "$_CC_SUP_ACTIVE/state.json" 2>/dev/null)
  cc_state_unlock
  case "$r" in
    ''|@running) return 1 ;;
    @other) _CC_SUP_REC=$st ;;
    *) _CC_SUP_REC=$r ;;
  esac
  return 0
}

# _cc_sup_finish <ok|error|invalid_json|timeout|interrupted|codex_modified> <message> : 세션·토큰·verdict 를 state 에 반영하고
# running=null, last_call 을 기록한 뒤 마지막으로 status 파일을 쓴다.
# (wait 는 status 파일을 보고 state·result 를 읽으므로 state 가 먼저다.)
#   - 시작하자마자 TERM/INT/HUP 을 무시한다. 마무리 도중 신호가 더 와도 끝까지 기록한다 (addendum A).
#   - status 파일에는 state 가 이 호출에 기록한 값을 쓴다 (다른 쪽이 먼저 기록했으면 그 값).
#   - 다시 불리면(_CC_SUP_FINAL 있음) 이미 정한 값을 그대로 쓴다.
#   - 마지막 그룹 정리가 "남은 것 없음" 을 확인하지 못했으면(_CC_SUP_STOP_FAILED=1, R30) running 을 지우지 않고
#     stop_failed 로 남기고, 메시지 끝에 프로세스가 남았을 수 있다는 안내(그룹·확인 명령)를 붙인다 (한 줄).
_cc_sup_finish() {
  local st="$1" msg="$2" sid ti tc to i keep=0 note
  local -a rarg
  trap '' TERM INT HUP
  if [ -n "${_CC_SUP_FINAL:-}" ]; then
    _cc_sup_write_status "$_CC_SUP_FINAL"
    _CC_SUP_DONE=1
    return 0
  fi
  if [ "${_CC_SUP_STOP_FAILED:-0}" = 1 ]; then
    keep=1
    # 그룹이 비었음을 확인하지 못했으면 결과를 반영하지 않는다 (Codex 리뷰 1차 2. _cc_sup_main 이 먼저 거르지만 한 번 더)
    if [ "$st" = ok ]; then
      st=error; msg="[cc] Codex 프로세스가 모두 끝났는지 확인하지 못해 결과를 반영하지 않았습니다"
    fi
    # 파일 변경 비교를 끝내지 못했다 (codex 를 실행했으면, 이미 바뀐 것을 찾았어도: 남은 프로세스가 더 바꿀 수 있다.
    #   Codex 리뷰 2차): 남은 프로세스가 끝난 뒤 다시 확인한다고 적는다 (그때 최종 목록으로 고쳐진다, wait.sh recheck)
    case "${_CC_SUP_EDIT:-none}" in
      same|unknown|pending|modified) msg="${msg:-[cc] Codex 호출은 끝났지만 결과를 반영하지 않았습니다} · $(_cc_edit_pending_note)" ;;
    esac
    note="일부 Codex 프로세스가 끝났는지 확인하지 못했습니다 (프로세스 그룹 $$. 확인: ps -o pid,command -g $$)"
    if [ -n "$msg" ]; then msg="$msg · $note"; else msg="[cc] Codex 호출은 끝났지만 $note"; fi
  fi
  sid=$(_cc_sup_session_all)
  read -r ti tc to <<EOF
$(_cc_sup_tokens_all)
EOF
  if [ "$st" = ok ]; then rarg=(--slurpfile r "$_CC_SUP_DIR/result.json"); else rarg=(--argjson r '[]'); fi
  # last_call.pre_tree / post_tree (R32: codex_modified·확인 불가일 때만 값이 있다)
  rarg[${#rarg[@]}]=--arg; rarg[${#rarg[@]}]=pre; rarg[${#rarg[@]}]="${_CC_SUP_LC_PRE:-}"
  rarg[${#rarg[@]}]=--arg; rarg[${#rarg[@]}]=post; rarg[${#rarg[@]}]="${_CC_SUP_LC_POST:-}"
  _CC_SUP_REC=""
  for i in 1 2 3; do
    _cc_sup_record_result "$st" "$msg" "$sid" "$ti" "$tc" "$to" "$keep" "${rarg[@]}" && break
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
# running=null(그룹이 빈 것을 확인했을 때만. 아니면 stop_failed 로 남김, R30) / last_call / status 를 기록한다.
# 이 동안 TERM/INT/HUP 은 무시한다.
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
  # 중단 신호여도 시간 상한 때와 같이 TERM 뒤 최대 3초를 준다: codex 가 따로 띄운 MCP 도우미를 스스로 정리할 시간이다
  # (최종 리뷰 minor f). 멤버 TERM 3초 + KILL 최대 2초 + 실행 뒤 스냅샷 + 기록이 기다리는 쪽(wait·check-orphan --kill)의
  # 감독 프로세스 유예 10초(_CC_WAIT_SUP_GRACE_TENTHS) 안에 끝나므로 마무리 도중 KILL 되지 않는다 (Task 7 addendum A)
  _cc_sup_stop_and_note "$_CC_SUP_CODEX_PID"
  # 이번 시도에서 codex 를 실행했으면 중단·오류로 끝나도 실행 전 트리와 비교한다 (R32).
  #   바뀌었으면 codex_modified 가 우선한다. 확인하지 못했으면 끝난 원인과 상관없이 error(phase failed, verdict null)로
  #   기록하고 원인과 확인 실패를 함께 적는다 (Codex 리뷰 1차 4). 어느 쪽이든 result 는 반영하지 않는다
  _cc_sup_edit_check
  case "${_CC_SUP_EDIT:-none}" in
    modified)
      st=codex_modified; msg=$(_cc_edit_modified_message "$_CC_SUP_PRE_TREE" "$_CC_SUP_POST_TREE")
      _CC_SUP_LC_PRE=$_CC_SUP_PRE_TREE; _CC_SUP_LC_POST=$_CC_SUP_POST_TREE ;;
    unknown)
      st=error; msg="$msg · $(_cc_edit_uncheck_note "$_CC_SUP_PRE_TREE")"; _CC_SUP_LC_PRE=$_CC_SUP_PRE_TREE ;;
  esac
  _cc_sup_finish "$st" "$msg"
}

_cc_sup_main() {
  local kind session mode root rc prompt known s tail why="" fast_used=0 fmt_used=0
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
    #   실행 전 작업 트리를 뜨지 못한 경우도 같다: Codex 가 파일을 바꾸는지 확인할 수 없으므로 실행하지 않았다 (R32)
    if [ "${_CC_SUP_NO_START:-0}" = 1 ]; then
      case "$_CC_SUP_EDIT" in
        nopre)
          _cc_sup_finish error "[cc] 작업 트리 스냅샷을 만들지 못해 Codex를 실행하지 않았습니다 (Codex가 프로젝트 파일을 바꾸는지 확인할 수 없음)." ;;
        norecord)
          _cc_sup_finish error "[cc] 실행 전 작업 트리를 상태 파일에 기록하지 못해 Codex를 실행하지 않았습니다 (중단돼도 Codex의 파일 수정을 확인할 수 있어야 함)." ;;
        *)
          _cc_sup_finish error "[cc] Codex 실행 인자를 만들지 못해 Codex를 실행하지 않았습니다 (세션 ID 형식 확인 필요)." ;;
      esac
      return 0
    fi
    # Codex 가 프로젝트 파일을 바꿨으면(R32) 어떻게 끝났든(시간 상한 포함) codex_modified 로 끝낸다:
    #   재시도·형식 재요청 없음, result 반영 없음, 아무것도 되돌리지 않음.
    #   실행 뒤 작업 트리를 뜨지 못했으면 확인할 수 없으므로 result 를 반영하지 않고 error 로 끝낸다.
    case "$_CC_SUP_EDIT" in
      modified)
        _CC_SUP_LC_PRE=$_CC_SUP_PRE_TREE; _CC_SUP_LC_POST=$_CC_SUP_POST_TREE
        _cc_sup_finish codex_modified "$(_cc_edit_modified_message "$_CC_SUP_PRE_TREE" "$_CC_SUP_POST_TREE")"; return 0 ;;
      same) ;;
      *)
        _CC_SUP_LC_PRE=$_CC_SUP_PRE_TREE
        if [ "$_CC_SUP_TIMED_OUT" = 1 ]; then
          _cc_sup_finish error "$(_cc_sup_timeout_message) · $(_cc_edit_uncheck_note "$_CC_SUP_PRE_TREE")"
        else
          _cc_sup_finish error "[cc] Codex 결과를 반영하지 않았습니다: $(_cc_edit_uncheck_note "$_CC_SUP_PRE_TREE")"
        fi
        return 0 ;;
    esac
    # 그룹이 비었음을 확인하지 못했으면(R30) 지금 "바뀐 것 없음" 이어도 안전하다고 보지 않는다 (Codex 리뷰 1차 2):
    #   남은 프로세스가 나중에 파일을 쓸 수 있다. 결과를 반영하지 않고(정상 응답이어도 error) 재실행·형식 재요청도 하지 않는다.
    #   running 은 stop_failed 로 남고(_cc_sup_finish), 그룹이 확실히 사라지면 저장된 pre_tree 로 다시 비교한다 (wait.sh)
    if [ "${_CC_SUP_STOP_FAILED:-0}" = 1 ]; then
      if [ "$_CC_SUP_TIMED_OUT" = 1 ]; then
        _cc_sup_finish timeout "$(_cc_sup_timeout_message)"
      else
        _cc_sup_finish error "[cc] Codex 프로세스가 모두 끝났는지 확인하지 못해 결과를 반영하지 않았고 다시 시도하지도 않았습니다 (종료 코드 $rc)"
      fi
      return 0
    fi
    # 시간 상한: 빠른 실패 구간 안이어도 timeout, 재시도 없음 (Ruling R6)
    if [ "$_CC_SUP_TIMED_OUT" = 1 ]; then
      _cc_sup_finish timeout "$(_cc_sup_timeout_message)"; return 0
    fi
    # 호출 종류에 맞고 절차가 쓸 수 있는 결과만 받는다 (Codex 리뷰 4). 아니면 why = 이유 한 줄
    if why=$(cc_result_problem "$_CC_SUP_DIR/result.json" "$kind"); then
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
    # 정상 종료했지만 쓸 수 있는 결과가 아님: 세션을 알면 형식 재요청 1회. 무엇이 틀렸는지(why)를 함께 보내
    #   형식만이 아니라 빠진 내용(지시·질문)이나 호출에 맞지 않는 verdict 도 고치게 한다 (Codex 리뷰 4)
    if [ "$fmt_used" = 0 ] && [ -n "$known" ]; then
      fmt_used=1
      if ! ( export CC_T_REASON="$why"; cc_render "$CC_PROMPT_DIR/pm-format-retry.md" "$_CC_SUP_DIR/prompt-format-retry.md" ); then
        _cc_sup_finish invalid_json "[cc] Codex 응답이 요구한 형식에 맞지 않고($why), 형식 재요청 프롬프트를 만들지 못했습니다."
        return 0
      fi
      _cc_sup_next_attempt
      case $? in
        0) mode=resume; session=$known; prompt="$_CC_SUP_DIR/prompt-format-retry.md"
           _cc_sup_log "쓸 수 없는 응답($why) → 같은 세션에 형식 재요청 1회"; continue ;;
        1) _cc_sup_finish invalid_json "[cc] Codex 응답이 요구한 형식에 맞지 않고($why), 호출 상한 ${_CC_SUP_MAX_CALLS}회에 도달해 형식 재요청을 하지 않았습니다."
           return 0 ;;
      esac
      _cc_sup_finish invalid_json "[cc] Codex 응답이 요구한 형식에 맞지 않습니다($why)."; return 0
    fi
    if [ "$fmt_used" = 1 ]; then
      _cc_sup_finish invalid_json "[cc] Codex 응답이 형식 재요청 뒤에도 요구한 형식에 맞지 않습니다($why)."
    else
      _cc_sup_finish invalid_json "[cc] Codex 응답이 요구한 형식에 맞지 않고($why), 이어 쓸 세션을 알 수 없어 형식 재요청을 하지 않았습니다."
    fi
    return 0
  done
}

# cc-codex.sh _supervise <call_id> [active]  (내부용. call 이 cc_spawn_group 으로 띄운다. 출력은 supervisor.log 로만)
#   active 경로 인자는 명령줄에 이 작업을 표시할 뿐 쓰지 않는다 (active 는 늘 cc_active_dir 로 정한다)
cc_cmd_supervise() {
  _CC_SUP_ID="${1:-}"
  _CC_SUP_DONE=0; _CC_SUP_CLAIMED=0; _CC_SUP_SIGNAL=""; _CC_SUP_CODEX_PID=""; _CC_SUP_CODEX_IDENT=""; _CC_SUP_FINAL=""
  _CC_SUP_CODEX_RECORDED=0; _CC_SUP_ATTEMPT=1; _CC_SUP_ATTEMPT_SECS=0; _CC_SUP_T0=""; _CC_SUP_TIMED_OUT=0; _CC_SUP_REC=""
  _CC_SUP_NO_START=0; _CC_SUP_STOP_FAILED=0
  _CC_SUP_EDIT=none; _CC_SUP_PRE_TREE=""; _CC_SUP_POST_TREE=""; _CC_SUP_LC_PRE=""; _CC_SUP_LC_POST=""
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
