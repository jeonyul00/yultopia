# test_skill.sh - Task 10: /yultopia:cc SKILL.md (Claude 가 따를 절차)

SKILL_FILE="$CC_REPO_ROOT/plugins/yultopia/skills/cc/SKILL.md"

# ---- 이 파일 전용 도우미 (test_ 로 시작하지 않게) ----
skill_frontmatter() { awk 'NR == 1 && $0 == "---" { inside = 1; next } inside && $0 == "---" { exit } inside { print }' "$SKILL_FILE"; }
# cc-codex.sh 의 하위 명령 분기(case "$cmd" in … esac)에 있는 이름들 (내부용 _supervise 제외)
skill_cli_subcommands() {
  sed -n '/^case "\$cmd" in/,/^esac/p' "$CC_BIN" | grep -oE '^  [a-z][a-z-]*\)' | tr -d ' )'
}

test_skill_frontmatter() {
  f="$SKILL_FILE"
  assert_file_exists "$f"
  assert_eq "$(sed -n 1p "$f")" "---"
  assert_contains "$(sed -n 1,8p "$f")" "name: cc"
  assert_contains "$(sed -n 1,8p "$f")" "disable-model-invocation: true"
  fm=$(skill_frontmatter)
  assert_contains "$fm" 'argument-hint: "[하고 싶은 것 — 대충 말해도 됨]"'
  assert_contains "$fm" "allowed-tools: Bash(cc-codex.sh:*)"
  desc=$(printf '%s\n' "$fm" | sed -n 's/^description: //p')
  [ -n "$desc" ] || _fail "description 없음"
  # description 은 영어 한 줄
  printf '%s' "$desc" | LC_ALL=C grep -q '[^ -~]' && _fail "description 이 영어(ASCII)가 아님: $desc"
  assert_contains "$desc" "Codex"
  assert_eq "$(printf '%s\n' "$fm" | grep -c '^description:')" "1"
}
test_skill_uses_only_existing_subcommands() {
  for sub in $(grep -o 'cc-codex\.sh [a-z-]*' "$SKILL_FILE" | awk '{print $2}' | sort -u); do
    assert_contains "preflight init path status call wait ack-rejects check-orphan cleanup-stale discard finish put release-quarantine" "$sub"
  done
}
test_skill_subcommands_exist_in_cli() {
  subs=$(skill_cli_subcommands)
  assert_contains "$subs" "put"
  for sub in $(grep -o 'cc-codex\.sh [a-z-]*' "$SKILL_FILE" | awk '{print $2}' | sort -u); do
    printf '%s\n' "$subs" | grep -qx -- "$sub" || _fail "SKILL 이 없는 하위 명령을 씀: $sub"
  done
  assert_not_contains "$(cat "$SKILL_FILE")" "_supervise"
}
test_skill_states_core_rules() {
  s=$(cat "$SKILL_FILE")
  assert_contains "$s" "묻지 않고"
  assert_contains "$s" "승인 없이"
  assert_contains "$s" "ack-rejects"
  assert_contains "$s" "finish"
}
test_skill_writes_state_files_only_through_put() {
  s=$(cat "$SKILL_FILE")
  # .git 안 상태 파일은 Write/Edit 도구로 쓸 수 없다 (Ruling R25): 보고·메시지·정리본·검증 출력은 put 으로
  assert_contains "$s" "cc-codex.sh put report <<'CC_END'"
  assert_contains "$s" "cc-codex.sh put message <<'CC_END'"
  assert_contains "$s" "cc-codex.sh put brief <<'CC_END'"
  assert_contains "$s" "cc-codex.sh init <<'CC_END'"
  assert_contains "$s" '2>&1 | cc-codex.sh put verify m'
  assert_contains "$s" "{ <검증 명령>; printf '\\nexit=%s\\n' \"\$?\"; } 2>&1 | cc-codex.sh put verify m"
  assert_not_contains "$s" 'echo "exit='
  assert_contains "$s" "Write·Edit 도구로 쓰지 않는다"
}
test_skill_wait_uses_long_bash_timeout() {
  s=$(cat "$SKILL_FILE")
  assert_contains "$s" "cc-codex.sh wait"
  assert_contains "$s" "600000"
  assert_contains "$s" "run_in_background"
}
test_skill_covers_hook_and_orphan_handling() {
  s=$(cat "$SKILL_FILE")
  assert_contains "$s" "[yultopia cc]"
  assert_contains "$s" "check-orphan --kill"
  assert_contains "$s" "ps -o pid,command -g"
}
test_skill_covers_preflight_codes() {
  s=$(cat "$SKILL_FILE")
  for code in not_git no_jq no_codex not_logged_in orphan_running active_present dirty ready stale_notice dirty_files; do
    assert_contains "$s" "$code"
  done
}
test_skill_covers_verdicts_and_user_priority() {
  s=$(cat "$SKILL_FILE")
  for v in plan approve reject done ask_user; do
    assert_contains "$s" "\`$v\`"
  done
  assert_contains "$s" "Codex 질문:"
  assert_contains "$s" "완료로 할까요? 커밋할까요?"
  assert_contains "$s" "미리 허락한 위험 작업"
  assert_contains "$s" "사용자의 말이 Codex 지시보다 항상 우선"
  assert_contains "$s" "푸시"
}
test_skill_message_results_are_not_reviews() {
  # Ruling R27: call message 의 결과는 검수가 아니다 → "승인 → 다음" 대신 중립 한 줄, 지금 마일스톤을 이어 간다
  s=$(cat "$SKILL_FILE")
  assert_contains "$s" "**\`call message\` 의 결과**"
  assert_contains "$s" "Codex 답변: <summary>"
  assert_contains "$s" "지금 마일스톤"
}
test_skill_third_reject_asks_before_rework() {
  # Task 10 리뷰 1·7: 반려 횟수는 status 로 알고, 3번째 반려면 보완 전에 묻는다
  s=$(cat "$SKILL_FILE")
  assert_contains "$s" "\"연속 반려 R회\""
  assert_contains "$s" "R 이 3 이면 보완하지 말고 바로 멈춰 묻는다"
  assert_contains "$s" "\`cc-codex.sh ack-rejects\` → 보완"
}
test_skill_reads_verify_log_when_exit_unknown() {
  s=$(cat "$SKILL_FILE")
  assert_contains "$s" "\`(exit=…)\` 가 없거나"
  assert_contains "$s" "실패한 검증 출력 원문"
}
# ---- 최종 리뷰 Important 1: 사용자가 멈추라고 하면 check-orphan --kill 을 먼저 (실행 중 거부·Esc 뒤·버리기/마무리 거부) ----
skill_section() {   # <장 번호> : "## N." 부터 다음 "## " 앞까지
  awk -v n="## $1." 'index($0, n) == 1 { on = 1; print; next } on && /^## / { exit } on { print }' "$SKILL_FILE"
}
test_skill_stop_request_kills_before_relaying() {
  s=$(cat "$SKILL_FILE")
  assert_contains "$s" "**Codex 멈추기**"
  # 멈추기 결과 해석: 끝냈으면 원래 명령을 한 번 다시, 확인 못 함·남음이면 알리고 멈춤
  stop=$(awk '/^\*\*Codex 멈추기\*\*/ { on = 1 } on && /^## / { exit } on { print }' "$SKILL_FILE")
  assert_contains "$stop" "cc-codex.sh check-orphan --kill"
  assert_contains "$stop" "사용자 말을 Codex에 전하기 전에"
  assert_contains "$stop" "종료했습니다"
  assert_contains "$stop" "확인하지 못해"
  assert_contains "$stop" "KILL 뒤에도"
  assert_contains "$stop" "ps -o pid,command -g"
  assert_contains "$stop" "한 번만 다시"
  # 세 곳에서 이 절차를 쓴다
  s7=$(skill_section 7); assert_contains "$s7" "\"이미 실행 중\""; assert_contains "$s7" "Codex 멈추기"
  s9=$(skill_section 9); assert_contains "$s9" "Esc"; assert_contains "$s9" "Codex 멈추기"
  s2=$(skill_section 2); assert_contains "$s2" "Codex가 실행 중입니다"; assert_contains "$s2" "Codex 멈추기"
  s11=$(skill_section 11); assert_contains "$s11" "Codex가 실행 중입니다"; assert_contains "$s11" "Codex 멈추기"
}
# ---- 최종 리뷰 Important 2: init 8 (작업 트리가 깨끗하지 않음) ----
test_skill_handles_init_dirty_exit_8() {
  s3=$(skill_section 3)
  assert_contains "$s3" "8(커밋되지 않은 변경"
  assert_contains "$s3" "구분할 수 없어"
  assert_contains "$s3" "정리본 전문"
  assert_contains "$s3" "묻지 않고"
}
# ---- 최종 리뷰 minor h: put 도 작업이 없으면 5 ----
test_skill_put_mentions_exit_5() {
  s1=$(skill_section 1)
  assert_contains "$s1" "진행 중인 작업이 없으면 5"
}
# ---- 최종 리뷰 minor c: done 뒤 추가 수정은 새 마일스톤 ----
test_skill_extra_work_after_done_is_new_milestone() {
  s11=$(skill_section 11)
  assert_contains "$s11" "새 마일스톤"
  assert_contains "$s11" "지금 번호 + 1"
}
# ---- Codex 리뷰 (R30) ----
test_skill_covers_unconfirmed_stop_broken_discard_and_plan_question() {
  # 1: 종료를 확인하지 못한 이전 호출 때문에 call 이 거부되면 알리고 멈춘다 (wait 줄의 안내도 전한다)
  s7=$(skill_section 7)
  assert_contains "$s7" "\"끝났는지 확인하지 못해\""
  assert_contains "$s7" "끝났는지 확인하지 못했습니다"
  assert_contains "$s7" "ps -o pid,command -g"
  # 3: 깨진 기록 버리기는 이 작업의 프로세스가 없을 때만 (R22 대체)
  s2=$(skill_section 2)
  assert_contains "$s2" "이 작업의 Codex 프로세스가 남아 있지 않은지"
  assert_contains "$s2" "확인하지 못하면 지우지 않는다"
  # 4: 계획 요청의 결과는 plan 또는 ask_user
  s4=$(skill_section 4)
  assert_contains "$s4" "\`ask_user\`"
  assert_contains "$s4" "Codex 질문:"
}
# ---- R31/R32: Codex 가 테스트를 직접 돌리고, Codex 가 프로젝트 파일을 바꾸면 멈춰 묻는다 ----
test_skill_codex_runs_tests_and_stops_on_codex_edits() {
  desc=$(skill_frontmatter | sed -n 's/^description: //p')
  assert_not_contains "$desc" "read-only"
  assert_contains "$desc" "tests"
  s=$(cat "$SKILL_FILE")
  assert_not_contains "$s" "읽기 전용"
  # Codex 는 테스트를 직접 돌린다. 그래도 Claude 는 검수 요청 전에 직접 돌려 기록한다 (Codex 가 비교)
  s0=$(awk '/^# cc$/ { on = 1 } on && /^## 1\./ { exit } on { print }' "$SKILL_FILE")
  assert_contains "$s0" "테스트·빌드를 직접 돌려"
  s5=$(skill_section 5)
  assert_contains "$s5" "Codex도 검수할 때 같은 명령을 직접 돌려"
  assert_contains "$s5" "비교"
  # wait 3 의 "Codex가 프로젝트 파일을 바꿨습니다": 멈추고, 줄과 diff 요약을 보여 주고, 되돌리지 않았다고 설명하고 묻는다
  s7=$(skill_section 7)
  assert_contains "$s7" "\"Codex가 프로젝트 파일을 바꿨습니다\""
  assert_contains "$s7" "git diff <pre> <post> --stat"
  assert_contains "$s7" "되돌리지 않았다"
  assert_contains "$s7" "직접 고친 파일"
  assert_contains "$s7" "그대로 둘지"
  assert_contains "$s7" "자동으로 이어 가지 않는다"
  # 대기가 끊긴 줄(130), Codex 멈추기, 이어 하기에서도 같은 처리
  s8=$(skill_section 8); assert_contains "$s8" "Codex가 프로젝트 파일을 바꿨습니다"
  stop=$(awk '/^\*\*Codex 멈추기\*\*/ { on = 1 } on && /^## / { exit } on { print }' "$SKILL_FILE")
  assert_contains "$stop" "Codex가 프로젝트 파일을 바꿨습니다"
  s10=$(skill_section 10); assert_contains "$s10" "Codex가 프로젝트 파일을 바꿨습니다"
}
# ---- 사용자 요구 (2026-10-18): Codex 결과가 올 때마다 한 줄 요약이 아니라 Codex 답변 자체를 보여주고 쉽게 설명한다 ----
test_skill_always_shows_codex_answer_verbatim() {
  s6=$(skill_section 6)
  show=$(awk '/^\*\*Codex 답변 보여주기\*\*/ { on = 1; print; next } on && /^\*\*/ { exit } on { print }' "$SKILL_FILE")
  [ -n "$show" ] || _fail "Codex 답변 보여주기 절차가 없음"
  # 언제: wait 0 으로 결과가 올 때마다 (계획·검수·메시지 답변, verdict 무관)
  assert_contains "$show" "\`wait\` 가 0"
  assert_contains "$show" "계획·검수·메시지 답변 모두"
  assert_contains "$show" "\`verdict\` 가 무엇이든"
  # 무엇을: 한 줄 요약으로 대신하지 않고 그대로 (읽기 쉬운 목록은 괜찮음)
  assert_contains "$show" "한 줄 요약으로 대신하지 말고"
  assert_contains "$show" "Codex 답변 자체를 사용자에게 보여준다"
  assert_contains "$show" "그대로 옮긴다"
  assert_contains "$show" "짧은 목록"
  for f in '`verdict`' '`summary`' '`instruction` 전문' '`findings` 전부' '파일, 줄, 문제(`issue`), 근거(`evidence`)' '`question`' '`plan`'; do
    assert_contains "$show" "$f"
  done
  # 그 뒤 쉬운 한국어 한두 문장으로 다음에 할 일
  assert_contains "$show" "쉬운 한국어 한두 문장으로 이제 무엇을 하는지"
  # 진행 줄은 그대로 쓰지만 대신하지 않는다. 이벤트 로그는 붙이지 않는다
  assert_contains "$show" "진행 줄이 Codex 답변 보여주기를 대신하지 않는다"
  assert_contains "$show" "이벤트 로그"
  assert_contains "$show" "결과 JSON 의 필드뿐"
  # 모든 결과 처리 경로가 이 절차를 먼저 거친다
  assert_contains "$s6" "**\`call review\` 의 결과** (마일스톤 검수. 어느 결과든 먼저 위 \"Codex 답변 보여주기\")"
  assert_contains "$s6" "어느 결과든 먼저 위 \"Codex 답변 보여주기\"):"
  assert_not_contains "$s6" "summary\` 와 필요한 부분만 짧게"
  assert_not_contains "$s6" "한 줄만 보여준다"
  assert_contains "$(skill_section 4)" "Codex 답변 보여주기"
  assert_contains "$(skill_section 10)" "Codex 답변 보여주기"
}
# ---- Codex 리뷰 1차 (R32) 2·3·4: 나중에 다시 비교한 결과·확인 실패 줄도 멈춰서 알린다 ----
test_skill_handles_rechecked_edits_and_unchecked_tree() {
  s7=$(skill_section 7)
  # call 6: 끝나지 않았던 이전 호출을 새 호출 전에 다시 비교한 결과
  assert_contains "$s7" "\`call\` 이 6 이고 줄에 \"Codex가 프로젝트 파일을 바꿨습니다\""
  # wait 3·call 6: 실행 뒤 작업 트리를 확인하지 못함
  assert_contains "$s7" "\"작업 트리를 확인하지 못해\""
  assert_contains "$s7" "git diff <pre>"
  # 종료를 확인하지 못해 결과를 반영하지 않은 줄
  assert_contains "$s7" "\"결과를 반영하지 않았\""
}
test_skill_stop_and_interrupt_lines_with_unchecked_tree() {
  stop=$(awk '/^\*\*Codex 멈추기\*\*/ { on = 1 } on && /^## / { exit } on { print }' "$SKILL_FILE")
  assert_contains "$stop" "\"작업 트리를 확인하지 못해\""
  s8=$(skill_section 8); assert_contains "$s8" "\"작업 트리를 확인하지 못해\""
}
test_skill_codex_modified_with_pending_recheck() {
  # Codex 리뷰 2차: 종료를 확인하지 못한 codex_modified 는 남은 프로세스가 끝난 뒤 다시 비교해 최종 목록으로 고쳐진다
  s7=$(skill_section 7)
  assert_contains "$s7" "\"다시 확인합니다\""
  assert_contains "$s7" "최종 목록"
}
test_skill_final_recheck_lines_and_stale_notice() {
  # Codex 리뷰 3차: 다시 비교를 마친 줄은 최종 결과다 (다시 기다리지 않는다). preflight 의 stale_notice 로 와도 같은 처리
  s7=$(skill_section 7)
  assert_contains "$s7" "\"다시 확인:\""
  assert_contains "$s7" "더 기다리지 않는다"
  s2=$(skill_section 2)
  assert_contains "$s2" "stale_notice"
  assert_contains "$s2" "\"Codex가 프로젝트 파일을 바꿨습니다\""
  assert_contains "$s2" "7장"
}
# ---- 2026-10-18 보안 수정 (R33/R34): git 설정을 바꿔 멈춘 줄, 감시 대상 무시 파일 ----
test_skill_handles_git_settings_change_without_git_commands() {
  s7=$(skill_section 7)
  assert_contains "$s7" "\"Codex가 git 설정을 바꿨습니다\""
  # 바뀐 설정이 명령을 실행할 수 있으므로 그 저장소에서 git 명령(diff 포함)을 돌리지 않고, 파일은 cat 으로만 보여준다
  assert_contains "$s7" "git 명령(\`git diff\`·\`git status\` 포함)을 실행하지 않는다"
  assert_contains "$s7" "\`cat\`"
  assert_contains "$(skill_section 2)" "\"Codex가 git 설정을 바꿨습니다\""
  assert_contains "$(skill_section 8)" "\"Codex가 git 설정을 바꿨습니다\""
  stop=$(awk '/^\*\*Codex 멈추기\*\*/ { on = 1 } on && /^## / { exit } on { print }' "$SKILL_FILE")
  assert_contains "$stop" "\"Codex가 git 설정을 바꿨습니다\""
}
test_skill_explains_watched_ignored_files_and_nested_repos() {
  s7=$(skill_section 7)
  assert_contains "$s7" "git이 무시하는 감시 대상"
  assert_contains "$s7" "git diff 에는 나오지 않는다"
  assert_contains "$s7" "중첩 git 저장소"
}
test_skill_git_settings_refusal_until_restored() {
  # 바뀐 git 설정이 그대로면 call 이 6 으로 거부한다: 그 줄을 보여주고 되돌리거나 버릴지(discard) 묻는다
  s7=$(skill_section 7)
  assert_contains "$s7" "아직 실행 전과 다르면"
  assert_contains "$s7" "\`cc-codex.sh discard\`"
}
test_skill_routes_integrity_unverified_and_git_config_changed_without_git() {
  # Codex 보안 검수 1차 5·1: git 설정 무결성을 확인하지 못한 줄, preflight 의 git_config_changed 도 git 명령 없이 처리한다
  s7=$(skill_section 7)
  assert_contains "$s7" "\"git 설정 무결성을 확인하지 못해\""
  assert_contains "$(skill_section 2)" "git_config_changed"
  assert_contains "$(skill_section 8)" "\"git 설정 무결성을 확인하지 못해\""
}
test_skill_release_quarantine_only_on_explicit_user_confirmation() {
  # 격리 기록은 사용자가 git 설정과 비교하지 못한 프로젝트 파일을 직접 확인했다고 분명히 말했을 때만 Claude 가 지운다
  s7=$(skill_section 7)
  assert_contains "$s7" "\`cc-codex.sh release-quarantine\`"
  assert_contains "$s7" "사용자가 git 설정 파일과 Codex 실행 중 바뀐 프로젝트 파일을 직접 확인했다고 분명히 말했을 때만"
  assert_contains "$s7" "스스로 판단해 실행하지 않는다"
}
