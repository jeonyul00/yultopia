---
name: collab-status
description: 현재 Claude 세션의 Codex 자동 검수 켜짐/꺼짐 상태를 표시한다. 사용자가 /yultopia:collab-status 를 실행했을 때만 사용한다.
disable-model-invocation: true
argument-hint: "(인자 없음)"
---

아래 명령을 그대로 한 번 실행하고, 출력을 그대로 사용자에게 보여준다.

```bash
"${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/yultopia}/bin/codex-review.sh" session-status "$CLAUDE_CODE_SESSION_ID"
```

명령 출력 외에 다른 설명을 덧붙이지 않는다.
