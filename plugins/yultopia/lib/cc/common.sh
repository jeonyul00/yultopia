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
