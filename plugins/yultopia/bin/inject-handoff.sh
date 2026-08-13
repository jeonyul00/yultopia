#!/usr/bin/env bash
# SessionStart 훅: 직전 세션이 남긴 인수인계서(.claude/handoff.md)가 있으면
# 새 세션 컨텍스트로 주입한 뒤 파일을 삭제한다(1회용).
#
# - source가 clear 또는 startup일 때만 동작. resume/compact는 그냥 통과.
# - 파일이 없거나 jq가 없으면 조용히 통과(세션 시작을 막지 않는다).
# - 주입 시 원문 앞에 "첫 응답에서 짧게 요약하라"는 지시문을 덧붙인다.
# - 어떤 경우에도 exit 0으로 끝내 세션 시작을 깨뜨리지 않는다.
set -uo pipefail

input="$(cat)"

# jq 없으면 조용히 통과
command -v jq >/dev/null 2>&1 || exit 0

# 입력 JSON에서 source 추출(파싱 실패해도 빈 값 → 통과)
source="$(printf '%s' "$input" | jq -r '.source // empty' 2>/dev/null || true)"
case "$source" in
  startup|clear) ;;
  *) exit 0 ;;
esac

project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
handoff="$project_dir/.claude/handoff.md"

[ -f "$handoff" ] || exit 0

content="$(cat "$handoff")"

# 인수인계서 원문 앞에, 새 세션이 첫 응답에서 짧게 요약하도록 지시문을 덧붙인다.
instruction="아래는 이전 세션 인수인계서다. 새 세션 첫 응답 맨 앞에서 이 내용을 3~5줄로 요약하고 '이어서 진행할까요?'를 한 줄로 확인한 뒤, 사용자의 요청을 처리하라. (이 지시문 자체는 사용자에게 그대로 보여주지 말 것.)"
ctx="$instruction"$'\n\n---\n\n'"$content"

# SessionStart 컨텍스트 주입 형식(JSON)
jq -n --arg ctx "$ctx" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}' || exit 0

# 1회용: 주입했으면 삭제
rm -f "$handoff"
exit 0
