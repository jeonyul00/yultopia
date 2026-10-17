#!/bin/bash
# cc-hook.sh - /yultopia:cc 훅 진입점: session-start | prompt-submit
#
# 약속 (사용자 결정)
#   - Codex 를 부르지 않는다. 네트워크를 쓰지 않는다. 프로세스를 직접 죽이지 않는다.
#   - 활성 /cc 작업이 없으면 출력 없이 곧바로 끝난다: git 명령 하나(rev-parse)와 존재 확인만 하고,
#     무거운 lib 는 active 가 있을 때만 불러온다.
#   - 어떤 경우에도 exit 0, stderr 도 삼킨다 (사용자 메시지·세션 시작을 막지 않는다).
#   - 메시지마다 긴 작업을 시작하지 않는다: 잠금 대기는 2초까지, 검사는 읽기와 신호 0 확인뿐이다.
#
# 출력 (둘 다 jq 로 만든 한 줄 JSON)
#   session-start : 14일 정리가 알릴 것이 있을 때만 {"systemMessage":"..."}
#   prompt-submit : 고아 Codex 일 때만 {"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"..."}}

cc_hook_main() {
  local mode="${1:-}" input="" cwd="" self_dir lib_dir l line ctx

  case "$mode" in session-start|prompt-submit) ;; *) return 0 ;; esac
  command -v jq >/dev/null 2>&1 || return 0

  # 스크립트 위치는 cd 하기 전에 정한다 (상대 경로로 불려도 동작)
  self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || return 0
  lib_dir="$self_dir/../lib/cc"

  # stdin 은 훅 JSON 객체여야 한다. 읽을 수 없으면 아무것도 하지 않는다. cwd 가 없는 JSON 일 때만 대체 경로를 쓴다.
  [ -t 0 ] || input=$(cat)
  cwd=$(printf '%s' "$input" | jq -rs 'if length == 1 and (.[0] | type) == "object" then (.[0].cwd | strings) // "" else error("not a hook json") end' 2>/dev/null) || return 0
  [ -n "$cwd" ] || cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
  cd "$cwd" 2>/dev/null || return 0
  # 빠른 길: 함수 정의만 있는 두 파일 (프로세스를 만들지 않는다). git 은 cc_active_exists 안의 rev-parse 한 번뿐
  : "${CC_STATE_LOCK_WAIT_SECS:=2}"
  . "$lib_dir/common.sh" || return 0
  . "$lib_dir/state.sh" || return 0
  cc_active_exists || return 0

  # 여기부터는 활성 작업이 있을 때만
  for l in snapshot proc render call wait housekeeping; do
    . "$lib_dir/$l.sh" || return 0
  done

  case "$mode" in
    session-start)
      _cc_hk_cleanup_stale
      line=$_CC_HK_LINE
      [ -n "$line" ] || return 0
      jq -nc --arg m "$line" '{systemMessage: $m}'
      ;;
    prompt-submit)
      cc_active_path_safe || return 0
      cc_is_orphan || return 0      # $(...) 안에서 부르면 CC_ORPHAN_* 가 사라진다
      if [ "$CC_ORPHAN_KIND" = leftover ]; then
        ctx="[yultopia cc] Codex 호출 $CC_ORPHAN_CALL_ID 의 감독 프로세스와 Codex는 끝났지만, 확인할 수 없는 프로세스가 프로세스 그룹 $CC_ORPHAN_PGID 에 남아 있습니다. /cc 는 이것을 자동으로 종료하지 않습니다. 사용자가 \`ps -o pid,command -g $CC_ORPHAN_PGID\` 로 직접 확인할 수 있습니다."
      else
        ctx="[yultopia cc] 기다리는 대기 명령 없이 Codex가 실행 중입니다 (호출 $CC_ORPHAN_CALL_ID, 경과 ${CC_ORPHAN_MINUTES}분). 사용자 메시지에 맞춰 \`cc-codex.sh check-orphan --kill\` 로 종료하거나 \`cc-codex.sh wait\` 로 다시 기다리세요."
      fi
      jq -nc --arg c "$ctx" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}'
      ;;
  esac
  return 0
}

( cc_hook_main "$@" ) 2>/dev/null
exit 0
