# snapshot.sh - 사용자 인덱스를 건드리지 않는 작업 트리 스냅샷과 Codex 수정 감시 도우미. source 전용.
#
# cc_snapshot_tree : 현재 작업 트리(추적 파일 + 무시되지 않은 untracked)의 tree sha 를 stdout 으로. 실패 시 1.
#   - 임시 인덱스만 쓴다. .git/index, 하위 모듈의 인덱스, 스테이징 상태는 바뀌지 않는다.
#     임시 인덱스는 이 호출만의 임시 폴더(active 가 있으면 그 안의 snap.XXXXXX, 없으면 TMPDIR)에 두고 끝나면 지운다.
#     그래서 동시에 뜨는 다른 스냅샷이나, 중간에 끊긴 스냅샷이 남긴 파일(잠금 포함)과 겹치지 않는다 (Codex 리뷰 1차 3).
#   - 초기화된 하위 모듈은 같은 방법으로 재귀적으로 뜬다(중첩 포함). 그 하위 모듈의 스냅샷이 하위 모듈 HEAD 의 tree 와
#     같으면 gitlink 를 HEAD 커밋 그대로 두고, 다르면 "HEAD + 그 스냅샷 tree" 로 만든 고정된 합성 값(git hash-object,
#     객체를 쓰지 않음. 실제 커밋이 아님)으로 바꾼다 (R32, Codex 리뷰 1차 1). 그래서 하위 모듈 안의 수정·삭제·새 파일도
#     최상위 tree 를 바꾸고 git diff <pre> <post> 에 하위 모듈 경로로 나온다. 같은 내용이면 언제나 같은 값이다.
#   - 2026-10-18 보안 수정 R33: Codex 는 작업 트리(와 어쩌면 .git)에 쓸 수 있으므로 그 안의 중첩 저장소 설정으로 git 이
#     명령을 실행하게 할 수 있다 (core.fsmonitor, filter 드라이버 등). 그래서
#     - 재귀로 들어가는 것은 실행 전부터 있던 등록된 하위 모듈뿐이다: HEAD 의 tree 에 gitlink 로 있고, HEAD 의 .gitmodules
#       (git config --blob HEAD:.gitmodules. 작업 트리의 .gitmodules 는 Codex 가 고칠 수 있으므로 보지 않는다)에 그 경로가
#       있고, 그 경로의 .git 이 일반 파일(gitfile)이며 그것이 가리키는 git 디렉터리(실제 경로)가 이 저장소의
#       $(git rev-parse --absolute-git-dir)/modules/ 아래에 있을 때.
#     - 그 밖의 중첩 저장소(새로 생긴 것, 등록되지 않은 것, git 디렉터리가 다른 곳인 것, .git 이 없는데 비어 있지 않은 gitlink
#       폴더)는 그 안에서 git 을 실행하지 않고 그 경로에 고정된 표시 gitlink(_CC_SNAP_NESTED_TEXT 의 해시) 하나로 둔다.
#       그래서 생기거나 없어지면 바뀐 것으로 나온다. 실행 전부터 있던 이런 저장소는 전후 같은 표시라 그 안의 변경은 보지 않는다(한계).
#     - git add -A 는 gitlink 폴더와 중첩 저장소를 제외(pathspec)하고 부른다: git add 가 그 안에서 git status 를 실행하거나
#       커밋 없는 중첩 저장소에서 실패하지 않도록. 그 경로의 gitlink 는 위 규칙으로 직접 정한다. gitlink 경로가 사라졌거나
#       파일·링크로 바뀌었으면 gitlink 를 빼고 git add -A 가 그 자리의 것을 다룬다 (이전 git add -A 와 같은 결과).
#     - 모든 git 명령은 _cc_git_harden_env 를 둔 서브셸에서 돈다 (common.sh: core.fsmonitor=false, core.hooksPath=/dev/null,
#       core.untrackedCache=false, submodule.recurse=false, GIT_CONFIG_NOSYSTEM=1. 하위 모듈의 git 에도 그대로 간다).
#       저장소 설정 파일에 사용자가 둔 filter 드라이버(git-lfs 등)는 그대로 돈다. 설정 파일 자체가 바뀌었는지는
#       cc_gitcfg_verify 가 실행 뒤 스냅샷 전에 따로 확인한다 (call.sh).
#
# cc_ignored_manifest <out> : git 이 무시하는 파일 중 감시 대상(common.sh 의 CC_IGNORED_WATCH_PATTERNS: 비밀·설정 파일과
#   의존성 폴더)의 내용 manifest 를 <out> 에 쓰고 그 요약값(sha1)을 stdout 에 (R34). 실패 1. 내용은 객체 저장소에 쓰지 않는다.
#   CC_IGNORED_WATCH_EXCLUDE 의 도구 캐시 폴더(node_modules/.cache/, node_modules/.vite/) 아래는 빼고 본다 (사용자 결정).
# cc_ignored_diff <pre> <pre-sum> <post> : 두 manifest 비교. 바뀌었으면 {"total","shown"} 한 줄, 같으면 빈 출력, 0.
#   pre 가 기록한 요약값과 다르거나 읽지 못하면 1
# cc_gitcfg_record : git 설정 지문 JSON 한 줄 (Codex 실행 전에). 실패 1
# cc_gitcfg_verify <지문 JSON> : git 을 부르지 않고 다시 계산해 비교. 0 같음 / 1 바뀜(stdout: {"total","shown"}) / 2 확인 불가
#   (자세한 대상은 watch.pl)

_CC_SNAP_MAX_DEPTH=20
_CC_SNAP_NESTED_TEXT='yultopia-cc nested git repository (not inspected)'

# watch.pl 의 절대 경로 (함수 안의 BASH_SOURCE 는 이 파일이다. 훅이 불러올 때 프로세스를 만들지 않도록 부를 때 정한다)
_cc_watch_pl() { printf '%s/watch.pl' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"; }

# _cc_snap_gitfile <경로> : <경로>/.git 이 일반 파일(링크 아님)이고 "gitdir: …" 이면 _CC_GF_CONTENT(파일 내용, 끝 줄바꿈 뺌)와
#   _CC_GF_GITDIR(가리키는 git 디렉터리의 실제 경로)를 정하고 0. git 을 부르지 않는다 (셸 내장 명령만)
_cc_snap_gitfile() {
  local p="$1" line gp
  _CC_GF_CONTENT=""; _CC_GF_GITDIR=""
  [ -f "$p/.git" ] && [ ! -L "$p/.git" ] || return 1
  IFS= read -r -d '' _CC_GF_CONTENT < "$p/.git"
  [ -n "$_CC_GF_CONTENT" ] || return 1
  while :; do case "$_CC_GF_CONTENT" in *$'\n') _CC_GF_CONTENT=${_CC_GF_CONTENT%$'\n'} ;; *) break ;; esac; done
  line=${_CC_GF_CONTENT%%$'\n'*}
  case "$line" in "gitdir: "?*) gp=${line#gitdir: } ;; *) return 1 ;; esac
  gp=${gp%"${gp##*[![:space:]]}"}
  case "$gp" in /*) ;; *) gp="$p/$gp" ;; esac
  _CC_GF_GITDIR=$(cd -P "$gp" 2>/dev/null && pwd -P) || return 1
}

# _cc_snap_reg_name <경로> <(경로, 이름) NUL 쌍 파일> : HEAD .gitmodules 에서 그 경로의 하위 모듈 이름을 stdout. 없으면 1
_cc_snap_reg_name() {
  local want="$1" p n
  while IFS= read -r -d '' p && IFS= read -r -d '' n; do
    [ "$p" = "$want" ] && { printf '%s' "$n"; return 0; }
  done < "$2"
  return 1
}

# _cc_snap_allowed <최상위 기준 경로> <gitdir> <gitfile 내용> <allowlist (경로, gitdir, gitfile) NUL 셋 파일> : 똑같은 항목이 있으면 0
_cc_snap_allowed() {
  local p g c
  while IFS= read -r -d '' p && IFS= read -r -d '' g && IFS= read -r -d '' c; do
    [ "$p" = "$1" ] && [ "$g" = "$2" ] && [ "$c" = "$3" ] && return 0
  done < "$4"
  return 1
}

# _cc_snap_trusted <경로> <prefix> <git 디렉터리> <modules 실제 경로> <(경로, 이름) 파일> : 이 하위 모듈 안에서 git 을 돌려도 되면 0
#   (Codex 보안 검수 1차 2). .git/modules 의 하위라는 것만으로는 믿지 않는다:
#   - allowlist(_CC_SNAP_ALLOW, 실행 전에 만든 것)가 있으면: 같은 경로의 gitfile 이 똑같은 내용으로 똑같은 gitdir 을 가리킬 때만.
#   - 없으면: HEAD .gitmodules 의 그 경로 이름으로 정한 정확한 <git 디렉터리>/modules/<이름> (실제 경로)을 가리킬 때만.
_cc_snap_trusted() {
  local p="$1" prefix="$2" gd="$3" modroot="$4" reg="$5" name canon
  _cc_snap_gitfile "$p" || return 1
  if [ -n "${_CC_SNAP_ALLOW:-}" ]; then
    _cc_snap_allowed "$prefix$p" "$_CC_GF_GITDIR" "$_CC_GF_CONTENT" "$_CC_SNAP_ALLOW"
    return
  fi
  [ -n "$modroot" ] || return 1
  name=$(_cc_snap_reg_name "$p" "$reg") && [ -n "$name" ] || return 1
  canon=$(cd -P "$gd/modules/$name" 2>/dev/null && pwd -P) || return 1
  [ "$canon" = "$_CC_GF_GITDIR" ] || return 1
  case "$canon" in "$modroot"/?*) return 0 ;; esac
  return 1
}

# _cc_snap_repo <저장소 폴더> <임시 인덱스 경로(절대)> <깊이> [<최상위 기준 경로 앞부분 "sub/">] : (서브셸) 그 저장소 작업 트리의
#   tree sha 를 stdout 으로
_cc_snap_repo() (
  dir=$1; idx=$2; depth=$3; prefix=${4:-}
  [ "$depth" -le "$_CC_SNAP_MAX_DEPTH" ] || exit 1
  cd "$dir" || exit 1
  _cc_git_harden_env
  export GIT_INDEX_FILE="$idx"
  has_head=0
  if git rev-parse --verify -q 'HEAD^{commit}' >/dev/null 2>&1; then
    has_head=1
    git read-tree HEAD || exit 1
  else
    git read-tree --empty || exit 1
  fi
  # HEAD 의 gitlink: 폴더면 git add -A 에서 빼고 아래에서 정한다. 없어졌거나 파일·링크로 바뀌었으면 빼고 git add -A 에 맡긴다
  git ls-files -s -z > "$idx.ls" || exit 1
  printf '.\0' > "$idx.ps"
  : > "$idx.head"; : > "$idx.nested"
  while IFS= read -r -d '' rec; do
    case "$rec" in 160000\ *) ;; *) continue ;; esac
    path=${rec#*	}
    if [ -d "$path" ] && [ ! -L "$path" ]; then
      printf '%s\0' "$path" >> "$idx.head"
      printf ':(exclude,literal)%s\0' "$path" >> "$idx.ps"
    else
      git update-index --force-remove -- "$path" || exit 1
    fi
  done < "$idx.ls"
  # 무시되지 않은 새 중첩 저장소 (git ls-files 가 "경로/" 로 낸다): git add -A 에서 빼고 표시로 둔다
  git ls-files -z -o --exclude-standard > "$idx.untracked" || exit 1
  while IFS= read -r -d '' path; do
    case "$path" in */) ;; *) continue ;; esac
    path=${path%/}
    printf '%s\0' "$path" >> "$idx.nested"
    printf ':(exclude,literal)%s\0' "$path" >> "$idx.ps"
  done < "$idx.untracked"
  if [ -s "$idx.head" ] || [ -s "$idx.nested" ]; then
    git add -A --pathspec-from-file="$idx.ps" --pathspec-file-nul >/dev/null || exit 1
  else
    git add -A >/dev/null || exit 1
  fi
  marker=""
  if [ -s "$idx.head" ] || [ -s "$idx.nested" ]; then
    marker=$(printf '%s\n' "$_CC_SNAP_NESTED_TEXT" | git hash-object --stdin) && [ -n "$marker" ] || exit 1
  fi
  # 등록된 하위 모듈 (경로, 이름): HEAD 의 .gitmodules 에서만
  : > "$idx.reg"
  if [ -s "$idx.head" ] && [ "$has_head" = 1 ] && git cat-file -e 'HEAD:.gitmodules' 2>/dev/null; then
    git config -z --blob 'HEAD:.gitmodules' --get-regexp '^submodule\..*\.path$' > "$idx.regraw" 2>/dev/null
    while IFS= read -r -d '' kv; do
      case "$kv" in
        *$'\n'*)
          key=${kv%%$'\n'*}; v=${kv#*$'\n'}; name=${key#submodule.}; name=${name%.path}
          printf '%s\0%s\0' "${v%/}" "$name" >> "$idx.reg" ;;
      esac
    done < "$idx.regraw"
  fi
  modroot=""
  gd=$(git rev-parse --absolute-git-dir 2>/dev/null) || gd=""
  [ -n "$gd" ] && modroot=$(cd -P "$gd/modules" 2>/dev/null && pwd -P) || modroot=""
  k=0
  while IFS= read -r -d '' path; do
    if [ ! -e "$path/.git" ] && [ ! -L "$path/.git" ]; then
      # .git 이 없는 gitlink 폴더: 비어 있으면 초기화하지 않은 하위 모듈 (HEAD 의 gitlink 그대로)
      [ -z "$(ls -A "$path" 2>/dev/null | head -n 1)" ] && continue
      git update-index --cacheinfo "160000,$marker,$path" || exit 1
      continue
    fi
    if ! _cc_snap_trusted "$path" "$prefix" "$gd" "$modroot" "$idx.reg"; then
      git update-index --cacheinfo "160000,$marker,$path" || exit 1
      continue
    fi
    k=$((k + 1))
    sub=$(cd "$path" && pwd -P) || exit 1
    # 그 경로가 정말 별도 저장소의 루트인지 (깨진 .git 이면 위 저장소를 보게 된다): 아니면 확인할 수 없으므로 실패
    top=$(unset GIT_INDEX_FILE; cd "$sub" && git rev-parse --show-toplevel 2>/dev/null) || exit 1
    [ "$top" = "$sub" ] || exit 1
    tree=$(_cc_snap_repo "$sub" "$idx.$k" $((depth + 1)) "$prefix$path/") || exit 1
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
  done < "$idx.head"
  while IFS= read -r -d '' path; do
    git update-index --add --cacheinfo "160000,$marker,$path" || exit 1
  done < "$idx.nested"
  git write-tree
)

# _cc_snap_tmpdir : 이 호출만의 임시 폴더 (active 가 있으면 그 안, 없으면 TMPDIR). 절대 경로
_cc_snap_tmpdir() {
  local a base d
  if a=$(cc_active_dir 2>/dev/null) && [ -d "$a" ] && [ ! -L "$a" ]; then
    base=$a
  else
    base="${TMPDIR:-/tmp}"
  fi
  d=$(mktemp -d "${base%/}/snap.XXXXXX") || return 1
  case "$d" in /*) ;; *) d="$(pwd -P)/$d" ;; esac    # 하위 모듈로 cd 해도 같은 파일을 가리키도록
  printf '%s\n' "$d"
}

# cc_snapshot_tree [<하위 모듈 allowlist JSON>] : allowlist 를 주면 그 목록과 똑같은 하위 모듈에만 들어간다 (감독 프로세스와
#   나중의 다시 비교: 실행 전후가 같은 목록을 쓴다). 주지 않으면 HEAD .gitmodules 이름 그대로의 gitdir 만 (Codex 보안 검수 1차 2)
_cc_snapshot_tree_allow_file() {   # <allowlist JSON> <파일> : (경로, gitdir, gitfile) NUL 셋으로
  printf '%s' "$1" | jq -j '.[] | .path, "\u0000", .gitdir, "\u0000", .gitfile, "\u0000"' > "$2" 2>/dev/null
}
cc_snapshot_tree() {
  local tmpdir top tree rc _CC_SNAP_ALLOW=""
  tmpdir=$(_cc_snap_tmpdir) || return 1
  if [ $# -gt 0 ]; then
    _CC_SNAP_ALLOW="$tmpdir/allow"
    _cc_snapshot_tree_allow_file "$1" "$_CC_SNAP_ALLOW" || { rm -rf "$tmpdir"; return 1; }
  fi
  top=$(git rev-parse --show-toplevel 2>/dev/null) || top=""
  tree=$(_cc_snap_repo "${top:-.}" "$tmpdir/index" 0 "")
  rc=$?
  rm -rf "$tmpdir"
  [ "$rc" -eq 0 ] && [ -n "$tree" ] || return 1
  printf '%s\n' "$tree"
}

# ---- 하위 모듈 allowlist (Codex 보안 검수 1차 2) ----
# cc_submodule_allowlist : Codex 실행 전에 부른다. 지금 믿을 수 있는 초기화된 하위 모듈(중첩 포함)의 JSON 배열
#   [{path: 최상위 기준 경로("sub", "sub/nested"), gitdir: 가리키는 git 디렉터리의 실제 경로, gitfile: <경로>/.git 의 내용}].
#   HEAD 의 gitlink 이고, HEAD 의 .gitmodules 에 그 경로가 있고, gitfile 이 정확히 <git 디렉터리>/modules/<그 이름> 을 가리킬 때만
#   (_cc_snap_trusted). 실행 뒤 스냅샷·manifest 는 이 목록과 똑같은 하위 모듈에만 들어간다. 깊이 제한을 넘거나 git 이 실패하면
#   조용히 빼지 않고 1 (감독 프로세스는 codex 를 실행하지 않는다)
cc_submodule_allowlist() {
  local top tmpdir rc out=""
  top=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n "$top" ] || return 1
  tmpdir=$(_cc_snap_tmpdir) || return 1
  _cc_snap_allow_walk "$top" "" 0 "$tmpdir" > "$tmpdir/allow"; rc=$?
  if [ "$rc" -eq 0 ]; then
    out=$(jq -Rsc 'split("\u0000") | .[:-1] | [range(0; length; 3) as $i | {path: .[$i], gitdir: .[$i + 1], gitfile: .[$i + 2]}]' \
            < "$tmpdir/allow" 2>/dev/null) || rc=1
  fi
  rm -rf "$tmpdir"
  [ "$rc" -eq 0 ] && [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}
# _cc_snap_allow_walk <저장소 폴더> <앞부분> <깊이> <임시 폴더> : (서브셸) 믿을 수 있는 하위 모듈의 (경로, gitdir, gitfile) NUL 셋을 stdout 에
_cc_snap_allow_walk() (
  dir=$1; prefix=$2; depth=$3; tmpd=$4
  _CC_SNAP_ALLOW=""          # 실행 전 규칙(HEAD .gitmodules 이름 그대로의 gitdir)으로 판단한다
  [ "$depth" -le "$_CC_SNAP_MAX_DEPTH" ] || exit 1
  cd "$dir" || exit 1
  _cc_git_harden_env
  unset GIT_INDEX_FILE
  git rev-parse --verify -q 'HEAD^{commit}' >/dev/null 2>&1 || exit 0
  git cat-file -e 'HEAD:.gitmodules' 2>/dev/null || exit 0
  gd=$(git rev-parse --absolute-git-dir 2>/dev/null) && [ -n "$gd" ] || exit 1
  modroot=$(cd -P "$gd/modules" 2>/dev/null && pwd -P) || exit 0     # 초기화된 하위 모듈이 없다
  reg="$tmpd/reg.$depth.$$"; : > "$reg"
  git config -z --blob 'HEAD:.gitmodules' --get-regexp '^submodule\..*\.path$' > "$reg.raw" 2>/dev/null
  while IFS= read -r -d '' kv; do
    case "$kv" in
      *$'\n'*)
        key=${kv%%$'\n'*}; v=${kv#*$'\n'}; name=${key#submodule.}; name=${name%.path}
        printf '%s\0%s\0' "${v%/}" "$name" >> "$reg" ;;
    esac
  done < "$reg.raw"
  while IFS= read -r -d '' p && IFS= read -r -d '' name; do
    [ -n "$p" ] || continue
    ent=""
    IFS= read -r -d '' ent < <(GIT_LITERAL_PATHSPECS=1 git ls-tree -z --full-tree HEAD -- "$p" 2>/dev/null)
    case "$ent" in "160000 commit "*"	$p") ;; *) continue ;; esac              # HEAD 의 gitlink 가 아니다
    _cc_snap_trusted "$p" "$prefix" "$gd" "$modroot" "$reg" || continue        # 초기화 안 됨, 또는 믿을 수 없음
    printf '%s\0%s\0%s\0' "$prefix$p" "$_CC_GF_GITDIR" "$_CC_GF_CONTENT"
    _cc_snap_allow_walk "$PWD/$p" "$prefix$p/" $((depth + 1)) "$tmpd" || exit 1
  done < "$reg"
  exit 0
)

# ---- 무시된 파일 감시 (R34) ----
# cc_ignored_manifest <out> [<하위 모듈 allowlist JSON>] : 최상위와, allowlist 의 하위 모듈 중 지금도 똑같은 gitdir 을 가리키는 것마다
#   git ls-files -o -i (굳힌 설정)로 고른 감시 대상을 하나의 manifest 로 (하위 모듈 안의 경로는 "sub/..." . Codex 보안 검수 1차 4).
#   더 믿을 수 없게 된 하위 모듈은 그 안에서 git 을 돌리지 않고 그 경로 하나("sub")를 "믿을 수 없음" 항목으로 둔다 (바뀐 것으로 나온다)
cc_ignored_manifest() {
  local out="$1" allow="${2-}" have_allow=0 top pl tmpdir rc
  [ $# -ge 2 ] && have_allow=1
  [ -n "$out" ] || return 1
  top=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n "$top" ] || return 1
  pl=$(_cc_watch_pl) || return 1
  tmpdir=$(_cc_snap_tmpdir) || return 1
  (
    cd "$top" || exit 1
    _cc_git_harden_env
    fmt=$(git rev-parse --show-object-format 2>/dev/null) || fmt=sha1
    git ls-files -z -o -i --exclude-standard > "$tmpdir/l0" || exit 1
    set -- "$fmt" "$CC_IGNORED_WATCH_PATTERNS" "$out" "$CC_IGNORED_WATCH_EXCLUDE" "" "$top" "$tmpdir/l0"
    if [ "$have_allow" = 1 ]; then
      _cc_snapshot_tree_allow_file "$allow" "$tmpdir/allow" || exit 1
      k=0
      while IFS= read -r -d '' p && IFS= read -r -d '' g && IFS= read -r -d '' c; do
        k=$((k + 1))
        if _cc_snap_gitfile "$p" && [ "$_CC_GF_GITDIR" = "$g" ] && [ "$_CC_GF_CONTENT" = "$c" ]; then
          (cd "$p" && git ls-files -z -o -i --exclude-standard) > "$tmpdir/l$k" || exit 1
          set -- "$@" "$p/" "$top/$p" "$tmpdir/l$k"
        else
          set -- "$@" "$p/" - -
        fi
      done < "$tmpdir/allow"
    fi
    perl "$pl" ignored-manifest "$@"
  )
  rc=$?
  rm -rf "$tmpdir"
  return "$rc"
}

cc_ignored_diff() {
  local pl
  pl=$(_cc_watch_pl) || return 1
  perl "$pl" ignored-diff "$1" "$2" "$3" || return 1
}

# ---- git 설정 지문 (R33) ----
cc_gitcfg_record() (
  _cc_git_harden_env
  top=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n "$top" ] || exit 1
  gd=$(git rev-parse --absolute-git-dir 2>/dev/null) && [ -n "$gd" ] || exit 1
  cd_=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) && [ -n "$cd_" ] || exit 1
  top=$(cd -P "$top" 2>/dev/null && pwd -P) && gd=$(cd -P "$gd" 2>/dev/null && pwd -P) \
    && cd_=$(cd -P "$cd_" 2>/dev/null && pwd -P) || exit 1
  pl=$(_cc_watch_pl) || exit 1
  perl "$pl" gitcfg-record "$top" "$gd" "$cd_"
)

cc_gitcfg_verify() {
  local pl
  [ -n "$1" ] || return 2
  pl=$(_cc_watch_pl) || return 2
  printf '%s' "$1" | perl "$pl" gitcfg-verify
  case $? in 0) return 0 ;; 1) return 1 ;; esac
  return 2
}
