# 테스트 도우미. source 전용 (bash 3.2 호환).
#
# 결과 읽는 방법:
#   run_cc ARGS...   cc-codex.sh 를 실행하고 OUT, ERR, CODE 를 설정한다. 반환값은 $CODE.
#                    결과는 파일($TMP/.cc.*)에도 남긴다 (`printf | run_cc` 처럼 파이프라인
#                    서브셸에서 실행돼도 보이도록).
#   assert_code N    항상 "직전 run_cc" 의 결과를 파일에서 다시 읽어 비교한다.
#   cc_last          직전 run_cc 의 OUT/ERR/CODE 를 변수로 다시 읽는다 (파이프라인 뒤에 필요).
#   cc_path NAME     path 하위 명령의 출력만 돌려주고 결과 파일을 건드리지 않는다.
#                    따라서 $(cc_path x) 를 불러도 assert_code 가 보는 값은 바뀌지 않는다.

CC_TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
CC_REPO_ROOT=$(cd "$CC_TEST_DIR/../.." && pwd -P)
CC_BIN="$CC_REPO_ROOT/plugins/yultopia/bin/cc-codex.sh"
HOOK="$CC_REPO_ROOT/plugins/yultopia/bin/cc-hook.sh"
TPL_DIR="$CC_REPO_ROOT/plugins/yultopia/lib/cc/prompts"
REVIEW_REPORT=$'구현 보고\n- 변경: src/a.txt 추가\n- 검증: 수동 확인 완료'

# 테스트용 짧은 기본값 (Ruling R1)
export CC_POLL_SECS="${CC_POLL_SECS:-1}"
export CC_WAIT_MAX_SECS="${CC_WAIT_MAX_SECS:-20}"
export CC_FAST_FAIL_SECS="${CC_FAST_FAIL_SECS:-5}"
export CC_CALL_TIMEOUT_SECS="${CC_CALL_TIMEOUT_SECS:-30}"
export CC_ORPHAN_GRACE_SECS="${CC_ORPHAN_GRACE_SECS:-2}"
# 가짜 codex (호출하는 쪽이 `CC_CODEX_BIN=... run_cc` 로 덮어쓸 수 있다)
export CC_CODEX_BIN="${CC_CODEX_BIN:-$CC_TEST_DIR/fake-codex}"
# 가짜 codex 설정값. 바깥 환경 값은 버리고 export 표시만 해 둔다.
# 그래서 테스트 안에서 `FAKE_CODEX_SEQ=hang` 처럼 대입만 해도 감독 프로세스와 가짜 codex 에 전달된다.
# FAKE_CODEX_LOG 는 start_task 가 테스트 폴더 안으로 정한다 (run_cc 도 같은 기본값을 쓴다).
unset FAKE_CODEX_SEQ FAKE_CODEX_RESULT FAKE_CODEX_DELAY FAKE_CODEX_LOG FAKE_CODEX_LOGIN
export FAKE_CODEX_SEQ FAKE_CODEX_RESULT FAKE_CODEX_DELAY FAKE_CODEX_LOG FAKE_CODEX_LOGIN

. "$CC_REPO_ROOT/plugins/yultopia/lib/cc/common.sh"
. "$CC_REPO_ROOT/plugins/yultopia/lib/cc/state.sh"

# ---- 단언 ----
cc_last() {
  [ -f "$TMP/.cc.code" ] || return 0
  OUT=$(cat "$TMP/.cc.out"); ERR=$(cat "$TMP/.cc.err"); CODE=$(cat "$TMP/.cc.code")
}
_fail() { echo "ASSERT FAIL: $*" >&2; : > "${TMP:-/tmp}/.failed"; return 1; }
assert_eq() { [ "$1" = "$2" ] || _fail "기대 [$2] 실제 [$1] ${3:-}"; }
assert_contains() { case "$1" in *"$2"*) ;; *) _fail "[$1] 에 [$2] 없음";; esac; }
assert_not_contains() { case "$1" in *"$2"*) _fail "[$1] 에 [$2] 있음";; esac; }
assert_file_exists() { [ -e "$1" ] || _fail "파일 없음: $1"; }
assert_no_path() { { [ ! -e "$1" ] && [ ! -L "$1" ]; } || _fail "경로가 있음: $1"; }
assert_code() { cc_last; [ "$CODE" = "$1" ] || _fail "종료 코드 기대 $1 실제 $CODE (out=[$OUT] err=[$ERR])"; }
assert_code_of() { local n="$1"; shift; "$@" >/dev/null 2>&1; local c=$?; [ "$c" = "$n" ] || _fail "종료 코드 기대 $n 실제 $c: $*"; }
assert_no_process_matching() { if pgrep -f -- "$1" >/dev/null 2>&1; then _fail "프로세스가 남아 있음: $1"; fi; }

# ---- 저장소·실행 ----
make_repo() {
  local d="$TMP/${1:-repo}"
  mkdir -p "$d" || return 1
  (
    cd "$d" || exit 1
    git init -q . && git config user.name tester && git config user.email tester@example.com \
      && git config commit.gpgsign false \
      && echo base > base.txt && git add base.txt && git commit -q -m init
  ) >/dev/null 2>&1 || return 1
  printf '%s\n' "$d"
}

run_cc() {
  local errf="$TMP/.run_cc.err"
  OUT=$(FAKE_CODEX_LOG="${FAKE_CODEX_LOG:-$TMP/fake-codex.log}" bash "$CC_BIN" "$@" 2>"$errf")
  CODE=$?
  ERR=$(cat "$errf")
  printf %s "$OUT" > "$TMP/.cc.out"; printf %s "$ERR" > "$TMP/.cc.err"; printf %s "$CODE" > "$TMP/.cc.code"
  return "$CODE"
}

# 결과 파일을 건드리지 않고 path 출력만 돌려준다
cc_path() { bash "$CC_BIN" path "$1" 2>/dev/null; }

start_task() {
  local repo
  FAKE_CODEX_LOG="${FAKE_CODEX_LOG:-$TMP/fake-codex.log}"
  repo=$(make_repo "${1:-repo}") || return 1
  cd "$repo" || return 1
  printf '목표: 기본 정리본\n' | run_cc init
  cc_last
  [ "$CODE" = 0 ] || { _fail "start_task init 실패: $OUT $ERR"; return 1; }
  ACTIVE=$(cc_path active)
  CALL1="$ACTIVE/calls/1"
}

state() { jq -r "$1" "$ACTIVE/state.json"; }
set_state() {
  local tmp="$ACTIVE/.set_state.$$"
  jq "$1" "$ACTIVE/state.json" > "$tmp" && mv "$tmp" "$ACTIVE/state.json"
}

wait_until_status_file() {
  local id="$1" secs="${2:-10}" i=0
  while [ ! -s "$ACTIVE/calls/$id/status" ]; do
    [ "$i" -ge $((secs * 10)) ] && return 1
    sleep 0.1; i=$((i+1))
  done
}

# 테스트가 끝날 때 남은 프로세스 정리: 명령줄에 $TMP 가 들어 있는 프로세스의 그룹만 대상
cleanup_test() {
  [ -n "${TMP:-}" ] || return 0
  local pids pid pgid mypg
  mypg=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')
  pids=$(pgrep -f -- "$TMP" 2>/dev/null)
  [ -n "$pids" ] || return 0
  for pass in TERM KILL; do
    for pid in $pids; do
      pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
      [ -n "$pgid" ] || continue
      if [ "$pgid" != "$mypg" ]; then kill -"$pass" -- "-$pgid" 2>/dev/null; else kill -"$pass" "$pid" 2>/dev/null; fi
    done
    [ "$pass" = TERM ] && sleep 0.3
  done
  return 0
}
