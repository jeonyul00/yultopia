# test_hooks.sh - Task 9: SessionStart 정리 훅, UserPromptSubmit 고아 확인 훅, hooks.json
. "$CC_REPO_ROOT/plugins/yultopia/lib/cc/proc.sh"

# ---- 이 파일 전용 도우미 ----
hh_until() {
  local secs="$1" i=0; shift
  until "$@"; do
    [ "$i" -ge $((secs * 10)) ] && return 1
    sleep 0.1; i=$((i+1))
  done
}
hh_codex_recorded() { [ -n "$(state '.running.codex_pid // empty')" ]; }
hh_iso_ago() { perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time - $ARGV[0]))' "$1"; }
# 훅 실행: hh_hook <session-start|prompt-submit> <cwd>  → OUT, CODE
hh_hook() {
  OUT=$(printf '{"cwd":"%s","hook_event_name":"x"}' "$2" | bash "$HOOK" "$1" 2>"$TMP/hook.err")
  CODE=$?
}
# 고아 만들기: hang 호출을 띄우고 유예(1초)가 지나도록 기다린다
hh_make_orphan() {
  FAKE_CODEX_SEQ=hang; CC_ORPHAN_GRACE_SECS=1
  start_task
  run_cc call plan; assert_code 0
  hh_until 5 hh_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  HH_PG=$(state .running.pgid); HH_CP=$(state .running.codex_pid)
  sleep 2.2
}
hh_reap() { [ -n "${HH_PG:-}" ] && kill -KILL -- "-$HH_PG" 2>/dev/null; return 0; }

# ==== SessionStart ====
test_session_start_hook_silent_without_active() {
  repo=$(make_repo)
  hh_hook session-start "$repo"
  assert_eq "$CODE" "0"; assert_eq "$OUT" ""
}
test_session_start_hook_reports_stale_cleanup() {
  start_task
  set_state ".last_activity_at = \"$(hh_iso_ago $((15 * 86400)))\""
  hh_hook session-start "$PWD"
  assert_eq "$CODE" "0"
  assert_eq "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "1"
  assert_eq "$(printf '%s' "$OUT" | jq -r 'keys | join(",")')" "systemMessage"
  assert_contains "$(printf '%s' "$OUT" | jq -r .systemMessage)" "정리했습니다"
  assert_no_path "$ACTIVE"
}
test_session_start_quarantines_legacy_running_record_instead_of_deleting_it() {
  start_task
  set_state ".last_activity_at = \"$(hh_iso_ago $((15 * 86400)))\"
    | .running = {call_id: 1, kind: \"plan\", pgid: 999999, supervisor_identity: \"old|gone\",
        codex_pid: null, codex_identity: null, started_at: .created_at, review_tree: null,
        pre_tree: .task_base_tree}"
  # 옛 호출이 악성 filter 를 남긴 상황. SessionStart 안의 rev-parse 자체는 이를 실행하지 않아야 하고, 이후 preflight 도 격리된다.
  printf '#!/bin/sh\ntouch "%s/legacy-filter-ran"\ncat\n' "$TMP" > "$TMP/legacy-filter"; chmod +x "$TMP/legacy-filter"
  git config filter.legacy.clean "$TMP/legacy-filter"
  printf '* filter=legacy\n' > .gitattributes
  hh_hook session-start "$PWD"
  assert_eq "$CODE" "0"
  assert_contains "$(printf '%s' "$OUT" | jq -r .systemMessage)" "이전 버전"
  assert_contains "$(printf '%s' "$OUT" | jq -r .systemMessage)" "격리"
  assert_file_exists "$ACTIVE/state.json"
  set -- "$CLAUDE_PLUGIN_DATA/cc/quarantine"/*.json
  q=$1
  assert_file_exists "$q"
  assert_eq "$(jq -r .state "$q")" "unverified"
  assert_eq "$(jq -r .baseline "$q")" "null"
  assert_no_path "$TMP/legacy-filter-ran"
  run_cc preflight; assert_code 7
  assert_eq "$(printf '%s' "$OUT" | jq -r .code)" "git_config_changed"
  assert_no_path "$TMP/legacy-filter-ran"
}
test_session_start_keeps_legacy_record_when_quarantine_write_fails() {
  start_task
  set_state ".last_activity_at = \"$(hh_iso_ago $((15 * 86400)))\"
    | .running = {call_id: 1, kind: \"plan\", pgid: 999999, supervisor_identity: \"old|gone\",
        codex_pid: null, codex_identity: null, started_at: .created_at, review_tree: null,
        pre_tree: .task_base_tree}"
  mkdir -p "$CLAUDE_PLUGIN_DATA/cc/quarantine"
  chmod 555 "$CLAUDE_PLUGIN_DATA/cc/quarantine"
  hh_hook session-start "$PWD"
  assert_eq "$CODE" "0"
  assert_contains "$(printf '%s' "$OUT" | jq -r .systemMessage)" "격리 기록도 남기지 못해"
  assert_file_exists "$ACTIVE/state.json"
  # 외부 기록이 여전히 없어도 다음 진입점은 active 의 옛 기록을 git 없이 먼저 찾아 막는다.
  mkdir -p "$TMP/git-spy"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/git.calls"\nexec "%s" "$@"\n' "$TMP" "$(command -v git)" > "$TMP/git-spy/git"
  chmod +x "$TMP/git-spy/git"
  PATH="$TMP/git-spy:$PATH" run_cc preflight; assert_code 7
  assert_eq "$(printf '%s' "$OUT" | jq -r .code)" "git_config_changed"
  assert_eq "$(cat "$TMP/git.calls" 2>/dev/null)" "" "격리 쓰기 실패 뒤 preflight 의 git 호출"
  assert_file_exists "$ACTIVE/state.json"
  chmod 755 "$CLAUDE_PLUGIN_DATA/cc/quarantine"
}
test_session_start_hook_silent_for_fresh_record() {
  start_task
  hh_hook session-start "$PWD"
  assert_eq "$CODE" "0"; assert_eq "$OUT" ""
  assert_file_exists "$ACTIVE/state.json"
}
test_session_start_hook_exits_zero_on_garbage() {
  start_task
  repo=$PWD
  set_state ".last_activity_at = \"$(hh_iso_ago $((15 * 86400)))\""
  OUT=$(printf 'not json' | CLAUDE_PROJECT_DIR="$repo" bash "$HOOK" session-start 2>/dev/null); assert_eq "$?" "0"; assert_eq "$OUT" ""
  assert_file_exists "$ACTIVE/state.json"   # 읽을 수 없는 입력이면 아무것도 하지 않는다
  set_state ".last_activity_at = \"$(hh_iso_ago 5)\""
  OUT=$(printf 'not json' | CLAUDE_PROJECT_DIR="$repo" bash "$HOOK" session-start 2>/dev/null); assert_eq "$?" "0"
  OUT=$(printf '{"cwd":"%s/nonexistent"}' "$TMP" | bash "$HOOK" session-start 2>/dev/null); assert_eq "$?" "0"; assert_eq "$OUT" ""
  OUT=$(bash "$HOOK" session-start </dev/null 2>/dev/null); assert_eq "$?" "0"
  OUT=$(bash "$HOOK" bogus-mode </dev/null 2>/dev/null); assert_eq "$?" "0"; assert_eq "$OUT" ""
  # 심볼릭 링크 active: 경고만 하고 0 (지우지 않는다)
  mv "$ACTIVE" "$TMP/elsewhere"; ln -s "$TMP/elsewhere" "$ACTIVE"
  OUT=$(printf '{"cwd":"%s"}' "$repo" | bash "$HOOK" session-start 2>/dev/null); assert_eq "$?" "0"
  printf '%s' "$OUT" | jq -e .systemMessage >/dev/null || _fail "경고 JSON 아님: $OUT"
  [ -d "$TMP/elsewhere" ] || _fail "링크 대상을 지움"
  rm -f "$ACTIVE"
}
test_session_start_hook_never_kills_or_calls_codex() {
  hh_make_orphan
  set_state ".last_activity_at = \"$(hh_iso_ago $((15 * 86400)))\""
  printf '#!/bin/sh\ntouch "%s/codex-called"\n' "$TMP" > "$TMP/stub-codex"; chmod +x "$TMP/stub-codex"
  OUT=$(printf '{"cwd":"%s"}' "$PWD" | CC_CODEX_BIN="$TMP/stub-codex" bash "$HOOK" session-start 2>/dev/null); assert_eq "$?" "0"
  assert_contains "$(printf '%s' "$OUT" | jq -r .systemMessage)" "실행 중이라 지우지 않았습니다"
  kill -0 "$HH_CP" 2>/dev/null || _fail "훅이 Codex 를 죽임"
  assert_no_path "$TMP/codex-called"
  hh_reap
}

# ==== UserPromptSubmit ====
test_prompt_submit_hook_flags_orphan_without_killing() {
  hh_make_orphan
  hh_hook prompt-submit "$PWD"
  assert_eq "$CODE" "0"
  assert_eq "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName')" "UserPromptSubmit"
  ctx=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext')
  assert_contains "$ctx" "[yultopia cc] 기다리는 대기 명령 없이 Codex가 실행 중입니다 (호출 1, 경과 0분)"
  assert_contains "$ctx" "check-orphan --kill"
  assert_contains "$ctx" "cc-codex.sh wait"
  kill -0 "$HH_CP" 2>/dev/null || _fail "훅이 Codex 를 죽임"
  assert_eq "$(state .running.call_id)" "1"
  hh_reap
}
test_prompt_submit_hook_leftover_does_not_suggest_kill() {
  start_task
  ids=$(perl -MPOSIX -e '
    POSIX::setsid() or die;
    my $p = fork; die unless defined $p;
    if ($p == 0) { open STDOUT, ">", "/dev/null"; open STDERR, ">", "/dev/null";
      exec "perl", "-e", "sleep 60", "leftover-member-$ENV{TMP}" or POSIX::_exit(1) }
    print "$$ $p\n"; exit 0')
  LEFT_PG=${ids% *}; LEFT_MEMBER=${ids#* }
  hh_until 3 eval '! kill -0 "$LEFT_PG" 2>/dev/null' || _fail "리더가 끝나지 않음"
  mkdir -p "$ACTIVE/calls/9"
  set_state ".running = {call_id: 9, kind: \"plan\", pgid: $LEFT_PG,
    supervisor_identity: \"Thu Jan  1 00:00:00 2020|bash gone\", codex_pid: null, codex_identity: null,
    started_at: \"$(hh_iso_ago 600)\", review_tree: null}"
  hh_hook prompt-submit "$PWD"
  assert_eq "$CODE" "0"
  ctx=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext')
  assert_contains "$ctx" "프로세스 그룹 $LEFT_PG"
  assert_contains "$ctx" "ps -o pid,command -g $LEFT_PG"
  assert_not_contains "$ctx" "--kill"
  kill -0 "$LEFT_MEMBER" 2>/dev/null || _fail "훅이 확인되지 않은 프로세스를 죽임"
  kill -KILL "$LEFT_MEMBER" 2>/dev/null
}
test_prompt_submit_hook_fast_outside_git() {
  mkdir -p "$TMP/plain"
  hh_hook prompt-submit "$TMP/plain"
  assert_eq "$CODE" "0"; assert_eq "$OUT" ""
}
test_prompt_submit_hook_fast_without_active() {
  repo=$(make_repo)
  t0=$(perl -MTime::HiRes -e 'print Time::HiRes::time()')
  for i in 1 2 3 4 5 6 7 8 9 10; do hh_hook prompt-submit "$repo"; assert_eq "$OUT" ""; assert_eq "$CODE" "0"; done
  t1=$(perl -MTime::HiRes -e 'print Time::HiRes::time()')
  perl -e 'exit(($ARGV[1] - $ARGV[0]) < 2 ? 0 : 1)' "$t0" "$t1" || _fail "10회에 2초 넘게 걸림"
}
test_prompt_submit_hook_silent_when_not_orphan() {
  CC_ORPHAN_GRACE_SECS=30
  start_task
  hh_hook prompt-submit "$PWD"; assert_eq "$CODE" "0"; assert_eq "$OUT" ""    # running 없음
  FAKE_CODEX_SEQ=hang; run_cc call plan; assert_code 0
  hh_until 5 hh_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  HH_PG=$(state .running.pgid)
  hh_hook prompt-submit "$PWD"; assert_eq "$CODE" "0"; assert_eq "$OUT" ""    # 유예(기본 2초) 안
  hh_reap
}
test_prompt_submit_hook_never_calls_codex() {
  hh_make_orphan
  printf '#!/bin/sh\ntouch "%s/codex-called"\n' "$TMP" > "$TMP/stub-codex"; chmod +x "$TMP/stub-codex"
  OUT=$(printf '{"cwd":"%s"}' "$PWD" | CC_CODEX_BIN="$TMP/stub-codex" bash "$HOOK" prompt-submit 2>/dev/null)
  assert_eq "$?" "0"
  printf '%s' "$OUT" | jq -e .hookSpecificOutput.additionalContext >/dev/null || _fail "고아를 알리지 않음: $OUT"
  assert_no_path "$TMP/codex-called"
  hh_reap
}
test_prompt_submit_hook_exits_zero_on_garbage() {
  start_task
  repo=$PWD
  OUT=$(printf 'not json' | CLAUDE_PROJECT_DIR="$repo" bash "$HOOK" prompt-submit 2>/dev/null); assert_eq "$?" "0"; assert_eq "$OUT" ""
  OUT=$(bash "$HOOK" prompt-submit </dev/null 2>/dev/null); assert_eq "$?" "0"; assert_eq "$OUT" ""
  echo '{bad' > "$ACTIVE/state.json"
  OUT=$(printf '{"cwd":"%s"}' "$repo" | bash "$HOOK" prompt-submit 2>/dev/null); assert_eq "$?" "0"; assert_eq "$OUT" ""
  rm -f "$ACTIVE/state.json"
  OUT=$(printf '{"cwd":"%s"}' "$repo" | bash "$HOOK" prompt-submit 2>/dev/null); assert_eq "$?" "0"; assert_eq "$OUT" ""
  mv "$ACTIVE" "$TMP/elsewhere"; ln -s "$TMP/elsewhere" "$ACTIVE"
  OUT=$(printf '{"cwd":"%s"}' "$repo" | bash "$HOOK" prompt-submit 2>/dev/null); assert_eq "$?" "0"; assert_eq "$OUT" ""
  rm -f "$ACTIVE"
}
test_prompt_submit_hook_dead_record_keeps_last_activity() {
  start_task
  old=$(hh_iso_ago $((13 * 86400)))
  pg=$(cc_spawn_group "$TMP/fake-sup.log" perl -e 'sleep 60' "fake-supervisor-$TMP") || _fail "대역 실패"
  id=$(cc_proc_identity "$pg")
  mkdir -p "$ACTIVE/calls/1"
  set_state ".calls_total = 1 | .last_activity_at = \"$old\" | .running = {call_id: 1, kind: \"plan\", pgid: $pg,
    supervisor_identity: \"$id\", codex_pid: null, codex_identity: null, started_at: \"$(hh_iso_ago 500)\", review_tree: null}"
  kill -KILL -- "-$pg"; hh_until 3 eval '! kill -0 -- "-$pg" 2>/dev/null' || _fail "그룹이 끝나지 않음"
  hh_hook prompt-submit "$PWD"
  assert_eq "$CODE" "0"; assert_eq "$OUT" ""
  assert_eq "$(state .running)" "null"
  assert_eq "$(state .last_activity_at)" "$old"
}

# ==== hooks.json ====
test_hooks_json_keeps_handoff_and_adds_cc() {
  h="$CC_REPO_ROOT/plugins/yultopia/hooks/hooks.json"
  ss=$(jq -r '.hooks.SessionStart[].hooks[].command' "$h")
  assert_eq "$(printf '%s\n' "$ss" | sed -n 1p)" '"${CLAUDE_PLUGIN_ROOT}"/bin/inject-handoff.sh'
  assert_contains "$ss" "inject-handoff.sh"
  assert_contains "$ss" "cc-hook.sh session-start"
  assert_contains "$(jq -r '.hooks.UserPromptSubmit[].hooks[].command' "$h")" "cc-hook.sh prompt-submit"
  assert_eq "$(jq -r '.hooks.Stop' "$h")" "null"
  assert_eq "$(jq -r '.hooks.SessionStart[].hooks[] | select(.command | contains("cc-hook")) | .timeout' "$h")" "10"
  assert_eq "$(jq -r '.hooks.UserPromptSubmit[].hooks[].timeout' "$h")" "5"
}
test_hook_script_is_executable_in_git() {
  assert_eq "$(git -C "$CC_REPO_ROOT" ls-files -s plugins/yultopia/bin/cc-hook.sh | cut -c1-6)" "100755"
}

# 활성 작업이 없는 빠른 길: git 한 번, ps·perl 없음
test_prompt_submit_hook_no_active_runs_only_one_git() {
  repo=$(make_repo)
  mkdir -p "$TMP/wrap"
  for c in git ps perl; do
    real=$(command -v $c)
    printf '#!/bin/sh\necho %s >> "%s/calls"\nexec %s "$@"\n' "$c" "$TMP" "$real" > "$TMP/wrap/$c"
    chmod +x "$TMP/wrap/$c"
  done
  OUT=$(printf '{"cwd":"%s"}' "$repo" | PATH="$TMP/wrap:$PATH" bash "$HOOK" prompt-submit 2>/dev/null)
  assert_eq "$?" "0"; assert_eq "$OUT" ""
  assert_eq "$(cat "$TMP/calls" 2>/dev/null)" "git"
}
# 상대 경로로 불러도 동작한다 (cd 하기 전에 스크립트 위치를 정한다)
test_prompt_submit_hook_works_with_relative_invocation() {
  hh_make_orphan
  rel=$(perl -MFile::Spec -e 'print File::Spec->abs2rel($ARGV[0], $ARGV[1])' "$HOOK" "$TMP")
  OUT=$(cd "$TMP" && printf '{"cwd":"%s"}' "$ACTIVE/../../.." | bash "$rel" prompt-submit 2>/dev/null)
  printf '%s' "$OUT" | jq -e .hookSpecificOutput.additionalContext >/dev/null || _fail "상대 경로 호출이 동작하지 않음: [$OUT]"
  hh_reap
}
