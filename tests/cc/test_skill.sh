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
    assert_contains "preflight init path status call wait ack-rejects check-orphan cleanup-stale discard finish put" "$sub"
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
