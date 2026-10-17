# snapshot.sh - 사용자 인덱스를 건드리지 않는 작업 트리 스냅샷. source 전용.
#
# cc_snapshot_tree : 현재 작업 트리(추적 파일 + 무시되지 않은 untracked)의 tree sha 를 stdout 으로. 실패 시 1.
#   - 임시 인덱스만 쓴다. .git/index, 하위 모듈의 인덱스, 스테이징 상태는 바뀌지 않는다.
#     임시 인덱스는 이 호출만의 임시 폴더(active 가 있으면 그 안의 snap.XXXXXX, 없으면 TMPDIR)에 두고 끝나면 지운다.
#     그래서 동시에 뜨는 다른 스냅샷이나, 중간에 끊긴 스냅샷이 남긴 파일(잠금 포함)과 겹치지 않는다 (Codex 리뷰 1차 3).
#   - 초기화된 하위 모듈(gitlink 이고 작업 트리의 그 경로에 .git 이 있음)은 같은 방법으로 재귀적으로 뜬다(중첩 포함).
#     그 하위 모듈의 스냅샷이 하위 모듈 HEAD 의 tree 와 같으면 gitlink 를 HEAD 커밋 그대로 두고, 다르면 "HEAD + 그 스냅샷 tree"
#     로 만든 고정된 합성 값(git hash-object, 객체를 쓰지 않음. 실제 커밋이 아님)으로 바꾼다 (R32, Codex 리뷰 1차 1).
#     그래서 하위 모듈 안의 수정·삭제·새 파일도 최상위 tree 를 바꾸고 git diff <pre> <post> 에 하위 모듈 경로로 나온다.
#     하위 모듈에서 git 이 무시하는 파일만 바뀌면 그대로다. 같은 내용이면 언제나 같은 값이다.

_CC_SNAP_MAX_DEPTH=20

# _cc_snap_repo <저장소 폴더> <임시 인덱스 경로(절대)> <깊이> : (서브셸) 그 저장소 작업 트리의 tree sha 를 stdout 으로
_cc_snap_repo() (
  dir=$1; idx=$2; depth=$3
  [ "$depth" -le "$_CC_SNAP_MAX_DEPTH" ] || exit 1
  cd "$dir" || exit 1
  export GIT_INDEX_FILE="$idx"
  if git rev-parse --verify -q 'HEAD^{commit}' >/dev/null 2>&1; then
    git read-tree HEAD || exit 1
  else
    git read-tree --empty || exit 1
  fi
  git add -A >/dev/null || exit 1
  git ls-files -s -z > "$idx.links" || exit 1
  k=0
  while IFS= read -r -d '' rec; do
    case "$rec" in 160000\ *) ;; *) continue ;; esac
    path=${rec#*	}
    [ -e "$path/.git" ] || continue          # 초기화되지 않은 하위 모듈: gitlink 를 그대로 둔다
    k=$((k + 1))
    sub=$(cd "$path" && pwd -P) || exit 1
    # 그 경로가 정말 별도 저장소의 루트인지 (깨진 .git 이면 위 저장소를 보게 된다): 아니면 확인할 수 없으므로 실패
    top=$(unset GIT_INDEX_FILE; cd "$sub" && git rev-parse --show-toplevel 2>/dev/null) || exit 1
    [ "$top" = "$sub" ] || exit 1
    tree=$(_cc_snap_repo "$sub" "$idx.$k" $((depth + 1))) || exit 1
    [ -n "$tree" ] || exit 1
    head=$(unset GIT_INDEX_FILE; cd "$sub" && git rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null)
    htree=""
    [ -n "$head" ] && htree=$(unset GIT_INDEX_FILE; cd "$sub" && git rev-parse "$head^{tree}" 2>/dev/null)
    if [ -n "$head" ] && [ "$tree" = "$htree" ]; then
      link=$head
    else
      link=$(printf 'yultopia-cc submodule snapshot\nhead %s\ntree %s\n' "${head:-none}" "$tree" | git hash-object --stdin) || exit 1
    fi
    git update-index --cacheinfo "160000,$link,$path" || exit 1
  done < "$idx.links"
  git write-tree
)

cc_snapshot_tree() {
  local a base tmpdir top tree rc
  if a=$(cc_active_dir 2>/dev/null) && [ -d "$a" ] && [ ! -L "$a" ]; then
    base=$a
  else
    base="${TMPDIR:-/tmp}"
  fi
  tmpdir=$(mktemp -d "${base%/}/snap.XXXXXX") || return 1
  case "$tmpdir" in /*) ;; *) tmpdir="$(pwd -P)/$tmpdir" ;; esac    # 하위 모듈로 cd 해도 같은 파일을 가리키도록
  top=$(git rev-parse --show-toplevel 2>/dev/null) || top=""
  tree=$(_cc_snap_repo "${top:-.}" "$tmpdir/index" 0)
  rc=$?
  rm -rf "$tmpdir"
  [ "$rc" -eq 0 ] && [ -n "$tree" ] || return 1
  printf '%s\n' "$tree"
}
