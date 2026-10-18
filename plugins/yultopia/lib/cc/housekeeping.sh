# housekeeping.sh - 고아 Codex 확인(check-orphan), 14일 정리(cleanup-stale), 시작 전 확인(preflight), 버리기·마무리.
# source 전용 (bash 3.2 호환). common.sh, state.sh, proc.sh, call.sh, wait.sh 뒤에 불러온다
# (call.sh 의 _cc_call_liveness·_cc_jq_get·_cc_sup_uint, wait.sh 의 _cc_wait_stop_group·_cc_wait_settle 을 쓴다).
#
# 판단 기준 (Task 8 addendum B)
#   기록된 호출이 아직 돌 수 있는지는 call·wait 와 같은 _cc_call_liveness 하나로 정한다: none | alive | dead | uncertain.
#   "확실히 안 돎" 은 none·dead 뿐이다. uncertain 을 근거로 지우거나 죽이지 않는다 (R8: 2 는 상태 삭제의 근거가 아님).
#   dead 를 확인하면 그 자리에서 state 를 정리한다: running=null, last_call.status=interrupted, phase=interrupted,
#   status 파일 == state (wait 가 기록 없이 죽은 호출을 정리할 때와 같은 값·같은 도우미).
#   running.stop_failed 기록(끝 상태는 기록됐지만 종료를 확인하지 못해 남긴 기록, R30)도 똑같이 판단한다. 살아 있거나
#   남은 그룹이면 고아로 알리고 지우지 않는다. dead 가 되면 running 만 지운다 (이미 기록된 끝 상태는 그대로).
#
# 고아 (addendum C): 다음을 모두 만족
#   1) alive, 또는 uncertain 이지만 "감독 프로세스·codex 는 확실히 없는데 그룹에 무언가 남음"(남은 그룹, addendum D)
#   2) waiter 가 없거나, 기록된 대기자가 확실히 끝났음 (cc_proc_alive_verified 1. 신원을 기록하지 못한 대기자는
#      그 PID 가 아예 없을 때만 끝난 것으로 본다). 살아 있거나 판단할 수 없는 대기자는 있는 것으로 본다.
#   3) 지금 - 기준 시각 > CC_ORPHAN_GRACE_SECS. 기준 시각 = waiter_last_seen_at 과 running.started_at 중 늦은 쪽
#      (이 호출을 한 번도 기다리지 않았으면 waiter_last_seen_at 은 앞 호출의 것이므로 호출 시작부터 센다).
#      사용자가 직접 시킨 check-orphan --kill 은 3) 을 건너뛴다 (cc_is_orphan --no-grace). 1)·2) 는 그대로다.
#   남은 그룹은 우리 것인지 확인할 수 없어 --kill 이어도 죽이지 않고, 사용자가 직접 볼 수 있게 PGID 와 ps 명령을 알린다.
#
# 삭제 (cleanup-stale, discard, finish): 확인된 <git-dir>/yultopia-cc/active 정확한 경로에만 (cc_delete_active).
#   state 잠금을 쥔 채 다시 읽고 다시 판단한 뒤 지운다 (그 사이 다른 call 이 시작했으면 지우지 않는다).
#   잠금 폴더는 active 안에 있어 함께 지워진다. 그 뒤 잠금을 기다리던 쪽은 잠금을 못 잡고 실패한다 (아무것도 쓰지 않음).
#   state 를 읽을 수 없거나 running 이 깨진 기록은 discard·finish 만, 명령줄에 이 active 경로를 가진 프로세스(codex·감독
#   프로세스)가 없음을 ps 로 확인한 뒤에 지운다 (R30). 있거나 ps 가 실패하면 지우지 않고(6) 그 PID·그룹을 알린다. 신호는 없다.
#
# 전역 (이 파일 안에서만): _CC_HK_ST(읽은 state JSON), _CC_HK_RS(none|alive|dead|uncertain|unreadable|fresh),
#   _CC_HK_LEFTOVER(1 = 남은 그룹), _CC_HK_PG(기록된 pgid), _CC_HK_ID(running.call_id), _CC_HK_LINE(알릴 한 줄),
#   _CC_HK_DIRTY / _CC_HK_DIRTY_N (preflight 의 변경 파일 최대 10개 / 전체 개수)
# 공개 (Task 9 훅도 쓴다): cc_running_state, cc_is_orphan 과 그 결과
#   CC_ORPHAN_LINE(한 줄), CC_ORPHAN_KIND(alive|leftover), CC_ORPHAN_CALL_ID, CC_ORPHAN_MINUTES, CC_ORPHAN_PGID

_CC_HK_STALE_UNREADABLE="[cc] 오래된 /cc 기록 상태를 확인할 수 없어 지우지 않았습니다"
_CC_HK_JSON_NOT_GIT='{"ok":false,"code":"not_git","message":"[cc] git 저장소가 아닙니다. /cc 는 git 저장소 안에서만 시작할 수 있습니다.","dirty_files":[],"stale_notice":null,"active":null}'
_CC_HK_JSON_NO_JQ='{"ok":false,"code":"no_jq","message":"[cc] jq 가 설치돼 있지 않아 /cc 를 시작할 수 없습니다. jq 를 설치한 뒤 다시 실행하세요.","dirty_files":[],"stale_notice":null,"active":null}'

# 호출 번호처럼 보이는가 (양의 정수, 앞자리 0 없음, 9자리 이하)
_cc_hk_valid_id() {
  case "$1" in ''|0*|*[!0-9]*|??????????*) return 1 ;; esac
  return 0
}

# state.json 을 한 줄 JSON 으로 (객체 하나가 아니면 1)
_cc_hk_read_state() {
  local a
  a=$(cc_active_dir) || return 1
  jq -cse 'if length == 1 and (.[0] | type) == "object" then .[0] else error("not one object") end' \
    "$a/state.json" 2>/dev/null
}

# _cc_hk_classify : state 를 읽어 분류만 한다 (아무것도 쓰지 않음). 읽지 못하면 _CC_HK_RS=unreadable, 1
_cc_hk_classify() {
  _CC_HK_RS=unreadable; _CC_HK_LEFTOVER=0; _CC_HK_PG=""; _CC_HK_ID=""; _CC_HK_MALFORMED=0
  _CC_HK_ST=$(_cc_hk_read_state) || { _CC_HK_ST=""; return 1; }
  _cc_call_liveness "$_CC_HK_ST"
  _CC_HK_RS=$_CC_LIVENESS; _CC_HK_LEFTOVER=$_CC_LIVENESS_LEFTOVER; _CC_HK_PG=$_CC_LIVENESS_PGID
  _CC_HK_ID=$(_cc_jq_get "$_CC_HK_ST" 'if (.running | type) == "object" then (.running.call_id // empty | tostring) else empty end')
  # running 기록이 온전하지 않으면 (_cc_running_wellformed) 읽을 수 없는 기록 (discard·finish 만, 이 작업의 프로세스가
  # 없음을 확인한 뒤에 지운다: _cc_hk_delete_if_idle, R30)
  _cc_running_wellformed "$_CC_HK_ST" || _CC_HK_MALFORMED=1
  return 0
}

# _cc_hk_running_state : 분류하고, dead 면 그 자리에서 state 를 정리한다 (running.call_id 가 그대로일 때만 바뀐다)
#   호출 번호가 이상한 기록은 고치지 않는다 (call 은 dead 를 "실행 중 아님" 으로 보고 새 기록으로 덮어쓴다).
_cc_hk_running_state() {
  _cc_hk_classify || return 1
  if [ "$_CC_HK_RS" = dead ] && _cc_hk_valid_id "$_CC_HK_ID"; then
    _CC_WAIT_ACTIVE=$(cc_active_dir)
    _CC_WAIT_SETTLE_WRITER=_cc_wait_update_keep_activity   # 정리는 활동이 아니다: last_activity_at 유지
    _cc_wait_settle "$_CC_HK_ID" interrupted \
      "[cc] Codex 감독 프로세스가 결과를 남기지 않고 끝나 호출 $_CC_HK_ID 을(를) 중단됨으로 기록했습니다." >/dev/null
    _CC_WAIT_SETTLE_WRITER=_cc_state_update_nolock
    _CC_HK_ST=$(_cc_hk_read_state) || _CC_HK_ST=""
  fi
  return 0
}

# cc_running_state : none | alive | dead | uncertain 한 줄. dead 면 state 를 정리한다. state 를 읽지 못하면 uncertain, 1
cc_running_state() {
  if _cc_hk_running_state; then
    printf '%s\n' "$_CC_HK_RS"
    return 0
  fi
  printf 'uncertain\n'
  return 1
}

# 남은 그룹 안내 (앞말 + 같은 뒷말). _CC_HK_PG 는 이때 형식이 맞는 PID 다 (_cc_call_liveness 의 r1=1)
_cc_hk_leftover_line() {
  printf '%s확인할 수 없는 프로세스가 프로세스 그룹 %s 에 남아 있습니다. /cc 는 이것을 자동으로 종료하지 않습니다. 확인: ps -o pid,command -g %s' \
    "$1" "$_CC_HK_PG" "$_CC_HK_PG"
}

# cc_is_orphan [--no-grace] : 0 = 고아 (CC_ORPHAN_* 에 결과) / 1 = 아님 (작업 없음·경로 비정상·읽기 실패 포함. 읽기 실패면 _CC_HK_RS=unreadable)
#   $(...) 안에서 부르면 결과 변수가 사라지므로 직접 부른다. dead 기록은 정리한다. 아무것도 죽이지 않는다.
#   --no-grace: 조건 3(유예)만 건너뛴다. 사용자가 직접 멈추라고 한 check-orphan --kill 만 쓴다 (최종 리뷰 Important 1:
#     Esc 직후에는 유예 60초 동안 멈출 방법이 없었다). 대기자 조건(2)과 신원·그룹 확인은 그대로다.
#     알리기만 하는 쪽(메시지 훅, 평소 check-orphan, preflight)은 유예를 지킨다.
cc_is_orphan() {
  local wp wid r grace age min id no_grace=0
  [ "${1:-}" = --no-grace ] && no_grace=1
  CC_ORPHAN_LINE=""; CC_ORPHAN_KIND=""; CC_ORPHAN_CALL_ID=""; CC_ORPHAN_MINUTES=""; CC_ORPHAN_PGID=""
  _CC_HK_RS=""
  cc_active_exists && cc_active_path_safe || return 1
  _cc_hk_running_state || return 1
  case "$_CC_HK_RS" in
    alive) ;;
    uncertain) [ "$_CC_HK_LEFTOVER" = 1 ] || return 1 ;;
    *) return 1 ;;
  esac
  wp=$(_cc_jq_get "$_CC_HK_ST" 'if (.waiter | type) == "object" then (.waiter.pid | tostring) else empty end')
  if [ -n "$wp" ]; then
    wid=$(_cc_jq_get "$_CC_HK_ST" '.waiter.identity // empty')
    cc_proc_alive_verified "$wp" "$wid"; r=$?
    # 신원을 기록하지 못한 대기자(등록 때 ps 실패)라도 그 PID 가 아예 없으면 확실히 끝난 것
    if [ "$r" -eq 2 ] && _cc_proc_is_pid "$wp"; then
      _cc_proc_probe "$wp"; [ $? -eq 1 ] && r=1
    fi
    [ "$r" -eq 1 ] || return 1
  fi
  grace=$(_cc_sup_uint "${CC_ORPHAN_GRACE_SECS:-}" 60)
  read -r age min <<EOF
$(printf '%s' "$_CC_HK_ST" | jq -r '
    def t($x): try ($x | fromdateiso8601) catch null;
    t(.running.started_at) as $s
    | ([t(.waiter_last_seen_at), $s] | map(select(type == "number"))) as $b
    | "\(if ($b | length) == 0 then "-" else (now - ($b | max) | floor) end) \(if $s == null then "?" else ((now - $s) / 60 | floor | if . < 0 then 0 else . end) end)"' 2>/dev/null)
EOF
  if [ "$no_grace" = 0 ]; then
    case "$age" in ''|-|*[!0-9-]*|?*-*) return 1 ;; esac
    [ "$age" -gt "$grace" ] || return 1
  fi
  case "$min" in ''|*[!0-9]*) min="?" ;; esac
  id=$_CC_HK_ID; _cc_hk_valid_id "$id" || id="?"
  CC_ORPHAN_CALL_ID=$id; CC_ORPHAN_MINUTES=$min; CC_ORPHAN_PGID=$_CC_HK_PG
  if [ "$_CC_HK_RS" = alive ]; then
    CC_ORPHAN_KIND=alive
    CC_ORPHAN_LINE="[cc] 기다리는 대기 명령 없이 Codex가 실행 중입니다 (호출 $id, 경과 ${min}분)"
  else
    CC_ORPHAN_KIND=leftover
    CC_ORPHAN_LINE=$(_cc_hk_leftover_line "[cc] Codex 호출 $id 의 감독 프로세스와 Codex는 끝났지만 ")
  fi
  return 0
}

# _cc_hk_kill_orphan : cc_is_orphan 이 고아(alive)로 본 호출을 wait 의 중단 처리와 같은 방법으로 끝낸다 (addendum A).
#   감독 프로세스 그룹에 TERM → 감독 프로세스가 스스로 멤버를 정리하고 기록할 때까지 기다림 → 남은 것에 KILL
#   (_cc_wait_stop_group). 감독 프로세스가 없으면 기록된 codex 신원으로 그룹을 끝낸다. 끝냈으면 _cc_wait_settle 로
#   running.call_id 가 그대로일 때만 interrupted 를 기록하고 status 파일을 state 에 맞춘다.
#   확인할 수 없어 거부되면(2) 아무것도 바꾸지 않는다. 결과 한 줄은 _CC_HK_LINE.
#   정리하는 동안 INT/TERM/HUP 은 무시한다 (끝 상태를 남기기 전에 끊기지 않도록).
_cc_hk_kill_orphan() {
  local st="$_CC_HK_ST" id="$CC_ORPHAN_CALL_ID" pg sid cp cid r=2 final="" i note
  pg=$(_cc_jq_get "$st" '.running.pgid // empty | tostring')
  sid=$(_cc_jq_get "$st" '.running.supervisor_identity // empty')
  cp=$(_cc_jq_get "$st" '.running.codex_pid // empty | tostring')
  cid=$(_cc_jq_get "$st" '.running.codex_identity // empty')
  trap '' INT TERM HUP
  _CC_WAIT_ACTIVE=$(cc_active_dir)
  if _cc_hk_valid_id "$id"; then
    _cc_wait_stop_group "$pg" "$sid" "$cp" "$cid"; r=$?
  fi
  case "$r" in
    0)
      for i in 1 2 3; do
        final=$(_cc_wait_settle "$id" interrupted "[cc] 기다리는 대기 명령 없이 실행 중이던 Codex를 종료했습니다 (호출 $id).") && break
        sleep 1
      done
      # 감독 프로세스가 마무리하며 Codex 의 프로젝트 파일 수정(codex_modified)이나 확인 실패를 기록했으면 줄 끝에 붙인다 (R32)
      note=$(_cc_wait_edit_note "$id" "$final")
      # 이 중단 처리 때문에 감독 프로세스가 수정 감시 결과(codex_modified, 확인 실패 error)를 기록하고 끝난 경우도 "멈춤" 이다
      if [ -z "$final" ] || [ "$final" = interrupted ] || [ "$final" = codex_modified ] \
         || { [ "$final" = error ] && [ -n "$note" ]; }; then
        _CC_HK_LINE="[cc] 남아 있던 Codex를 종료했습니다${note:+ · $note}"
      else
        _CC_HK_LINE="[cc] Codex 호출 $id 은(는) 종료하기 전에 이미 끝나 있었습니다 ($final)${note:+ · $note}"
      fi ;;
    3)
      # 종료를 확인하지 못했다: 끝 상태는 기록하되 프로세스 기록(running)은 남겨 계속 추적한다 (R30)
      _cc_wait_settle "$id" interrupted \
        "[cc] 남아 있던 Codex를 종료하려 했지만 일부 프로세스가 KILL 뒤에도 남아 있습니다 (호출 $id)." keep >/dev/null
      _CC_HK_LINE="[cc] 남아 있던 Codex를 종료하려 했지만 일부 프로세스가 KILL 뒤에도 남아 있습니다 (호출 $id)" ;;
    *)
      _CC_HK_LINE="[cc] 기다리는 대기 명령 없이 Codex가 실행 중이지만 안전하게 종료할 수 있는지 확인하지 못해 종료하지 않았습니다 (호출 $id)" ;;
  esac
  trap - INT TERM HUP
}

# cc-codex.sh check-orphan [--kill]
#   고아가 아니면 출력 없이 0. 고아면 한 줄, 10. --kill 이면 검증 후 종료하고 결과 한 줄, 10.
#   남은 그룹(확인할 수 없는 프로세스)은 --kill 이어도 죽이지 않고 안내 한 줄, 10.
#   --kill 은 사용자가 직접 멈추라고 할 때만 SKILL 이 부른다: 유예(CC_ORPHAN_GRACE_SECS)를 기다리지 않는다.
#   살아 있거나 판단할 수 없는 대기자가 있으면 --kill 이어도 아무것도 하지 않는다 (0, 출력 없음).
cc_cmd_check_orphan() {
  local kill=0 grace_opt=""
  case "$#:${1:-}" in
    0:) ;;
    1:--kill) kill=1; grace_opt=--no-grace ;;
    *) cc_line "[cc] 사용법: check-orphan [--kill]"; return 1 ;;
  esac
  cc_git_dir >/dev/null 2>&1 || return 0
  cc_active_exists || return 0
  cc_active_path_safe || { cc_line "[cc] 상태 폴더 경로가 비정상입니다."; return 1; }
  if ! cc_is_orphan $grace_opt; then
    if [ "$_CC_HK_RS" = unreadable ]; then
      cc_line "[cc] 상태 파일을 읽을 수 없어 고아 Codex를 확인하지 못했습니다."
      return 1
    fi
    return 0
  fi
  if [ "$kill" = 1 ] && [ "$CC_ORPHAN_KIND" = alive ]; then
    _cc_hk_kill_orphan
    cc_line "$_CC_HK_LINE"
  else
    cc_line "$CC_ORPHAN_LINE"
  fi
  return 10
}

# ---- 14일 정리 (스펙 5-4) ----
# state 의 last_activity_at 으로부터 지난 초 (파일 mtime 은 쓰지 않는다). 없음·형식 오류·읽기 실패면 1
_cc_hk_activity_age() {
  local a age
  a=$(cc_active_dir) || return 1
  age=$(jq -sr '
      (if length == 1 and (.[0] | type) == "object" then .[0].last_activity_at else null end)
      | if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
        then (now - fromdateiso8601) | floor else error("bad last_activity_at") end' "$a/state.json" 2>/dev/null) || return 1
  case "$age" in ''|-|*[!0-9-]*|?*-*) return 1 ;; esac
  printf '%s\n' "$age"
}

_cc_hk_stale_limit() { printf '%s\n' $(( $(_cc_sup_uint "${CC_STALE_DAYS:-}" 14) * 86400 )); }

# _cc_hk_task_procs : 이 작업의 Codex·감독 프로세스로 보이는 프로세스를 찾는다. 아무 신호도 보내지 않는다 (R30).
#   state 를 읽을 수 없거나 running 이 깨져 실행 기록으로는 Codex 가 도는지 알 수 없을 때, 버리기·마무리 전에만 쓴다.
#   명령줄에 이 저장소의 active 경로가 (바로 뒤에 "/"·공백·끝이 오는 꼴로) 들어 있는 프로세스를 찾는다:
#   codex 는 -o <active>/calls/<n>/result.json, 감독 프로세스는 _supervise <n> <active> 로 실행된다 (call.sh).
#   macOS 의 LC_ALL=C ps 는 비ASCII·제어 문자를 vis(3) 꼴(한글 바이트 → M-m, M^U … / 탭·줄바꿈 → \011, \012)로 보여
#   주므로, 경로를 같은 꼴로 바꾼 것과 원래 경로 둘 다로 찾는다. 경로는 환경변수로 넘긴다 (찾는 perl 자신의 명령줄에
#   나오지 않도록). 이 판단은 지울지 말지에만 쓴다: 찾은 프로세스가 우리 것인지 확인하지 않으므로 죽이지 않는다.
#   0 = 찾음: _CC_HK_PROCS = "PID 123 (그룹 120), …" (최대 5개, 나머지는 "외 N개"), _CC_HK_PROC_PGS = 그룹 번호들
#   1 = 없음 / 2 = 판단 불가 (ps 실패, 목록이 비었거나 이상함)
_cc_hk_task_procs() {
  local a out rc pid pg n=0 more=0
  _CC_HK_PROCS=""; _CC_HK_PROC_PGS=""
  a=$(cc_active_dir) || return 2
  out=$(CC_HK_SCAN_PATH="$a" LC_ALL=C perl -e '
    my $a = $ENV{CC_HK_SCAN_PATH};
    exit 2 unless defined $a && length $a;
    sub vis {
      my $o = "";
      for my $c (unpack("C*", $_[0])) {
        if ($c >= 0x20 && $c < 0x7f) { $o .= chr($c); next }
        if ($c == 0x09 || $c == 0x0a || ($c & 0x7f) == 0x20) { $o .= sprintf("\\%03o", $c); next }
        my $m = ($c & 0x80) ? "M" : "";
        $c &= 0x7f;
        $o .= ($c < 0x20 || $c == 0x7f) ? $m . "^" . ($c == 0x7f ? "?" : chr($c + 64)) : $m . "-" . chr($c);
      }
      return $o;
    }
    my @pats = ($a);
    my $v = vis($a);
    push @pats, $v if $v ne $a;
    open(my $fh, "-|", "ps", "-A", "-ww", "-o", "pid=,pgid=,command=") or exit 2;
    my ($seen, @hits) = (0);
    while (my $l = <$fh>) {
      chomp $l;
      my ($pid, $pg, $cmd) = $l =~ /^\s*([0-9]+)\s+([0-9]+)\s(.*)$/ or next;
      $seen++;
      next if $pid == $$;
      for my $p (@pats) { if ($cmd =~ /\Q$p\E(?:[\/ ]|$)/) { push @hits, "$pid $pg"; last } }
    }
    close $fh or exit 2;
    exit 2 unless $seen;
    print "$_\n" for @hits;
    exit(@hits ? 0 : 1);
  ' 2>/dev/null)
  rc=$?
  case "$rc" in
    0) ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
  while read -r pid pg; do
    _cc_proc_is_pid "$pid" && _cc_proc_is_pid "$pg" || continue
    if [ "$n" -lt 5 ]; then _CC_HK_PROCS="${_CC_HK_PROCS:+$_CC_HK_PROCS, }PID $pid (그룹 $pg)"; else more=$((more + 1)); fi
    n=$((n + 1))
    case " $_CC_HK_PROC_PGS " in *" $pg "*) ;; *) _CC_HK_PROC_PGS="${_CC_HK_PROC_PGS:+$_CC_HK_PROC_PGS }$pg" ;; esac
  done <<EOF
$out
EOF
  [ -n "$_CC_HK_PROCS" ] || return 2
  [ "$more" -gt 0 ] && _CC_HK_PROCS="$_CC_HK_PROCS 외 ${more}개"
  return 0
}

# _cc_hk_delete_if_idle <stale_limit_secs | ""> : state 잠금을 쥔 채 다시 확인하고 none·dead 일 때만 active 를 지운다.
#   stale_limit 을 주면(cleanup-stale) last_activity_at 이 아직 그보다 오래됐고 state 를 읽을 수 있을 때만 지운다.
#   주지 않으면(discard·finish: 사용자가 직접 고른 삭제) state 를 읽을 수 없거나 running 이 깨진 기록도, 이 작업의
#   프로세스가 없음을 확인했을 때만 지운다 (_cc_hk_task_procs. R30 이 R22 를 대체: 실행 기록 없이 지우면 돌고 있는
#   Codex 의 유일한 추적 기록을 잃는다). 찾았거나 확인하지 못하면 지우지 않는다. 아무 신호도 보내지 않는다.
#   0 지움 / 1 지우지 않음 (_CC_HK_RS = alive | uncertain | unreadable | fresh | procs | procs_unknown)
#   2 잠금 실패 / 3 경로 비정상·삭제 실패
_cc_hk_delete_if_idle() {
  local limit="$1" age rc=1
  cc_state_lock || return 2
  if [ -n "$limit" ]; then
    if ! age=$(_cc_hk_activity_age); then
      _CC_HK_RS=unreadable; cc_state_unlock; return 1
    fi
    if [ "$age" -le "$limit" ]; then
      _CC_HK_RS=fresh; cc_state_unlock; return 1
    fi
  fi
  if _cc_hk_classify || [ -z "$limit" ]; then
    # 사용자가 직접 고른 삭제(limit 없음)는 running 이 형식이 틀린 기록도 읽을 수 없는 기록처럼 다룬다: 실행 기록으로는
    # 판단할 수 없으므로 아래 프로세스 확인으로 정한다. 자동 정리(limit 있음)는 이 경우 지우지 않는다.
    if [ "$_CC_HK_RS" = uncertain ] && [ -z "$limit" ] && [ "$_CC_HK_MALFORMED" = 1 ]; then
      _CC_HK_RS=unreadable
    fi
    if [ "$_CC_HK_RS" = unreadable ] && [ -z "$limit" ]; then
      _cc_hk_task_procs
      case $? in
        1) ;;                            # 이 작업의 프로세스 없음 → 지운다
        0) _CC_HK_RS=procs ;;            # 있음 → 지우지 않는다
        *) _CC_HK_RS=procs_unknown ;;    # 확인 못 함 → 지우지 않는다
      esac
    fi
    case "$_CC_HK_RS" in
      none|dead|unreadable)
        if cc_delete_active; then
          _CC_STATE_LOCK_DEPTH=0          # 잠금 폴더도 active 와 함께 지워졌다
          return 0
        fi
        rc=3 ;;
    esac
  fi
  cc_state_unlock
  return "$rc"
}

# 오래된 기록을 지우지 않은 이유 한 줄 (_CC_HK_RS 로). fresh(그 사이 갱신됨)는 알릴 것이 없다
_cc_hk_stale_reason() {
  case "$_CC_HK_RS" in
    fresh) _CC_HK_LINE="" ;;
    alive) _CC_HK_LINE="[cc] 오래된 /cc 기록이 있지만 Codex가 아직 실행 중이라 지우지 않았습니다" ;;
    unreadable) _CC_HK_LINE=$_CC_HK_STALE_UNREADABLE ;;
    *)
      if [ "$_CC_HK_LEFTOVER" = 1 ]; then
        _CC_HK_LINE=$(_cc_hk_leftover_line "[cc] 오래된 /cc 기록을 지우지 않았습니다: ")
      else
        _CC_HK_LINE="[cc] 오래된 /cc 기록의 Codex 실행 여부를 확인할 수 없어 지우지 않았습니다"
      fi ;;
  esac
}

# _cc_hk_quarantine_legacy_running : 실행 전 트리는 있지만 git 설정 지문/무시 파일 manifest/하위 모듈 allowlist 중 하나가 없는
#   옛 running 기록이면, 현재 작업 트리의 정규화된 경로로 저장소 밖 unverified 격리 기록을 남긴다. git 을 부르지 않는다.
#   0 = 옛 기록을 격리함 (_CC_HK_LEGACY_ID), 1 = 해당 없음, 2 = 격리 실패. 자동 정리는 0/2 모두 active 를 지우지 않는다.
_cc_hk_quarantine_legacy_running() {
  local a root here
  _CC_HK_LEGACY_ID=""
  a=$(cc_active_dir 2>/dev/null) || return 2
  _CC_HK_LEGACY_ID=$(cc_legacy_running_id "$a/state.json")
  [ -n "$_CC_HK_LEGACY_ID" ] || return 1

  # state.json 의 repo_root 는 옛 Codex 호출이 바꿨을 수 있으므로 우선 믿지 않는다. 현재 위치에서 셸만으로 찾은 작업 트리
  # 루트를 쓰고, 찾지 못할 때만 state 의 경로가 현재 위치의 조상인지 확인해 쓴다.
  root=""
  if _cc_repo_discover && [ -n "${_CC_DISC_TOP:-}" ]; then
    root=$_CC_DISC_TOP
  else
    root=$(jq -r '.repo_root // empty' "$a/state.json" 2>/dev/null)
    [ -n "$root" ] && root=$(cd -P "$root" 2>/dev/null && pwd -P) || root=""
    here=$(pwd -P 2>/dev/null) || here=""
    case "$here/" in "$root/"*) ;; *) root="" ;; esac
  fi
  [ -n "$root" ] || return 2
  cc_quarantine_put "$root" unverified null null "$_CC_HK_LEGACY_ID" || return 2
  return 0
}

# _cc_hk_cleanup_stale : 알릴 한 줄을 _CC_HK_LINE 에 (할 일이 없으면 빈 값). 프로세스는 건드리지 않는다.
#   경로 비정상(심볼릭 링크 등)이면 그 안의 기록을 믿지 않고 나이와 상관없이 지우지 않는다고 알린다.
_cc_hk_cleanup_stale() {
  local age limit r
  _CC_HK_LINE=""
  cc_git_dir >/dev/null 2>&1 || return 0
  cc_active_exists || return 0
  if ! cc_active_path_safe; then
    _CC_HK_LINE="[cc] /cc 기록 폴더 경로가 비정상이라 오래된 기록인지 확인하지 않고 지우지 않았습니다"
    return 0
  fi
  age=$(_cc_hk_activity_age) || { _CC_HK_LINE=$_CC_HK_STALE_UNREADABLE; return 0; }
  limit=$(_cc_hk_stale_limit)
  [ "$age" -gt "$limit" ] || return 0
  _cc_hk_classify || { _CC_HK_LINE=$_CC_HK_STALE_UNREADABLE; return 0; }
  case "$_CC_HK_RS" in
    none|dead) ;;
    *) _cc_hk_stale_reason; return 0 ;;
  esac
  # 지문 없는 옛 호출은 SessionStart 를 포함한 어느 자동 정리에서도 그냥 지우지 않는다. 먼저 저장소 밖에 baseline:null
  # unverified 기록을 남기고 멈춘다. 다음 진입점부터는 사용자가 직접 확인하고 release-quarantine 하기 전까지 git 을 쓰지 않는다.
  # 기록 쓰기가 실패해도 active 를 남겨 다음 기회에 다시 시도한다 (Codex 보안 검수 2차 후속).
  if [ "$_CC_HK_RS" = dead ]; then
    _cc_hk_quarantine_legacy_running
    r=$?
    case "$r" in
      0)
        _CC_HK_LINE="[cc] 오래된 /cc 기록은 이전 버전이라 git 설정 변경 여부를 확인할 수 없어 격리했고 지우지 않았습니다. git 설정 파일을 직접 확인하세요"
        return 0 ;;
      2)
        _CC_HK_LINE="[cc] 오래된 /cc 기록은 git 설정 변경 여부를 확인할 수 없고 격리 기록도 남기지 못해 지우지 않았습니다"
        return 0 ;;
    esac
  fi
  # (Codex 가 바꾼 git 설정의 격리 기록은 active 와 따로 남으므로 여기서 지워도 된다. cc-codex.sh 의 cleanup-stale 은 격리 중이면
  #  여기까지 오지 않는다: cc_quarantine_gate)
  # 끝난 기록에 실행 전 트리(running.pre_tree)가 있으면 지우기 전에 최종 다시 비교한다 (Codex 리뷰 3차 2). 정리는 활동이
  #   아니므로 last_activity_at 은 그대로 둔다. 새로 알게 된 것(Codex 의 파일 수정, 최종 확인 실패)이 있으면 이번에는 지우지
  #   않고 그 한 줄을 알린다 (preflight 의 stale_notice). 사용자가 부른 cc-codex.sh 에서만 한다: 세션 시작 훅은 스냅샷을 뜨지
  #   않고 지금처럼 정리한다 (_CC_EDIT_SETTLE_OK)
  if [ "$_CC_HK_RS" = dead ] && [ "${_CC_EDIT_SETTLE_OK:-0}" = 1 ] && _cc_hk_valid_id "$_CC_HK_ID"; then
    _CC_WAIT_ACTIVE=$(cc_active_dir)
    _CC_WAIT_SETTLE_WRITER=_cc_wait_update_keep_activity
    _cc_edit_settle_dead "$_CC_HK_ID"; r=$?
    _CC_WAIT_SETTLE_WRITER=_cc_state_update_nolock
    if [ "$r" -ne 0 ]; then
      # 최종 비교 결과를 기록하지 못했다: 이번에는 지우지 않는다 (Codex 리뷰 4차 1)
      _CC_HK_LINE="[cc] 오래된 /cc 기록의 최종 비교 결과를 기록하지 못해 지우지 않았습니다"
      return 0
    fi
    if [ -n "$_CC_EDIT_NEW_LINE" ]; then
      _CC_HK_LINE=$_CC_EDIT_NEW_LINE
      return 0
    fi
  fi
  _cc_hk_delete_if_idle "$limit"; r=$?
  case "$r" in
    0) _CC_HK_LINE="[cc] 오래된 /cc 중단 기록을 정리했습니다" ;;
    1) _cc_hk_stale_reason ;;
    2) _CC_HK_LINE="[cc] 상태 파일이 잠겨 있어 오래된 /cc 기록을 지우지 않았습니다" ;;
    *) _CC_HK_LINE="[cc] 오래된 /cc 기록 폴더를 지우지 못했습니다" ;;
  esac
}

# cc-codex.sh cleanup-stale : 정리·경고 시 한 줄, 할 일이 없으면 출력 없음. 항상 0
cc_cmd_cleanup_stale() {
  _cc_hk_cleanup_stale
  [ -n "$_CC_HK_LINE" ] && cc_line "$_CC_HK_LINE"
  return 0
}

# ---- 버리기·마무리 ----
# _cc_hk_remove_active <완료 줄> : Codex 가 돌 수 있으면(alive·uncertain) 6 과 한 줄, 아니면 active 를 지운다
#   (R8: 판단할 수 없음은 삭제의 근거가 아니다. 남은 그룹이면 PGID 와 확인 방법을 알린다)
_cc_hk_remove_active() {
  local done_line="$1" r g cmds="" warn="" list a legacy root
  # Codex 가 바꾼 git 설정이 아직 그대로면(격리 중: cc-codex.sh 의 cc_quarantine_gate) git 을 돌리지 않고 지운다. 외부 격리 기록은
  #   작업 기록과 따로 남아 새 작업도 막는다는 것을 줄 끝에 알린다 (Codex 보안 검수 1·2차)
  if [ "${_CC_QUARANTINED:-0}" = 1 ]; then
    list=$(_cc_edit_summary_text "$_CC_GITCFG_TAMPER_SUMMARY"); [ -n "$list" ] || list="(목록을 읽지 못함)"
    if [ "$_CC_GITCFG_TAMPER_UNSURE" = 1 ]; then
      warn="주의: git 설정 무결성을 확인하지 못해(기록된 파일: $list) 사용자가 확인하기 전에는 /cc 가 git 명령을 실행하지 않습니다(새 작업도 시작하지 않음). 기록: ${_CC_GITCFG_QUARANTINE:-?}"
    else
      warn="주의: Codex가 바꾼 git 설정 파일이 아직 실행 전과 다릅니다: $list. 되돌리기 전에는 /cc 가 git 명령을 실행하지 않습니다(새 작업도 시작하지 않음). git 명령을 쓰기 전에 직접 확인해 되돌리세요"
    fi
  fi
  cc_active_exists || { cc_line "[cc] 진행 중인 작업이 없습니다.${warn:+ · $warn}"; return 0; }
  cc_active_path_safe || { cc_line "[cc] 상태 폴더 경로가 비정상이라 삭제하지 않았습니다."; return 1; }
  # 지문 없이 남은 이전 버전의 호출 기록(실행 전 트리만 있음)은 지우기 전에 기준 없는 unverified 외부 격리 기록을 남긴다:
  #   그 호출이 git 설정을 바꿨는지 알 수 없으므로 사용자가 확인하기 전까지 git 을 쓰지 않는다 (Codex 보안 검수 2차 2). 못 남기면 지우지 않는다
  if [ "${_CC_QUARANTINED:-0}" != 1 ] && a=$(cc_active_dir 2>/dev/null); then
    legacy=$(jq -r 'if (.running | type) == "object" and (.running.pre_tree | type) == "string"
                       and ((.running.pre_gitcfg | type) != "object" or (.running.pre_submodules | type) != "array"
                            or (.running.pre_ignored | type) != "string")
                    then (.running.call_id // "?" | tostring) else empty end' "$a/state.json" 2>/dev/null)
    if [ -n "$legacy" ]; then
      root=$(jq -r '.running.pre_root // .repo_root // empty' "$a/state.json" 2>/dev/null)
      [ -n "$root" ] && root=$(cd -P "$root" 2>/dev/null && pwd -P) || root=""
      if [ -z "$root" ] || ! cc_quarantine_put "$root" unverified null null "$legacy"; then
        cc_line "[cc] 이전 호출이 git 설정을 바꿨는지 확인할 수 없는데 격리 기록을 남기지 못해 지우지 않았습니다."
        return 1
      fi
      warn="주의: 이전 호출 $legacy 이 git 설정을 바꿨는지 확인할 수 없어 사용자가 확인하기 전에는 /cc 가 git 명령을 실행하지 않습니다"
    fi
  fi
  _cc_hk_delete_if_idle ""; r=$?
  case "$r" in
    0) cc_line "$done_line${warn:+ · $warn}"; return 0 ;;
    2) cc_line "[cc] 상태 파일이 잠겨 있어 지우지 못했습니다. 잠시 뒤 다시 시도하세요."; return 1 ;;
    3) cc_line "[cc] 상태 폴더를 지우지 못했습니다."; return 1 ;;
  esac
  case "$_CC_HK_RS" in
    alive)
      cc_line "[cc] Codex가 실행 중입니다. 먼저 종료하세요" ;;
    procs)
      # 기록을 읽을 수 없어 우리 것인지 확인할 수 없다: 종료하지 않고 사용자가 직접 볼 수 있게 PID·그룹·확인 명령을 알린다
      for g in $_CC_HK_PROC_PGS; do cmds="${cmds:+$cmds, }ps -o pid,command -g $g"; done
      cc_line "[cc] 상태 기록을 읽을 수 없는데 이 작업의 Codex 프로세스로 보이는 것이 남아 있어 지우지 않았습니다: $_CC_HK_PROCS. /cc 는 이것을 자동으로 종료하지 않습니다. 확인: $cmds" ;;
    procs_unknown)
      cc_line "[cc] 상태 기록을 읽을 수 없고 이 작업의 Codex 프로세스가 남아 있는지 확인하지 못해 지우지 않았습니다. 잠시 뒤 다시 시도하세요" ;;
    *)
      if [ "$_CC_HK_LEFTOVER" = 1 ]; then
        cc_line "$(_cc_hk_leftover_line "[cc] 지우지 않았습니다: ")"
      else
        cc_line "[cc] Codex가 실행 중인지 확인할 수 없어 지우지 않았습니다. 잠시 뒤 다시 시도하세요"
      fi ;;
  esac
  return 6
}

# cc-codex.sh discard : active 를 버린다. 코드 변경은 건드리지 않는다
cc_cmd_discard() {
  _cc_hk_remove_active "[cc] /cc 작업 기록을 버렸습니다. 코드 변경은 그대로 두었습니다."
}

# ---- 시작 전 확인 ----
# active 의 {phase, milestone, milestones_total, last_activity_at} 한 줄 JSON (읽을 수 없으면 null)
_cc_hk_active_json() {
  local a j=""
  a=$(cc_active_dir) && j=$(jq -cs 'if length == 1 and (.[0] | type) == "object"
        then .[0] | {phase, milestone, milestones_total, last_activity_at} else null end' "$a/state.json" 2>/dev/null)
  [ -n "$j" ] || j=null
  printf '%s\n' "$j"
}

# _cc_hk_dirty_scan <저장소 루트> : 커밋되지 않은 변경과 무시 목록에 없는 untracked 파일
#   _CC_HK_DIRTY = 앞의 최대 10개 경로(저장소 루트 기준, 따옴표 없이), _CC_HK_DIRTY_N = 전체 개수. git 실패면 1
#   상태 폴더는 git 디렉터리 안(작업 트리 밖)이라 나오지 않는다. -z 로 받아 공백·한글 파일명도 그대로 둔다.
#   스냅샷과 같이 굳힌 설정으로 부른다 (cc_git_safe: core.fsmonitor 등을 실행하지 않음. 2026-10-18 보안 수정 R33)
_cc_hk_dirty_scan() {
  local top="$1" tmp entry skip=0
  _CC_HK_DIRTY=(); _CC_HK_DIRTY_N=0
  tmp=$(mktemp "${TMPDIR:-/tmp}/cc-status.XXXXXX") || return 1
  if ! (cd "$top" && cc_git_safe --no-optional-locks status --porcelain -z --untracked-files=all) > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  while IFS= read -r -d '' entry; do
    # 이름 바꾸기·복사는 "XY 새이름" 다음 항목에 옛 이름이 따로 온다: 새 이름만 센다
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "${entry:0:2}" in R*|C*|?R|?C) skip=1 ;; esac
    _CC_HK_DIRTY_N=$((_CC_HK_DIRTY_N + 1))
    [ "${#_CC_HK_DIRTY[@]}" -lt 10 ] && _CC_HK_DIRTY[${#_CC_HK_DIRTY[@]}]=${entry:3}
  done < "$tmp"
  rm -f "$tmp"
  return 0
}

# _cc_hk_preflight_emit <code> <message> <stale_notice|""> <active-json> [dirty_files...] : JSON 한 줄. ready 면 0, 아니면 7
_cc_hk_preflight_emit() {
  local code="$1" msg="$2" stale="$3" active="$4" out
  shift 4
  out=$(jq -nc --arg code "$code" --arg msg "$msg" --arg stale "$stale" --argjson active "$active" \
    '{ok: ($code == "ready"), code: $code, message: $msg, dirty_files: $ARGS.positional,
      stale_notice: (if $stale == "" then null else $stale end), active: $active}' --args -- "$@" 2>/dev/null)
  if [ -z "$out" ]; then
    printf '{"ok":false,"code":"%s","message":"[cc] 시작 전 확인 결과를 만들지 못했습니다.","dirty_files":[],"stale_notice":null,"active":null}\n' "$code"
    return 7
  fi
  printf '%s\n' "$out"
  [ "$code" = ready ] && return 0
  return 7
}

# cc-codex.sh preflight : 새 /cc 작업을 시작해도 되는지 순서대로 확인하고 JSON 한 줄. 0 ready / 7 시작 불가
#   git 저장소 → jq → codex 설치 → codex login status → 14일 정리(stale_notice) → 고아 → active → 작업 트리
#   프로세스를 죽이지 않는다 (고아면 알리기만 한다. 종료는 사용자에게 알린 뒤 check-orphan --kill).
cc_cmd_preflight() {
  local top stale active msg
  if ! cc_git_dir >/dev/null 2>&1 || ! top=$(git rev-parse --show-toplevel 2>/dev/null) || [ -z "$top" ]; then
    printf '%s\n' "$_CC_HK_JSON_NOT_GIT"
    return 7
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' "$_CC_HK_JSON_NO_JQ"
    return 7
  fi
  if ! command -v "$CC_CODEX_BIN" >/dev/null 2>&1; then
    _cc_hk_preflight_emit no_codex "[cc] Codex CLI가 설치돼 있지 않습니다. Codex CLI를 설치하고 로그인한 뒤 다시 실행하세요." "" null
    return $?
  fi
  cc_run_with_timeout "$CC_LOGIN_TIMEOUT_SECS" "$CC_CODEX_BIN" login status >/dev/null 2>&1
  case $? in
    0) ;;
    124)
      _cc_hk_preflight_emit not_logged_in "[cc] Codex CLI 로그인 확인이 ${CC_LOGIN_TIMEOUT_SECS}초 안에 끝나지 않았습니다 (시간 초과). 터미널에서 codex login status 를 확인한 뒤 다시 시작하세요." "" null
      return $?  ;;
    *)
      _cc_hk_preflight_emit not_logged_in "[cc] Codex CLI에 로그인돼 있지 않습니다. 터미널에서 codex login 을 실행한 뒤 다시 시작하세요." "" null
      return $? ;;
  esac
  _cc_hk_cleanup_stale
  stale=$_CC_HK_LINE
  if cc_active_exists; then
    if ! cc_active_path_safe; then
      _cc_hk_preflight_emit active_present "[cc] /cc 기록 폴더 경로가 비정상이라 이어 하거나 지울 수 없습니다." "$stale" null
      return $?
    fi
    if cc_is_orphan; then
      _cc_hk_preflight_emit orphan_running "$CC_ORPHAN_LINE" "$stale" "$(_cc_hk_active_json)"
      return $?
    fi
    active=$(_cc_hk_active_json)
    if [ "$active" = null ]; then
      msg="[cc] 이전 /cc 작업 기록이 있지만 상태 파일을 읽을 수 없습니다."
    elif ! _cc_running_wellformed "$(_cc_hk_read_state)"; then
      msg="[cc] 이전 /cc 작업 기록이 깨져 있어 이어 할 수 없습니다. 버릴 수만 있습니다."
    else
      msg="[cc] 이전 /cc 작업 기록이 남아 있습니다. 이어 하거나 버릴 수 있습니다."
    fi
    _cc_hk_preflight_emit active_present "$msg" "$stale" "$active"
    return $?
  fi
  if ! _cc_hk_dirty_scan "$top"; then
    _cc_hk_preflight_emit dirty "[cc] 작업 트리 상태를 확인하지 못해 새 /cc 작업을 시작할 수 없습니다." "$stale" null
    return $?
  fi
  if [ "$_CC_HK_DIRTY_N" -gt 0 ]; then
    _cc_hk_preflight_emit dirty \
      "[cc] 커밋되지 않은 변경이 ${_CC_HK_DIRTY_N}개 있어 새 /cc 작업을 시작할 수 없습니다 (기존 변경과 /cc 변경을 구분할 수 없음)." \
      "$stale" null "${_CC_HK_DIRTY[@]}"
    return $?
  fi
  _cc_hk_preflight_emit ready "[cc] 새 /cc 작업을 시작할 수 있습니다." "$stale" null
}
