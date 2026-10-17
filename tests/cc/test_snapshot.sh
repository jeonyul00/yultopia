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
test_init_refuses_dirty_files_instead_of_snapshotting_them() {
  # 최종 리뷰 Important 2: 더러운 작업 트리는 기준 스냅샷에 섞지 않고 init 이 거부한다 (8)
  repo=$(make_repo); cd "$repo"; printf 'd\n' > dirty.txt
  printf 'g\n' | run_cc init; assert_code 8
  assert_contains "$OUT" "dirty.txt"
  assert_no_path "$(git rev-parse --absolute-git-dir)/yultopia-cc/active"
}
test_init_fails_cleanly_when_snapshot_fails() {
  # 깨끗한 트리에서 스냅샷만 실패하게 한다: write-tree 만 실패하는 git 대역
  repo=$(make_repo); cd "$repo"
  real_git=$(command -v git)
  mkdir -p "$TMP/bin"
  printf '#!/bin/sh\n[ "$1" = write-tree ] && exit 1\nexec "%s" "$@"\n' "$real_git" > "$TMP/bin/git"
  chmod +x "$TMP/bin/git"
  printf 'g\n' | PATH="$TMP/bin:$PATH" run_cc init; rc=$CODE; cc_last
  assert_eq "$CODE" "1"
  assert_contains "$OUT" "작업을 시작하지 못했습니다"
  assert_no_path "$(git rev-parse --absolute-git-dir)/yultopia-cc/active"
}

# ==== Codex 리뷰 1차 (R32) 1: 초기화된 하위 모듈 안의 변경도 스냅샷에 잡힌다 (중첩 포함, 사용자 인덱스는 그대로) ====
# sn_git_repo <폴더> <파일> : 커밋 하나가 있는 저장소
sn_git_repo() {
  mkdir -p "$1" && (
    cd "$1" && git init -q . && git config user.name t && git config user.email t@example.com \
      && git config commit.gpgsign false && echo "$2" > "$2" && git add "$2" && git commit -q -m init
  ) >/dev/null 2>&1
}
# sn_make_sub_repo <이름> : $TMP/<이름> 저장소 + 하위 모듈 sub(s.txt, .gitignore 에 ign/) + 그 안의 하위 모듈 nested(n.txt). 경로 출력
sn_make_sub_repo() {
  local nsrc="$TMP/nestsrc-$1" src="$TMP/subsrc-$1" repo
  sn_git_repo "$nsrc" n.txt || return 1
  sn_git_repo "$src" s.txt || return 1
  ( cd "$src" && printf 'ign/\n' > .gitignore && git add .gitignore \
      && git -c protocol.file.allow=always submodule add -q "$nsrc" nested && git commit -q -m nested ) >/dev/null 2>&1 || return 1
  repo=$(make_repo "$1") || return 1
  ( cd "$repo" && git -c protocol.file.allow=always submodule add -q "$src" sub \
      && git -c protocol.file.allow=always submodule update -q --init --recursive && git commit -q -m sub ) >/dev/null 2>&1 || return 1
  [ -f "$repo/sub/nested/n.txt" ] || return 1
  printf '%s\n' "$repo"
}
sn_indexes() { git ls-files -s; git -C sub ls-files -s; git -C sub/nested ls-files -s; git diff --cached --name-only; git -C sub diff --cached --name-only; }
test_snapshot_sees_changes_inside_submodules() {
  repo=$(sn_make_sub_repo "my repo 한글") || { _fail "하위 모듈 저장소를 만들지 못함 (테스트 전제)"; return 1; }
  cd "$repo"
  idx_before=$(sn_indexes)
  t0=$(cc_snapshot_tree) || _fail "스냅샷 실패"
  # 깨끗한 하위 모듈은 지금처럼 하위 모듈 HEAD 커밋을 gitlink 로 둔다. 같은 상태면 같은 값
  assert_eq "$(git ls-tree "$t0" sub | awk '{print $3}')" "$(git -C sub rev-parse HEAD)"
  assert_eq "$(cc_snapshot_tree)" "$t0"
  # 하위 모듈의 추적 파일 수정: 최상위 tree 가 바뀌고 diff 에 하위 모듈 경로가 나온다. 같은 내용이면 같은 값 (고정된 합성 값)
  echo x >> sub/s.txt
  t1=$(cc_snapshot_tree)
  [ -n "$t1" ] && [ "$t1" != "$t0" ] || _fail "하위 모듈 안의 수정을 못 잡음"
  assert_eq "$(git diff --name-only "$t0" "$t1")" "sub"
  assert_eq "$(cc_snapshot_tree)" "$t1"
  git -C sub checkout -q -- s.txt
  assert_eq "$(cc_snapshot_tree)" "$t0" "되돌린 뒤"
  # 추적 파일 삭제
  rm sub/s.txt
  t2=$(cc_snapshot_tree); [ -n "$t2" ] && [ "$t2" != "$t0" ] || _fail "하위 모듈 안의 삭제를 못 잡음"
  assert_eq "$(git diff --name-only "$t0" "$t2")" "sub"
  git -C sub checkout -q -- s.txt
  # 무시되지 않는 새 파일
  echo n > "sub/새 파일.txt"
  t3=$(cc_snapshot_tree); [ -n "$t3" ] && [ "$t3" != "$t0" ] || _fail "하위 모듈 안의 새 파일을 못 잡음"
  rm "sub/새 파일.txt"
  # 무시되는 파일만 바뀌면 그대로
  mkdir -p sub/ign; echo c > sub/ign/cache.log
  assert_eq "$(cc_snapshot_tree)" "$t0" "하위 모듈의 무시된 파일"
  rm -rf sub/ign
  # 중첩 하위 모듈 안의 수정도 최상위 하위 모듈 경로로 나온다
  echo y >> sub/nested/n.txt
  t4=$(cc_snapshot_tree); [ -n "$t4" ] && [ "$t4" != "$t0" ] || _fail "중첩 하위 모듈 안의 수정을 못 잡음"
  assert_eq "$(git diff --name-only "$t0" "$t4")" "sub"
  git -C sub/nested checkout -q -- n.txt
  assert_eq "$(cc_snapshot_tree)" "$t0" "중첩을 되돌린 뒤"
  # 사용자 인덱스(최상위·하위 모듈·중첩)와 스테이징은 그대로
  assert_eq "$(sn_indexes)" "$idx_before"
}
test_snapshot_ignores_leftover_temp_files_from_interrupted_snapshot() {
  # 중간에 끊긴 스냅샷(감독 프로세스가 KILL 된 경우 등)이 남긴 임시 인덱스·잠금 파일이 다음 스냅샷을 막지 않는다
  start_task
  printf 'garbage' > "$ACTIVE/snap.index"; : > "$ACTIVE/snap.index.lock"
  t=$(cc_snapshot_tree) || _fail "남은 임시 파일 때문에 스냅샷 실패"
  assert_eq "$t" "$(git rev-parse 'HEAD^{tree}')"
  assert_eq "$(find "$ACTIVE" -maxdepth 1 -name 'snap.*' -type d | wc -l | tr -d ' ')" "0" "이 스냅샷의 임시 폴더가 남음"
}
