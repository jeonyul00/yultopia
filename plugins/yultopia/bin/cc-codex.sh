#!/bin/bash
# cc-codex.sh - /yultopia:cc CLI 진입점
SELF="${BASH_SOURCE[0]}"
SELF_DIR=$(cd "$(dirname "$SELF")" && pwd -P)
LIB_DIR="$SELF_DIR/../lib/cc"
# 감독 프로세스를 띄울 때 쓰는 이 스크립트의 절대 경로
CC_SELF_ABS="$SELF_DIR/$(basename "$SELF")"

for _cc_lib in common state snapshot proc render call wait housekeeping put; do
  . "$LIB_DIR/$_cc_lib.sh" || { echo "[cc] 내부 오류: $LIB_DIR/$_cc_lib.sh 를 불러오지 못했습니다"; exit 1; }
done

cc_init_fail() {
  # 이 실행이 만든 active 를 치우고 한 줄 오류 출력, 종료 코드 1
  cc_delete_active 2>/dev/null || rmdir "$(cc_active_dir)" 2>/dev/null
  cc_line "[cc] 작업을 시작하지 못했습니다."
  [ -n "$1" ] && cc_err "$1"
  return 1
}

# 작업 트리가 깨끗한지 init 에서도 다시 본다 (preflight 와 같은 _cc_hk_dirty_scan, 최종 리뷰 Important 2).
#   인터뷰하는 동안 파일이 바뀌었을 수 있다. 기존 변경이 섞이면 /cc 변경과 구분할 수 없으므로 시작하지 않는다.
#   0 깨끗함 / 8 변경 있음(한 줄: 개수와 최대 10개 파일) / 1 확인 실패(한 줄)
_cc_init_require_clean_tree() {
  local top="$1" list="" f n
  if ! _cc_hk_dirty_scan "$top"; then
    cc_line "[cc] 작업 트리 상태를 확인하지 못해 작업을 시작하지 않았습니다."
    return 1
  fi
  [ "$_CC_HK_DIRTY_N" -gt 0 ] || return 0
  for f in "${_CC_HK_DIRTY[@]}"; do list="${list:+$list, }$f"; done
  n=$((_CC_HK_DIRTY_N - ${#_CC_HK_DIRTY[@]}))
  [ "$n" -gt 0 ] && list="$list 외 ${n}개"
  # 파일 이름의 줄바꿈·제어 문자는 ? 로 바꿔 언제나 한 줄로 끝낸다 (R7)
  list=$(printf '%s' "$list" | LC_ALL=C tr '\000-\037\177' '?')
  cc_line "[cc] 커밋되지 않은 변경이 ${_CC_HK_DIRTY_N}개 있어 작업을 시작하지 않았습니다 (기존 변경과 /cc 변경을 구분할 수 없음): $list"
  return 8
}

cc_cmd_init() {
  local root active top now tmp base_tree rc
  cc_git_dir >/dev/null || { cc_line "[cc] git 저장소가 아닙니다."; return 1; }
  root=$(cc_root_dir)
  active=$(cc_active_dir)
  if [ -L "$root" ]; then
    cc_line "[cc] 상태 폴더 경로가 비정상입니다."
    return 1
  fi
  # 다른 세션의 작업이 먼저 있으면 그것을 알린다 (그 작업의 변경 때문에 트리가 더러울 수 있다). 최종 판단은 아래 mkdir
  if [ -e "$active" ] || [ -L "$active" ]; then
    cc_line "[cc] 이미 진행 중인 작업이 있습니다."
    return 4
  fi
  # 변경이 있으면 아무것도 만들지 않고 8 (상태 폴더도 만들지 않는다)
  top=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n "$top" ] || {
    cc_line "[cc] 작업 트리 위치를 찾지 못해 작업을 시작하지 않았습니다."; return 1; }
  _cc_init_require_clean_tree "$top"; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  mkdir -p "$root" 2>/dev/null || { cc_line "[cc] 상태 폴더를 만들지 못했습니다."; return 1; }
  # 원자적 생성: 동시에 시작해도 한 쪽만 성공한다
  if ! mkdir "$active" 2>/dev/null; then
    if [ -e "$active" ] || [ -L "$active" ]; then
      cc_line "[cc] 이미 진행 중인 작업이 있습니다."
      return 4
    fi
    cc_line "[cc] 상태 폴더를 만들지 못했습니다."
    return 1
  fi
  # 여기부터 이 실행이 active 를 소유한다
  cc_active_path_safe || { rmdir "$active" 2>/dev/null; cc_line "[cc] 상태 폴더 경로가 비정상입니다."; return 1; }
  cat > "$active/brief.md" || { cc_init_fail "brief.md 를 쓰지 못했습니다"; return 1; }
  now=$(cc_now_iso)
  base_tree=$(cc_snapshot_tree) && [ -n "$base_tree" ] || { cc_init_fail "작업 트리 스냅샷 실패"; return 1; }
  tmp=$(mktemp "$active/.state.XXXXXX") || { cc_init_fail "임시 파일 생성 실패"; return 1; }
  jq -n --arg now "$now" --arg root "$top" --arg base "$base_tree" '{
    version: 1, created_at: $now, last_activity_at: $now, repo_root: $root,
    phase: "planning", session_id: null, milestone: null, milestones_total: null,
    task_base_tree: $base, milestone_base_tree: null, calls_total: 0, rejects_in_row: 0,
    tokens: {input: 0, cached_input: 0, output: 0},
    running: null, waiter: null, waiter_last_seen_at: null, last_call: null
  }' > "$tmp" && mv "$tmp" "$active/state.json" || { cc_init_fail "state.json 을 쓰지 못했습니다"; return 1; }
  mkdir -p "$active/calls" "$active/verify" || { cc_init_fail "하위 폴더 생성 실패"; return 1; }
  cc_line "[cc] 작업을 시작했습니다."
}


cc_cmd_path() {
  local a
  a=$(cc_active_dir) || { cc_line "[cc] git 저장소가 아닙니다."; return 1; }
  case "${1:-}" in
    active)  cc_line "$a" ;;
    brief)   cc_line "$a/brief.md" ;;
    report)  cc_line "$a/report.md" ;;
    message) cc_line "$a/message.md" ;;
    verify)  cc_line "$a/verify" ;;
    *) cc_line "[cc] 사용법: path <active|brief|report|message|verify>"; return 1 ;;
  esac
}

cc_cmd_status() {
  local a line
  cc_active_exists || { cc_line "[cc] 진행 중인 작업이 없습니다."; return 5; }
  cc_active_path_safe || { cc_line "[cc] 상태 폴더 경로가 비정상입니다."; return 1; }
  a=$(cc_active_dir)
  # 연속 반려는 SKILL 이 3번째 반려를 알아보는 데, 토큰은 완료 보고에 쓴다 (스펙 3-4, 3-5).
  # 기록이 없거나 숫자가 아니면 0 으로 보인다
  line=$(jq -er 'def n: if type == "number" then . else 0 end;
                 select(type == "object" and (.phase | type == "string") and (.calls_total | type == "number"))
                 | (.tokens | if type == "object" then . else {} end) as $t
                 | "[cc] 단계: \(.phase), Codex 호출 \(.calls_total)회, 연속 반려 \(.rejects_in_row | n)회, 토큰 입력 \($t.input | n) (캐시 \($t.cached_input | n)) · 출력 \($t.output | n)"' \
               "$a/state.json" 2>/dev/null) || {
    cc_line "[cc] 상태 파일을 읽을 수 없습니다."
    cc_err "state.json 이 없거나 형식이 올바르지 않습니다: $a/state.json"
    return 1
  }
  cc_line "$line"
}


# 사용자가 계속하라고 했을 때만 SKILL 이 부른다: 같은 마일스톤의 연속 반려 횟수를 0 으로
cc_cmd_ack_rejects() {
  cc_active_exists || { cc_line "[cc] 진행 중인 작업이 없습니다."; return 1; }
  cc_active_path_safe || { cc_line "[cc] 상태 폴더 경로가 비정상입니다."; return 1; }
  cc_state_update '.rejects_in_row = 0' 2>/dev/null || { cc_line "[cc] 상태 파일을 고치지 못했습니다."; return 1; }
  cc_line "[cc] 연속 반려 횟수를 0으로 되돌렸습니다. 검수를 다시 요청할 수 있습니다."
}

# 사용자가 완료를 확인했을 때: Codex 가 돌 수 있으면 6 으로 거부, 아니면 active 삭제 (housekeeping.sh)
cc_cmd_finish() {
  _cc_hk_remove_active "[cc] 작업을 마무리하고 상태를 정리했습니다."
}

cmd="${1:-}"
[ $# -gt 0 ] && shift
case "$cmd" in
  init)   cc_cmd_init "$@" ;;
  path)   cc_cmd_path "$@" ;;
  status) cc_cmd_status "$@" ;;
  finish) cc_cmd_finish "$@" ;;
  call)   cc_cmd_call "$@" ;;
  ack-rejects) cc_cmd_ack_rejects "$@" ;;
  wait)   cc_cmd_wait "$@" ;;
  check-orphan)  cc_cmd_check_orphan "$@" ;;
  cleanup-stale) cc_cmd_cleanup_stale "$@" ;;
  preflight)     cc_cmd_preflight "$@" ;;
  discard)       cc_cmd_discard "$@" ;;
  put)           cc_cmd_put "$@" ;;
  _supervise) cc_cmd_supervise "$@" ;;
  *) cc_line "[cc] 알 수 없는 하위 명령: ${cmd:-(없음)}"; exit 1 ;;
esac
exit $?
