. "$CC_REPO_ROOT/plugins/yultopia/lib/cc/render.sh"
SCHEMA="$CC_REPO_ROOT/plugins/yultopia/lib/cc/pm-output.schema.json"

test_schema_is_strict() {
  assert_eq "$(jq '[.. | objects | select(has("properties"))] | all((.required|sort)==(.properties|keys|sort) and .additionalProperties==false)' "$SCHEMA")" "true"
  assert_eq "$(jq -c '.properties.verdict.enum' "$SCHEMA")" '["plan","approve","reject","done","ask_user"]'
  assert_eq "$(jq -c '.required|sort' "$SCHEMA")" '["findings","instruction","milestone","plan","question","summary","verdict"]'
  assert_eq "$(jq -c '.properties.plan.type' "$SCHEMA")" '["object","null"]'
  assert_eq "$(jq -c '.properties.findings.items.properties.line.type' "$SCHEMA")" '["integer","null"]'
}
test_render_preserves_special_chars() {
  CC_T_BRIEF=$'따옴표 " \' 달러 $HOME 백틱 `ls` 역슬래시 \\n \\1 $1 @x\n둘째 줄' cc_render "$TPL_DIR/pm-plan.md" "$TMP/out"
  assert_contains "$(cat "$TMP/out")" $'따옴표 " \' 달러 $HOME 백틱 `ls` 역슬래시 \\n \\1 $1 @x\n둘째 줄'
  assert_not_contains "$(cat "$TMP/out")" "{{BRIEF}}"
}
test_render_large_value() {
  big=$(head -c 12000 /dev/zero | tr '\0' 'a')
  CC_T_BRIEF="$big" cc_render "$TPL_DIR/pm-plan.md" "$TMP/out"
  assert_contains "$(cat "$TMP/out")" "$big"
}
test_render_fails_on_missing_placeholder() {
  unset CC_T_BRIEF
  cc_render "$TPL_DIR/pm-plan.md" "$TMP/out" >/dev/null 2>&1; c=$?
  assert_eq "$c" 1
  assert_no_path "$TMP/out"
}
test_render_empty_value_counts_as_set() {
  CC_T_BRIEF="" cc_render "$TPL_DIR/pm-plan.md" "$TMP/out"; c=$?
  assert_eq "$c" 0
  assert_not_contains "$(cat "$TMP/out")" "{{"
}
test_render_all_templates() {
  CC_T_BRIEF=b CC_T_REPORT=r CC_T_MILESTONE=2 CC_T_MILESTONE_BASE_TREE=aaa CC_T_REVIEW_TREE=bbb \
    CC_T_TASK_BASE_TREE=ccc CC_T_VERIFY_DIR=/v CC_T_MESSAGE=m CC_T_PHASE=done CC_T_REASON=why
  export CC_T_BRIEF CC_T_REPORT CC_T_MILESTONE CC_T_MILESTONE_BASE_TREE CC_T_REVIEW_TREE CC_T_TASK_BASE_TREE CC_T_VERIFY_DIR CC_T_MESSAGE CC_T_PHASE CC_T_REASON
  for t in pm-plan pm-review pm-message pm-format-retry; do
    cc_render "$TPL_DIR/$t.md" "$TMP/o-$t"; assert_eq "$?" 0 "$t"
    assert_not_contains "$(cat "$TMP/o-$t")" "{{"
  done
  assert_contains "$(cat "$TMP/o-pm-review")" "git diff aaa bbb"
  assert_contains "$(cat "$TMP/o-pm-review")" "git diff ccc bbb"
  assert_contains "$(cat "$TMP/o-pm-review")" "/v"
}
test_prompts_state_pm_rules() {
  p=$(cat "$TPL_DIR/pm-plan.md")
  assert_contains "$p" "파일을 만들거나 고치지"
  assert_contains "$p" "마일스톤"
  assert_contains "$p" "AGENTS.md"
  assert_contains "$p" "## Yultopia 중점 점검 항목"
  assert_contains "$p" "ask_user"
  assert_contains "$p" "한국어"
  assert_contains "$p" "JSON"
  r=$(cat "$TPL_DIR/pm-review.md")
  assert_contains "$r" "파일을 만들거나 고치지"
  for v in approve reject done ask_user; do assert_contains "$r" "$v"; done
  assert_contains "$(cat "$TPL_DIR/pm-message.md")" "최우선"
  # Ruling R27: 메시지 답변은 검수가 아니다. 이어가기 = 지금 마일스톤 번호로 approve
  m=$(cat "$TPL_DIR/pm-message.md")
  assert_contains "$m" "지금 진행 중인 마일스톤: {{MILESTONE}}"
  assert_contains "$m" "검수가 아닙니다"
  assert_contains "$m" "verdict \"approve\""
  assert_contains "$m" "verdict \"ask_user\""
  assert_contains "$m" "plan 에"
  # 최종 리뷰 minor c: done 뒤의 메시지는 추가 수정 요구 = 새 마일스톤
  assert_contains "$m" "지금 단계: {{PHASE}}"
  assert_contains "$m" "추가 수정 요구"
  assert_contains "$m" "새 마일스톤"
  assert_contains "$(cat "$TPL_DIR/pm-format-retry.md")" "JSON"
  # Codex 리뷰 4: 형식 재요청은 무엇이 틀렸는지(이유)를 알려 내용도 고치게 한다
  fr=$(cat "$TPL_DIR/pm-format-retry.md")
  assert_contains "$fr" "{{REASON}}"
  assert_contains "$fr" "채우거나 고쳐서"
}
# ---- R31/R32: Codex 는 테스트·빌드·린트를 직접 돌려 확인하되, 프로젝트 파일은 바꾸지 않는다 (바뀌면 작업이 멈춤) ----
test_prompts_let_codex_run_tests_but_not_edit_files() {
  for t in pm-plan pm-review pm-message pm-format-retry; do
    p=$(cat "$TPL_DIR/$t.md")
    assert_contains "$p" "프로젝트 파일" "$t"
    assert_contains "$p" "멈춥니다" "$t"
    assert_not_contains "$p" "읽기만 합니다" "$t"
    assert_not_contains "$p" "다시 돌리지" "$t"
    assert_not_contains "$p" "권한 오류" "$t"
  done
  for t in pm-plan pm-review pm-message; do
    p=$(cat "$TPL_DIR/$t.md")
    assert_contains "$p" "직접 실행" "$t"
    assert_contains "$p" "git 이 무시하는 파일" "$t"
    assert_contains "$p" "네트워크는 막혀 있습니다" "$t"
    assert_contains "$p" "반려 근거가 아닙니다" "$t"
    assert_contains "$p" "findings" "$t"
    assert_contains "$p" "Claude 만 고칩니다" "$t"
  done
  r=$(cat "$TPL_DIR/pm-review.md")
  # 검수 때는 테스트·빌드·린트를 반드시 직접 돌리고, Claude 가 저장한 검증 출력과 비교한다
  assert_contains "$r" "반드시 직접 실행"
  assert_contains "$r" "{{VERIFY_DIR}}"
  assert_contains "$r" "비교"
  # 승인 책임: 완료 기준을 직접 확인했을 때만 approve·done, 반려에는 구체적인 보완 지시
  assert_contains "$r" "책임"
  assert_contains "$r" "완료 기준"
  assert_contains "$r" "보완할 내용"
  assert_contains "$(cat "$TPL_DIR/pm-plan.md")" "최우선"
  assert_contains "$(cat "$TPL_DIR/pm-review.md")" "최우선"
}
