# test_docs.sh - Task 11: 문서와 버전

test_versions_are_2_1_0() {
  assert_eq "$(jq -r .version "$CC_REPO_ROOT/plugins/yultopia/.claude-plugin/plugin.json")" "2.1.0"
  assert_eq "$(jq -r '.plugins[0].version' "$CC_REPO_ROOT/.claude-plugin/marketplace.json")" "2.1.0"
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
