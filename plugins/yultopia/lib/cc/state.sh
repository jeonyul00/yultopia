# state.sh - git 디렉터리·active 경로, 안전 검사, state.json 읽기/쓰기. source 전용.

# 절대 git 디렉터리. 실패 시 1.
cc_git_dir() {
  local d
  d=$(git rev-parse --absolute-git-dir 2>/dev/null) || return 1
  [ -n "$d" ] || return 1
  printf '%s\n' "$d"
}

cc_root_dir() {
  local gd
  gd=$(cc_git_dir) || return 1
  printf '%s\n' "$gd/yultopia-cc"
}

cc_active_dir() {
  local gd
  gd=$(cc_git_dir) || return 1
  printf '%s\n' "$gd/yultopia-cc/active"
}

# active 가 (심볼릭 링크 포함) 존재하는가
cc_active_exists() {
  local a
  a=$(cc_active_dir) || return 1
  [ -e "$a" ] || [ -L "$a" ]
}

# 0 안전 / 1 비정상: 두 단계 모두 심볼릭 링크가 아니고, 실제 경로가 git 디렉터리 아래
cc_active_path_safe() {
  local gd root active real_gd real_active
  gd=$(cc_git_dir) || return 1
  root="$gd/yultopia-cc"
  active="$root/active"
  [ -L "$root" ] && return 1
  [ -L "$active" ] && return 1
  [ -d "$root" ] || return 1
  [ -d "$active" ] || return 1
  real_gd=$(cd -P "$gd" 2>/dev/null && pwd -P) || return 1
  real_active=$(cd -P "$active" 2>/dev/null && pwd -P) || return 1
  case "$real_active" in
    "$real_gd"/yultopia-cc/active) return 0 ;;
  esac
  return 1
}

cc_state_get() {
  local a
  a=$(cc_active_dir) || return 1
  jq -r "$1" "$a/state.json"
}

# cc_state_update <jq-filter> [--arg k v ...] : 임시 파일 + mv 로 원자적 쓰기, last_activity_at 갱신
cc_state_update() {
  local filter="$1" a tmp now
  shift
  a=$(cc_active_dir) || return 1
  now=$(cc_now_iso)
  tmp=$(mktemp "$a/.state.XXXXXX") || return 1
  if jq "$@" --arg _cc_now "$now" "($filter) | .last_activity_at = \$_cc_now" "$a/state.json" > "$tmp" 2>/dev/null \
     && jq -es -e 'length == 1 and (.[0] | type == "object")' "$tmp" >/dev/null 2>&1; then
    mv "$tmp" "$a/state.json"
  else
    rm -f "$tmp"
    return 1
  fi
}

# 안전 검사를 통과할 때만 active 를 정확한 경로로 삭제
cc_delete_active() {
  local a
  cc_active_path_safe || return 1
  a=$(cc_active_dir) || return 1
  rm -rf "$a"
}
