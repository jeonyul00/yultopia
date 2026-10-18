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
: "${CC_LOGIN_TIMEOUT_SECS:=10}"

# git 이 무시하는 파일 중 Codex 실행 전후로 내용을 비교해 감시할 것 (2026-10-18 보안 수정 R34). 이 목록 하나만 고치면 된다.
#   공백으로 구분한 glob. "/" 로 끝나지 않는 것은 파일 이름(깊이 상관없음), "/" 로 끝나는 것은 그 이름의 폴더 아래 전부.
#   추적 중인 파일은 원래 작업 트리 스냅샷이 본다. 여기 없는 무시된 출력(빌드 폴더, 캐시, 커버리지, 로그)은 바뀌어도 된다.
#   환경변수로 덮어쓰지 않는다 (감시를 끄는 값이 끼어들지 않도록).
CC_IGNORED_WATCH_PATTERNS='.env .env.* *.pem *.key *.p12 *.pfx id_rsa* id_ed25519* .npmrc .yarnrc .yarnrc.yml .pypirc .netrc *.keystore credentials* secrets* node_modules/ vendor/ .venv/ venv/ Pods/ .bundle/'
# 위 감시에서 뺄 폴더 (사용자 결정 2026-10-18): 테스트·빌드 도구가 돌 때마다 다시 쓰는 캐시라 감시하면 매번 멈춘다.
#   "a/b/" 는 이어진 폴더 이름 a, b (어느 깊이든: 예) app/node_modules/.vite/ 도). 그 아래는 이름 패턴(.env 등)도 보지 않는다.
#   대신 Codex 가 이 캐시를 바꿔 두면 다음 빌드가 그 내용을 쓸 수 있다 (README 에 적음).
CC_IGNORED_WATCH_EXCLUDE='node_modules/.cache/ node_modules/.vite/'

# _cc_git_harden_env : 이 셸(서브셸 안에서 부른다)에서 실행하는 git 이 작업 트리나 중첩 저장소에 놓인 설정으로 다른 명령을
#   실행하지 않도록 명령줄 범위 설정을 둔다 (2026-10-18 보안 수정 R33). `git -c k=v` 와 같은 범위(설정 파일보다 우선)인
#   GIT_CONFIG_COUNT/KEY/VALUE 를 쓴다: git 이 띄우는 하위 모듈 git 에도 그대로 가고, git 의 첫 인자(하위 명령)는 바뀌지 않는다.
#   core.fsmonitor=false, core.hooksPath=/dev/null, core.untrackedCache=false, submodule.recurse=false, 시스템 설정 읽지 않음.
#   이미 GIT_CONFIG_COUNT 가 있으면 그 뒤에 덧붙인다. diff 는 부르는 쪽이 --no-ext-diff --no-textconv 를 준다.
_cc_git_harden_env() {
  local n="${GIT_CONFIG_COUNT:-0}" kv
  case "$n" in ''|*[!0-9]*|????*) n=0 ;; esac
  n=$((10#$n))
  for kv in core.fsmonitor=false core.hooksPath=/dev/null core.untrackedCache=false submodule.recurse=false; do
    export "GIT_CONFIG_KEY_$n=${kv%%=*}" "GIT_CONFIG_VALUE_$n=${kv#*=}"
    n=$((n + 1))
  done
  export GIT_CONFIG_COUNT=$n GIT_CONFIG_NOSYSTEM=1
}

# cc_git_safe <git 인자…> : _cc_git_harden_env 를 둔 서브셸에서 git 을 실행한다
cc_git_safe() ( _cc_git_harden_env; exec git "$@" )

cc_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# cc_age_secs <iso> : 해당 시각으로부터 경과한 초(정수)
cc_age_secs() {
  jq -nr --arg t "$1" '(now - ($t | fromdateiso8601)) | floor'
}

# 사용자에게 보이는 한 줄 (stdout)
cc_line() { printf '%s\n' "$*"; }

# 오류 한 줄 (stderr)
cc_err() { printf '%s\n' "$*" >&2; }

# cc_run_with_timeout <secs> <cmd...> : stdin 은 /dev/null. 새 프로세스 그룹에서 돌리고 시간이 넘으면 그룹째 KILL 한다.
#   종료 코드: 명령의 코드 / 124 시간 초과 / 125 시작 실패
cc_run_with_timeout() {
  local secs="$1"
  shift
  case "$secs" in ''|*[!0-9]*|???????*) secs=10 ;; *) secs=$((10#$secs)) ;; esac   # 00 도 0 으로 읽어 시간 제한이 없어지지 않게
  [ "$secs" -gt 0 ] || secs=10
  perl -MPOSIX -e '
    my ($t, @c) = @ARGV;
    my $pid = fork;
    exit 125 unless defined $pid;
    if (!$pid) {
      setpgrp(0, 0);
      open(STDIN, "<", "/dev/null");
      exec { $c[0] } @c or POSIX::_exit(127);
    }
    $SIG{ALRM} = sub { kill "KILL", -$pid; kill "KILL", $pid; waitpid($pid, 0); exit 124 };
    # 신호로 끊기면 우리가 만든 자식 그룹을 정리하고 끝낸다 (자식은 setpgrp 로 자기 그룹의 리더)
    for my $s (qw(TERM INT HUP)) { $SIG{$s} = sub { kill "KILL", -$pid; kill "KILL", $pid; waitpid($pid, 0); exit 143 } }
    alarm $t;
    waitpid($pid, 0);
    alarm 0;
    exit(($? & 127) ? 1 : ($? >> 8));
  ' -- "$secs" "$@"
}
