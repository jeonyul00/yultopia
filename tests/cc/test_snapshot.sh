. "$CC_REPO_ROOT/plugins/yultopia/lib/cc/snapshot.sh"

test_snapshot_includes_untracked_excludes_ignored() {
  repo=$(make_repo); cd "$repo"; printf 'ignored.txt\n' > .gitignore; git add .gitignore; git commit -qm ign
  printf 'new\n' > new.txt; printf 'x\n' > ignored.txt
  t=$(cc_snapshot_tree)
  assert_contains "$(git ls-tree -r --name-only "$t")" "new.txt"
  assert_not_contains "$(git ls-tree -r --name-only "$t")" "ignored.txt"
}
test_snapshot_does_not_touch_user_index() {
  repo=$(make_repo); cd "$repo"
  printf 'a\n' > staged.txt; git add staged.txt
  printf 'b\n' > untracked.txt; printf 'changed\n' > base.txt
  before=$(git diff --cached --name-only); idx_before=$(git ls-files -s)
  t=$(cc_snapshot_tree)
  assert_eq "$(git diff --cached --name-only)" "$before"
  assert_eq "$(git ls-files -s)" "$idx_before"
  assert_not_contains "$(git diff --cached --name-only)" "untracked.txt"
  assert_contains "$(git ls-tree -r --name-only "$t")" "untracked.txt"
  assert_eq "$(git show "$t:base.txt")" "changed"
}
test_snapshot_without_head() {
  mkdir -p "$TMP/empty"; cd "$TMP/empty"; git init -q .
  printf 'f\n' > file.txt
  t=$(cc_snapshot_tree); rc=$?
  assert_eq "$rc" "0"
  assert_contains "$(git ls-tree -r --name-only "$t")" "file.txt"
}
test_snapshot_works_from_subdir_and_cleans_tmp_index() {
  repo=$(make_repo "my repo 한글"); cd "$repo"; mkdir sub; printf 's\n' > sub/s.txt
  cd sub
  t=$(cc_snapshot_tree)
  assert_contains "$(git ls-tree -r --full-tree --name-only "$t")" "sub/s.txt"
  assert_contains "$(git ls-tree -r --full-tree --name-only "$t")" "base.txt"
  assert_eq "$(ls "$(git rev-parse --absolute-git-dir)" | grep -c 'snap\|tmp\.' )" "0"
}
test_snapshot_with_active_removes_snap_index() {
  start_task
  printf 'n\n' > n.txt
  t=$(cc_snapshot_tree)
  assert_contains "$(git ls-tree -r --name-only "$t")" "n.txt"
  assert_no_path "$ACTIVE/snap.index"
}
test_snapshot_failure_removes_tmp_index() {
  start_task
  printf 'secret\n' > unreadable.txt; chmod 000 unreadable.txt
  cc_snapshot_tree >/dev/null 2>&1; rc=$?
  chmod 644 unreadable.txt
  [ "$rc" != 0 ] || _fail "실패해야 함"
  assert_no_path "$ACTIVE/snap.index"
}
test_init_records_task_base_tree() {
  repo=$(make_repo); cd "$repo"
  printf 'g\n' | run_cc init; assert_code 0
  assert_eq "$(state_of_repo)" "$(git rev-parse 'HEAD^{tree}')"
}
state_of_repo() { jq -r .task_base_tree "$(cc_path active)/state.json"; }
test_init_task_base_tree_includes_dirty_files() {
  repo=$(make_repo); cd "$repo"; printf 'd\n' > dirty.txt
  printf 'g\n' | run_cc init; assert_code 0
  t=$(state_of_repo)
  assert_contains "$(git ls-tree -r --name-only "$t")" "dirty.txt"
}
test_init_fails_cleanly_when_snapshot_fails() {
  repo=$(make_repo); cd "$repo"
  printf 'secret\n' > unreadable.txt; chmod 000 unreadable.txt
  printf 'g\n' | run_cc init; rc=$CODE; cc_last
  chmod 644 unreadable.txt
  assert_eq "$CODE" "1"
  assert_contains "$OUT" "작업을 시작하지 못했습니다"
  assert_no_path "$(git rev-parse --absolute-git-dir)/yultopia-cc/active"
}
