# yultopia 플러그인

한국어 코드리뷰·인수인계·문서 정리 스킬 묶음. Codex 수동 협업과 Codex PM 자동 협업(`/yultopia:cc`) 포함.

설치 방법과 스킬 설명은 저장소 루트의 [README](../../README.md)를 본다.

## 구성

- `skills/` — init, code-review, update-docs, handoff, collab, cc
- `hooks/hooks.json` — SessionStart(inject-handoff, cc-hook session-start), UserPromptSubmit(cc-hook prompt-submit)
- `bin/` — inject-handoff.sh, cc-codex.sh, cc-hook.sh
- `lib/cc/` — cc-codex.sh 가 쓰는 보조 스크립트와 프롬프트

## 프로젝트 고유 규칙

플러그인 본체에는 어떤 프로젝트 고유 내용도 없다.
스킬은 각 프로젝트 `AGENTS.md` 의 `## Yultopia 중점 점검 항목` 절을 읽고,
없으면 일반 기준으로 동작한다.
그 절은 프로젝트에서 `/yultopia:init` 을 한 번 실행하면 자동 생성된다.
