#!/bin/bash
# 테스트 러너: tests/cc/run.sh [test_file...]
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
. "$HERE/lib.sh"

if [ $# -gt 0 ]; then FILES=("$@"); else FILES=("$HERE"/test_*.sh); fi
passed=0; failed=0
for f in "${FILES[@]}"; do
  [ -f "$f" ] || { echo "FAIL $f (파일 없음)"; failed=$((failed+1)); continue; }
  f=$(cd "$(dirname "$f")" && pwd -P)/$(basename "$f")
  before=$(declare -F | awk '{print $3}' | grep '^test_' | sort)
  . "$f"
  after=$(declare -F | awk '{print $3}' | grep '^test_' | sort)
  names=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))
  for t in $names; do
    TMP=$(mktemp -d "${TMPDIR:-/tmp}/cc-test.XXXXXX") && TMP=$(cd -P "$TMP" && pwd -P)
    case "$TMP" in
      */cc-test.*) ;;
      *) echo "FAIL $t (임시 폴더 생성 실패)"; failed=$((failed+1)); continue ;;
    esac
    export TMP
    ( cd "$TMP" && "$t" ) > "$TMP/.test.out" 2>&1
    rc=$?
    cleanup_test
    if [ $rc -eq 0 ] && [ ! -e "$TMP/.failed" ]; then
      echo "PASS $t"; passed=$((passed+1))
    else
      echo "FAIL $t"; sed 's/^/    /' "$TMP/.test.out"; failed=$((failed+1))
    fi
    case "$TMP" in */cc-test.*) rm -rf "$TMP" ;; esac
  done
  for t in $names; do unset -f "$t"; done
done
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
