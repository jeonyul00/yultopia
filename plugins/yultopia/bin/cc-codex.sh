#!/bin/bash
# cc-codex.sh - /yultopia:cc CLI 진입점
SELF="${BASH_SOURCE[0]}"
SELF_DIR=$(cd "$(dirname "$SELF")" && pwd -P)
LIB_DIR="$SELF_DIR/../lib/cc"

for _cc_lib in common state; do
  . "$LIB_DIR/$_cc_lib.sh" || { echo "[cc] 내부 오류: $LIB_DIR/$_cc_lib.sh 를 불러오지 못했습니다"; exit 1; }
done

cc_init_fail() {
  # 이 실행이 만든 active 를 치우고 한 줄 오류 출력, 종료 코드 1
  cc_delete_active 2>/dev/null || rmdir "$(cc_active_dir)" 2>/dev/null
  cc_line "[cc] 작업을 시작하지 못했습니다."
  [ -n "$1" ] && cc_err "$1"
  return 1
}

cc_cmd_init() {
  local root active top now tmp
  cc_git_dir >/dev/null || { cc_line "[cc] git 저장소가 아닙니다."; return 1; }
  root=$(cc_root_dir)
  active=$(cc_active_dir)
  if [ -L "$root" ]; then
    cc_line "[cc] 상태 폴더 경로가 비정상입니다."
    return 1
  fi
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
  top=$(git rev-parse --show-toplevel 2>/dev/null) || top=$(pwd -P)
  now=$(cc_now_iso)
  tmp=$(mktemp "$active/.state.XXXXXX") || { cc_init_fail "임시 파일 생성 실패"; return 1; }
  jq -n --arg now "$now" --arg root "$top" '{
    version: 1, created_at: $now, last_activity_at: $now, repo_root: $root,
    phase: "planning", session_id: null, milestone: null, milestones_total: null,
    task_base_tree: null, milestone_base_tree: null, calls_total: 0, rejects_in_row: 0,
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
  line=$(jq -er 'select(type == "object" and (.phase | type == "string") and (.calls_total | type == "number"))
                 | "[cc] 단계: \(.phase), Codex 호출 \(.calls_total)회"' "$a/state.json" 2>/dev/null) || {
    cc_line "[cc] 상태 파일을 읽을 수 없습니다."
    cc_err "state.json 이 없거나 형식이 올바르지 않습니다: $a/state.json"
    return 1
  }
  cc_line "$line"
}


cc_cmd_finish() {
  cc_active_exists || { cc_line "[cc] 진행 중인 작업이 없습니다."; return 0; }
  cc_delete_active || { cc_line "[cc] 상태 폴더 경로가 비정상이라 삭제하지 않았습니다."; return 1; }
  cc_line "[cc] 작업을 마무리하고 상태를 정리했습니다."
}

cmd="${1:-}"
[ $# -gt 0 ] && shift
case "$cmd" in
  init)   cc_cmd_init "$@" ;;
  path)   cc_cmd_path "$@" ;;
  status) cc_cmd_status "$@" ;;
  finish) cc_cmd_finish "$@" ;;
  *) cc_line "[cc] 알 수 없는 하위 명령: ${cmd:-(없음)}"; exit 1 ;;
esac
exit $?
