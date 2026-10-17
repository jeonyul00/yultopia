# test_docs.sh - Task 11: 문서와 버전

test_versions_are_2_1_0() {
  assert_eq "$(jq -r .version "$CC_REPO_ROOT/plugins/yultopia/.claude-plugin/plugin.json")" "2.2.0"
  assert_eq "$(jq -r '.plugins[0].version' "$CC_REPO_ROOT/.claude-plugin/marketplace.json")" "2.2.0"
}
test_descriptions_mention_codex_pm() {
  assert_contains "$(jq -r .description "$CC_REPO_ROOT/plugins/yultopia/.claude-plugin/plugin.json")" "Codex PM 자동 협업"
  assert_contains "$(jq -r '.plugins[0].description' "$CC_REPO_ROOT/.claude-plugin/marketplace.json")" "Codex PM 자동 협업"
}
test_readme_documents_cc_and_keeps_collab() {
  r=$(cat "$CC_REPO_ROOT/README.md")
  assert_contains "$r" "/yultopia:cc"; assert_contains "$r" "/yultopia:collab"; assert_contains "$r" "Codex CLI"
}
test_plugin_readme_lists_cc_parts() {
  r=$(cat "$CC_REPO_ROOT/plugins/yultopia/README.md")
  assert_contains "$r" "cc-codex.sh"; assert_contains "$r" "cc-hook.sh"; assert_contains "$r" "lib/cc"
  assert_contains "$r" "UserPromptSubmit"
}
test_readme_cc_notes_cover_limits_and_helpers() {
  # 최종 리뷰 minor i: 호출 상한, 연속 반려 멈춤, 재시도 규칙, 강제 종료 때 남을 수 있는 Codex 도우미
  notes=$(awk '/^#### `\/yultopia:cc` 알아둘 것/ { on = 1; next } on && /^##/ { exit } on { print }' "$CC_REPO_ROOT/README.md")
  assert_contains "$notes" "20회"
  assert_contains "$notes" "연속 3번 반려"
  assert_contains "$notes" "한 번만 다시 시도"
  assert_contains "$notes" "시간 초과는 다시 시도하지 않는다"
  assert_contains "$notes" "MCP"
  assert_contains "$notes" "codex-code-mode-host"
  assert_contains "$notes" "pgrep -fl 'mcp|codex-code-mode-host'"
}
# ---- R31/R32 (2026-10-18): Codex 가 테스트를 직접 돌리고, 프로젝트 파일을 바꾸면 멈춘다 ----
test_readme_cc_notes_cover_codex_tests_and_edit_stop() {
  r=$(cat "$CC_REPO_ROOT/README.md")
  assert_not_contains "$r" "읽기 전용 PM"
  notes=$(awk '/^#### `\/yultopia:cc` 알아둘 것/ { on = 1; next } on && /^##/ { exit } on { print }' "$CC_REPO_ROOT/README.md")
  assert_not_contains "$notes" "Codex는 파일을 고치지 않는다"
  assert_contains "$notes" "테스트·빌드를 직접 돌려"
  assert_contains "$notes" "네트워크는 막혀"
  assert_contains "$notes" "git이 무시하는"
  assert_contains "$notes" "바로 멈추고"
  assert_contains "$notes" "자동으로 되돌리지 않는다"
}
test_design_spec_records_codex_tests_change() {
  d=$(cat "$CC_REPO_ROOT/docs/superpowers/specs/2026-10-17-yultopia-cc-design.md")
  assert_contains "$d" "2026-10-18 변경"
  assert_contains "$d" "R31"
  assert_contains "$d" "R32"
  assert_contains "$d" "workspace-write"
  assert_contains "$d" "codex_modified"
}
test_docs_record_codex_review_round1_fixes() {
  notes=$(awk '/^#### `\/yultopia:cc` 알아둘 것/ { on = 1; next } on && /^##/ { exit } on { print }' "$CC_REPO_ROOT/README.md")
  assert_contains "$notes" "하위 모듈"
  d=$(cat "$CC_REPO_ROOT/docs/superpowers/specs/2026-10-17-yultopia-cc-design.md")
  assert_contains "$d" "Codex 1차 검수 반영"
  assert_contains "$d" "running.pre_tree"
  assert_contains "$d" "stop_failed"
}
test_docs_record_codex_review_round2_fix() {
  d=$(cat "$CC_REPO_ROOT/docs/superpowers/specs/2026-10-17-yultopia-cc-design.md")
  assert_contains "$d" "Codex 2차 검수 반영"
}
test_docs_record_codex_review_round3_fixes() {
  d=$(cat "$CC_REPO_ROOT/docs/superpowers/specs/2026-10-17-yultopia-cc-design.md")
  assert_contains "$d" "Codex 3차 검수 반영"
}
test_docs_record_codex_review_round4_fixes() {
  d=$(cat "$CC_REPO_ROOT/docs/superpowers/specs/2026-10-17-yultopia-cc-design.md")
  assert_contains "$d" "Codex 4차 검수 반영"
}
