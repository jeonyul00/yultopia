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
# ---- 2026-10-18 보안 수정 (R33/R34) ----
test_readme_cc_notes_cover_security_fix() {
  notes=$(awk '/^#### `\/yultopia:cc` 알아둘 것/ { on = 1; next } on && /^##/ { exit } on { print }' "$CC_REPO_ROOT/README.md")
  # 무시된 비밀·설정 파일과 의존성 폴더도 감시 (범주와 목록 위치)
  assert_contains "$notes" ".env"
  assert_contains "$notes" "*.pem"
  assert_contains "$notes" "node_modules"
  assert_contains "$notes" ".venv"
  assert_contains "$notes" "CC_IGNORED_WATCH_PATTERNS"
  # Codex 가 만든 새 중첩 저장소, git 설정 변경
  assert_contains "$notes" "중첩 git 저장소"
  assert_contains "$notes" "git 설정"
}
test_design_spec_records_security_fix() {
  d=$(cat "$CC_REPO_ROOT/docs/superpowers/specs/2026-10-17-yultopia-cc-design.md")
  assert_contains "$d" "2026-10-18 보안 수정"
  assert_contains "$d" "R33"
  assert_contains "$d" "R34"
  assert_contains "$d" "core.fsmonitor"
  assert_contains "$d" "HEAD:.gitmodules"
  assert_contains "$d" "CC_IGNORED_WATCH_PATTERNS"
}
test_readme_cc_notes_explain_unwatched_tool_caches() {
  notes=$(awk '/^#### `\/yultopia:cc` 알아둘 것/ { on = 1; next } on && /^##/ { exit } on { print }' "$CC_REPO_ROOT/README.md")
  assert_contains "$notes" "node_modules/.cache/"
  assert_contains "$notes" "node_modules/.vite/"
  assert_contains "$notes" "CC_IGNORED_WATCH_EXCLUDE"
  assert_contains "$notes" "다음 빌드"
}
test_docs_record_codex_security_review_round1_fixes() {
  d=$(cat "$CC_REPO_ROOT/docs/superpowers/specs/2026-10-17-yultopia-cc-design.md")
  assert_contains "$d" "Codex 보안 검수 1차 반영"
  assert_contains "$d" "gitcfg-quarantine.json"
  assert_contains "$d" "pre_submodules"
  notes=$(awk '/^#### `\/yultopia:cc` 알아둘 것/ { on = 1; next } on && /^##/ { exit } on { print }' "$CC_REPO_ROOT/README.md")
  assert_contains "$notes" "cc/quarantine"      # 2차에서 저장소 밖으로 옮겼다
  assert_contains "$notes" "하위 모듈 안의 그런 파일도"
}
test_docs_record_codex_security_review_round2_fixes() {
  d=$(cat "$CC_REPO_ROOT/docs/superpowers/specs/2026-10-17-yultopia-cc-design.md")
  assert_contains "$d" "Codex 보안 검수 2차 반영"
  assert_contains "$d" "R36"
  assert_contains "$d" "armed"
  notes=$(awk '/^#### `\/yultopia:cc` 알아둘 것/ { on = 1; next } on && /^##/ { exit } on { print }' "$CC_REPO_ROOT/README.md")
  assert_contains "$notes" "~/.claude/plugins/data/yultopia/cc/quarantine"
  assert_contains "$notes" "release-quarantine"
  assert_contains "$notes" "자동으로 풀지 않는다"
  assert_contains "$d" "SessionStart를 포함한 모든 자동 정리"
}
