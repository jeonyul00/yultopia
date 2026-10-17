# snapshot.sh - 사용자 인덱스를 건드리지 않는 작업 트리 스냅샷. source 전용.

# 현재 작업 트리(추적 파일 + 무시되지 않은 untracked)의 tree sha 를 stdout 으로.
# 임시 인덱스만 쓰므로 .git/index 와 스테이징 상태는 바뀌지 않는다. 실패 시 1.
cc_snapshot_tree() {
  local a idx tmpdir="" tree rc top
  if a=$(cc_active_dir 2>/dev/null) && [ -d "$a" ] && [ ! -L "$a" ]; then
    idx="$a/snap.index"
    rm -f "$idx"
  else
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/cc-snap.XXXXXX") || return 1
    idx="$tmpdir/index"
  fi
  top=$(git rev-parse --show-toplevel 2>/dev/null) || top=""
  tree=$(
    export GIT_INDEX_FILE="$idx"
    [ -n "$top" ] && { cd "$top" || exit 1; }
    if git rev-parse --verify -q 'HEAD^{commit}' >/dev/null 2>&1; then
      git read-tree HEAD || exit 1
    else
      git read-tree --empty || exit 1
    fi
    git add -A >/dev/null || exit 1
    git write-tree
  )
  rc=$?
  rm -f "$idx"
  [ -n "$tmpdir" ] && rm -rf "$tmpdir"
  [ "$rc" -eq 0 ] && [ -n "$tree" ] || return 1
  printf '%s\n' "$tree"
}
