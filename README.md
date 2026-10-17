# yultopia

한국어로 코드리뷰·인수인계·문서 정리를 수행하는 Claude Code 플러그인.

> **Note for English speakers**
> All skills in this plugin are written in Korean and instruct Claude to **respond in Korean**.
> If you don't read Korean, this plugin is probably not for you.

## 무엇을 하나

AI에게 코드 리뷰를 시키면 흔히 이렇게 망가진다.

- 그럴듯한데 사실이 아닌 문제를 자신 있게 나열한다
- 찾을 게 없으면 억지로 만들어낸다
- 뭘 못 봤는지 말하지 않는다

이 플러그인의 스킬들은 그걸 **형식으로 막는다.** 근거가 약하면 `추정`이라 표시하고, 확인하지 못한 영역을 보고서에 반드시 남기고, 문제가 없으면 "현재 확인 범위에서는 없음"이라고 말하게 한다.

또 하나. 프로젝트마다 위험한 지점은 다르다. `/yultopia:init`을 한 번 실행하면 프로젝트를 직접 조사해서 `AGENTS.md`에 「중점 점검 항목」을 만들어 넣고, 나머지 스킬이 그걸 읽고 그 프로젝트에 맞게 동작한다. 플러그인 본체에는 어떤 프로젝트 고유 내용도 들어있지 않다.

## 요구사항

| 항목 | 필요 여부 | 없으면 |
|---|---|---|
| Claude Code | 필수 | — |
| `jq` | 권장 (`/yultopia:cc` 에는 필수) | 인수인계서 자동 주입이 조용히 비활성화됨 |
| Codex CLI | 선택 (`/yultopia:cc` 에만 필요) | `/yultopia:cc` 를 쓸 수 없음. 쓰려면 `codex login` 으로 로그인해 둘 것 |

## 설치

```
/plugin marketplace add jeonyul00/yultopia
/plugin install yultopia@yultopia
```

설치 후 Claude Code를 재시작하면 `/yultopia:` 로 시작하는 스킬이 뜬다.

업데이트는 이렇게 받는다.

```
/plugin marketplace update yultopia
```

## 스킬

### 먼저 한 번 실행

| 스킬 | 하는 일 |
|---|---|
| `/yultopia:init` | 프로젝트를 조사해 `AGENTS.md`에 「중점 점검 항목」을 만든다. 새 프로젝트에서 처음 한 번. 나머지 스킬이 이 절을 읽는다 |

`init`을 안 돌려도 다른 스킬은 동작한다. 다만 그 프로젝트에 특화된 판단 없이 일반 기준으로만 본다.

### 코드를 고치지 않는다

| 스킬 | 하는 일 |
|---|---|
| `/yultopia:code-review` | 저장소·디렉터리를 품질·구조·성능·중복·보안·버그위험 관점으로 점검하고 심각도순 보고서를 낸다 |
| `/yultopia:update-docs` | 프로젝트 문서를 실제 코드에 맞춘다. 낡은 문서는 고치고, 쓸모없어진 문서는 지우고, 빠진 문서는 추가한다. `AGENTS.md`·`CLAUDE.md`도 함께 정리한다 |

두 스킬 모두 코드 수정·커밋·푸시·DB 쓰기를 하지 않는다. `code-review`는 보고서만 내고, `update-docs`는 문서 파일만 고치고 지우고 만든다.

`update-docs`는 문서를 지울 때 묻지 않는다. 대신 git이 추적하는 문서만 지우므로 잘못 지워도 git으로 되돌릴 수 있고, 무엇을 왜 지웠는지 완료 보고에 남긴다.

### 세션 관리

| 스킬 | 하는 일 |
|---|---|
| `/yultopia:handoff` | `/clear` 직전에 현재 세션을 인수인계서로 저장한다. 다음 세션 시작 시 자동 주입되고 파일은 삭제된다(1회용) |

인수인계서는 `<프로젝트>/.claude/handoff.md`에 저장된다. 저장소에 올리고 싶지 않으면 `.gitignore`에 추가할 것.

### Codex 협업

| 스킬 | 하는 일 |
|---|---|
| `/yultopia:cc <하고 싶은 것>` | 자동 협업. Claude가 먼저 인터뷰하고, Codex(읽기 전용 PM)가 마일스톤을 짜고 마일스톤마다 검수한다. Claude는 구현한다. 복붙이 필요 없다 |
| `/yultopia:collab` | 수동 협업. 작업 **시작 전** Codex에게 줄 지시문을 만든다. 지시문과 작업 보고는 사용자가 Codex와 Claude 사이에서 직접 옮긴다(복붙) |

`/yultopia:collab` 은 Codex를 따로 쓸 수 있어야 한다. `/yultopia:cc` 는 Codex CLI가 설치되고 로그인되어 있으면 된다.

#### `/yultopia:cc` 알아둘 것

- git 작업 트리가 깨끗할 때만 시작한다(인터뷰를 마치고 실제로 시작하기 직전에도 다시 확인한다). 먼저 커밋하거나 stash 할 것.
- Codex는 본인의 Codex 모델·추론 강도 설정을 그대로 쓴다. 느릴 수 있어서 10분 이내 간격으로 진행 줄을 보여준다.
- Codex는 파일을 고치지 않는다.
- Codex 실행이 20분을 넘으면 멈추고 다시 시도하지 않는다.
- 작업 하나에서 Codex 호출은 모두 합쳐 20회까지다. 다 쓰면 멈추고 어떻게 할지 묻는다.
- 같은 마일스톤이 연속 3번 반려되면 보완을 멈추고 어떻게 할지 묻는다.
- 시작하자마자 분명한 기술 오류로 끝난 Codex 실행은 한 번만 다시 시도한다. 시간 초과는 다시 시도하지 않는다.
- 한계: Codex는 MCP 서버나 `codex-code-mode-host` 같은 도우미 프로세스를 따로 띄운다. /cc 가 Codex를 강제로 끝내야 했을 때(시간 초과, 중단) 이것들이 남을 수 있다. `pgrep -fl 'mcp|codex-code-mode-host'` 로 확인할 수 있다.
- 진행 기록은 저장소마다 하나, `.git/yultopia-cc/` 에 저장된다(작업 트리가 아님). 완료를 확인하면 지워지고, 14일 넘게 멈춘 기록은 Codex가 돌고 있지 않을 때 자동 정리된다.
- 세션 시작 때 정리 안내를 띄우고, 메시지마다 끊긴 작업이 없는지 가볍게 확인한다. Codex 호출도 네트워크도 쓰지 않는다.
- 자동 커밋·푸시는 하지 않는다.

## 제거

```
/plugin uninstall yultopia@yultopia
```

`AGENTS.md`에 생성된 「중점 점검 항목」은 남는다. 지우려면 `<!-- BEGIN yultopia -->` ~ `<!-- END yultopia -->` 구간만 삭제하면 된다.

## 라이선스

MIT — [LICENSE](LICENSE)
