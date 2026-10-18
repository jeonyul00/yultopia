# state.sh - git 디렉터리·active 경로, 안전 검사, state.json 읽기/쓰기. source 전용.

# _cc_repo_discover : git 을 부르지 않고 지금 위치의 저장소를 찾는다 (셸 내장 명령만. Codex 보안 검수 1차 1).
#   _CC_DISC_TOP = 작업 트리 루트(.git 이 있는 폴더), _CC_DISC_GITDIR = git 디렉터리의 실제 경로 (.git 폴더, 또는 gitfile 이
#   가리키는 곳). GIT_DIR 이 있으면 그것. 못 찾으면 1. git 의 저장소 찾기와 보통 같은 결과지만 판단은 하지 않는다:
#   격리 기록(아래 cc_git_dir)을 git 없이 찾는 데만 쓴다.
_cc_repo_discover() {
  local d line gp
  _CC_DISC_TOP=""; _CC_DISC_GITDIR=""
  if [ -n "${GIT_DIR:-}" ]; then
    _CC_DISC_GITDIR=$(cd -P "$GIT_DIR" 2>/dev/null && pwd -P) || return 1
    return 0
  fi
  d=$(pwd -P 2>/dev/null) || return 1
  while :; do
    if [ -d "$d/.git" ]; then
      _CC_DISC_GITDIR=$(cd -P "${d%/}/.git" 2>/dev/null && pwd -P) || return 1
      _CC_DISC_TOP=$d
      return 0
    fi
    if [ -f "$d/.git" ]; then
      IFS= read -r line < "${d%/}/.git" || [ -n "$line" ] || return 1
      case "$line" in "gitdir: "?*) gp=${line#gitdir: } ;; *) return 1 ;; esac
      gp=${gp%"${gp##*[![:space:]]}"}
      case "$gp" in /*) ;; *) gp="${d%/}/$gp" ;; esac
      _CC_DISC_GITDIR=$(cd -P "$gp" 2>/dev/null && pwd -P) || return 1
      _CC_DISC_TOP=$d
      return 0
    fi
    [ "$d" = / ] && return 1
    d=${d%/*}; [ -n "$d" ] || d=/
  done
}

# ---- 외부 격리 기록 (Codex 보안 검수 2차, R36) ----
# Codex 를 실행할 때마다 그 전에 저장소 밖(Codex sandbox 가 쓸 수 없는 Claude 쪽 상태 폴더)에 기록을 남기고, 확인을 마쳐야 지운다:
#   ${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/yultopia}/cc/quarantine/<작업 트리 실제 경로(pwd -P)의 sha256>.json
#   = {v, state: armed|tampered|unverified, repo, call_id, baseline: 실행 전 git 설정 지문|null, changed, updated_at}
#   .git 이 아니라 작업 트리 경로로 찾으므로 Codex 가 .git 을 옮기거나 gitfile·링크로 바꿔도 남는다. 쓰기·지우기는 call.sh.
# cc_quarantine_dir : 그 폴더 경로 (만들지 않는다). 정할 수 없으면 1
cc_quarantine_dir() {
  local base="${CLAUDE_PLUGIN_DATA:-}"
  if [ -z "$base" ]; then
    [ -n "${HOME:-}" ] || return 1
    base="$HOME/.claude/plugins/data/yultopia"
  fi
  printf '%s/cc/quarantine\n' "${base%/}"
}
_cc_state_watch_pl() { printf '%s/watch.pl' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"; }

# cc_legacy_running_id <state.json> : 실행 전 트리는 있지만 현재 보안 비교에 필요한 git 설정 지문/무시 파일 manifest/하위 모듈
# allowlist 중 하나가 없는 옛 running 기록의 호출 번호. 없거나 읽을 수 없으면 빈 출력. git 을 부르지 않는다.
cc_legacy_running_id() {
  jq -r 'if (.running | type) == "object" and (.running.pre_tree | type) == "string"
      and ((.running.pre_gitcfg | type) != "object" or (.running.pre_submodules | type) != "array"
           or (.running.pre_ignored | type) != "string")
    then (.running.call_id // "?" | tostring) else empty end' "$1" 2>/dev/null
}

# _cc_quarantine_find : 지금 위치(pwd -P)와 그 위 폴더들 중 외부 격리 기록이 있는 작업 트리를 찾는다. git 을 부르지 않는다.
#   0 찾음(_CC_Q_FILE, _CC_Q_ROOT) / 1 없음 / 2 확인할 수 없음 (기록 폴더를 읽을 수 없음 등: 막는 쪽으로 다룬다)
#   기록 폴더가 없거나 비어 있으면 셸 내장 명령만 쓴다 (훅이 빠르도록. 폴더를 만들지도 않는다)
_cc_quarantine_find() {
  local qdir start out r
  _CC_Q_FILE=""; _CC_Q_ROOT=""
  qdir=$(cc_quarantine_dir) || return 1
  [ -e "$qdir" ] || [ -L "$qdir" ] || return 1
  { [ -d "$qdir" ] && [ -r "$qdir" ] && [ -x "$qdir" ]; } || return 2
  set -- "$qdir"/*.json
  [ -e "$1" ] || [ -L "$1" ] || return 1
  start=$(pwd -P 2>/dev/null) || return 2
  out=$(perl "$(_cc_state_watch_pl)" qfind "$qdir" "$start"); r=$?
  case "$r" in 0) ;; 1) return 1 ;; *) return 2 ;; esac
  _CC_Q_FILE=${out%%$'\n'*}; _CC_Q_ROOT=${out#*$'\n'}
  [ -n "$_CC_Q_FILE" ] && [ -n "$_CC_Q_ROOT" ] || return 2
  return 0
}

# 절대 git 디렉터리. 실패 시 1.
#   _CC_GITDIR_OVERRIDE 가 있으면 그것 (git 을 부르지 않는다: 격리 중인 cc-codex.sh, 그리고 실행 전에 경로를 정한 감독 프로세스).
#   외부 격리 기록(위)이 있거나 확인할 수 없으면 git 없이 찾은 경로를 쓴다 (훅 포함. 바뀐 설정으로 git 을 돌리지 않도록:
#   Codex 보안 검수 1·2차). cc-codex.sh 가 진입 확인을 마쳤으면(_CC_QCHECKED=1) 다시 찾지 않는다. 그 밖에는 git rev-parse.
cc_git_dir() {
  local d
  if [ -n "${_CC_GITDIR_OVERRIDE:-}" ]; then
    printf '%s\n' "$_CC_GITDIR_OVERRIDE"
    return 0
  fi
  if [ "${_CC_QCHECKED:-0}" != 1 ]; then
    _cc_quarantine_find
    if [ $? -ne 1 ]; then
      _cc_repo_discover || return 1
      printf '%s\n' "$_CC_DISC_GITDIR"
      return 0
    fi
  fi
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
#   - 잠금 자리(state.lock)는 진짜 폴더, 그 안의 owner 는 보통 파일이어야 한다 (lstat 으로 본다. Codex 리뷰 2, R30).
#     심볼릭 링크 등이면 따라가서 읽거나 그 안의 것을 지우지 않고 곧바로 거부한다 (링크를 따라가면 active 밖의 파일을
#     지울 수 있었다). 옮긴 자리도 진짜 폴더임을 다시 확인한 뒤에만 그 안의 owner 를 지운다.
#   PID 는 perl 의 getppid() 로 얻는다. bash 3.2 의 $$ 는 서브셸에서도 바깥 셸 PID 라서 쓸 수 없다.
: "${CC_STATE_LOCK_WAIT_SECS:=5}"
_CC_STATE_LOCK_DEPTH=0

# 두 perl 이 함께 쓰는 owner 읽기: 소유자 PID 문자열 ("" = 잠금·owner 없음 또는 빈 파일),
#   undef = 잠금 자리가 진짜 폴더가 아니거나 owner 가 보통 파일이 아님 (따라가지 않는다)
_CC_STATE_OWNER_OF='
  use Fcntl qw(O_RDONLY O_NOFOLLOW);
  sub cc_owner_of {
    my ($d) = @_;
    my @s = lstat($d);
    return ($!{ENOENT} ? "" : undef) unless @s;
    return undef unless -d _;               # lstat 이므로 심볼릭 링크는 폴더가 아니다
    @s = lstat("$d/owner");
    return ($!{ENOENT} ? "" : undef) unless @s;
    return undef unless -f _;
    sysopen(my $f, "$d/owner", O_RDONLY | O_NOFOLLOW) or return ($!{ENOENT} ? "" : undef);
    my $p = <$f>; close $f;
    $p = "" unless defined $p; chomp $p; return $p;
  }
'

# 0 잡음 / 1 시간 안에 못 잡음·오류·잠금 자리 비정상(거부)
cc_state_lock() {
  local a
  if [ "${_CC_STATE_LOCK_DEPTH:-0}" -gt 0 ]; then
    _CC_STATE_LOCK_DEPTH=$((_CC_STATE_LOCK_DEPTH + 1))
    return 0
  fi
  a=$(cc_active_dir) || return 1
  [ -d "$a" ] || return 1
  perl -MTime::HiRes -MFcntl=:flock -e "$_CC_STATE_OWNER_OF"'
    my ($lock, $wait, $dir) = @ARGV;
    my $me = getppid();
    my $deadline = Time::HiRes::time() + $wait;
    my $abnormal = sub {
      print STDERR "[cc] state.json 잠금 자리가 진짜 폴더가 아니거나 owner 가 보통 파일이 아니라(심볼릭 링크 등) 잠그지 않았습니다: $lock\n";
      exit 3;
    };
    while (1) {
      my $tmp = "$lock.tmp.$me.$$." . int(rand(1e9));
      mkdir $tmp or exit 1;
      my $f;
      my $ok = open($f, ">", "$tmp/owner") && print($f "$me\n") && close($f);
      if ($ok && rename($tmp, $lock)) { exit 0 }
      unlink "$tmp/owner"; rmdir $tmp;
      exit 1 unless $ok;
      my $p = cc_owner_of($lock);
      $abnormal->() unless defined $p;
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
        my $q = $may ? cc_owner_of($lock) : "";
        $abnormal->() unless defined $q;
        if ($may && $q eq $p) {
          my $gone = "$lock.stale.$me.$$." . int(rand(1e9));
          if (rename($lock, $gone)) {
            # 옮긴 자리가 진짜 폴더이고 owner 가 보통 파일일 때만 그 안을 지운다
            my $g = cc_owner_of($gone);
            if (defined $g && $g eq $p) {
              unlink "$gone/owner"; rmdir $gone;
              $broke = 1;
            } elsif (!rename($gone, $lock)) {
              # 살아 있는 잠금(또는 비정상 자리)을 옮겼는데 되돌릴 자리를 이미 다른 쪽이 잡았다. 지우지 않고 남겨 둔다.
              print STDERR "[cc] state.json 잠금을 되돌리지 못했습니다: $gone\n";
            }
            $abnormal->() unless defined $g;
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
  perl -e "$_CC_STATE_OWNER_OF"'
    my ($lock) = @ARGV;
    my $me = getppid();
    my $p = cc_owner_of($lock);
    exit 1 unless defined $p && $p eq $me;
    my $gone = "$lock.rel.$me.$$." . int(rand(1e9));
    rename($lock, $gone) or exit 1;
    # 옮긴 자리가 여전히 진짜 폴더일 때만 그 안을 지운다. 아니면 되돌리고 아무것도 지우지 않는다.
    my $g = cc_owner_of($gone);
    if (defined $g) { unlink "$gone/owner"; rmdir $gone; exit 0 }
    rename($gone, $lock);
    exit 1;
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
