# yultopia

한국어로 코드리뷰·버그조사·인수인계·문서동기화를 수행하는 Claude Code 플러그인.

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
| `jq` | 권장 | 인수인계서 자동 주입이 조용히 비활성화됨 |
| [Codex CLI](https://developers.openai.com/codex/cli) | **선택** | 스킬 6개는 정상 동작. Codex 자동 검수 기능만 못 씀 |

**Codex가 없어도 쓸 수 있다.** `init` / `code-review` / `find-bug` / `update-docs` / `handoff` / `collab`은 Claude 단독으로 동작한다. Codex가 필요한 건 자동 검수(`collab-on` / `collab-off` / `collab-status`)뿐이다.

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

### 읽기 전용 (코드를 고치지 않는다)

| 스킬 | 하는 일 |
|---|---|
| `/yultopia:code-review` | 저장소·디렉터리를 품질·구조·성능·중복·보안·버그위험 관점으로 점검하고 심각도순 보고서를 낸다 |
| `/yultopia:find-bug` | 증상·로그·시각·요청을 단서로 원인을 추적한다. 결론/위치/원인/증거/영향/수정방향으로 보고 |
| `/yultopia:update-docs` | `AGENTS.md`·`CLAUDE.md`를 실제 코드·명령어와 맞춘다 (문서만 수정) |

세 스킬 모두 코드 수정·커밋·푸시·DB 쓰기를 하지 않는다.

### 세션 관리

| 스킬 | 하는 일 |
|---|---|
| `/yultopia:handoff` | `/clear` 직전에 현재 세션을 인수인계서로 저장한다. 다음 세션 시작 시 자동 주입되고 파일은 삭제된다(1회용) |

인수인계서는 `<프로젝트>/.claude/handoff.md`에 저장된다. 저장소에 올리고 싶지 않으면 `.gitignore`에 추가할 것.

### Codex 협업 (Codex CLI 필요)

| 스킬 | 하는 일 |
|---|---|
| `/yultopia:collab` | Codex를 PM·리뷰어로, Claude를 구현자로 두는 수동 협업. 작업 **시작 전** Codex에게 줄 지시문을 만든다 |
| `/yultopia:collab-on` | 현재 세션에서 Codex 자동 검수를 켠다 |
| `/yultopia:collab-off` | 끈다 |
| `/yultopia:collab-status` | 현재 상태를 본다 |

**자동 검수는 세션마다 항상 꺼진 상태로 시작한다.** 필요할 때 `/yultopia:collab-on`으로 켠다.

## 알아둘 것

**자동 검수를 켜면 응답이 느려진다.** Claude가 응답을 마칠 때마다 Codex 검수가 돌고, 훅 타임아웃이 400초로 잡혀 있다. 짧은 대화를 여러 번 주고받는 상황에서는 체감이 크다. 껐다 켜며 쓰는 것을 권한다.

**스크립트 위치 찾기.** 아래 두 기능은 스킬이 아니라 스크립트를 직접 실행한다. 설치 방식에 따라 경로가 다르므로 먼저 찾는다.

```bash
find ~/.claude -name codex-review.sh -path '*yultopia*' 2>/dev/null
```

**비상 정지.** 검수가 멈추지 않으면 전부 끌 수 있다.

```bash
"$(find ~/.claude -name codex-review.sh -path '*yultopia*' | head -1)" disable
```

**직전 검수 원문 보기.**

```bash
"$(find ~/.claude -name codex-review.sh -path '*yultopia*' | head -1)" show-last
```

## (선택) 자연어로 부르기

말로 부르고 싶으면 `~/.claude/CLAUDE.md`에 아래를 직접 넣는다. **넣지 않아도 슬래시 명령은 전부 동작한다.**

`<스크립트경로>` 자리에는 위 「스크립트 위치 찾기」로 확인한 실제 경로를 넣는다.

```markdown
## Yultopia 협업 모드

평소에는 Claude만 응답한다. 사용자가 `/yultopia:collab-on` 을 실행한 세션에서만
작업 완료 시 Codex 자동 검수가 돌아간다. 새 세션은 항상 꺼짐이다.

| 사용자 표현 | 실행할 명령 |
|---|---|
| "코덱스 검수 원문 보여줘" | `<스크립트경로> show-last` |
| "협업 모드 상태 알려줘" | `/yultopia:collab-status` 스킬 |
| "코덱스 검수 전부 멈춰줘" (비상) | `<스크립트경로> disable` |

원문을 요청받으면 `show-last` 출력을 **그대로** 보여준다. 요약하거나 고쳐 쓰지 않는다.
원문이 없거나 만료됐으면 그 사실을 그대로 전한다.
Codex 의 말을 내 의견처럼 바꾸어 전달하지 않는다.
```

## 제거

```
/plugin uninstall yultopia@yultopia
```

`AGENTS.md`에 생성된 「중점 점검 항목」은 남는다. 지우려면 `<!-- BEGIN yultopia -->` ~ `<!-- END yultopia -->` 구간만 삭제하면 된다.

## 라이선스

MIT — [LICENSE](LICENSE)
