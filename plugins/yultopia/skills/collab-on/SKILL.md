---
name: collab-on
description: 현재 Claude 세션에서 Codex 자동 검수(Yultopia 협업 모드)를 켠다. 사용자가 /yultopia:collab-on 을 실행했을 때만 사용한다.
disable-model-invocation: true
argument-hint: "(인자 없음)"
---

아래 명령을 그대로 한 번 실행하고, 출력을 그대로 사용자에게 보여준다.

```bash
codex-review.sh session-enable "$CLAUDE_CODE_SESSION_ID" "$PWD"
```

명령 출력 외에 다른 설명을 덧붙이지 않는다. 상황을 판단하거나 다른 명령을 실행하지 않는다.
명령이 실패하면 실패 출력을 그대로 보여주고 끝낸다.
