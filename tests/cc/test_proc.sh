. "$CC_REPO_ROOT/plugins/yultopia/lib/cc/proc.sh"

# ---- 이 파일 전용 도우미 (test_ 로 시작하지 않게) ----
# 조건이 참이 될 때까지 0.1초 간격으로 최대 N초 기다린다
proc_until() {
  local secs="$1" i=0; shift
  until "$@"; do
    [ "$i" -ge $((secs * 10)) ] && return 1
    sleep 0.1; i=$((i+1))
  done
}
# PID 처럼 보이는 값(양의 정수)인지 확인
proc_assert_pid() { case "$1" in ''|0*|*[!0-9]*) _fail "PID 가 아님: [$1]" ;; esac; }
proc_gone() { ! kill -0 "$1" 2>/dev/null; }
# 테스트가 만든 프로세스 그룹을 실패해도 확실히 정리한다 (자기 그룹·잘못된 값은 건드리지 않음)
proc_reap() {
  local g mypg
  mypg=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')
  for g in "$@"; do
    case "$g" in ''|*[!0-9]*|0|1) continue ;; esac
    [ "$g" = "$mypg" ] && continue
    kill -KILL -- "-$g" 2>/dev/null
  done
  return 0
}
# 항상 실패하는 가짜 ps (PATH 앞에 두면 "ps 실패" 상황이 된다)
proc_fake_ps_fail() {
  mkdir -p "$TMP/bin"
  printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/ps"
  chmod +x "$TMP/bin/ps"
}
# 특정 PID 를 물을 때만 실패하는 가짜 ps (그 밖에는 진짜 /bin/ps)
proc_fake_ps_fail_for() {
  mkdir -p "$TMP/bin"
  printf '#!/bin/sh\nfor a; do last=$a; done\n[ "$last" = "%s" ] && exit 1\nexec /bin/ps "$@"\n' "$1" > "$TMP/bin/ps"
  chmod +x "$TMP/bin/ps"
}
# 파일이 생겼거나 프로세스가 끝났으면 참 (자기 그룹을 죽여 버리는 버그가 있어도 오래 기다리지 않게)
proc_file_or_gone() { [ -s "$1" ] || proc_gone "$2"; }
# setsid 로 자기 그룹을 만든 뒤 exec 까지 끝났으면 참 (PGID == PID, 명령줄이 "-moved" 로 끝남)
proc_moved() {
  [ "$(ps -o pgid= -p "$1" 2>/dev/null | tr -d ' ')" = "$1" ] || return 1
  case "$(ps -o command= -p "$1" 2>/dev/null)" in *-moved) return 0 ;; esac
  return 1
}
# 리더가 1초 뒤 끝나고, 멤버(bash + 그 자식 sleep)만 같은 그룹에 남는다. 멤버 PID 는 $TMP/member
proc_spawn_leader_exits_leaving_member() {
  cc_spawn_group "$TMP/log" bash -c 'bash -c "sleep 30; :" "$0-member" & echo $! > "$1"; sleep 1' \
    "cc-test-$TMP" "$TMP/member"
}
# 그룹 리더로 실행돼 자기 그룹을 죽이려 해 보는 스크립트. 종료 코드를 <out> 에 쓰고 계속 살아 있는다.
#   bash self-kill.sh <repo_root> <out> <leader|member>
proc_write_self_kill_script() {
  cat > "$TMP/self-kill.sh" <<'EOF'
#!/bin/bash
. "$1/plugins/yultopia/lib/cc/common.sh"; . "$1/plugins/yultopia/lib/cc/proc.sh"
out="$2"
id=$(cc_proc_identity $$)
pg=$(ps -o pgid= -p $$ | tr -d ' ')
case "$3" in
  leader) cc_kill_group_verified "$pg" "$id" ;;
  member) cc_kill_group_via_member $$ "$id" "$pg" ;;
esac
echo "$?" > "$out.tmp" && mv "$out.tmp" "$out"
sleep 30
EOF
}
# 명령의 종료 코드만 출력 (가짜 ps 를 PATH 앞에 두고 서브셸에서 실행)
proc_rc_with_failing_ps() {
  ( export PATH="$TMP/bin:$PATH"; hash -r; "$@" ) >/dev/null 2>&1
  echo $?
}

# ---- cc_spawn_group ----
test_spawn_creates_new_group() {
  pg=$(cc_spawn_group "$TMP/log" bash -c 'sleep 30 & sleep 30' "cc-test-$TMP")
  proc_assert_pid "$pg"
  assert_eq "$(ps -o pgid= -p "$pg" | tr -d ' ')" "$pg"
  proc_reap "$pg"
}
test_spawn_returns_after_exec_with_stable_identity() {
  # 돌아온 직후 신원이 이미 실제 명령이어야 한다 (perl 래퍼 단계의 신원을 기록하면 나중에 불일치)
  pg=$(cc_spawn_group "$TMP/log" bash -c 'sleep 30; :' "cc-test-$TMP")
  id1=$(cc_proc_identity "$pg")
  assert_contains "$id1" "|bash -c sleep 30; : cc-test-$TMP"
  assert_not_contains "$id1" "POSIX"
  sleep 0.3
  assert_eq "$(cc_proc_identity "$pg")" "$id1"
  proc_reap "$pg"
}
test_spawn_stdin_is_devnull_and_output_goes_to_log() {
  printf 'before\n' > "$TMP/log"
  printf 'secret-input\n' > "$TMP/input"
  pg=$(cc_spawn_group "$TMP/log" bash -c 'echo out-line; echo err-line >&2; cat > "$1"' \
        "cc-test-$TMP" "$TMP/stdin.out" < "$TMP/input")
  assert_eq "$?" "0"
  proc_assert_pid "$pg"
  proc_until 5 proc_gone "$pg" || _fail "자식이 끝나지 않음"
  assert_file_exists "$TMP/stdin.out"
  assert_eq "$(cat "$TMP/stdin.out")" ""
  assert_eq "$(cat "$TMP/log")" $'before\nout-line\nerr-line'
  proc_reap "$pg"
}
test_spawn_does_not_hold_caller_pipes() {
  # 호출한 쪽의 파이프(여기선 fd 3)를 자식이 물려받으면 $(...) 가 자식이 끝날 때까지 멈춘다
  start=$SECONDS
  pg=$(cc_spawn_group "$TMP/log" bash -c 'sleep 6; :' "cc-test-$TMP" 3>&1)
  elapsed=$((SECONDS - start))
  proc_assert_pid "$pg"
  [ "$elapsed" -lt 3 ] || _fail "호출자가 ${elapsed}초 기다림"
  proc_reap "$pg"
}
test_spawn_does_not_hold_high_numbered_fds() {
  # fd 번호가 커도(4096 이상) 물려주지 않아야 한다 (fd 를 닫는 범위에 상한을 두면 새어 나간다)
  cur=$(ulimit -n)
  if [ "$cur" != unlimited ] && [ "$cur" -lt 8192 ]; then
    ulimit -n 8192 2>/dev/null || { _fail "fd 한도를 8192 로 올릴 수 없음 (현재 $cur)"; return 1; }
  fi
  start=$SECONDS
  pg=$(cc_spawn_group "$TMP/log" bash -c 'sleep 6; :' "cc-test-$TMP" 5000>&1)
  elapsed=$((SECONDS - start))
  proc_assert_pid "$pg"
  [ "$elapsed" -lt 3 ] || _fail "호출자가 ${elapsed}초 기다림 (fd 5000 을 물려줌)"
  proc_reap "$pg"
}
test_spawn_reports_exec_failure() {
  pg=$(cc_spawn_group "$TMP/log" "$TMP/no-such-command" 2>/dev/null); rc=$?
  assert_eq "$rc" "1" "(pg=[$pg])"
  assert_eq "$pg" ""
  proc_reap "$pg"
}
test_spawn_rejects_missing_args() {
  assert_code_of 1 cc_spawn_group "$TMP/log"
  assert_code_of 1 cc_spawn_group "" true
}

# ---- cc_proc_identity ----
test_identity_format_is_locale_independent() {
  # 한글이 섞인 200자 넘는 명령줄: 호출한 쪽 로케일과 무관하게 신원이 같고, 200자 자르기도 같아야 한다
  kor=$(printf '한%.0s' $(seq 1 120))
  pg=$(cc_spawn_group "$TMP/log" bash -c 'sleep 30; :' "cc-test-$TMP-$kor")
  a=$(export LANG=ko_KR.UTF-8 LC_ALL=ko_KR.UTF-8; cc_proc_identity "$pg")
  b=$(export LANG=C LC_ALL=C; cc_proc_identity "$pg")
  c=$(export LANG=en_US.UTF-8; unset LC_ALL; cc_proc_identity "$pg")
  assert_eq "$a" "$b"
  assert_eq "$a" "$c"
  lstart=${a%%|*}; cmd=${a#*|}
  printf '%s\n' "$lstart" | grep -Eq '^[A-Z][a-z]{2} [A-Z][a-z]{2} [ 0-9][0-9] [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4}$' \
    || _fail "lstart 형식: [$lstart]"
  assert_eq "${#cmd}" "200"
  if printf '%s' "$a" | LC_ALL=C grep -q '[^ -~]'; then _fail "신원에 ASCII 가 아닌 문자: [$a]"; fi
  assert_contains "$cmd" "bash -c sleep 30; : cc-test-$TMP-"
  proc_reap "$pg"
}
test_identity_truncates_command_to_200_chars() {
  long=$(printf '%0300d' 0)
  pg=$(cc_spawn_group "$TMP/log" bash -c 'sleep 30; :' "cc-test-$TMP-$long")
  id=$(cc_proc_identity "$pg"); cmd=${id#*|}
  assert_eq "${#cmd}" "200"
  case "bash -c sleep 30; : cc-test-$TMP-$long" in
    "$cmd"*) ;;
    *) _fail "명령 앞 200자가 아님: [$cmd]" ;;
  esac
  proc_reap "$pg"
}
test_identity_missing_pid_exits_1() {
  pg=$(cc_spawn_group "$TMP/log" true)
  proc_until 5 proc_gone "$pg" || _fail "끝나지 않음"
  assert_code_of 1 cc_proc_identity "$pg"
}
test_identity_ps_failure_exits_2_for_live_pid() {
  pg=$(cc_spawn_group "$TMP/log" bash -c 'sleep 30; :' "cc-test-$TMP")
  proc_fake_ps_fail
  assert_eq "$(proc_rc_with_failing_ps cc_proc_identity "$pg")" "2"
  proc_reap "$pg"
}
test_identity_ps_failure_still_exits_1_for_dead_pid() {
  pg=$(cc_spawn_group "$TMP/log" true)
  proc_until 5 proc_gone "$pg" || _fail "끝나지 않음"
  proc_fake_ps_fail
  assert_eq "$(proc_rc_with_failing_ps cc_proc_identity "$pg")" "1"
}

# ---- cc_proc_alive_verified ----
test_alive_verified_matches_live_process() {
  pg=$(cc_spawn_group "$TMP/log" bash -c 'sleep 30; :' "cc-test-$TMP")
  id=$(cc_proc_identity "$pg")
  assert_code_of 0 cc_proc_alive_verified "$pg" "$id"
  proc_reap "$pg"
}
test_alive_verified_reports_dead_pid() {
  pg=$(cc_spawn_group "$TMP/log" bash -c 'sleep 30; :' "cc-test-$TMP")
  id=$(cc_proc_identity "$pg")
  kill -KILL -- "-$pg"
  proc_until 5 proc_gone "$pg" || _fail "끝나지 않음"
  assert_code_of 1 cc_proc_alive_verified "$pg" "$id"
  proc_reap "$pg"
}
test_alive_verified_reports_reused_pid() {
  pg=$(cc_spawn_group "$TMP/log" bash -c 'sleep 30; :' "cc-test-$TMP")
  id=$(cc_proc_identity "$pg")
  # 같은 PID, 다른 시작 시각 → 다른 프로세스(PID 재사용)
  assert_code_of 1 cc_proc_alive_verified "$pg" "Thu Jan  1 00:00:00 1970|${id#*|}"
  # 같은 시작 시각, 다른 명령 → 역시 다른 프로세스
  assert_code_of 1 cc_proc_alive_verified "$pg" "${id%%|*}|bash -c something-else"
  proc_reap "$pg"
}
test_alive_verified_uncertain_when_ps_fails() {
  pg=$(cc_spawn_group "$TMP/log" bash -c 'sleep 30; :' "cc-test-$TMP")
  id=$(cc_proc_identity "$pg")
  proc_fake_ps_fail
  assert_eq "$(proc_rc_with_failing_ps cc_proc_alive_verified "$pg" "$id")" "2"
  proc_reap "$pg"
}
test_alive_verified_malformed_args_are_uncertain() {
  pg=$(cc_spawn_group "$TMP/log" bash -c 'sleep 30; :' "cc-test-$TMP")
  id=$(cc_proc_identity "$pg")
  assert_code_of 2 cc_proc_alive_verified "$pg" ""
  assert_code_of 2 cc_proc_alive_verified "$pg" "null"
  assert_code_of 2 cc_proc_alive_verified "" "$id"
  assert_code_of 2 cc_proc_alive_verified "abc" "$id"
  proc_reap "$pg"
}

# ---- cc_kill_group_verified ----
test_kill_group_kills_children() {
  pg=$(cc_spawn_group "$TMP/log" bash -c 'sleep 30 & echo $! > "$1"; sleep 30' "cc-test-$TMP" "$TMP/child")
  proc_until 5 test -s "$TMP/child" || _fail "자식 PID 파일 없음"
  child=$(cat "$TMP/child")
  id=$(cc_proc_identity "$pg")
  start=$SECONDS
  cc_kill_group_verified "$pg" "$id"; rc=$?
  elapsed=$((SECONDS - start))
  assert_eq "$rc" "0"
  [ "$elapsed" -lt 3 ] || _fail "TERM 으로 끝났는데 ${elapsed}초 걸림"
  proc_until 3 proc_gone "$pg"
  proc_until 3 proc_gone "$child"
  assert_code_of 1 kill -0 "$pg"
  assert_code_of 1 kill -0 "$child"
  proc_reap "$pg"
}
test_kill_escalates_to_sigkill_when_term_ignored() {
  pg=$(cc_spawn_group "$TMP/log" bash -c 'trap "" TERM; sleep 30 & echo $! > "$1"; wait' "cc-test-$TMP" "$TMP/child")
  proc_until 5 test -s "$TMP/child" || _fail "자식 PID 파일 없음"
  child=$(cat "$TMP/child")
  id=$(cc_proc_identity "$pg")
  start=$SECONDS
  cc_kill_group_verified "$pg" "$id"; rc=$?
  elapsed=$((SECONDS - start))
  assert_eq "$rc" "0"
  [ "$elapsed" -ge 2 ] || _fail "TERM 뒤 기다리지 않고 바로 KILL (${elapsed}초)"
  [ "$elapsed" -le 8 ] || _fail "너무 오래 걸림 (${elapsed}초)"
  assert_code_of 1 kill -0 "$pg"
  assert_code_of 1 kill -0 "$child"
  proc_reap "$pg"
}
test_kill_refuses_identity_mismatch() {
  victim=$(cc_spawn_group "$TMP/log" bash -c 'sleep 30; :' "cc-test-$TMP")
  id=$(cc_proc_identity "$victim")
  assert_code_of 1 cc_kill_group_verified "$victim" "Thu Jan  1 00:00:00 1970|${id#*|}"
  sleep 0.3
  assert_code_of 0 kill -0 "$victim"
  assert_code_of 0 cc_proc_alive_verified "$victim" "$id"
  proc_reap "$victim"
}
test_kill_refuses_when_leader_gone_but_members_alive() {
  # 리더가 먼저 끝나면 리더 신원을 확인할 수 없으므로 그룹의 나머지도 죽이지 않는다
  pg=$(cc_spawn_group "$TMP/log" bash -c 'bash -c "sleep 30; :" "$0-child" & echo $! > "$1"; sleep 1' \
        "cc-test-$TMP" "$TMP/child")
  id=$(cc_proc_identity "$pg")
  proc_until 5 test -s "$TMP/child" || _fail "자식 PID 파일 없음"
  child=$(cat "$TMP/child")
  proc_until 5 proc_gone "$pg" || _fail "리더가 끝나지 않음"
  assert_code_of 0 kill -0 "$child"
  assert_code_of 1 cc_kill_group_verified "$pg" "$id"
  sleep 0.3
  assert_code_of 0 kill -0 "$child"
  assert_eq "$(ps -o pgid= -p "$child" | tr -d ' ')" "$pg"
  proc_reap "$pg"
}
test_kill_kills_nothing_when_uncertain() {
  pg=$(cc_spawn_group "$TMP/log" bash -c 'sleep 30; :' "cc-test-$TMP")
  id=$(cc_proc_identity "$pg")
  # 대상 PID 의 신원만 알 수 없게 한다 (자기 그룹 확인 등 다른 ps 는 정상)
  proc_fake_ps_fail_for "$pg"
  assert_eq "$(proc_rc_with_failing_ps cc_kill_group_verified "$pg" "$id")" "2"
  assert_eq "$(proc_rc_with_failing_ps cc_kill_group_via_member "$pg" "$id" "$pg")" "2"
  sleep 0.3
  assert_code_of 0 kill -0 "$pg"
  proc_reap "$pg"
}
test_kill_refuses_non_leader_pid() {
  # 신원이 맞아도 그 PID 가 그룹 리더가 아니면 "-PID" 그룹은 없다: 아무것도 보내지 않고 "거부(2)"
  pg=$(cc_spawn_group "$TMP/log" bash -c 'bash -c "sleep 30; :" "$0-member" & echo $! > "$1"; sleep 30' \
        "cc-test-$TMP" "$TMP/member")
  proc_until 5 test -s "$TMP/member" || _fail "멤버 PID 파일 없음"
  m=$(cat "$TMP/member")
  mid=$(cc_proc_identity "$m")
  assert_eq "$(ps -o pgid= -p "$m" | tr -d ' ')" "$pg"
  cc_kill_group_verified "$m" "$mid"; rc=$?
  assert_eq "$rc" "2"
  sleep 0.3
  assert_code_of 0 kill -0 "$m"
  assert_code_of 0 kill -0 "$pg"
  proc_reap "$pg"
}
test_kill_refuses_own_group() {
  proc_write_self_kill_script
  pg=$(cc_spawn_group "$TMP/log" bash "$TMP/self-kill.sh" "$CC_REPO_ROOT" "$TMP/self.rc" leader)
  proc_until 6 proc_file_or_gone "$TMP/self.rc" "$pg" || _fail "결과가 없음"
  assert_code_of 0 kill -0 "$pg"
  assert_eq "$(cat "$TMP/self.rc" 2>/dev/null)" "2"
  proc_reap "$pg"
}

# ---- cc_kill_group_via_member ----
test_via_member_kills_group_after_leader_exit() {
  pg=$(proc_spawn_leader_exits_leaving_member)
  proc_until 5 test -s "$TMP/member" || _fail "멤버 PID 파일 없음"
  m=$(cat "$TMP/member")
  mid=$(cc_proc_identity "$m")
  proc_until 5 proc_gone "$pg" || _fail "리더가 끝나지 않음"
  assert_code_of 0 kill -0 -- "-$pg"
  cc_kill_group_via_member "$m" "$mid" "$pg"; rc=$?
  assert_eq "$rc" "0"
  assert_code_of 1 kill -0 "$m"
  assert_code_of 1 kill -0 -- "-$pg"
  proc_reap "$pg"
}
test_via_member_refuses_identity_mismatch() {
  pg=$(proc_spawn_leader_exits_leaving_member)
  proc_until 5 test -s "$TMP/member" || _fail "멤버 PID 파일 없음"
  m=$(cat "$TMP/member")
  mid=$(cc_proc_identity "$m")
  assert_code_of 1 cc_kill_group_via_member "$m" "Thu Jan  1 00:00:00 1970|${mid#*|}" "$pg"
  sleep 0.3
  assert_code_of 0 kill -0 "$m"
  assert_code_of 0 kill -0 -- "-$pg"
  proc_reap "$pg"
}
test_via_member_refuses_pgid_mismatch() {
  # 멤버가 스스로 다른 그룹으로 옮겨 간 경우(setsid)와 엉뚱한 그룹 번호를 준 경우: 아무것도 죽이지 않는다
  pg=$(cc_spawn_group "$TMP/log" bash -c \
        'perl -MPOSIX -e "POSIX::setsid(); exec @ARGV" bash -c "sleep 30; :" "$0-moved" & echo $! > "$1"; sleep 30' \
        "cc-test-$TMP" "$TMP/member")
  other=$(cc_spawn_group "$TMP/log" bash -c 'sleep 30; :' "cc-test-$TMP-other")
  proc_until 5 test -s "$TMP/member" || _fail "멤버 PID 파일 없음"
  m=$(cat "$TMP/member")
  proc_until 5 proc_moved "$m" || _fail "멤버가 다른 그룹으로 옮겨 가지 않음"
  mid=$(cc_proc_identity "$m")
  cc_kill_group_via_member "$m" "$mid" "$pg"; rc1=$?
  cc_kill_group_via_member "$m" "$mid" "$other"; rc2=$?
  assert_eq "$rc1" "2"
  assert_eq "$rc2" "2"
  sleep 0.3
  assert_code_of 0 kill -0 "$m"
  assert_code_of 0 kill -0 "$pg"
  assert_code_of 0 kill -0 "$other"
  proc_reap "$pg" "$other" "$m"
}
test_via_member_refuses_own_group() {
  proc_write_self_kill_script
  pg=$(cc_spawn_group "$TMP/log" bash "$TMP/self-kill.sh" "$CC_REPO_ROOT" "$TMP/self.rc" member)
  proc_until 6 proc_file_or_gone "$TMP/self.rc" "$pg" || _fail "결과가 없음"
  assert_code_of 0 kill -0 "$pg"
  assert_eq "$(cat "$TMP/self.rc" 2>/dev/null)" "2"
  proc_reap "$pg"
}

test_kill_rejects_invalid_pgid_without_signalling() {
  # 0 은 자기 그룹, 1 은 "모든 프로세스" 가 되므로 신원과 무관하게 거부해야 한다.
  # 신호 경로에 닿지 않도록 kill 과 신원 확인을 모두 가로챈다: 거부는 신원 확인보다 먼저 일어나야 한다.
  launchd_id=$(cc_proc_identity 1)
  assert_contains "$launchd_id" "|"   # PGID 1 은 신원이 "맞는" 경우에도 거부돼야 한다
  : > "$TMP/kills"; : > "$TMP/rcs"; : > "$TMP/verified"
  (
    kill() { echo "kill $*" >> "$TMP/kills"; return 0; }
    cc_proc_alive_verified() { echo "verify $*" >> "$TMP/verified"; return 1; }
    for g in "" 0 1 -1 abc 12x; do
      cc_kill_group_verified "$g" "$launchd_id"; echo "verified[$g]=$?" >> "$TMP/rcs"
      cc_kill_group_via_member 1 "$launchd_id" "$g"; echo "member[$g]=$?" >> "$TMP/rcs"
    done
    for m in "" 0 -1 abc; do
      cc_kill_group_via_member "$m" "$launchd_id" 12345; echo "badmember[$m]=$?" >> "$TMP/rcs"
    done
  ) >/dev/null 2>&1
  assert_eq "$(cat "$TMP/kills")" ""
  assert_eq "$(cat "$TMP/verified")" ""
  # 형식이 잘못된 인자는 "거부(2)": 아무것도 죽이지 않는다
  assert_eq "$(grep -vc '=2$' "$TMP/rcs")" "0" "$(cat "$TMP/rcs")"
  assert_eq "$(wc -l < "$TMP/rcs" | tr -d ' ')" "16"
}

# ---- cc-codex.sh 가 proc.sh 를 불러오는지 ----
test_cli_fails_loudly_without_proc_lib() {
  mkdir -p "$TMP/plugin/bin" "$TMP/plugin/lib/cc"
  cp "$CC_BIN" "$TMP/plugin/bin/cc-codex.sh"
  cp "$CC_REPO_ROOT"/plugins/yultopia/lib/cc/*.sh "$TMP/plugin/lib/cc/"
  rm -f "$TMP/plugin/lib/cc/proc.sh"
  out=$(bash "$TMP/plugin/bin/cc-codex.sh" status 2>/dev/null); rc=$?
  assert_eq "$rc" "1"
  assert_contains "$out" "proc.sh"
}
