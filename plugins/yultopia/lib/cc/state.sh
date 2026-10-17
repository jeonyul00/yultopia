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

# ---- state.json 잠금 (Ruling R11) ----
# 여러 프로세스(call, 감독 프로세스, wait …)가 state.json 을 읽고-고쳐-쓰므로 갱신은 잠금 안에서 한다.
#   잠금 = active/state.lock 디렉터리, 안의 owner 파일 = 잠금을 잡은 셸의 PID.
#   - 잡기: 임시 디렉터리에 owner 를 먼저 써 두고 rename 으로 state.lock 자리에 놓는다.
#     rename 은 비어 있지 않은 디렉터리를 덮지 못하므로 한 쪽만 성공하고, owner 가 빈 잠금은 생기지 않는다.
#   - 기다리기: 최대 CC_STATE_LOCK_WAIT_SECS 초(기본 5).
#   - 소유자가 확실히 죽었을 때(kill 0 → ESRCH)만 잠금을 치운다. 권한 없음·판단 불가면 살아 있다고 본다.
#     치우는 쪽끼리는 active 폴더의 flock 으로 한 번에 하나만 "owner 재확인 → rename" 을 한다. 그래서 다른
#     대기자가 같은 낡은 잠금을 먼저 치우고 새로 잡은 잠금을 이쪽이 옮겨 버리는 일이 없다 (flock 은 프로세스가
#     끝나면 저절로 풀려 낡은 상태로 남지 않는다). 옮긴 뒤 owner 가 치우려던 죽은 PID 가 아니면 제자리로 되돌린다.
#   - owner 가 자기 PID 면 자기 잠금이다 (잡은 직후 신호로 깊이 기록만 잃은 경우). 그대로 잡은 것으로 본다.
#   - 풀기: owner 가 자기일 때만 다른 이름으로 rename 한 뒤 지운다.
#   - 같은 셸 안에서는 다시 잡아도 된다(깊이만 센다). 이 값은 export 하지 않으므로 자식 프로세스로 넘어가지 않는다.
#   PID 는 perl 의 getppid() 로 얻는다. bash 3.2 의 $$ 는 서브셸에서도 바깥 셸 PID 라서 쓸 수 없다.
: "${CC_STATE_LOCK_WAIT_SECS:=5}"
_CC_STATE_LOCK_DEPTH=0

# 0 잡음 / 1 시간 안에 못 잡음·오류
cc_state_lock() {
  local a
  if [ "${_CC_STATE_LOCK_DEPTH:-0}" -gt 0 ]; then
    _CC_STATE_LOCK_DEPTH=$((_CC_STATE_LOCK_DEPTH + 1))
    return 0
  fi
  a=$(cc_active_dir) || return 1
  [ -d "$a" ] || return 1
  perl -MTime::HiRes -MFcntl=:flock -e '
    my ($lock, $wait, $dir) = @ARGV;
    my $me = getppid();
    my $deadline = Time::HiRes::time() + $wait;
    my $owner_of = sub {
      open(my $f, "<", "$_[0]/owner") or return "";
      my $p = <$f>; close $f;
      $p = "" unless defined $p; chomp $p; return $p;
    };
    while (1) {
      my $tmp = "$lock.tmp.$me.$$." . int(rand(1e9));
      mkdir $tmp or exit 1;
      my $f;
      my $ok = open($f, ">", "$tmp/owner") && print($f "$me\n") && close($f);
      if ($ok && rename($tmp, $lock)) { exit 0 }
      unlink "$tmp/owner"; rmdir $tmp;
      exit 1 unless $ok;
      my $p = $owner_of->($lock);
      # 자기 PID 의 잠금: 잡은 직후 신호 처리로 깊이 기록만 잃은 경우다 (살아 있는 PID 는 하나뿐). 그대로 쓴다.
      exit 0 if $p eq $me;
      if ($p =~ /^[1-9][0-9]*$/ && !kill(0, $p) && $!{ESRCH}) {
        # 소유자가 확실히 없다. 치우는 쪽끼리 flock 으로 줄을 세운 뒤, 그 사이 다른 쪽이 치우고 새로 잡지
        # 않았는지 owner 를 한 번 더 보고 치운다. 다른 쪽이 치우는 중이면 잠깐 기다렸다 처음부터 다시 본다.
        # (flock 을 쓸 수 없는 파일 시스템이면 아래 "옮긴 뒤 확인·되돌리기" 에만 기댄다)
        my ($bf, $may) = (undef, 1);
        if (open($bf, "<", $dir)) {
          if (!flock($bf, LOCK_EX | LOCK_NB)) { $may = 0 if $!{EWOULDBLOCK} || $!{EAGAIN} || $!{EINTR} }
        } else { undef $bf }
        my $broke = 0;
        if ($may && $owner_of->($lock) eq $p) {
          my $gone = "$lock.stale.$me.$$." . int(rand(1e9));
          if (rename($lock, $gone)) {
            if ($owner_of->($gone) eq $p) {
              unlink "$gone/owner"; rmdir $gone;
              $broke = 1;
            } elsif (!rename($gone, $lock)) {
              # 살아 있는 잠금을 옮겼는데 되돌릴 자리를 이미 다른 쪽이 잡았다. 지우지 않고 남겨 둔다.
              print STDERR "[cc] state.json 잠금을 되돌리지 못했습니다: $gone\n";
            }
          }
        }
        close $bf if $bf;
        next if $broke;
      }
      exit 1 if Time::HiRes::time() >= $deadline;
      Time::HiRes::sleep(0.05);
    }
  ' -- "$a/state.lock" "$CC_STATE_LOCK_WAIT_SECS" "$a" || return 1
  _CC_STATE_LOCK_DEPTH=1
}

cc_state_unlock() {
  local a
  [ "${_CC_STATE_LOCK_DEPTH:-0}" -gt 0 ] || return 0
  _CC_STATE_LOCK_DEPTH=$((_CC_STATE_LOCK_DEPTH - 1))
  [ "$_CC_STATE_LOCK_DEPTH" -eq 0 ] || return 0
  a=$(cc_active_dir) || return 1
  perl -e '
    my ($lock) = @ARGV;
    my $me = getppid();
    open(my $f, "<", "$lock/owner") or exit 1;
    my $p = <$f>; close $f;
    $p = "" unless defined $p; chomp $p;
    exit 1 unless $p eq $me;
    my $gone = "$lock.rel.$me.$$." . int(rand(1e9));
    rename($lock, $gone) or exit 1;
    unlink "$gone/owner"; rmdir $gone;
    exit 0;
  ' -- "$a/state.lock"
}

# 잠금 없이 한 번 갱신 (cc_state_update 와 잠금을 이미 잡은 호출자만 쓴다)
_cc_state_update_nolock() {
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

# cc_state_update <jq-filter> [--arg k v ...] : 잠금 안에서 임시 파일 + mv 로 원자적 쓰기, last_activity_at 갱신
#   잠금을 못 잡으면 쓰지 않고 1. 갱신이 실패해도 잠금은 항상 푼다.
cc_state_update() {
  local rc
  if ! cc_state_lock; then
    cc_err "[cc] state.json 잠금을 얻지 못했습니다"
    return 1
  fi
  _cc_state_update_nolock "$@"
  rc=$?
  cc_state_unlock
  return "$rc"
}

# 안전 검사를 통과할 때만 active 를 정확한 경로로 삭제
cc_delete_active() {
  local a
  cc_active_path_safe || return 1
  a=$(cc_active_dir) || return 1
  rm -rf "$a"
}
