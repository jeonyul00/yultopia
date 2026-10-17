# common.sh - 공통 함수 (bash 3.2 호환). source 전용.

# 기본값 (환경변수로만 덮어씀)
: "${CC_CALL_TIMEOUT_SECS:=1200}"
: "${CC_FAST_FAIL_SECS:=60}"
: "${CC_WAIT_MAX_SECS:=540}"
: "${CC_POLL_SECS:=5}"
: "${CC_ORPHAN_GRACE_SECS:=60}"
: "${CC_STALE_DAYS:=14}"
: "${CC_MAX_CALLS:=20}"
: "${CC_MAX_REJECTS:=3}"
: "${CC_CODEX_BIN:=codex}"

cc_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# cc_age_secs <iso> : 해당 시각으로부터 경과한 초(정수)
cc_age_secs() {
  jq -nr --arg t "$1" '(now - ($t | fromdateiso8601)) | floor'
}

# 사용자에게 보이는 한 줄 (stdout)
cc_line() { printf '%s\n' "$*"; }

# 오류 한 줄 (stderr)
cc_err() { printf '%s\n' "$*" >&2; }
