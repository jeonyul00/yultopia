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

# ==== 2026-10-18 보안 수정 R33: Codex 가 쓸 수 있는 파일(작업 트리, 중첩 저장소의 .git)로 git 이 명령을 실행하지 않는다 ====
# sn_evil_scripts : 실행되면 $TMP/marker.fsmonitor·marker.filter 를 만드는 스크립트 (git 이 실행했다는 증거)
sn_evil_scripts() {
  printf '#!/bin/sh\n: > "%s/marker.fsmonitor"\nexit 1\n' "$TMP" > "$TMP/evil-fsmonitor.sh"
  printf '#!/bin/sh\n: > "%s/marker.filter"\ncat\n' "$TMP" > "$TMP/evil-clean.sh"
  chmod +x "$TMP/evil-fsmonitor.sh" "$TMP/evil-clean.sh"
}
sn_evil_config() { git config -f "$1" core.fsmonitor "$TMP/evil-fsmonitor.sh" && git config -f "$1" filter.evil.clean "$TMP/evil-clean.sh"; }
sn_no_markers() {
  assert_no_path "$TMP/marker.fsmonitor"
  assert_no_path "$TMP/marker.filter"
}
sn_marker_link() { printf 'yultopia-cc nested git repository (not inspected)\n' | git hash-object --stdin; }
# sn_nested_evil <폴더> <1 커밋 | 0 없음> : 악성 설정을 가진 중첩 저장소
sn_nested_evil() {
  git init -q "$1" || return 1
  printf 'e\n' > "$1/e.txt"
  if [ "$2" = 1 ]; then
    ( cd "$1" && git add e.txt && git -c user.name=c -c user.email=c@example.com -c commit.gpgsign=false commit -q -m e ) || return 1
    printf 'changed\n' >> "$1/e.txt"
  fi
  printf '* filter=evil\n' > "$1/.gitattributes"
  sn_evil_config "$1/.git/config"
}
test_snapshot_does_not_run_git_inside_new_nested_repo() {
  repo=$(make_repo "my repo 한글"); cd "$repo"; sn_evil_scripts
  t0=$(cc_snapshot_tree) || _fail "스냅샷 실패 (전)"
  sn_nested_evil "evil dir" 1 || { _fail "중첩 저장소를 만들지 못함 (테스트 전제)"; return 1; }
  t1=$(cc_snapshot_tree) || _fail "중첩 저장소가 있으면 스냅샷 실패"
  sn_no_markers
  # 고정된 표시 하나로 나타나고 (안은 보지 않음), diff 에 그 경로가 나온다
  assert_eq "$(git ls-tree "$t1" "evil dir" | awk '{print $1, $2, $3}')" "160000 commit $(sn_marker_link)"
  assert_eq "$(git diff --name-only "$t0" "$t1")" "evil dir"
  # 안을 바꿔도 같은 값 (한계: 등록된 하위 모듈이 아닌 중첩 저장소 안은 보지 않는다)
  printf 'more\n' >> "evil dir/e.txt"
  assert_eq "$(cc_snapshot_tree)" "$t1"
  sn_no_markers
  # 없어지면 원래대로
  rm -rf "evil dir"
  assert_eq "$(cc_snapshot_tree)" "$t0"
}
test_snapshot_handles_new_nested_repo_without_commit() {
  repo=$(make_repo); cd "$repo"; sn_evil_scripts
  t0=$(cc_snapshot_tree)
  mkdir -p deep/er; sn_nested_evil deep/er/empty 0 || { _fail "중첩 저장소를 만들지 못함 (테스트 전제)"; return 1; }
  t1=$(cc_snapshot_tree); rc=$?
  assert_eq "$rc" "0" "커밋 없는 중첩 저장소에서 스냅샷 실패"
  sn_no_markers
  assert_eq "$(git diff --name-only "$t0" "$t1")" "deep/er/empty"
}
test_snapshot_hardens_git_against_repo_fsmonitor() {
  # 저장소 설정의 core.fsmonitor 는 스냅샷이 실행하지 않는다 (core.fsmonitor=false 로 덮어씀)
  repo=$(make_repo); cd "$repo"; sn_evil_scripts
  git config core.fsmonitor "$TMP/evil-fsmonitor.sh"
  echo x >> base.txt; echo n > new.txt
  t=$(cc_snapshot_tree) || _fail "스냅샷 실패"
  assert_no_path "$TMP/marker.fsmonitor"
  assert_contains "$(git ls-tree -r --name-only "$t")" "new.txt"
}
# sn_sub_repo : 하위 모듈 sub(s.txt)를 가진 저장소를 $TMP/<이름> 에 만들고 들어간다
sn_sub_repo() {
  local src="$TMP/subsrc-$1" repo
  sn_git_repo "$src" s.txt || return 1
  repo=$(make_repo "$1") || return 1
  cd "$repo" || return 1
  git -c protocol.file.allow=always submodule add -q "$src" sub >/dev/null 2>&1 && git commit -q -m sub >/dev/null 2>&1
}
test_snapshot_still_inspects_registered_submodule() {
  sn_sub_repo reg || { _fail "하위 모듈 저장소를 만들지 못함 (테스트 전제)"; return 1; }
  sn_evil_scripts
  t0=$(cc_snapshot_tree)
  assert_eq "$(git ls-tree "$t0" sub | awk '{print $3}')" "$(git -C sub rev-parse HEAD)"
  echo x >> sub/s.txt
  t1=$(cc_snapshot_tree)
  [ "$t1" != "$t0" ] || _fail "등록된 하위 모듈 안의 수정을 못 잡음"
  assert_eq "$(git diff --name-only "$t0" "$t1")" "sub"
  # 등록된 하위 모듈의 설정에 든 fsmonitor 도 실행하지 않는다 (하위 모듈 git 에도 같은 설정 덮어쓰기)
  git config -f .git/modules/sub/config core.fsmonitor "$TMP/evil-fsmonitor.sh"
  cc_snapshot_tree >/dev/null || _fail "스냅샷 실패"
  assert_no_path "$TMP/marker.fsmonitor"
}
test_snapshot_does_not_inspect_submodule_with_gitdir_outside_modules() {
  sn_sub_repo outside || { _fail "하위 모듈 저장소를 만들지 못함 (테스트 전제)"; return 1; }
  sn_evil_scripts
  t0=$(cc_snapshot_tree)
  # 하위 모듈의 git 디렉터리를 .git/modules 밖으로 옮기고 그곳 설정에 악성 filter 를 둔다
  mv .git/modules/sub "$TMP/elsewhere-gitdir"
  printf 'gitdir: %s\n' "$TMP/elsewhere-gitdir" > sub/.git
  git config -f "$TMP/elsewhere-gitdir/config" core.worktree "$PWD/sub"
  sn_evil_config "$TMP/elsewhere-gitdir/config"
  printf '* filter=evil\n' > sub/.gitattributes; echo x >> sub/s.txt
  t1=$(cc_snapshot_tree) || _fail "스냅샷 실패"
  sn_no_markers
  assert_eq "$(git ls-tree "$t1" sub | awk '{print $3}')" "$(sn_marker_link)"
  assert_eq "$(git diff --name-only "$t0" "$t1")" "sub"
}
test_snapshot_does_not_inspect_submodule_registered_only_in_work_tree() {
  # HEAD 의 .gitmodules 에 없는 gitlink 는 작업 트리의 .gitmodules (Codex 가 고칠 수 있음) 에 적혀 있어도 들여다보지 않는다
  repo=$(make_repo); cd "$repo"; sn_evil_scripts
  sn_git_repo emb e.txt || { _fail "저장소를 만들지 못함 (테스트 전제)"; return 1; }
  git add emb >/dev/null 2>&1 && git commit -q -m emb || { _fail "gitlink 커밋 실패 (테스트 전제)"; return 1; }
  printf '[submodule "emb"]\n\tpath = emb\n\turl = ./emb\n' > .gitmodules
  printf '* filter=evil\n' > emb/.gitattributes; echo x >> emb/e.txt
  sn_evil_config emb/.git/config
  t=$(cc_snapshot_tree) || _fail "스냅샷 실패"
  sn_no_markers
  assert_eq "$(git ls-tree "$t" emb | awk '{print $3}')" "$(sn_marker_link)"
}
test_snapshot_keeps_uninitialized_and_removed_submodule_semantics() {
  sn_sub_repo uninit || { _fail "하위 모듈 저장소를 만들지 못함 (테스트 전제)"; return 1; }
  link=$(git rev-parse HEAD:sub)
  # 초기화되지 않은 하위 모듈(빈 폴더): HEAD 의 gitlink 그대로
  git submodule deinit -q -f sub >/dev/null 2>&1
  [ -d sub ] && [ -z "$(ls -A sub)" ] || { _fail "deinit 실패 (테스트 전제)"; return 1; }
  t=$(cc_snapshot_tree) || _fail "스냅샷 실패"
  assert_eq "$(git ls-tree "$t" sub | awk '{print $1, $3}')" "160000 $link"
  # 폴더가 없어지면 gitlink 도 빠진다 (git add -A 와 같음)
  rmdir sub
  t=$(cc_snapshot_tree) || _fail "스냅샷 실패"
  assert_eq "$(git ls-tree "$t" sub)" ""
  # 파일로 바뀌면 그 파일
  echo f > sub
  t=$(cc_snapshot_tree) || _fail "스냅샷 실패"
  assert_eq "$(git ls-tree "$t" sub | awk '{print $1, $2}')" "100644 blob"
}

# ---- git 설정 지문 (실행 전 기록, 실행 뒤 git 없이 다시 계산해 비교) ----
test_gitcfg_fingerprint_detects_config_changes() {
  sn_sub_repo gcf || { _fail "하위 모듈 저장소를 만들지 못함 (테스트 전제)"; return 1; }
  git config include.path ../cc-local.gitconfig
  fp=$(cc_gitcfg_record) || { _fail "지문을 만들지 못함"; return 1; }
  assert_eq "$(printf '%s' "$fp" | jq -r 'type')" "object"
  out=$(cc_gitcfg_verify "$fp"); rc=$?
  assert_eq "$rc" "0" "바뀐 것 없음"
  # .git/config
  git config core.fsmonitor /bin/true
  out=$(cc_gitcfg_verify "$fp"); rc=$?
  assert_eq "$rc" "1"; assert_contains "$out" ".git/config"
  git config --unset core.fsmonitor
  assert_code_of 0 cc_gitcfg_verify "$fp"
  # 하위 모듈 설정
  git config -f .git/modules/sub/config filter.x.clean cat
  out=$(cc_gitcfg_verify "$fp"); rc=$?
  assert_eq "$rc" "1"; assert_contains "$out" ".git/modules/sub/config"
  git config -f .git/modules/sub/config --remove-section filter.x
  assert_code_of 0 cc_gitcfg_verify "$fp"
  # .git/info/attributes 생성
  mkdir -p .git/info; printf '* filter=x\n' > .git/info/attributes
  out=$(cc_gitcfg_verify "$fp"); rc=$?
  assert_eq "$rc" "1"; assert_contains "$out" ".git/info/attributes"
  rm .git/info/attributes
  # .git/modules 아래 새 git 디렉터리
  mkdir -p .git/modules/evil; : > .git/modules/evil/HEAD; printf '[core]\n' > .git/modules/evil/config
  out=$(cc_gitcfg_verify "$fp"); rc=$?
  assert_eq "$rc" "1"; assert_contains "$out" ".git/modules/evil"
  rm -rf .git/modules/evil
  # include.path 가 가리키는 파일 (작업 트리 안, 아직 없음 → 생김)
  printf '[core]\n\tfsmonitor = /bin/true\n' > cc-local.gitconfig
  out=$(cc_gitcfg_verify "$fp"); rc=$?
  assert_eq "$rc" "1"; assert_contains "$out" "cc-local.gitconfig"
  rm cc-local.gitconfig
  assert_code_of 0 cc_gitcfg_verify "$fp"
}
test_gitcfg_verify_runs_no_git() {
  # 실행 뒤 비교는 git 을 부르지 않는다 (git 이 바뀐 설정을 읽기 전에 멈추기 위해)
  repo=$(make_repo); cd "$repo"
  fp=$(cc_gitcfg_record) || { _fail "지문을 만들지 못함"; return 1; }
  mkdir -p "$TMP/spy"
  printf '#!/bin/sh\n: > "%s/git.called"\nexit 1\n' "$TMP" > "$TMP/spy/git"; chmod +x "$TMP/spy/git"
  PATH="$TMP/spy:$PATH" cc_gitcfg_verify "$fp" >/dev/null; rc=$?
  assert_eq "$rc" "0"
  assert_no_path "$TMP/git.called"
}

# ==== R34: git 이 무시하는 파일 중 비밀·설정 파일과 의존성 폴더는 내용으로 감시한다 ====
sn_ignored_fixture() {
  repo=$(make_repo "ign 한글"); cd "$repo"
  printf '.env\n.env.*\n*.pem\nnode_modules/\ndist/\n.cache/\n*.log\nconfig/\nsecrets.yaml\n' > .gitignore
  git add .gitignore && git commit -q -m ign
  printf 'SECRET=1\n' > .env; printf 'L=1\n' > .env.local; printf 'k\n' > server.pem
  mkdir -p node_modules/pkg node_modules/.bin dist .cache config deep/a
  printf 'module.exports = 1\n' > node_modules/pkg/index.js
  ln -s ../pkg/index.js node_modules/.bin/tool
  printf 'b\n' > dist/app.js; printf 'c\n' > .cache/c.txt; printf 'l\n' > app.log
  printf 'cred\n' > config/credentials.json; printf 's\n' > deep/a/secrets.yaml
}
sn_manifest_paths() { tr '\0' '\n' < "$1" | cut -f1; }
sn_manifest_entry() { tr '\0' '\n' < "$1" | awk -F '\t' -v p="$2" '$1 == p { print $2 }'; }
test_ignored_manifest_lists_only_watched_ignored_files() {
  sn_ignored_fixture
  sum=$(cc_ignored_manifest "$TMP/m1") || { _fail "manifest 실패"; return 1; }
  [ -n "$sum" ] || _fail "manifest 요약값이 없음"
  got=$(sn_manifest_paths "$TMP/m1")
  assert_eq "$got" "$(printf '%s\n' .env .env.local config/credentials.json deep/a/secrets.yaml node_modules/.bin/tool node_modules/pkg/index.js server.pem | LC_ALL=C sort)"
  # 내용 해시는 git 과 같은 blob id, 심볼릭 링크는 따라가지 않고 링크 대상 문자열로
  assert_eq "$(sn_manifest_entry "$TMP/m1" node_modules/pkg/index.js)" "100644 $(git hash-object --no-filters node_modules/pkg/index.js)"
  assert_eq "$(sn_manifest_entry "$TMP/m1" node_modules/.bin/tool)" "120000 $(printf '%s' ../pkg/index.js | git hash-object --stdin)"
  # 내용을 객체 저장소에 쓰지 않는다
  for f in .env node_modules/pkg/index.js server.pem; do
    git cat-file -e "$(git hash-object --no-filters "$f")" 2>/dev/null && _fail "감시 파일 내용이 객체 저장소에 쓰임: $f"
  done
  return 0
}
test_ignored_diff_reports_content_changes_additions_and_deletions() {
  sn_ignored_fixture
  sum=$(cc_ignored_manifest "$TMP/pre") || { _fail "manifest 실패"; return 1; }
  cc_ignored_manifest "$TMP/same" >/dev/null
  out=$(cc_ignored_diff "$TMP/pre" "$sum" "$TMP/same"); rc=$?
  assert_eq "$rc" "0"; assert_eq "$out" ""
  # 감시 대상이 아닌 무시된 파일(빌드·캐시·로그)은 바뀌어도 된다
  echo x >> dist/app.js; echo y > .cache/new; echo z >> app.log
  cc_ignored_manifest "$TMP/p0" >/dev/null
  assert_eq "$(cc_ignored_diff "$TMP/pre" "$sum" "$TMP/p0")" ""
  # 내용 변경·새 파일·삭제·링크 대상 변경
  echo CODEX=1 >> .env; printf 'n\n' > node_modules/pkg/new.js; rm server.pem
  ln -sf ../pkg/new.js node_modules/.bin/tool
  cc_ignored_manifest "$TMP/p1" >/dev/null
  out=$(cc_ignored_diff "$TMP/pre" "$sum" "$TMP/p1"); rc=$?
  assert_eq "$rc" "0"
  assert_eq "$(printf '%s' "$out" | jq -r .total)" "4"
  assert_eq "$(printf '%s' "$out" | jq -r '.shown | join(",")')" ".env,node_modules/.bin/tool,node_modules/pkg/new.js,server.pem"
  # 새 중첩 저장소도 (안을 보지 않고) 하나의 항목으로
  git init -q node_modules/gitdep
  cc_ignored_manifest "$TMP/p2" >/dev/null
  assert_contains "$(cc_ignored_diff "$TMP/pre" "$sum" "$TMP/p2")" "node_modules/gitdep"
  # 실행 전 manifest 가 기록과 다르면 비교할 수 없다
  printf 'x' >> "$TMP/pre"
  cc_ignored_diff "$TMP/pre" "$sum" "$TMP/p1" >/dev/null; rc=$?
  [ "$rc" != 0 ] || _fail "바뀐 실행 전 manifest 를 받아들임"
}
test_ignored_watch_patterns_are_one_constant() {
  for p in '.env' '.env.*' '*.pem' '*.key' '*.p12' '*.pfx' 'id_rsa*' 'id_ed25519*' '.npmrc' '.yarnrc' '.yarnrc.yml' '.pypirc' \
           '.netrc' '*.keystore' 'credentials*' 'secrets*' 'node_modules/' 'vendor/' '.venv/' 'venv/' 'Pods/' '.bundle/'; do
    case " $CC_IGNORED_WATCH_PATTERNS " in *" $p "*) ;; *) _fail "감시 목록에 [$p] 없음" ;; esac
  done
  assert_eq "$(grep -c 'CC_IGNORED_WATCH_PATTERNS=' "$CC_REPO_ROOT/plugins/yultopia/lib/cc/common.sh")" "1"
}
test_gitcfg_fingerprint_with_non_ascii_repo_path() {
  # 저장소 경로에 공백·한글이 있어도 지문이 그대로 맞는다 (JSON 으로 저장했다 읽은 경로로 파일을 찾는다)
  repo=$(make_repo "설정 저장소 한글"); cd "$repo"
  git config include.path "../포함 설정.gitconfig"
  fp=$(cc_gitcfg_record) || { _fail "지문을 만들지 못함"; return 1; }
  stored=$(printf '%s' "$fp" | jq -c .)          # state.json 에 저장했다 읽는 것과 같은 길
  out=$(cc_gitcfg_verify "$stored"); rc=$?
  assert_eq "$rc" "0" "바뀐 것 없음인데 [$out]"
  printf '[core]\n\tfsmonitor = /bin/true\n' > "포함 설정.gitconfig"
  out=$(cc_gitcfg_verify "$stored"); rc=$?
  assert_eq "$rc" "1"; assert_contains "$out" "포함 설정.gitconfig"
  assert_not_contains "$out" ".git/config"
}
test_gitcfg_verify_does_not_block_on_fifo() {
  # Codex 가 include 대상 자리에 FIFO 를 두어도 비교가 멈추지 않고 "바뀜" 으로 끝난다
  repo=$(make_repo); cd "$repo"
  git config include.path ../cc-fifo.gitconfig
  fp=$(cc_gitcfg_record) || { _fail "지문을 만들지 못함"; return 1; }
  mkfifo cc-fifo.gitconfig
  ( cc_gitcfg_verify "$fp" > "$TMP/v.out"; echo $? > "$TMP/v.rc" ) &
  vp=$!
  i=0; while kill -0 "$vp" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$vp" 2>/dev/null; then
    _fail "FIFO 에서 멈춤"
    pkill -P "$vp" 2>/dev/null; kill "$vp" 2>/dev/null   # 막힌 읽기 쪽만 끝낸다 (쓰기 쪽을 열면 그것이 대신 막힌다)
    return 1
  fi
  assert_eq "$(cat "$TMP/v.rc")" "1"
  assert_contains "$(cat "$TMP/v.out")" "cc-fifo.gitconfig"
}
test_ignored_manifest_skips_node_modules_tool_caches() {
  # 사용자 결정: node_modules 바로 아래 .cache/ 와 .vite/ 는 (깊이 상관없이) 감시하지 않는다. 그 밖의 node_modules 는 감시
  repo=$(make_repo); cd "$repo"
  printf 'node_modules/\n' > .gitignore; git add .gitignore; git commit -qm ign
  mkdir -p node_modules/.cache/babel node_modules/.vite/deps app/node_modules/.vite node_modules/pkg/.cache
  echo c > node_modules/.cache/babel/x.json; echo v > node_modules/.vite/deps/a.js; echo w > app/node_modules/.vite/b.js
  echo p > node_modules/pkg/index.js; echo q > node_modules/pkg/.cache/y
  cc_ignored_manifest "$TMP/m" >/dev/null || { _fail "manifest 실패"; return 1; }
  assert_eq "$(sn_manifest_paths "$TMP/m")" "$(printf '%s\n' node_modules/pkg/.cache/y node_modules/pkg/index.js)"
  assert_eq "$CC_IGNORED_WATCH_EXCLUDE" "node_modules/.cache/ node_modules/.vite/"
  assert_eq "$(grep -c 'CC_IGNORED_WATCH_EXCLUDE=' "$CC_REPO_ROOT/plugins/yultopia/lib/cc/common.sh")" "1"
}

# ==== Codex 보안 검수 1차 2: 등록된 하위 모듈의 .git 을 .git/modules 아래 새 git 디렉터리로 돌려도 그 안에서 git 을 돌리지 않는다 ====
# sn_redirect_sub_to_evil : sub/.git 을 .git/modules/sub/evil (악성 filter·fsmonitor 설정) 로 바꾸고 sub 안의 파일을 고친다
sn_redirect_sub_to_evil() {
  git init -q --bare .git/modules/sub/evil || return 1
  git config -f .git/modules/sub/evil/config core.bare false
  git config -f .git/modules/sub/evil/config core.worktree "$PWD/sub"
  sn_evil_config .git/modules/sub/evil/config
  printf 'gitdir: ../.git/modules/sub/evil\n' > sub/.git
  printf '* filter=evil\n' > sub/.gitattributes; echo x >> sub/s.txt
}
test_submodule_allowlist_records_exact_gitdir_and_gitfile() {
  sn_sub_repo allow || { _fail "하위 모듈 저장소를 만들지 못함 (테스트 전제)"; return 1; }
  allow=$(cc_submodule_allowlist) || { _fail "allowlist 를 만들지 못함"; return 1; }
  assert_eq "$(printf '%s' "$allow" | jq -r 'length')" "1"
  assert_eq "$(printf '%s' "$allow" | jq -r '.[0].path')" "sub"
  assert_eq "$(printf '%s' "$allow" | jq -r '.[0].gitdir')" "$(cd -P .git/modules/sub && pwd -P)"
  assert_eq "$(printf '%s' "$allow" | jq -r '.[0].gitfile')" "$(cat sub/.git)"
}
test_snapshot_does_not_follow_submodule_redirect_into_modules_subdir() {
  sn_sub_repo redir || { _fail "하위 모듈 저장소를 만들지 못함 (테스트 전제)"; return 1; }
  sn_evil_scripts
  allow=$(cc_submodule_allowlist) || _fail "allowlist 를 만들지 못함"
  t0=$(cc_snapshot_tree "$allow") || _fail "스냅샷 실패 (전)"
  assert_eq "$(git ls-tree "$t0" sub | awk '{print $3}')" "$(git -C sub rev-parse HEAD)"
  sn_redirect_sub_to_evil || { _fail "재지정 실패 (테스트 전제)"; return 1; }
  # 실행 전 allowlist 로 뜬 스냅샷: 같은 경로의 gitfile 이 같은 gitdir 을 가리키지 않으므로 들여다보지 않는다
  t1=$(cc_snapshot_tree "$allow") || _fail "스냅샷 실패 (allowlist)"
  sn_no_markers
  assert_eq "$(git ls-tree "$t1" sub | awk '{print $3}')" "$(sn_marker_link)"
  assert_eq "$(git diff --name-only "$t0" "$t1")" "sub"
  # allowlist 없이 뜨는 스냅샷도 .git/modules 의 하위라는 이유만으로 믿지 않는다 (HEAD 의 .gitmodules 이름 그대로의 gitdir 만)
  t2=$(cc_snapshot_tree) || _fail "스냅샷 실패 (allowlist 없음)"
  sn_no_markers
  assert_eq "$(git ls-tree "$t2" sub | awk '{print $3}')" "$(sn_marker_link)"
}
test_gitcfg_scan_limits_and_unreadable_dirs_fail_verification() {
  # 모듈 탐색이 깊이 제한에 닿거나 폴더를 읽지 못하면 조용히 넘기지 않고 확인 실패(2)
  repo=$(make_repo); cd "$repo"
  fp=$(cc_gitcfg_record) || { _fail "지문을 만들지 못함"; return 1; }
  d=.git/modules; i=0; while [ "$i" -lt 15 ]; do d="$d/x$i"; i=$((i + 1)); done
  mkdir -p "$d"
  cc_gitcfg_verify "$fp" >/dev/null; rc=$?
  assert_eq "$rc" "2" "깊이 제한"
  rm -rf .git/modules
  mkdir -p .git/modules/locked; chmod 000 .git/modules/locked
  cc_gitcfg_verify "$fp" >/dev/null; rc=$?
  chmod 755 .git/modules/locked
  assert_eq "$rc" "2" "읽을 수 없는 폴더"
}

# ==== Codex 보안 검수 1차 4: allowlist 의 하위 모듈 안의 무시된 중요 파일도 감시한다 (경로는 sub/...) ====
sn_sub_with_ignored() {
  local src="$TMP/subsrc-ign"
  sn_git_repo "$src" s.txt || return 1
  ( cd "$src" && printf '.env\nnode_modules/\ndist/\n' > .gitignore && git add .gitignore && git commit -q -m ign ) >/dev/null 2>&1 || return 1
  repo=$(make_repo subign) || return 1
  cd "$repo" || return 1
  git -c protocol.file.allow=always submodule add -q "$src" sub >/dev/null 2>&1 && git commit -q -m sub >/dev/null 2>&1 || return 1
  printf 'S=1\n' > sub/.env
  mkdir -p sub/node_modules/pkg sub/node_modules/.bin sub/node_modules/.cache sub/node_modules/.vite sub/dist
  printf 'p\n' > sub/node_modules/pkg/index.js; printf 'q\n' > sub/node_modules/pkg/old.js
  ln -s ../pkg/index.js sub/node_modules/.bin/t
  printf 'c\n' > sub/node_modules/.cache/c; printf 'v\n' > sub/node_modules/.vite/v; printf 'd\n' > sub/dist/a.js
}
test_ignored_manifest_covers_allowlisted_submodules() {
  sn_sub_with_ignored || { _fail "하위 모듈 저장소를 만들지 못함 (테스트 전제)"; return 1; }
  allow=$(cc_submodule_allowlist) || { _fail "allowlist 를 만들지 못함"; return 1; }
  sum=$(cc_ignored_manifest "$TMP/pre" "$allow") || { _fail "manifest 실패"; return 1; }
  assert_eq "$(sn_manifest_paths "$TMP/pre")" "$(printf '%s\n' sub/.env sub/node_modules/.bin/t sub/node_modules/pkg/index.js sub/node_modules/pkg/old.js)"
  # 내용 변경·새 파일·삭제·링크 대상 변경 (캐시 두 곳과 dist 는 그대로 허용)
  echo X=1 >> sub/.env; printf 'n\n' > sub/node_modules/pkg/new.js; rm sub/node_modules/pkg/old.js
  ln -sf ../pkg/new.js sub/node_modules/.bin/t
  echo c2 >> sub/node_modules/.cache/c; echo v2 >> sub/node_modules/.vite/v; echo d2 >> sub/dist/a.js
  cc_ignored_manifest "$TMP/post" "$allow" >/dev/null || { _fail "manifest 실패"; return 1; }
  out=$(cc_ignored_diff "$TMP/pre" "$sum" "$TMP/post")
  assert_eq "$(printf '%s' "$out" | jq -r '.shown | join(",")')" "sub/.env,sub/node_modules/.bin/t,sub/node_modules/pkg/new.js,sub/node_modules/pkg/old.js"
  # 하위 모듈을 더 믿을 수 없게 되면(.git 재지정) 그 안을 보지 않고 바뀐 것으로 나온다
  printf 'gitdir: %s\n' "$TMP/nowhere" > sub/.git
  cc_ignored_manifest "$TMP/post2" "$allow" >/dev/null || { _fail "manifest 실패"; return 1; }
  assert_contains "$(cc_ignored_diff "$TMP/pre" "$sum" "$TMP/post2")" '"sub"'
}
