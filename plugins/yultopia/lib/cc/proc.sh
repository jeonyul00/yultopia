# proc.sh - 새 프로세스 그룹 실행, 프로세스 신원 확인, 검증된 그룹 종료. source 전용 (bash 3.2 호환).
#
# 신원(identity) = "<lstart>|<command 앞 200자>"  (ps -o lstart= / ps -o command=)
#   - PID 는 재사용되므로, 기록해 둔 PID 를 죽이거나 "살아 있다/끝났다" 고 판단하기 전에
#     시작 시각과 명령줄까지 같은지 확인한다.
#   - ps 는 항상 LC_ALL=C 로 부른다. 로케일마다 lstart 표기(요일·월 이름)와 비ASCII 명령줄 표기가
#     달라서, 기록한 쪽과 확인하는 쪽의 환경이 다르면 같은 프로세스도 신원이 어긋나기 때문이다.
#     C 로케일의 ps 는 비ASCII·제어 문자를 이스케이프하므로 신원은 항상 한 줄 ASCII 이고,
#     200자 자르기가 멀티바이트 문자를 쪼개지 않으며 JSON 에 저장했다 읽어도 그대로다.
#   - exec 하면 같은 PID 라도 command 가 바뀐다. 그래서 cc_spawn_group 은 exec 가 끝난 뒤에 돌아온다.
#
# 종료 코드 계약 (Ruling R8)
#   cc_proc_identity        0 출력함 / 1 그런 프로세스 없음 / 2 알 수 없음
#   cc_proc_alive_verified  0 살아 있고 신원 일치 / 1 확실히 없음 또는 PID 재사용 / 2 불확실
#   cc_kill_group_verified, cc_kill_group_via_member
#     0 = 신호를 보냈고 그룹이 사라짐
#     1 = 우리 것이 아님이 확인됨 / 없음 → 아무 신호도 보내지 않음
#     2 = 불확실 또는 거부(ps 실패, 인자 형식 오류, PGID 0·1, 호출한 쪽 자신의 그룹,
#         신원은 맞지만 그 그룹 소속이 아님) → 아무 신호도 보내지 않음
#     3 = KILL 뒤에도 그룹이 남아 있음
#   0 만 "죽였다", 1 만 "없다/우리 것 아님" 으로 다룰 수 있다. 2 를 근거로 상태를 지우면 안 된다.
#   cc_kill_own_group_members (그룹 리더 자신이 부름)
#     0 = 리더 말고 남은 멤버 없음 / 2 = 거부·판단 불가(신호 안 보냄) / 3 = KILL 뒤에도 멤버가 남음

# 양의 정수(앞자리 0 없음)인지
_cc_proc_is_pid() {
  case "$1" in ''|0*|*[!0-9]*) return 1 ;; esac
  return 0
}

# _cc_proc_probe <pid | -pgid> : kill(…, 0) 로 존재 여부만 확인.
#   0 있음(권한 없음 EPERM 포함) / 1 확실히 없음(ESRCH) / 2 알 수 없음
# bash 의 kill -0 은 ESRCH 와 EPERM 을 같은 종료 코드로 돌려주고 메시지는 로케일에 따라 달라서 perl 로 구분한다.
_cc_proc_probe() {
  perl -e 'exit 0 if kill 0, $ARGV[0]; exit 1 if $!{ESRCH}; exit 0 if $!{EPERM}; exit 2' -- "$1" 2>/dev/null
  case $? in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

# 앞뒤 공백 제거 (ps 는 lstart 칸 뒤를 공백으로 채운다)
_cc_proc_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# cc_spawn_group <logfile> CMD...
#   CMD 를 새 세션의 리더(= 새 프로세스 그룹의 리더)로 실행하고 그 PID(= PGID)를 stdout 으로 출력한다.
#   - stdin 은 /dev/null, stdout·stderr 는 logfile 에 이어 쓴다. 호출한 쪽의 다른 fd(파이프 등)는
#     물려주지 않는다. 물려주면 $(...) 나 그 파이프를 읽는 쪽이 CMD 가 끝날 때까지 기다리게 된다.
#   - CMD 가 exec 된 뒤에야 돌아온다. `perl … &` 후 `$!` 방식은 돌아온 직후에 아직 setsid 전(PGID 가
#     호출한 쪽 것)이고 명령줄도 perl 래퍼라서, 그때 잡은 신원은 나중 신원과 달라진다.
#     exec 성공은 close-on-exec 파이프가 닫히는 것(EOF)으로 확인한다.
#     단, CMD 자신이 다시 exec 하면(예: bash -c '명령 하나' 는 그 명령으로 exec 한다) 신원이 또 바뀐다.
#     신원을 기록할 프로세스는 스스로 exec 하지 않는 형태(스크립트 실행 등)로 띄운다.
#   - perl 이 fork 하고 부모 perl 은 곧바로 끝나므로 CMD 는 호출한 셸의 자식이 아니다
#     (호출한 쪽이 CMD 를 기다리거나 좀비로 남기지 않는다).
#   실패(인자 부족, setsid·로그 열기·exec 실패): stdout 없음, stderr 에 이유, 종료 코드 1.
cc_spawn_group() {
  local log="$1"
  if [ -z "$log" ] || [ $# -lt 2 ]; then
    cc_err "cc_spawn_group: 사용법: cc_spawn_group <logfile> CMD..."
    return 1
  fi
  shift
  # perl 이 직접 연 fd($r, $w)는 3 이상이라 기본으로 close-on-exec 이다.
  perl -MPOSIX -e '
    my $log = shift @ARGV;
    pipe(my $r, my $w) or do { print STDERR "cc_spawn_group: pipe: $!\n"; exit 1 };
    my $pid = fork;
    defined $pid or do { print STDERR "cc_spawn_group: fork: $!\n"; exit 1 };
    if ($pid == 0) {
      close $r;
      my $fail = sub { my $m = "$_[0]: $!"; syswrite $w, $m; POSIX::_exit(127) };
      POSIX::setsid() or $fail->("setsid");
      open(STDIN, "<", "/dev/null") or $fail->("stdin");
      open(STDOUT, ">>", $log) or $fail->("log $log");
      open(STDERR, ">&", \*STDOUT) or $fail->("stderr");
      # 열려 있는 fd 를 /dev/fd 에서 그대로 읽어 3 이상을 모두 닫는다 (번호 상한 없음).
      # /dev/fd 가 없는 시스템에서만 OPEN_MAX 까지 훑는다 (무한대 대비 2^20 에서 멈춤).
      my $keep = fileno $w;
      my @fds;
      if (opendir(my $d, "/dev/fd")) {
        @fds = grep { /^[0-9]+$/ && $_ > 2 } readdir $d;
        closedir $d;
      } else {
        my $max = POSIX::sysconf(POSIX::_SC_OPEN_MAX());
        $max = 1048576 if !defined $max || $max <= 0 || $max > 1048576;
        @fds = (3 .. $max - 1);
      }
      for my $fd (@fds) { POSIX::close($fd) unless $fd == $keep }
      exec { $ARGV[0] } @ARGV or $fail->("exec $ARGV[0]");
    }
    close $w;
    my $err = "";
    1 while sysread($r, $err, 512, length $err);
    if (length $err) { waitpid($pid, 0); print STDERR "cc_spawn_group: $err\n"; exit 1 }
    print "$pid\n";
    exit 0;
  ' -- "$log" "$@" || return 1
}

# cc_proc_identity <pid> : 신원 한 줄을 stdout 으로.
#   0 = 출력함 / 1 = 그런 프로세스 없음 / 2 = 알 수 없음(ps 실패, 잘못된 PID)
# macOS ps 는 "없는 PID" 와 "ps 자체 실패" 를 둘 다 exit 1 로 알리므로, ps 가 답을 못 주면
# kill(pid, 0) 으로 다시 확인한다: ESRCH 면 확실히 없음(1), 있는데 ps 가 실패했거나 판단 불가면 2.
cc_proc_identity() {
  local pid="$1" lstart="" cmd="" ok=0
  _cc_proc_is_pid "$pid" || return 2
  if lstart=$(LC_ALL=C ps -ww -o lstart= -p "$pid" 2>/dev/null); then
    lstart=$(_cc_proc_trim "$lstart")
    if [ -n "$lstart" ] && cmd=$(LC_ALL=C ps -ww -o command= -p "$pid" 2>/dev/null); then
      cmd=$(_cc_proc_trim "$cmd")
      [ -n "$cmd" ] && ok=1
    fi
  fi
  if [ "$ok" -ne 1 ]; then
    _cc_proc_probe "$pid"
    case $? in
      1) return 1 ;;
      *) return 2 ;;
    esac
  fi
  printf '%s|%s\n' "$lstart" "${cmd:0:200}"
}

# cc_proc_alive_verified <pid> <identity>
#   0 = 살아 있고 신원 일치
#   1 = 확실히 없음, 또는 신원 불일치(다른 프로세스가 PID 를 재사용)
#   2 = 불확실(ps 실패, 인자 형식 오류)
cc_proc_alive_verified() {
  local pid="$1" want="$2" cur rc
  _cc_proc_is_pid "$pid" || return 2
  case "$want" in ?*'|'*) ;; *) return 2 ;; esac
  cur=$(cc_proc_identity "$pid"); rc=$?
  case "$rc" in
    0) [ "$cur" = "$want" ] && return 0; return 1 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

# _cc_proc_pgid <pid> : 그 프로세스의 현재 PGID 를 stdout 으로. 0 / 1 그런 프로세스 없음 / 2 알 수 없음
_cc_proc_pgid() {
  local g
  if g=$(LC_ALL=C ps -o pgid= -p "$1" 2>/dev/null); then
    g=$(_cc_proc_trim "$g")
    if _cc_proc_is_pid "$g"; then
      printf '%s\n' "$g"
      return 0
    fi
  fi
  _cc_proc_probe "$1"
  [ $? -eq 1 ] && return 1
  return 2
}

# _cc_proc_target_pgid_ok <pgid> : 신호를 보내도 되는 그룹 번호인지. 아니면 2(거부).
#   - 양의 정수이고 1 보다 커야 한다 (kill -- -0 은 "자기 그룹", kill -- -1 은 "모든 프로세스").
#   - 호출한 쪽 자신의 그룹이면 거부한다 (TERM 이 호출 도중 자기 자신에게 간다).
#     $(...) 안의 perl 은 호출한 (서브)셸과 같은 그룹에 있으므로 getpgrp 가 호출한 쪽 그룹이다.
#     ps 로 본 $$ 의 그룹도 함께 거부한다. 자기 그룹을 알아내지 못하면 거부한다.
_cc_proc_target_pgid_ok() {
  local pgid="$1" mine top
  _cc_proc_is_pid "$pgid" || return 2
  [ "$pgid" -gt 1 ] 2>/dev/null || return 2
  mine=$(perl -e 'print getpgrp()' 2>/dev/null)
  _cc_proc_is_pid "$mine" || return 2
  [ "$pgid" = "$mine" ] && return 2
  top=$(_cc_proc_pgid $$) || return 2
  [ "$pgid" = "$top" ] && return 2
  return 0
}

# _cc_proc_verify_in_group <pid> <identity> <pgid> : 그 프로세스가 기록한 그 프로세스이고 지금 그룹 <pgid> 에 있는지.
#   0 맞음 / 1 없음·신원 불일치 / 2 불확실, 또는 신원은 맞는데 다른 그룹(우리 프로세스가 살아 있으므로 "없음" 이 아님)
_cc_proc_verify_in_group() {
  local pid="$1" want="$2" pgid="$3" g rc
  cc_proc_alive_verified "$pid" "$want"; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  g=$(_cc_proc_pgid "$pid"); rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  [ "$g" = "$pgid" ] || return 2
  return 0
}

# _cc_proc_wait_group_gone <pgid> <0.1초 단위 횟수> : 그룹이 확실히 사라지면 0, 시간 안에 안 사라지면 1
_cc_proc_wait_group_gone() {
  local i=0
  while [ "$i" -lt "$2" ]; do
    _cc_proc_probe "-$1"; [ $? -eq 1 ] && return 0
    sleep 0.1; i=$((i+1))
  done
  return 1
}

# _cc_proc_wait_leader_or_group <pgid> <0.1초 단위 시간> : 그룹이 사라지면 0, 리더(PID = PGID)만 끝났거나
#   시간이 다 되면 1. perl 한 번 안에서 실제 시각으로 잰다 (반복마다 프로세스를 띄우면 시간이 늘어난다).
#   리더가 끝난 뒤에는 그룹이 남아 있는 한 그 번호가 다른 프로세스에 재사용되지 않는다.
_cc_proc_wait_leader_or_group() {
  perl -MTime::HiRes -e '
    my ($g, $tenths) = @ARGV;
    my $until = Time::HiRes::time() + $tenths / 10;
    while (1) {
      exit 0 if !kill(0, -$g) && $!{ESRCH};
      exit 1 if !kill(0, $g) && $!{ESRCH};
      exit 1 if Time::HiRes::time() >= $until;
      Time::HiRes::sleep(0.05);
    }
  ' -- "$1" "$2" 2>/dev/null
}

# _cc_proc_signal_group <pgid> [leader_grace] : 검증을 마친 그룹에 TERM, 그 뒤 남은 것에 KILL.
#   leader_grace 없음: 그룹이 약 3초 안에 안 사라지면 KILL.
#   leader_grace (0.1초 단위 정수) 있음: 그룹이 사라지거나 리더가 끝날 때까지 최대 그만큼 기다린 뒤 KILL.
#     리더(감독 프로세스)가 TERM 을 받고 스스로 멤버를 정리하고 상태를 기록할 시간을 주고 (정리 도중 KILL 하지 않음),
#     리더가 끝났는데 남은 것이 있으면 남은 시간을 기다리지 않고 바로 KILL 한다.
#   0 사라짐 / 1 TERM 전에 이미 그룹이 없음(신호 안 보냄) / 2 신호를 보낼 수 없음(신호 안 보냄) / 3 KILL 뒤에도 남음
_cc_proc_signal_group() {
  local pgid="$1" grace="${2:-}"
  if ! kill -TERM -- "-$pgid" 2>/dev/null; then
    _cc_proc_probe "-$pgid"
    [ $? -eq 1 ] && return 1
    return 2
  fi
  if _cc_proc_is_pid "$grace"; then
    _cc_proc_wait_leader_or_group "$pgid" "$grace" && return 0
  else
    _cc_proc_wait_group_gone "$pgid" 30 && return 0
  fi
  kill -KILL -- "-$pgid" 2>/dev/null
  _cc_proc_wait_group_gone "$pgid" 20 && return 0
  cc_err "cc_proc: KILL 뒤에도 프로세스 그룹 $pgid 이(가) 남아 있습니다"
  return 3
}

# cc_kill_group_verified <pgid> <identity> [leader_grace]
#   리더(PID = PGID)의 신원이 맞고 그 프로세스가 실제로 그룹 <pgid> 의 리더일 때만 그룹 전체에
#   TERM 을 보내고, 약 3초 안에 사라지지 않으면 KILL 을 보낸다. 종료 코드는 맨 위 계약(R8).
#   leader_grace(0.1초 단위)를 주면 3초 대신 "리더가 끝날 때까지 최대 그만큼" 기다린 뒤 남은 것에 KILL 한다
#   (_cc_proc_signal_group 참고. wait 의 중단 처리가 감독 프로세스의 마무리를 끊지 않도록 쓴다).
# 리더가 먼저 끝났고 그룹의 다른 프로세스만 살아 있으면 리더 신원을 확인할 수 없으므로 1 을
# 돌려주고 아무것도 죽이지 않는다. 남은 프로세스가 정말 우리 것인지 이 함수는 알 수 없기 때문이다.
# 그 경우는 따로 기록해 둔 멤버(codex)의 신원으로 cc_kill_group_via_member 를 쓴다.
cc_kill_group_verified() {
  local pgid="$1" want="$2" grace="${3:-}"
  _cc_proc_target_pgid_ok "$pgid" || return 2
  _cc_proc_verify_in_group "$pgid" "$want" "$pgid" || return $?
  _cc_proc_signal_group "$pgid" "$grace"
}

# cc_kill_group_via_member <member_pid> <member_identity> <pgid>
#   감독 프로세스(그룹 리더)는 끝났지만 같은 그룹의 codex 가 아직 살아 있을 때 쓴다 (Ruling R9).
#   멤버의 신원이 맞고 그 멤버가 지금 그룹 <pgid> 에 있을 때만 그룹 전체를 끝낸다.
#   종료 코드는 맨 위 계약(R8).
cc_kill_group_via_member() {
  local member="$1" want="$2" pgid="$3"
  _cc_proc_is_pid "$member" || return 2
  _cc_proc_target_pgid_ok "$pgid" || return 2
  _cc_proc_verify_in_group "$member" "$want" "$pgid" || return $?
  _cc_proc_signal_group "$pgid"
}

# cc_kill_own_group_members <leader_pid> [term_secs]
#   그룹 리더(감독 프로세스)가 자기 그룹에 남은 다른 프로세스(codex 와 그 자식 등)를 모두 끝낸다.
#   리더 자신은 건드리지 않는다 (그래서 리더의 TERM 처리기가 돌지 않고, KILL 로 자신이 죽지도 않는다).
#   - 리더의 메인 셸이 직접 불러야 한다. $(...)·파이프·서브셸 안에서 부르면 거부한다:
#     perl 의 부모가 <leader_pid> 이고 perl 의 그룹이 <leader_pid> (= 리더가 자기 그룹의 리더) 여야 한다.
#     리더가 이끄는 그룹에는 리더의 자손만 들어올 수 있으므로 멤버는 모두 우리 프로세스다.
#   - 그룹 전체 신호(kill -- -PGID)는 리더에게도 가므로 쓰지 않는다. ps 로 멤버를 찾고, 멤버마다 신호 직전에
#     그 PID 가 아직 이 그룹인지 다시 확인한 뒤 하나씩 보낸다. 좀비는 이미 끝난 것으로 본다.
#   - TERM → 최대 term_secs 초(기본 3) → 남으면 KILL → 최대 약 2초. 그 사이 새로 생긴 멤버도 처음 보일 때 TERM 을 받는다.
#     (감독 프로세스가 중단 신호를 받았을 때는 멤버도 이미 같은 TERM 을 받았으므로 짧게 1초를 준다)
#   0 = 남은 멤버 없음 (신호를 보냈든 처음부터 없었든) / 2 = 거부·판단 불가 (신호 안 보냄) / 3 = KILL 뒤에도 남음
cc_kill_own_group_members() {
  local leader="$1" term="${2:-3}"
  _cc_proc_is_pid "$leader" || return 2
  case "$term" in ''|*[!0-9]*) term=3 ;; esac
  perl -MTime::HiRes -e '
    my ($leader, $term) = @ARGV;
    exit 2 unless getppid() == $leader && getpgrp(0) == $leader;
    $SIG{$_} = "IGNORE" for qw(TERM INT HUP);
    my $members = sub {
      my $ps = open(my $fh, "-|", "ps", "-A", "-o", "pid=,pgid=,stat=");
      return undef unless $ps;
      my @m;
      while (my $l = <$fh>) {
        my ($p, $g, $s) = split " ", $l;
        next unless defined $s && $p =~ /^[0-9]+$/ && $g =~ /^[0-9]+$/ && $g == $leader;
        next if $p == $leader || $p == $$ || $p == $ps || $s =~ /^Z/;
        push @m, $p;
      }
      close $fh or return undef;
      return \@m;
    };
    my $send = sub { my ($sig, $p) = @_; kill($sig, $p) if getpgrp($p) == $leader };
    my ($sent, %termed) = (0);
    my $until = Time::HiRes::time() + $term;
    while (1) {
      my $m = $members->();
      exit($sent ? 3 : 2) unless defined $m;
      exit 0 unless @$m;
      for my $p (@$m) { next if $termed{$p}++; $send->("TERM", $p); $sent = 1 }
      last if Time::HiRes::time() >= $until;
      Time::HiRes::sleep(0.1);
    }
    $until = Time::HiRes::time() + 2;
    while (1) {
      my $m = $members->();
      exit 3 unless defined $m;
      exit 0 unless @$m;
      $send->("KILL", $_) for @$m;
      last if Time::HiRes::time() >= $until;
      Time::HiRes::sleep(0.1);
    }
    print STDERR "cc_proc: KILL 뒤에도 그룹 $leader 에 프로세스가 남아 있습니다\n";
    exit 3;
  ' -- "$leader" "$term"
}
