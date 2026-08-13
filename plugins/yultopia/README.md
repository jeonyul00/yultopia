# yultopia 플러그인

한국어 코드리뷰·버그조사·인수인계·문서동기화 스킬 묶음. Codex 자동 검수 연동(선택).

설치 방법과 스킬 설명은 저장소 루트의 [README](../../README.md)를 본다.

## 구성

- `skills/` — init, code-review, find-bug, update-docs, handoff, collab, collab-on, collab-off, collab-status
- `hooks/hooks.json` — SessionStart(인수인계 주입), UserPromptSubmit/Stop(Codex 자동 검수)
- `bin/` — codex-review.sh, inject-handoff.sh, codex-review.schema.json

## 프로젝트 고유 규칙

플러그인 본체에는 어떤 프로젝트 고유 내용도 없다.
스킬은 각 프로젝트 `AGENTS.md` 의 `## Yultopia 중점 점검 항목` 절을 읽고,
없으면 일반 기준으로 동작한다.
그 절은 프로젝트에서 `/yultopia:init` 을 한 번 실행하면 자동 생성된다.
