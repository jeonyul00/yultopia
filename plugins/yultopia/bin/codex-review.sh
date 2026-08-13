#!/usr/bin/env bash
# codex-review.sh — Yultopia Claude–Codex 협업 모드 (세션별 활성화)
#
# 훅 모드
#   start          : UserPromptSubmit. 협업 모드가 켜진 세션에서만 시작 지문 기록
#   stop           : Stop. 변경이 있을 때만 Codex 호출
#
# 세션 제어 (스킬이 호출)
#   session-enable  <session_id> <cwd>
#   session-disable <session_id>
#   session-status  <session_id>
#
# 조회 / 전역 비상정지
#   show-last [cwd] | status | enable | disable | uninstall
#
# 불변 규칙
#   - Stop 알림에 hookSpecificOutput.additionalContext 를 절대 쓰지 않는다.
#     (Stop 에서 그 필드는 "턴을 계속하라"는 뜻이라 무한 반복을 일으킨다)
#   - 턴을 이어가는 유일한 경로는 decision:block 이며, 저장된 라운드 카운터가
#     있을 때만 진입한다. 카운터가 없으면 절대 이어가지 않는다.
#   - 대상 저장소의 파일은 어떤 경우에도 수정하지 않는다.

set -uo pipefail

MODE="${1:-}"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
STATE_DIR="${CODEX_REVIEW_STATE_DIR:-$CLAUDE_HOME/codex-review-state}"
SCHEMA="${CODEX_REVIEW_SCHEMA:-$SELF_DIR/codex-review.schema.json}"
CODEX_BIN="${CODEX_REVIEW_CODEX_BIN:-codex}"
TIMEOUT="${CODEX_REVIEW_TIMEOUT:-300}"
MAX_ROUNDS="${CODEX_REVIEW_MAX_ROUNDS:-2}"
TTL_HOURS="${CODEX_REVIEW_TTL_HOURS:-24}"
SESSION_TTL_HOURS="${CODEX_REVIEW_SESSION_TTL_HOURS:-168}"   # 7일. 사용 때마다 갱신됨
KILL_FILE="${CODEX_REVIEW_KILL_FILE:-$CLAUDE_HOME/codex-review.off}"
MAX_FINDINGS="${CODEX_REVIEW_MAX_FINDINGS:-20}"
MAX_STRLEN="${CODEX_REVIEW_MAX_STRLEN:-600}"

SESS_DIR="$STATE_DIR/sessions"
TURN_DIR="$STATE_DIR/turns"
RAW_DIR="$STATE_DIR/raw"
mkdir -p "$SESS_DIR" "$TURN_DIR" "$RAW_DIR" 2>/dev/null

# macOS 는 shasum, 대부분의 리눅스는 sha256sum 이다. 둘 다 지원한다.
if command -v shasum >/dev/null 2>&1; then
  sha() { shasum -a 256 2>/dev/null | cut -d' ' -f1; }
elif command -v sha256sum >/dev/null 2>&1; then
  sha() { sha256sum 2>/dev/null | cut -d' ' -f1; }
else
  echo "codex-review: shasum 또는 sha256sum 이 필요합니다." >&2
  exit 1
fi
key() { printf '%s' "$1" | sha | cut -c1-32; }

# ---- 훅 출력 ------------------------------------------------------------
# 조용히 끝냄 (아무 것도 표시하지 않음)
quiet_exit() { exit 0; }

# 사용자 화면에만 표시하고 턴을 끝냄. 절대 턴을 이어가지 않는다.
show_exit() { jq -nc --arg m "$1" '{systemMessage:$m}'; exit 0; }

# 턴을 이어가는 유일한 경로. 사용자 화면 메시지는 내지 않는다
# (중간 상태는 표시하지 않고, 최종 결과만 표시한다).
block_stop() { jq -nc --arg r "$1" '{decision:"block",reason:$r}'; exit 0; }

# ---- 공통 ---------------------------------------------------------------
canon() { ( cd "$1" 2>/dev/null && pwd -P ) || printf '%s' "$1"; }

is_forbidden_root() {
  [ -z "${1:-}" ] && return 0
  local r h; r="$(canon "$1")"; h="$(canon "$HOME")"
  case "$r" in "/"|"$h") return 0 ;; esac
  return 1
}

kill_switch_on() {
  [ -f "$KILL_FILE" ] && return 0
  [ "${CODEX_REVIEW_DISABLED:-0}" = "1" ] && return 0
  return 1
}

sess_file() { printf '%s/%s.on' "$SESS_DIR" "$(key "$1")"; }
turn_file() { printf '%s/%s/%s.json' "$TURN_DIR" "$(key "$1")" "$(key "$2")"; }

# 켜져 있으면 표식 mtime 을 갱신해 장수 세션이 TTL 로 꺼지지 않게 한다
session_on() {
  local f; f="$(sess_file "$1")"
  [ -f "$f" ] || return 1
  touch "$f" 2>/dev/null
  return 0
}

atomic_write() {
  local dest="$1" tmp; mkdir -p "$(dirname "$dest")" 2>/dev/null
  tmp="$(mktemp "${dest}.XXXXXX")" || return 1
  cat > "$tmp" && mv -f "$tmp" "$dest"
}

ttl_sweep() {
  find "$RAW_DIR"  -maxdepth 1 -type f -mmin "+$((TTL_HOURS * 60))" -delete 2>/dev/null
  find "$TURN_DIR" -mindepth 2 -type f -mmin "+$((TTL_HOURS * 60))" -delete 2>/dev/null
  find "$SESS_DIR" -maxdepth 1 -type f -mmin "+$((SESSION_TTL_HOURS * 60))" -delete 2>/dev/null
  find "$TURN_DIR" -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null
}

run_with_timeout() {
  local secs="$1"; shift
  "$@" & local cpid=$!
  ( sleep "$secs"; kill -TERM "$cpid" 2>/dev/null ) & local wpid=$!
  wait "$cpid"; local rc=$?
  kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
  return $rc
}

# ---- 저장소 지문 --------------------------------------------------------
untracked_fp() {
  local root="$1"
  git -C "$root" ls-files --others --exclude-standard -z 2>/dev/null \
  | LC_ALL=C sort -z \
  | while IFS= read -r -d '' f; do
      printf '%s ' "$f"
      git -C "$root" hash-object -- "$f" 2>/dev/null || printf 'UNREADABLE\n'
    done | sha
}

emit_fingerprint() {
  local root="$1" head staged unstaged untracked
  head="$(git -C "$root" rev-parse HEAD 2>/dev/null || echo NOHEAD)"
  staged="$(git -C "$root" diff --cached 2>/dev/null | sha)"
  unstaged="$(git -C "$root" diff 2>/dev/null | sha)"
  untracked="$(untracked_fp "$root")"
  jq -nc --arg root "$root" --arg head "$head" --arg staged "$staged" \
         --arg unstaged "$unstaged" --arg untracked "$untracked" \
    '{root:$root,head:$head,staged:$staged,unstaged:$unstaged,untracked:$untracked}'
}

# ===================== 세션 제어 =========================================
case "$MODE" in
  session-enable)
    sid="${2:-}"; cwd="${3:-$PWD}"
    [ -n "$sid" ] || { echo "세션을 식별할 수 없습니다. Claude Code 안에서 실행해 주세요."; exit 1; }
    if kill_switch_on; then
      echo "Yultopia 협업 모드를 켤 수 없습니다 — 전역 비상정지가 켜져 있습니다."
      echo "해제하려면: ~/.claude/codex-review.sh enable"
      exit 1
    fi
    root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)"
    if [ -z "$root" ]; then
      echo "Yultopia 협업 모드를 켤 수 없습니다 — 여기는 Git 프로젝트 폴더가 아닙니다."
      echo "프로젝트 폴더로 이동해서 Claude를 실행한 뒤 다시 시도해 주세요."
      exit 1
    fi
    if is_forbidden_root "$root"; then
      echo "Yultopia 협업 모드를 켤 수 없습니다 — 홈 폴더 전체는 검수 대상이 될 수 없습니다."
      echo "실제 프로젝트 폴더에서 Claude를 실행한 뒤 다시 시도해 주세요."
      exit 1
    fi
    ttl_sweep
    jq -nc --arg root "$root" --arg ts "$(date '+%Y-%m-%d %H:%M:%S')" \
      '{root:$root,ts:$ts}' | atomic_write "$(sess_file "$sid")"
    echo "Yultopia 협업 모드: 켜짐 — 다음 요청부터 Codex 자동 검수가 적용됩니다."
    exit 0 ;;

  session-disable)
    sid="${2:-}"
    [ -n "$sid" ] || { echo "세션을 식별할 수 없습니다."; exit 1; }
    rm -f "$(sess_file "$sid")" 2>/dev/null
    # 진행 중인 검수 반복도 즉시 중단 (이 세션의 라운드 상태 제거)
    rm -rf "$TURN_DIR/$(key "$sid")" 2>/dev/null
    echo "Yultopia 협업 모드: 꺼짐 — 이제 Claude만 응답합니다."
    exit 0 ;;

  session-status)
    sid="${2:-}"
    if [ -n "$sid" ] && [ -f "$(sess_file "$sid")" ]; then
      echo "Yultopia 협업 모드: 켜짐"
    else
      echo "Yultopia 협업 모드: 꺼짐"
    fi
    exit 0 ;;
esac

# ===================== 조회 / 전역 비상정지 ==============================
case "$MODE" in
  enable)  rm -f "$KILL_FILE"; echo "전역 비상정지: 해제됨"; exit 0 ;;
  disable) mkdir -p "$(dirname "$KILL_FILE")"; touch "$KILL_FILE"
           echo "전역 비상정지: 켜짐 — 모든 세션에서 Codex 검수가 즉시 중단됩니다."; exit 0 ;;
  status)
    if kill_switch_on; then echo "전역 비상정지: 켜짐 (모든 검수 중단)"; else echo "전역 비상정지: 꺼짐 (정상)"; fi
    n=$(find "$SESS_DIR" -name '*.on' 2>/dev/null | wc -l | tr -d ' ')
    echo "협업 모드가 켜진 세션: ${n}개"
    r=$(find "$RAW_DIR" -name '*.raw' 2>/dev/null | wc -l | tr -d ' ')
    echo "보관 중인 검수 원문: ${r}건 (${TTL_HOURS}시간 보관)"
    exit 0 ;;
  show-last)
    root="$(git -C "${2:-$PWD}" rev-parse --show-toplevel 2>/dev/null)"
    f=""
    [ -n "$root" ] && [ -f "$RAW_DIR/$(key "$root").raw" ] && f="$RAW_DIR/$(key "$root").raw"
    [ -n "$f" ] || f="$(ls -t "$RAW_DIR"/*.raw 2>/dev/null | head -1)"
    if [ -z "$f" ] || [ ! -f "$f" ]; then
      echo "보관된 Codex 검수 원문이 없습니다. (${TTL_HOURS}시간이 지나 만료됐거나, 아직 검수가 실행된 적이 없습니다.)"
      exit 0
    fi
    m="${f%.raw}.meta.json"
    if [ -f "$m" ]; then
      echo "=== Codex 검수 원문 (가공 없음) ==="
      jq -r '"프로젝트: \(.root)\n시각: \(.ts)\n상태: \(.status)"' "$m" 2>/dev/null
      echo "==================================="
    fi
    cat "$f"
    exit 0 ;;
  uninstall)
    # 플러그인 본체 + 상태 제거. 예전 방식(~/.claude 직접 설치)으로 깔린 흔적도 함께 정리한다.
    S="$CLAUDE_HOME/settings.json"
    if [ -f "$S" ] && grep -q "codex-review" "$S" 2>/dev/null; then
      cp "$S" "$S.bak.$(date +%Y%m%d%H%M%S)"
      tmp="$(mktemp)"
      jq '
        def clean(ev):
          if (.hooks[ev]? | type) == "array" then
            .hooks[ev] = ([ .hooks[ev][]
              | .hooks = [ .hooks[]? | select((.command // "") | test("codex-review\\.sh") | not) ]
              | select((.hooks | length) > 0) ])
            | (if (.hooks[ev] | length) == 0 then .hooks |= del(.[ev]) else . end)
          else . end;
        if (.hooks? | type) == "object"
          then clean("UserPromptSubmit") | clean("Stop")
               | (if (.hooks | length) == 0 then del(.hooks) else . end)
          else . end' "$S" > "$tmp" && mv -f "$tmp" "$S"
      echo "settings.json 에서 예전 방식 훅을 제거했습니다 (백업 생성)."
    fi
    C="$CLAUDE_HOME/CLAUDE.md"
    if [ -f "$C" ] && grep -q "BEGIN codex-review" "$C"; then
      cp "$C" "$C.bak.$(date +%Y%m%d%H%M%S)"
      tmp="$(mktemp)"
      sed '/<!-- BEGIN codex-review/,/<!-- END codex-review/d' "$C" > "$tmp" && mv -f "$tmp" "$C"
      echo "CLAUDE.md 에서 예전 방식 구간을 제거했습니다 (백업 생성)."
    fi
    rm -rf "$STATE_DIR"; rm -f "$KILL_FILE"
    # 예전 방식으로 깔린 개별 스킬/스크립트
    rm -rf "$CLAUDE_HOME/skills/yultopia-collab-on" \
           "$CLAUDE_HOME/skills/yultopia-collab-off" \
           "$CLAUDE_HOME/skills/yultopia-collab-status"
    rm -f "$CLAUDE_HOME/codex-review.sh" "$CLAUDE_HOME/codex-review.schema.json"
    # 플러그인 본체
    rm -rf "$CLAUDE_HOME/skills/yultopia"
    echo "Yultopia 플러그인을 완전히 제거했습니다. Claude 를 다시 시작하세요."
    exit 0 ;;
esac

# =========================== start 모드 ==================================
if [ "$MODE" = "start" ]; then
  kill_switch_on && quiet_exit
  input="$(cat)"
  sid="$(printf '%s' "$input" | jq -r '.session_id // ""')"
  pid="$(printf '%s' "$input" | jq -r '.prompt_id // ""')"
  cwd="$(printf '%s' "$input" | jq -r '.cwd // ""')"
  [ -n "$sid" ] && [ -n "$pid" ] || quiet_exit

  # 협업 모드가 꺼진 세션에서는 아무 것도 기록하지 않는다
  session_on "$sid" || quiet_exit

  ttl_sweep
  root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || quiet_exit
  [ -n "$root" ] || quiet_exit
  is_forbidden_root "$root" && quiet_exit

  emit_fingerprint "$root" | jq -c '. + {rounds:0}' | atomic_write "$(turn_file "$sid" "$pid")"
  quiet_exit
fi

# =========================== stop 모드 ===================================
if [ "$MODE" != "stop" ]; then
  echo "usage: codex-review.sh {start|stop|session-enable|session-disable|session-status|status|show-last|enable|disable|uninstall}" >&2
  exit 1
fi

# 1) 전역 비상정지가 최우선. 아래에 두면 꺼도 멈추지 않는다.
kill_switch_on && quiet_exit

input="$(cat)"
sid="$(printf '%s' "$input" | jq -r '.session_id // ""')"
pid="$(printf '%s' "$input" | jq -r '.prompt_id // ""')"
cwd="$(printf '%s' "$input" | jq -r '.cwd // ""')"

# 2) 이 세션에서 협업 모드가 꺼져 있으면 완전히 조용히 끝낸다
session_on "$sid" || quiet_exit

root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$root" ] || quiet_exit
is_forbidden_root "$root" && quiet_exit

# 3) 시작 기록이 없으면 (협업 모드를 켠 바로 그 턴) 조용히 끝낸다.
#    라운드를 셀 수 없으므로 어떤 경우에도 턴을 이어가지 않는다.
sfile="$(turn_file "$sid" "$pid")"
[ -f "$sfile" ] || quiet_exit

start_json="$(cat "$sfile")"
rounds="$(printf '%s' "$start_json" | jq -r '.rounds // 0')"
s_head="$(printf '%s' "$start_json" | jq -r '.head')"
now_json="$(emit_fingerprint "$root")"

changed=""
for k in head staged unstaged untracked; do
  a="$(printf '%s' "$start_json" | jq -r --arg k "$k" '.[$k]')"
  b="$(printf '%s' "$now_json"   | jq -r --arg k "$k" '.[$k]')"
  [ "$a" != "$b" ] && changed="$changed $k"
done

# 4) 코드 변경이 없는 일반 질문 → 아무 메시지도 표시하지 않는다
[ -z "$changed" ] && quiet_exit

# 5) 라운드 상한 — 소진되면 턴을 끝낸다.
#    반복 방어는 오직 이 카운터가 담당한다. stop_hook_active 는 판단에 쓰지 않는다.
#    (다른 Stop 훅이 턴을 이어가면 그 플래그가 true 가 되는데, 그걸 근거로 건너뛰면
#     정상 검수가 통째로 누락된다.)
if [ "$rounds" -ge "$MAX_ROUNDS" ]; then
  show_exit "Codex 검수: ${MAX_ROUNDS}회 후에도 미해결 — 사용자 확인 필요"
fi

# 라운드 선반영 (타임아웃이 반복돼도 상한 유지)
printf '%s' "$start_json" | jq -c --argjson r "$((rounds + 1))" '.rounds=$r' | atomic_write "$sfile"

pkey="$(key "$root")"
out="$TURN_DIR/$(key "$sid")/$(key "$pid").result.json"
rm -f "$out" 2>/dev/null

PROMPT="너는 독립적인 코드 리뷰어다. 코드를 수정하지 마라. 읽기만 하라.

이번 턴에서 변경된 영역: ${changed# }
턴 시작 시점의 HEAD: ${s_head}

다음을 네가 직접 조사하라. 남이 정리해준 요약을 신뢰하지 마라.
1. git diff ${s_head}..HEAD  (시작 HEAD 와 현재 HEAD 사이의 커밋된 변경)
2. git diff --cached  및  git diff  (staged / unstaged 변경)
3. git ls-files --others --exclude-standard 로 untracked 새 파일 목록을 얻고, 각 파일 내용을 직접 읽어라
4. 저장소의 AGENTS.md / CLAUDE.md 와 테스트 규칙

판정 기준:
- 확실한 correctness 버그, 데이터 손상, 보안 결함만 findings 에 넣어라.
- 스타일, 취향, 네이밍, 선호도 의견은 절대 넣지 마라.
- 확신이 없으면 넣지 마라.
- P1(확실한 오류)이 하나라도 있으면 verdict 는 block, 아니면 pass."

rc=0
run_with_timeout "$TIMEOUT" "$CODEX_BIN" exec \
  --ephemeral -s read-only -C "$root" \
  --output-schema "$SCHEMA" -o "$out" "$PROMPT" >/dev/null 2>&1 || rc=$?

save_raw() {
  [ -s "$out" ] && cp -f "$out" "$RAW_DIR/$pkey.raw" 2>/dev/null
  jq -nc --arg ts "$(date '+%Y-%m-%d %H:%M:%S')" --arg root "$root" \
         --arg status "$1" --arg changed "${changed# }" --arg round "$((rounds + 1))" \
    '{ts:$ts,root:$root,status:$status,changed:$changed,round:$round}' \
    > "$RAW_DIR/$pkey.meta.json" 2>/dev/null
}

fail_out() { save_raw "실행 실패: $1"; show_exit "Codex 검수: 실행 실패 — 검수되지 않음 ($1)"; }

[ $rc -ne 0 ] && fail_out "타임아웃 또는 실행 오류"
[ ! -s "$out" ] && fail_out "빈 응답"
jq -e . "$out" >/dev/null 2>&1 || fail_out "JSON 형식 오류"

verdict="$(jq -r '.verdict // ""' "$out")"
[ "$verdict" = "pass" ] || [ "$verdict" = "block" ] || fail_out "verdict 누락"

p1="$(jq -r '[.findings[]? | select(.severity=="P1")] | length' "$out")"
nf="$(jq -r '.findings | length' "$out")"

# 모델이 pass 라 해도 P1 이 있으면 보수적으로 block 처리
[ "$verdict" = "pass" ] && [ "$p1" -gt 0 ] && verdict="block"

if [ "$verdict" = "pass" ]; then
  if [ "$rounds" -gt 0 ]; then
    save_raw "문제 발견 후 수정하여 통과"
    show_exit "Codex 검수: 문제 발견 후 Claude가 수정하여 통과"
  fi
  save_raw "통과"
  show_exit "Codex 검수: 통과"
fi

save_raw "문제 발견 (${nf}건) — 수정 중"

body="$(jq -c --argjson n "$MAX_FINDINGS" --argjson L "$MAX_STRLEN" '
  {verdict:.verdict,
   findings:[.findings[]? | {severity,file,line,why:(.why[0:$L]),fix:(.fix[0:$L])}][0:$n]}' "$out")"

block_stop "Codex 독립 검수 결과: BLOCK

$body

위 findings 를 수정하라. 스타일 의견이 아니라 확실한 오류만 지적된 것이다.
수정 후 이 검수는 자동으로 다시 실행된다 (남은 라운드: $((MAX_ROUNDS - rounds - 1))).
동의할 수 없는 지적이 있으면 고치지 말고 근거와 함께 사용자에게 설명하라."
