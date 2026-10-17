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
    CC_T_TASK_BASE_TREE=ccc CC_T_VERIFY_DIR=/v CC_T_MESSAGE=m
  export CC_T_BRIEF CC_T_REPORT CC_T_MILESTONE CC_T_MILESTONE_BASE_TREE CC_T_REVIEW_TREE CC_T_TASK_BASE_TREE CC_T_VERIFY_DIR CC_T_MESSAGE
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
  assert_contains "$r" "테스트를 다시 돌리지"
  assert_contains "$r" "권한 오류"
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
  assert_contains "$(cat "$TPL_DIR/pm-format-retry.md")" "JSON"
}
