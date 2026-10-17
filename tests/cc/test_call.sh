# test_call.sh - Task 5: Codex 호출 정상 흐름 (call, _supervise, 가짜 codex)
. "$CC_REPO_ROOT/plugins/yultopia/lib/cc/proc.sh"

CC_SCHEMA="$CC_REPO_ROOT/plugins/yultopia/lib/cc/pm-output.schema.json"

# ---- 이 파일 전용 도우미 (test_ 로 시작하지 않게) ----
# 조건이 참이 될 때까지 0.1초 간격으로 최대 N초 기다린다
call_until() {
  local secs="$1" i=0; shift
  until "$@"; do
    [ "$i" -ge $((secs * 10)) ] && return 1
    sleep 0.1; i=$((i+1))
  done
}
call_codex_recorded() { [ -n "$(state '.running.codex_pid // empty')" ]; }
call_group_gone() { ! kill -0 -- "-$1" 2>/dev/null; }
# 실행 중인 호출의 그룹을 KILL 로 끝내고 사라질 때까지 기다린다 (테스트 정리용, 자기 그룹은 건드리지 않음)
call_reap() {
  local pg mypg
  pg=$(state '.running.pgid // empty' 2>/dev/null)
  case "$pg" in ''|*[!0-9]*|0|1) return 0 ;; esac
  mypg=$(ps -o pgid= -p $$ | tr -d ' ')
  [ "$pg" = "$mypg" ] && return 0
  kill -KILL -- "-$pg" 2>/dev/null
  call_until 3 call_group_gone "$pg"
}
# call_result <verdict> <milestone|null> [plan-json] : 스키마에 맞는 결과 JSON 한 줄
call_result() {
  jq -cn --arg v "$1" --argjson m "$2" --argjson p "${3:-null}" '{
    verdict: $v, summary: "요약", plan: $p, milestone: $m,
    instruction: (if $m == null then null else "지시" end),
    findings: (if $v == "reject" then [{file: "a.txt", line: 1, issue: "문제", evidence: "근거"}] else [] end),
    question: (if $v == "ask_user" then "질문" else null end)
  }'
}
call_lines() { printf '%s\n' "$1" | wc -l | tr -d ' '; }

# ---- 정상 흐름 ----
test_plan_call_creates_session_and_applies_plan() {
  start_task "my repo 한글"
  run_cc call plan; assert_code 0; assert_contains "$OUT" "[cc] Codex 호출 시작"
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  assert_eq "$(cat "$CALL1/status")" "ok"
  assert_eq "$(state .session_id)" "fake-thread-1"
  assert_eq "$(state .milestone)" "1"; assert_eq "$(state .phase)" "working"
  assert_eq "$(state .milestones_total)" "2"
  assert_eq "$(state .milestone_base_tree)" "$(state .task_base_tree)"
  assert_eq "$(state .calls_total)" "1"
  assert_eq "$(state .tokens.input)" "100"
  assert_eq "$(state .tokens.cached_input)" "20"
  assert_eq "$(state .tokens.output)" "10"; assert_eq "$(state .running)" "null"
  assert_eq "$(state .last_call.status)" "ok"
  assert_eq "$(state .last_call.verdict)" "plan"
  assert_eq "$(state .last_call.call_id)" "1"
  assert_eq "$(state .last_call.kind)" "plan"
  assert_file_exists "$CALL1/prompt.md"
  assert_file_exists "$CALL1/events.jsonl"
  assert_eq "$(jq -r .verdict "$CALL1/result.json")" "plan"
}
test_codex_argv_is_workspace_write_without_model_overrides() {
  # R31: Codex 가 테스트를 직접 돌리도록 쓰기 sandbox. 네트워크 설정은 덮어쓰지 않는다 (Codex 기본값 그대로: 막힘)
  start_task; run_cc call plan; wait_until_status_file 1
  printf '%s' "$REVIEW_REPORT" > "$(cc_path report)"; run_cc call review; wait_until_status_file 2
  a1=$(cat "$FAKE_CODEX_LOG/1.argv"); a2=$(cat "$FAKE_CODEX_LOG/2.argv")
  assert_contains "$a1" "workspace-write"; assert_contains "$a2" 'sandbox_mode="workspace-write"'
  assert_not_contains "$a1$a2" "read-only"
  assert_not_contains "$a1$a2" "network"
  assert_contains "$a2" "fake-thread-1"
  for a in "$a1" "$a2"; do                     # argv 는 한 줄에 인자 하나
    assert_eq "$(printf '%s\n' "$a" | grep -cx -e '-m' -e '--model')" "0"
    assert_not_contains "$a" "model"           # model=, model_reasoning_effort 모두 차단 (sandbox_mode 는 "model" 을 포함하지 않음)
  done
}
test_codex_argv_exact_shapes() {
  start_task; run_cc call plan; wait_until_status_file 1
  printf '%s' "$REVIEW_REPORT" > "$(cc_path report)"; run_cc call review; wait_until_status_file 2
  want1=$(printf '%s\n' exec --json -s workspace-write --output-schema "$CC_SCHEMA" -o "$ACTIVE/calls/1/result.json" -)
  want2=$(printf '%s\n' exec resume --json -c 'sandbox_mode="workspace-write"' --output-schema "$CC_SCHEMA" \
    -o "$ACTIVE/calls/2/result.json" fake-thread-1 -)
  assert_eq "$(cat "$FAKE_CODEX_LOG/1.argv")" "$want1"
  assert_eq "$(cat "$FAKE_CODEX_LOG/2.argv")" "$want2"
}
test_codex_runs_from_repo_root() {
  start_task "my repo 한글"
  repo=$(pwd -P)
  mkdir -p sub/deeper; cd sub/deeper
  run_cc call plan; assert_code 0
  wait_until_status_file 1
  assert_eq "$(cat "$FAKE_CODEX_LOG/1.cwd")" "$repo"
}
test_prompt_reaches_codex_stdin_intact() {
  repo=$(make_repo "my repo 한글"); cd "$repo"
  FAKE_CODEX_LOG="$TMP/fake-codex.log"
  cat > "$TMP/brief.txt" <<'EOF'
목표: "쌍따옴표" 'i' $HOME ${PATH} $(uname) `uname` \역슬래시 \n 그대로
자리표시자처럼 보이는 글: {{BRIEF}} {{REPORT}} {{MESSAGE}}
	탭으로 시작하는 줄 & | ; < > * ? [a] ~ ! # %
EOF
  perl -e 'print "긴 본문 줄 $_: 가나다라마바사 abcdefghij \$x `y` \"q\"\n" for 1..200' >> "$TMP/brief.txt"
  size=$(wc -c < "$TMP/brief.txt" | tr -d ' ')
  [ "$size" -ge 10240 ] || _fail "정리본이 10KB 미만: $size"
  run_cc init < "$TMP/brief.txt"; assert_code 0
  ACTIVE=$(cc_path active)
  run_cc call plan; assert_code 0
  wait_until_status_file 1
  got=$(cat "$FAKE_CODEX_LOG/1.stdin")
  assert_contains "$got" "$(cat "$TMP/brief.txt")"
  assert_contains "$got" "<brief>"
  cmp -s "$FAKE_CODEX_LOG/1.stdin" "$ACTIVE/calls/1/prompt.md" || _fail "codex stdin 이 prompt.md 와 다름"
}
test_call_stdout_has_no_event_log() {
  start_task; run_cc call plan; assert_code 0
  assert_eq "$(call_lines "$OUT")" "1"
  assert_not_contains "$OUT" "thread.started"
  wait_until_status_file 1
  assert_not_contains "$OUT" "turn.completed"
  grep -q '"thread.started"' "$CALL1/events.jsonl" || _fail "이벤트가 events.jsonl 에 기록되지 않음"
}
test_review_records_trees_and_approve_moves_milestone() {
  start_task "my repo 한글"
  run_cc call plan; wait_until_status_file 1
  base=$(state .task_base_tree)
  mkdir -p src; echo a > src/a.txt
  want_tree=$(GIT_INDEX_FILE="$TMP/expect.index" sh -c 'git read-tree HEAD && git add -A && git write-tree')
  [ "$want_tree" != "$base" ] || _fail "작업 트리 변경이 스냅샷에 반영되지 않음"
  printf '%s' "$REVIEW_REPORT" > "$(cc_path report)"
  set_state '.rejects_in_row = 1'
  plan3='{"overview":"바뀐 계획","milestones":[{"id":1,"title":"a","done_criteria":"x"},{"id":2,"title":"b","done_criteria":"y"},{"id":3,"title":"c","done_criteria":"z"}]}'
  FAKE_CODEX_RESULT=$(call_result approve 2 "$plan3")
  run_cc call review; assert_code 0
  wait_until_status_file 2
  assert_eq "$(cat "$ACTIVE/calls/2/status")" "ok"
  assert_eq "$(state .milestone)" "2"
  assert_eq "$(state .milestone_base_tree)" "$want_tree"
  assert_eq "$(state .rejects_in_row)" "0"
  assert_eq "$(state .phase)" "working"
  assert_eq "$(state .milestones_total)" "3"
  assert_eq "$(state .last_call.verdict)" "approve"
  assert_eq "$(state .last_call.kind)" "review"
  p2=$(cat "$FAKE_CODEX_LOG/2.stdin")
  assert_contains "$p2" "마일스톤 1 을 검수"
  assert_contains "$p2" "git diff $base $want_tree"
  assert_contains "$p2" "$REVIEW_REPORT"
  assert_contains "$p2" "$ACTIVE/verify"
  [ -d "$ACTIVE/verify" ] || _fail "verify 폴더 없음"
  assert_eq "$(git diff --cached --name-only)" ""
}
test_verdicts_update_phase_and_rejects() {
  start_task; run_cc call plan; wait_until_status_file 1
  printf '사용자 지시: 계속 진행\n' > "$(cc_path message)"
  FAKE_CODEX_RESULT=$(call_result reject 1); run_cc call message; assert_code 0; wait_until_status_file 2
  # Ruling R27: 메시지 호출의 reject 는 검수가 아니므로 연속 반려로 세지 않는다
  assert_eq "$(state .rejects_in_row)" "0"; assert_eq "$(state .phase)" "working"
  assert_eq "$(state .milestone)" "1"; assert_eq "$(state .last_call.verdict)" "reject"
  FAKE_CODEX_RESULT=$(call_result ask_user null); run_cc call message; assert_code 0; wait_until_status_file 3
  assert_eq "$(state .phase)" "asking"; assert_eq "$(state .rejects_in_row)" "0"
  FAKE_CODEX_RESULT=$(call_result done null); run_cc call message; assert_code 0; wait_until_status_file 4
  # 최종 리뷰 minor b: 메시지 호출의 done 은 검수가 아니므로 작업 완료가 아니다 → 이어가기(working)
  assert_eq "$(state .phase)" "working"
  assert_eq "$(state .last_call.status)" "ok"; assert_eq "$(state .last_call.verdict)" "done"
  assert_eq "$(state .calls_total)" "4"
  assert_eq "$(state .tokens.output)" "40"
  assert_eq "$(state .session_id)" "fake-thread-1"
  assert_eq "$(sed -n 2p "$FAKE_CODEX_LOG/4.argv")" "resume"
  assert_contains "$(cat "$FAKE_CODEX_LOG/2.stdin")" "사용자 지시: 계속 진행"
}

# ---- Ruling R27: call message 의 결과는 검수가 아니다 (마일스톤은 call review 로만 승인·반려) ----
test_message_approve_same_milestone_continues_without_review() {
  start_task; run_cc call plan; wait_until_status_file 1
  set_state '.rejects_in_row = 2 | .milestone_base_tree = "base-before-message"'
  printf '사용자 지시: 방향 수정\n' > "$(cc_path message)"
  plan3='{"overview":"바뀐 계획","milestones":[{"id":1,"title":"a","done_criteria":"x"},{"id":2,"title":"b","done_criteria":"y"},{"id":3,"title":"c","done_criteria":"z"}]}'
  FAKE_CODEX_RESULT=$(call_result approve 1 "$plan3"); run_cc call message; assert_code 0
  wait_until_status_file 2 || _fail "calls/2/status 가 생기지 않음"
  assert_eq "$(cat "$ACTIVE/calls/2/status")" "ok"
  assert_eq "$(state .milestone)" "1"
  assert_eq "$(state .rejects_in_row)" "2"
  assert_eq "$(state .milestone_base_tree)" "base-before-message"
  assert_eq "$(state .phase)" "working"
  assert_eq "$(state .milestones_total)" "3"
  assert_eq "$(state .last_call.kind)" "message"; assert_eq "$(state .last_call.verdict)" "approve"
}
test_message_approve_other_milestone_keeps_current() {
  start_task; run_cc call plan; wait_until_status_file 1
  set_state '.milestone = 2 | .rejects_in_row = 1 | .milestone_base_tree = "m2-base"'
  printf '사용자 지시: 다음으로 넘어가\n' > "$(cc_path message)"
  FAKE_CODEX_RESULT=$(call_result approve 3); run_cc call message; assert_code 0
  wait_until_status_file 2 || _fail "calls/2/status 가 생기지 않음"
  assert_eq "$(state .milestone)" "2"
  assert_eq "$(state .milestone_base_tree)" "m2-base"
  assert_eq "$(state .rejects_in_row)" "1"
  assert_eq "$(state .phase)" "working"
}
test_message_reject_does_not_count_toward_reject_limit() {
  start_task; run_cc call plan; wait_until_status_file 1
  set_state '.rejects_in_row = 2'
  printf 'Claude 반대 의견\n' > "$(cc_path message)"
  FAKE_CODEX_RESULT=$(call_result reject 1); run_cc call message; assert_code 0
  wait_until_status_file 2 || _fail "calls/2/status 가 생기지 않음"
  assert_eq "$(state .rejects_in_row)" "2"; assert_eq "$(state .phase)" "working"
  assert_eq "$(state .milestone)" "1"
  # 검수 요청은 아직 막히지 않고, 검수의 reject 는 센다
  printf '%s' "$REVIEW_REPORT" > "$(cc_path report)"
  FAKE_CODEX_RESULT=$(call_result reject 1); run_cc call review; assert_code 0
  wait_until_status_file 3 || _fail "calls/3/status 가 생기지 않음"
  assert_eq "$(state .rejects_in_row)" "3"
}
test_message_approve_without_milestone_adopts_codex_milestone() {
  # 계획 호출이 세션만 남기고 실패한 경우 (milestone 이 아직 없음): Codex 가 준 번호를 쓴다
  start_task; set_state '.session_id = "fake-thread-1"'
  printf '사용자 지시\n' > "$(cc_path message)"
  FAKE_CODEX_RESULT=$(call_result approve 1); run_cc call message; assert_code 0
  wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  assert_eq "$(state .milestone)" "1"
  assert_eq "$(state .rejects_in_row)" "0"
  assert_eq "$(state .milestone_base_tree)" "null"
}
# ---- 최종 리뷰 minor c: done 뒤 추가 수정 요구(call message)는 새 마일스톤. 기준은 메시지 호출 때의 작업 트리 ----
call_tree_now() { GIT_INDEX_FILE="$TMP/expect.index" sh -c 'git read-tree HEAD && git add -A && git write-tree'; }
call_to_done() {   # 계획 → 작업 → 검수 done 까지 (마일스톤 1)
  run_cc call plan; wait_until_status_file 1 || _fail "calls/1/status 가 생기지 않음"
  mkdir -p src; echo a > src/a.txt
  printf '%s' "$REVIEW_REPORT" > "$(cc_path report)"
  FAKE_CODEX_RESULT=$(call_result done null); run_cc call review; assert_code 0
  wait_until_status_file 2 || _fail "calls/2/status 가 생기지 않음"
  assert_eq "$(state .phase)" "done"
}
test_message_after_done_starts_new_milestone_from_fresh_base() {
  start_task; call_to_done
  set_state '.rejects_in_row = 2'
  want=$(call_tree_now)
  [ "$want" != "$(state .milestone_base_tree)" ] || _fail "테스트 전제 깨짐: 기준 트리가 같음"
  printf '사용자 지시: b 도 추가해 줘\n' > "$(cc_path message)"
  FAKE_CODEX_RESULT=$(call_result approve 2); run_cc call message; assert_code 0
  wait_until_status_file 3 || _fail "calls/3/status 가 생기지 않음"
  assert_eq "$(cat "$ACTIVE/calls/3/status")" "ok"
  assert_eq "$(state .milestone)" "2"
  assert_eq "$(state .milestone_base_tree)" "$want"
  assert_eq "$(state .rejects_in_row)" "0"
  assert_eq "$(state .phase)" "working"
  assert_eq "$(state .milestones_total)" "2"
  assert_eq "$(state .running)" "null"
  # Codex 에는 완료 뒤의 추가 수정 요구라는 것이 전해진다
  assert_contains "$(cat "$FAKE_CODEX_LOG/3.stdin")" "지금 단계: done"
  # 다음 검수는 새 작업만 본다: 마일스톤 2, 기준 = 메시지 호출 때의 트리
  echo b > src/b.txt
  FAKE_CODEX_RESULT=$(call_result approve 3); run_cc call review; assert_code 0
  wait_until_status_file 4 || _fail "calls/4/status 가 생기지 않음"
  p4=$(cat "$FAKE_CODEX_LOG/4.stdin")
  assert_contains "$p4" "마일스톤 2 을 검수"
  assert_contains "$p4" "git diff $want "
}
test_message_after_done_advances_even_if_codex_keeps_number() {
  start_task; call_to_done
  want=$(call_tree_now)
  printf '사용자 지시: 조금 더\n' > "$(cc_path message)"
  # Codex 가 지금 번호(1)를 그대로 주어도 새 마일스톤(2)으로 센다. 전체 수보다 커지면 전체 수도 늘린다
  set_state '.milestones_total = 1'
  FAKE_CODEX_RESULT=$(call_result approve 1); run_cc call message; assert_code 0
  wait_until_status_file 3 || _fail "calls/3/status 가 생기지 않음"
  assert_eq "$(state .milestone)" "2"; assert_eq "$(state .milestones_total)" "2"
  assert_eq "$(state .milestone_base_tree)" "$want"; assert_eq "$(state .phase)" "working"
  # 이어지는 메시지(이제 done 아님)는 평소처럼 지금 마일스톤·기준을 유지한다
  FAKE_CODEX_RESULT=$(call_result approve 2); run_cc call message; assert_code 0
  wait_until_status_file 4 || _fail "calls/4/status 가 생기지 않음"
  assert_eq "$(state .milestone)" "2"; assert_eq "$(state .milestone_base_tree)" "$want"
  assert_contains "$(cat "$FAKE_CODEX_LOG/4.stdin")" "지금 단계: working"
}
test_message_after_done_question_still_opens_new_milestone() {
  # Codex 가 먼저 물어도(ask_user) 새 마일스톤의 기준은 사용자가 추가 수정을 요구한 그때의 트리다
  start_task; call_to_done
  want=$(call_tree_now)
  printf '사용자 지시: 추가 기능\n' > "$(cc_path message)"
  FAKE_CODEX_RESULT=$(call_result ask_user null); run_cc call message; assert_code 0
  wait_until_status_file 3 || _fail "calls/3/status 가 생기지 않음"
  assert_eq "$(state .phase)" "asking"
  assert_eq "$(state .milestone)" "2"; assert_eq "$(state .milestone_base_tree)" "$want"
}
test_message_prompt_names_current_milestone() {
  start_task; run_cc call plan; wait_until_status_file 1
  set_state '.milestone = 2'
  printf '사용자 지시\n' > "$(cc_path message)"
  FAKE_CODEX_RESULT=$(call_result approve 2); run_cc call message; assert_code 0
  wait_until_status_file 2 || _fail "calls/2/status 가 생기지 않음"
  assert_contains "$(cat "$FAKE_CODEX_LOG/2.stdin")" "지금 진행 중인 마일스톤: 2"
}
test_supervisor_records_codex_identity() {
  FAKE_CODEX_SEQ=hang; start_task
  run_cc call plan; assert_code 0
  call_until 5 call_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  pg=$(state .running.pgid); cp=$(state .running.codex_pid)
  assert_contains "$(state .running.codex_identity)" "fake-codex"
  assert_contains "$(state .running.supervisor_identity)" "_supervise 1"
  assert_code_of 0 cc_proc_alive_verified "$cp" "$(state .running.codex_identity)"
  assert_code_of 0 cc_proc_alive_verified "$pg" "$(state .running.supervisor_identity)"
  assert_eq "$(ps -o pgid= -p "$cp" | tr -d ' ')" "$pg"
  assert_eq "$(ps -o pgid= -p "$pg" | tr -d ' ')" "$pg"
  assert_eq "$(state .running.kind)" "plan"
  assert_eq "$(state .running.call_id)" "1"
  call_reap
}
test_activity_updates_while_events_grow() {
  FAKE_CODEX_SEQ=slow; FAKE_CODEX_DELAY=5; start_task
  run_cc call plan; assert_code 0
  call_until 5 call_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  t0=$(state .last_activity_at)
  sleep 2.5
  t1=$(state .last_activity_at)
  [ "$(state .running)" != "null" ] || _fail "호출이 너무 일찍 끝남"
  [[ "$t1" > "$t0" ]] || _fail "이벤트가 늘었는데 last_activity_at 이 그대로 ($t0 → $t1)"
  wait_until_status_file 1 10
  assert_eq "$(cat "$CALL1/status")" "ok"
}

# ---- 실행 중 단계 (Task 7): review → reviewing, plan → planning, message 는 그대로 ----
test_review_call_sets_phase_reviewing() {
  FAKE_CODEX_SEQ=ok,hang; start_task
  run_cc call plan; wait_until_status_file 1
  assert_eq "$(state .phase)" "working"
  printf '%s' "$REVIEW_REPORT" > "$(cc_path report)"
  run_cc call review; assert_code 0
  assert_eq "$(state .phase)" "reviewing"
  run_cc status; assert_contains "$OUT" "단계: reviewing"
  call_reap
}
test_plan_call_sets_phase_planning() {
  FAKE_CODEX_SEQ=hang; start_task
  set_state '.phase = "failed"'
  run_cc call plan; assert_code 0
  assert_eq "$(state .phase)" "planning"
  call_reap
}
test_message_call_keeps_phase() {
  FAKE_CODEX_SEQ=ok,hang; start_task
  run_cc call plan; wait_until_status_file 1
  set_state '.phase = "asking"'
  printf '사용자 답변\n' > "$(cc_path message)"
  run_cc call message; assert_code 0
  assert_eq "$(state .phase)" "asking"
  call_reap
}

# ---- 실패로 끝나는 호출 (Task 6 의 재시도가 붙어도 결과가 같도록 두 번 연속 실패시킨다) ----
test_invalid_result_ends_call_as_invalid_json() {
  FAKE_CODEX_SEQ=invalid_json,invalid_json; start_task
  run_cc call plan; assert_code 0
  wait_until_status_file 1
  assert_eq "$(cat "$CALL1/status")" "invalid_json"
  assert_eq "$(state .running)" "null"
  assert_eq "$(state .last_call.status)" "invalid_json"
  assert_eq "$(state .last_call.verdict)" "null"
  assert_contains "$(state .last_call.message)" "형식"
  assert_eq "$(state .phase)" "failed"
  assert_eq "$(state .session_id)" "fake-thread-1"
}
test_supervisor_killed_still_leaves_terminal_state() {
  FAKE_CODEX_SEQ=hang; start_task
  run_cc call plan; assert_code 0
  call_until 5 call_codex_recorded || _fail "codex_pid 가 기록되지 않음"
  pg=$(state .running.pgid)
  kill -TERM "$pg"                              # 감독 프로세스에만 신호
  wait_until_status_file 1 || _fail "status 파일이 생기지 않음"
  assert_eq "$(cat "$CALL1/status")" "interrupted"
  assert_eq "$(state .running)" "null"
  assert_eq "$(state .last_call.status)" "interrupted"
  assert_eq "$(state .phase)" "interrupted"
  call_until 3 call_group_gone "$pg" || _fail "codex 그룹이 남아 있음"
  assert_no_process_matching "fake-codex-hang:$FAKE_CODEX_LOG"
}
test_codex_failure_ends_call_as_error() {
  FAKE_CODEX_SEQ=fail_fast,fail_fast; start_task
  run_cc call plan; assert_code 0
  wait_until_status_file 1
  assert_eq "$(cat "$CALL1/status")" "error"
  assert_eq "$(state .running)" "null"
  assert_eq "$(state .last_call.status)" "error"
  assert_contains "$(state .last_call.message)" "실패"
  assert_eq "$(state .phase)" "failed"
}

# ---- 거부 ----
test_call_refuses_while_running() {
  FAKE_CODEX_SEQ=hang; start_task
  run_cc call plan; assert_code 0
  run_cc call plan; assert_code 6
  assert_eq "$(call_lines "$OUT")" "1"; assert_contains "$OUT" "실행 중"
  assert_eq "$(state .calls_total)" "1"
  assert_no_path "$ACTIVE/calls/2"
  assert_eq "$(state .running.call_id)" "1"
  call_reap
}
test_call_refuses_at_max_calls() {
  start_task; set_state '.calls_total = 20'
  run_cc call plan; assert_code 6
  assert_eq "$(call_lines "$OUT")" "1"; assert_contains "$OUT" "호출 상한 20회"
  assert_eq "$(state .calls_total)" "20"; assert_eq "$(state .running)" "null"
  assert_no_path "$ACTIVE/calls/21"
  assert_no_path "$FAKE_CODEX_LOG/1.argv"
}
test_review_refused_at_max_rejects() {
  start_task; set_state '.session_id = "fake-thread-1" | .rejects_in_row = 3'
  printf '%s' "$REVIEW_REPORT" > "$(cc_path report)"
  run_cc call review; assert_code 6
  assert_eq "$(call_lines "$OUT")" "1"; assert_contains "$OUT" "연속 반려 3회"
  assert_eq "$(state .calls_total)" "0"
  printf '사용자 지시\n' > "$(cc_path message)"
  run_cc call message; assert_code 0
  wait_until_status_file 1
}
test_review_and_message_need_session() {
  # Ruling R14: 세션 없음은 정책 거부(6)가 아니라 오류(1)
  start_task
  printf '%s' "$REVIEW_REPORT" > "$(cc_path report)"
  run_cc call review; assert_code 1
  assert_eq "$(call_lines "$OUT")" "1"; assert_contains "$OUT" "세션"
  printf '사용자 지시\n' > "$(cc_path message)"
  run_cc call message; assert_code 1
  assert_eq "$(call_lines "$OUT")" "1"; assert_contains "$OUT" "세션"
  assert_eq "$(state .calls_total)" "0"; assert_eq "$(state .running)" "null"
  assert_no_path "$FAKE_CODEX_LOG/1.argv"
}
test_call_needs_input_files() {
  start_task; set_state '.session_id = "fake-thread-1"'
  run_cc call review; assert_code 1
  assert_eq "$(call_lines "$OUT")" "1"; assert_contains "$OUT" "보고"
  run_cc call message; assert_code 1
  assert_eq "$(call_lines "$OUT")" "1"; assert_contains "$OUT" "메시지"
  run_cc call bogus; assert_code 1
  assert_eq "$(call_lines "$OUT")" "1"
  assert_eq "$(state .calls_total)" "0"
  repo2=$(make_repo other); cd "$repo2"
  run_cc call plan; assert_code 1
  assert_eq "$(call_lines "$OUT")" "1"
}
test_call_not_blocked_by_dead_running_record() {
  start_task
  bash -c 'exit 0' & dead=$!; wait "$dead"
  set_state ".running = {call_id: 9, kind: \"plan\", pgid: $dead,
    supervisor_identity: \"Thu Jan  1 00:00:00 2020|bash gone\", codex_pid: null, codex_identity: null,
    started_at: \"2020-01-01T00:00:00Z\", review_tree: null}"
  run_cc call plan; assert_code 0
  wait_until_status_file 1
  assert_eq "$(cat "$CALL1/status")" "ok"
  assert_eq "$(state .running)" "null"
}

# ---- 결과 검증 (Ruling R12) ----
test_result_validator_follows_r12() {
  . "$CC_REPO_ROOT/plugins/yultopia/lib/cc/call.sh"
  f="$TMP/r.json"
  ok_case()  { printf '%s\n' "$1" > "$f"; cc_result_valid "$f" || _fail "받아야 함: $1"; }
  bad_case() { printf '%s\n' "$1" > "$f"; cc_result_valid "$f" && _fail "거부해야 함: $1"; return 0; }
  plan2='{"overview":"o","milestones":[{"id":1,"title":"a","done_criteria":"x"}]}'
  ok_case "$(call_result plan 1 "$plan2")"
  ok_case "$(call_result approve 2)"
  ok_case "$(call_result approve 2 "$plan2")"
  ok_case "$(call_result reject 1 "$plan2")"
  ok_case "$(call_result done null)"
  ok_case "$(call_result done 3)"
  ok_case "$(call_result ask_user null)"
  bad_case 'not json'
  bad_case '[]'
  bad_case "$(call_result plan 1 "$plan2") $(call_result plan 1 "$plan2")"
  bad_case "$(call_result plan 1 "$plan2" | jq -c 'del(.question)')"
  bad_case "$(call_result plan 1 "$plan2" | jq -c '.verdict = "pla"')"
  bad_case "$(call_result plan 1)"
  bad_case "$(call_result approve null)"
  bad_case "$(call_result approve 2 '{"overview":"o"}')"
  : > "$f"; cc_result_valid "$f" && _fail "빈 파일을 받음"
  cc_result_valid "$TMP/없는파일.json" && _fail "없는 파일을 받음"
  return 0
}

# ---- Codex 리뷰 4 (R30): 호출 종류·verdict 별로 절차가 다음에 할 일이 있는 결과만 받는다 ----
test_result_validator_checks_kind_and_verdict_content() {
  . "$CC_REPO_ROOT/plugins/yultopia/lib/cc/call.sh"
  f="$TMP/r.json"
  ok_k()  { printf '%s\n' "$2" > "$f"; cc_result_valid "$f" "$1" || _fail "받아야 함 ($1): $2"; }
  bad_k() { printf '%s\n' "$2" > "$f"; cc_result_valid "$f" "$1" && _fail "거부해야 함 ($1): $2"; return 0; }
  plan1='{"overview":"o","milestones":[{"id":1,"title":"a","done_criteria":"x"}]}'
  empty='{"overview":"o","milestones":[]}'
  # plan 호출: plan(마일스톤 1개 이상, 지시, milestone 1 또는 null) 또는 ask_user(질문) 만
  ok_k plan "$(call_result plan 1 "$plan1")"
  ok_k plan "$(call_result plan 1 "$plan1" | jq -c '.milestone = null')"
  ok_k plan "$(call_result ask_user null)"
  bad_k plan "$(call_result plan 1 "$empty")"
  bad_k plan "$(call_result plan 1 "$plan1" | jq -c '.instruction = null')"
  bad_k plan "$(call_result plan 1 "$plan1" | jq -c '.instruction = "  "')"
  bad_k plan "$(call_result plan 2 "$plan1")"
  bad_k plan "$(call_result ask_user null | jq -c '.question = null')"
  bad_k plan "$(call_result ask_user null | jq -c '.question = ""')"
  bad_k plan "$(call_result done null)"
  bad_k plan "$(call_result approve 1)"
  bad_k plan "$(call_result reject 1)"
  # review 호출: approve(정수 milestone, 지시), reject(지시), done, ask_user(질문)
  ok_k review "$(call_result approve 2)"
  ok_k review "$(call_result approve 2 "$plan1")"
  ok_k review "$(call_result reject 1)"
  ok_k review "$(call_result done null)"
  ok_k review "$(call_result ask_user null)"
  bad_k review "$(call_result approve 2 | jq -c '.instruction = null')"
  bad_k review "$(call_result approve null)"
  bad_k review "$(call_result reject 1 | jq -c '.instruction = ""')"
  bad_k review "$(call_result ask_user null | jq -c '.question = null')"
  bad_k review "$(call_result plan 1 "$plan1")"
  # message 호출: approve(지시), ask_user(질문), plan(마일스톤 1개 이상 + 지시). done·reject 는 R27 대로 받는다
  ok_k message "$(call_result approve 1)"
  ok_k message "$(call_result ask_user null)"
  ok_k message "$(call_result plan 1 "$plan1")"
  ok_k message "$(call_result done null)"
  ok_k message "$(call_result reject 1)"
  bad_k message "$(call_result approve 1 | jq -c '.instruction = null')"
  bad_k message "$(call_result ask_user null | jq -c '.question = "   "')"
  bad_k message "$(call_result plan 1 "$empty")"
  bad_k message "$(call_result plan 1 "$plan1" | jq -c '.instruction = null')"
  # 거부 이유는 한 줄이고 무엇이 틀렸는지 말한다 (형식 재요청 프롬프트에 그대로 넣는다)
  printf '%s\n' "$(call_result plan 1 "$empty")" > "$f"
  why=$(cc_result_problem "$f" plan); assert_eq "$?" "1"
  assert_eq "$(call_lines "$why")" "1"; assert_contains "$why" "마일스톤"
  printf '%s\n' "$(call_result ask_user null | jq -c '.question = null')" > "$f"
  assert_contains "$(cc_result_problem "$f" review)" "question"
  printf '%s\n' "$(call_result done null)" > "$f"
  assert_contains "$(cc_result_problem "$f" plan)" "plan"
  printf 'not json\n' > "$f"
  why=$(cc_result_problem "$f" plan); assert_eq "$?" "1"
  assert_contains "$why" "JSON"; assert_not_contains "$why" "not json"
  printf '%s\n' "$(call_result plan 1 "$plan1")" > "$f"
  why=$(cc_result_problem "$f" plan); assert_eq "$?" "0"; assert_eq "$why" ""
  return 0
}
