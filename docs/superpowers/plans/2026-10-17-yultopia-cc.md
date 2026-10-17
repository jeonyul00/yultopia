# `/yultopia:cc` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `/yultopia:cc <자유 텍스트>` 한 번으로 Claude가 인터뷰 → Codex(PM, 읽기 전용)가 마일스톤 계획·검수 → Claude가 구현하는 자동 협업을 yultopia 플러그인에 추가한다.

**Architecture:** Claude가 따를 절차는 `skills/cc/SKILL.md` 에, Codex 호출·상태·프로세스 관리는 bash 스크립트 `bin/cc-codex.sh`(+ `lib/cc/*.sh`)에 둔다. Codex는 `codex exec` / `codex exec resume` 로 부르고, 별도 프로세스 그룹의 감독 프로세스가 20분 상한을 지킨다. 상태는 `<git-dir>/yultopia-cc/active/` 하나에만 저장하고, SessionStart·UserPromptSubmit 훅은 정리·고아 확인만 한다.

**Tech Stack:** bash 3.2 호환 셸, jq, git, perl(POSIX::setsid), codex-cli 0.163.0. 테스트는 순수 bash 테스트 러너 + 가짜 codex 실행 파일.

**Spec:** `docs/superpowers/specs/2026-10-17-yultopia-cc-design.md`

**작업 방식 (사용자 결정):** 새 브랜치를 만들지 않고 현재 브랜치(`main`)에서 작업한다. 태스크마다 ① 구현 에이전트가 테스트를 먼저 쓰고 구현 ② 테스트 실행 ③ 새 검토 에이전트가 계획·diff·테스트 결과 검토(코드 수정 안 함) ④ 근거 있는 문제만 수정 ⑤ 관련 테스트 재실행 ⑥ 검토·테스트 통과 후에만 커밋 ⑦ 다음 태스크. 재검토는 중요한 문제가 있었을 때만 한 번. 구현 에이전트는 커밋하지 않고 자기 파일만 `git add` 해 둔다. 각 태스크의 "Commit" 단계는 검토 통과 후 컨트롤러가 수행한다. 설계·계획 문서는 Task 1 커밋에 포함한다. 푸시·병합·리베이스 금지. 12단계 후 별도 에이전트가 전체 변경을 한 번 최종 검토한다.

## Global Constraints

- 모든 셸 코드는 **bash 3.2** 에서 돈다 (macOS 기본). 연관 배열, `mapfile`, `${v,,}`, `wait -n`, `declare -n` 금지.
- 의존성은 bash, jq, git, perl, ps, codex 만. Node·Python·bats 금지.
- Codex 실행 인자에 **`-m`, `--model`, `model_reasoning_effort`, `model=` 를 절대 넣지 않는다.** 강제하는 설정은 sandbox 뿐: `exec` 는 `-s read-only`, `resume` 은 `-c sandbox_mode="read-only"`.
- Codex stdin 은 항상 프롬프트 파일에서 리다이렉트한다(`- < prompt.md`). 열린 터미널 stdin 을 물려주지 않는다.
- Codex JSONL 이벤트 로그는 파일에만 쓴다. `cc-codex.sh` 의 stdout 은 **한 줄 상태** 또는 **한 줄 JSON** 만.
- 상태 위치: `$(git rev-parse --absolute-git-dir)/yultopia-cc/active`. 저장소당 하나. history 없음.
- 기본값(환경변수로만 덮어씀, 테스트용): `CC_CALL_TIMEOUT_SECS=1200`, `CC_FAST_FAIL_SECS=60`, `CC_WAIT_MAX_SECS=540`, `CC_POLL_SECS=5`, `CC_ORPHAN_GRACE_SECS=60`, `CC_STALE_DAYS=14`, `CC_MAX_CALLS=20`, `CC_MAX_REJECTS=3`, `CC_CODEX_BIN=codex`.
- 시간은 `date -u +%Y-%m-%dT%H:%M:%SZ` 로 기록하고, 경과 계산은 jq `fromdateiso8601` 로 한다. 만료 판단에 파일 mtime 을 쓰지 않는다.
- 사용자에게 보이는 문구는 한국어. 스크립트 식별자는 영어.
- 자동 커밋·푸시 없음 (기능 자체가 커밋하지 않는다).
- 기존 `skills/collab/`, `bin/inject-handoff.sh` 는 동작을 바꾸지 않는다.

## Review Focus

- 저장소 경로에 공백·한글이 있을 때 모든 명령이 동작해야 한다 → Task 1, Task 5 테스트에 `"my repo 한글"` 경로 사용.
- 커밋이 하나도 없는 새 저장소(HEAD 없음)에서도 시작·스냅샷이 동작해야 한다 → Task 2 `test_snapshot_without_head`.
- git worktree 처럼 `.git` 이 파일인 저장소에서 상태가 올바른 git 디렉터리에 생겨야 한다 → Task 1 `test_git_dir_in_worktree`.
- 같은 저장소에서 두 번째 Claude 세션이 `/cc` 를 시작하면 기존 작업을 덮지 않고 거부해야 한다 → Task 1 `test_init_refuses_when_active_exists`, Task 5 `test_call_refuses_while_running`.
- 정리본·보고에 따옴표, `$`, 백틱, 줄바꿈, 긴 텍스트가 있어도 Codex에 그대로 전달돼야 한다 → Task 4 `test_render_preserves_special_chars`, Task 5 `test_prompt_reaches_codex_stdin_intact`.

---

## 파일 구조

| 파일 | 책임 |
|---|---|
| `plugins/yultopia/bin/cc-codex.sh` | CLI 진입점. 하위 명령을 lib 함수로 연결 |
| `plugins/yultopia/bin/cc-hook.sh` | 훅 진입점 (`session-start`, `prompt-submit`). 항상 exit 0 |
| `plugins/yultopia/lib/cc/common.sh` | 기본값, 시간 함수, 출력 함수 |
| `plugins/yultopia/lib/cc/state.sh` | git 디렉터리·active 경로, 경로 안전 검사, state.json 읽기/쓰기, init/삭제 |
| `plugins/yultopia/lib/cc/snapshot.sh` | 사용자 인덱스를 건드리지 않는 작업 트리 스냅샷 |
| `plugins/yultopia/lib/cc/proc.sh` | 새 프로세스 그룹 실행, 프로세스 신원 확인, 검증된 그룹 종료 |
| `plugins/yultopia/lib/cc/render.sh` | 프롬프트 템플릿 치환 |
| `plugins/yultopia/lib/cc/call.sh` | Codex 인자 구성, 감독 프로세스, 재시도 정책, 결과 검증, 상태 반영 |
| `plugins/yultopia/lib/cc/wait.sh` | 대기 루프, 중단 신호 처리 |
| `plugins/yultopia/lib/cc/housekeeping.sh` | 고아 판정, 14일 정리, preflight, discard |
| `plugins/yultopia/lib/cc/pm-output.schema.json` | Codex 출력 스키마 |
| `plugins/yultopia/lib/cc/prompts/*.md` | PM 프롬프트 템플릿 4종 |
| `plugins/yultopia/skills/cc/SKILL.md` | Claude 절차 |
| `plugins/yultopia/hooks/hooks.json` | 훅 등록 (수정) |
| `tests/cc/run.sh`, `tests/cc/lib.sh` | 테스트 러너, 단언·임시 저장소 도우미 |
| `tests/cc/fake-codex` | 가짜 codex |
| `tests/cc/test_*.sh` | 태스크별 테스트 |
| `tests/cc/smoke-real-codex.sh` | 실제 Codex 3회 smoke test |

`tests/` 는 저장소 루트에 두어 플러그인 배포물(`plugins/yultopia/`)에 섞이지 않게 한다.

### state.json 형태 (모든 태스크 공통)

```json
{
  "version": 1,
  "created_at": "2026-10-17T05:00:00Z",
  "last_activity_at": "2026-10-17T05:10:00Z",
  "repo_root": "/abs/path",
  "phase": "planning|working|reviewing|asking|done|failed|interrupted",
  "session_id": null,
  "milestone": null,
  "milestones_total": null,
  "task_base_tree": "<tree sha>",
  "milestone_base_tree": null,
  "calls_total": 0,
  "rejects_in_row": 0,
  "tokens": {"input": 0, "cached_input": 0, "output": 0},
  "running": null,
  "waiter": null,
  "waiter_last_seen_at": null,
  "last_call": null
}
```

- `running`: `null`(실행 중 호출 없음을 명시) 또는 `{"call_id","kind","pgid","supervisor_identity","codex_pid","codex_identity","started_at","review_tree"}`
- `waiter`: `null` 또는 `{"pid","identity","started_at"}`
- `last_call`: `null` 또는 `{"call_id","kind","status":"ok|timeout|error|invalid_json|interrupted|refused","verdict","message"}`
- 호출별 파일: `active/calls/<call_id>/{prompt.md,events.jsonl,result.json,stderr.log,status}`
- 그 밖: `active/brief.md`, `active/report.md`, `active/message.md`, `active/verify/`, `active/supervisor.log`

### `cc-codex.sh` 하위 명령 (모든 태스크 공통 계약)

| 명령 | 출력(stdout) | 종료 코드 |
|---|---|---|
| `init` (stdin = 정리본) | 한 줄 | 0 / 4 이미 active / 1 오류 |
| `path <active\|brief\|report\|message\|verify>` | 절대 경로 한 줄 | 0 / 1 |
| `status` | 한 줄 | 0 / 5 active 없음 |
| `call <plan\|review\|message>` | 한 줄 (`[cc] Codex 호출 시작 …`) | 0 / 6 거부(실행 중·상한·반려 3회) / 1 |
| `wait [--max SECS]` | 완료 시 결과 JSON 한 줄, 진행 중이면 상태 한 줄, 실패면 한 줄 | 0 완료 / 2 진행 중 / 3 실패 / 130 중단 |
| `ack-rejects` | 한 줄 | 0 |
| `check-orphan [--kill]` | 고아면 한 줄, 아니면 없음 | 0 없음 / 10 고아 발견(또는 종료함) |
| `cleanup-stale` | 정리·경고 시 한 줄, 아니면 없음 | 0 |
| `preflight` | JSON 한 줄 `{"ok","code","message","dirty_files","stale_notice","active"}` | 0 ok / 7 시작 불가 |
| `discard` | 한 줄 | 0 / 6 Codex 실행 중 |
| `finish` | 한 줄 | 0 / 6 Codex 실행 중 |
| `_supervise <call_id>` | (내부용, 로그 파일로만 출력) | — |

---

### Task 1: 테스트 틀 + 상태 모듈 + init/path/status/finish

**Files:**
- Create: `tests/cc/run.sh`, `tests/cc/lib.sh`, `tests/cc/test_state.sh`
- Create: `plugins/yultopia/bin/cc-codex.sh`, `plugins/yultopia/lib/cc/common.sh`, `plugins/yultopia/lib/cc/state.sh`

**Interfaces:**
- Produces (tests/cc/lib.sh): `make_repo [dirname]` → 커밋 1개 있는 임시 저장소 경로 출력; `start_task [dirname]` → make_repo + cd + 기본 정리본으로 init, `ACTIVE` 설정; `run_cc ARGS...` → `OUT`, `ERR`, `CODE` 설정(테스트용 짧은 기본값과 `CC_CODEX_BIN=tests/cc/fake-codex`, `FAKE_CODEX_LOG` 적용); `state <jq-filter>` / `set_state <jq-filter>` (active state.json 읽기/쓰기); `cc_path <name>` (= `run_cc path <name>` 의 출력); `wait_until_status_file <call_id> [secs=10]`; `assert_eq`, `assert_contains`, `assert_not_contains`, `assert_file_exists`, `assert_no_path`, `assert_code <n>`(직전 run_cc), `assert_code_of <n> CMD...`, `assert_no_process_matching <pattern>`(pgrep -f). 변수: `TMP`(테스트별 임시 폴더, 끝나면 삭제), `CALL1`(= `$ACTIVE/calls/1`), `HOOK`(cc-hook.sh 경로), `TPL_DIR`(prompts 폴더), `REVIEW_REPORT`(예시 보고 텍스트). 각 테스트 종료 시 남은 가짜 codex 프로세스 그룹을 정리한다.
- Produces (common.sh): `cc_now_iso`, `cc_age_secs <iso>`(jq fromdateiso8601), `cc_line <msg>`(stdout 한 줄), `cc_err <msg>`(stderr).
- Produces (state.sh): `cc_git_dir` (절대 git dir, 실패 시 1), `cc_active_dir`, `cc_active_exists`, `cc_active_path_safe` (0 안전 / 1 비정상), `cc_state_get <jq-filter>`, `cc_state_update <jq-filter> [--arg k v ...]` (임시 파일 + mv 원자적 쓰기, `last_activity_at` 갱신 포함), `cc_delete_active` (안전 검사 통과 시에만 `rm -rf` 정확한 경로).

- [ ] **Step 1: 테스트 러너 작성** — `tests/cc/run.sh [test_file...]` 는 각 파일을 source 해서 `test_*` 함수를 하나씩 서브셸에서 실행하고 `PASS/FAIL 이름` 과 마지막에 `N passed, M failed` 를 출력, 실패가 있으면 exit 1.

- [ ] **Step 2: 실패하는 테스트 작성** (`tests/cc/test_state.sh`)

```bash
test_init_creates_active_in_git_dir() {
  repo=$(make_repo "my repo 한글"); cd "$repo"
  printf '목표: 테스트\n' | run_cc init; assert_code 0
  gd=$(git rev-parse --absolute-git-dir)
  assert_file_exists "$gd/yultopia-cc/active/brief.md"
  assert_eq "$(jq -r .phase "$gd/yultopia-cc/active/state.json")" "planning"
  assert_eq "$(jq -r .running "$gd/yultopia-cc/active/state.json")" "null"
  assert_eq "$(git status --porcelain)" ""        # 작업 트리에 아무것도 안 생김
}
test_init_refuses_when_active_exists() { …init 두 번 → 두 번째 assert_code 4, brief 내용 그대로… }
test_git_dir_in_worktree() { …git worktree add 후 그 안에서 init → active 가 .git/worktrees/<name>/yultopia-cc/active 에 생김… }
test_path_prints_absolute_paths() { …run_cc path brief → "$gd/yultopia-cc/active/brief.md"… }
test_delete_refuses_symlinked_active() {
  …init 후 active 를 다른 곳으로 옮기고 심볼릭 링크로 바꿈 → run_cc finish; assert_code 1; 링크 대상 디렉터리 그대로 존재…
}
test_delete_refuses_symlinked_parent() { …yultopia-cc 자체가 링크 → finish 거부… }
test_finish_deletes_only_active() { …init → finish → active 없음, yultopia-cc 디렉터리 밖 파일 그대로… }
test_state_update_is_atomic_and_touches_activity() { …last_activity_at 을 과거로 바꾼 뒤 cc_state_update '.milestone=1' → milestone 1, last_activity_at 이 최근(cc_age_secs < 5)… }
test_status_without_active() { …run_cc status → assert_code 5… }
```

- [ ] **Step 3: 실패 확인** — Run: `bash tests/cc/run.sh tests/cc/test_state.sh` / Expected: 모든 테스트 FAIL (`cc-codex.sh` 없음)

- [ ] **Step 4: 구현** — `cc-codex.sh` 는 `SELF_DIR` 기준 `../lib/cc/*.sh` 를 source 하고 `case` 로 하위 명령 분기. `init` 은 git 저장소 확인 → active 있으면 4 → 디렉터리 생성 → stdin 을 `brief.md` 로 → state.json 초기값 작성(`task_base_tree` 는 Task 2 전까지 `null`, Task 2 에서 채움). `cc_active_path_safe` 는 `yultopia-cc`, `active` 가 각각 심볼릭 링크가 아니고 `cd -P` 로 얻은 실제 경로가 `cc_git_dir` 아래인지 확인.

- [ ] **Step 5: 통과 확인** — Run: `bash tests/cc/run.sh tests/cc/test_state.sh` / Expected: 전부 PASS

- [ ] **Step 6: Commit** — `git add tests/cc plugins/yultopia/bin/cc-codex.sh plugins/yultopia/lib/cc && git commit -m "feat(cc): 상태 저장과 테스트 틀"`

---

### Task 2: 작업 트리 스냅샷

**Files:**
- Create: `plugins/yultopia/lib/cc/snapshot.sh`, `tests/cc/test_snapshot.sh`
- Modify: `plugins/yultopia/lib/cc/state.sh` (init 에서 `task_base_tree` 기록)

**Interfaces:**
- Consumes: `cc_active_dir`, `cc_state_update`
- Produces: `cc_snapshot_tree` → 현재 작업 트리(추적 + 무시 목록에 없는 untracked)의 tree sha 를 stdout 으로. 사용자 인덱스(`.git/index`)와 스테이징 상태를 바꾸지 않는다.

- [ ] **Step 1: 실패하는 테스트 작성**

```bash
test_snapshot_includes_untracked_excludes_ignored() {
  repo=$(make_repo); cd "$repo"; printf 'ignored.txt\n' > .gitignore; git add .gitignore; git commit -qm ign
  printf 'new\n' > new.txt; printf 'x\n' > ignored.txt
  t=$(cc_snapshot_tree)
  assert_contains "$(git ls-tree -r --name-only "$t")" "new.txt"
  assert_not_contains "$(git ls-tree -r --name-only "$t")" "ignored.txt"
}
test_snapshot_does_not_touch_user_index() { …git add 로 일부 스테이징 → 스냅샷 전후 `git diff --cached --name-only` 동일, untracked 파일이 스테이징되지 않음… }
test_snapshot_without_head() { …git init 만 한 저장소에서 파일 생성 → cc_snapshot_tree 성공, 결과 트리에 파일 포함… }
test_init_records_task_base_tree() { …init → state.task_base_tree == HEAD^{tree}… }
```

- [ ] **Step 2: 실패 확인** — Run: `bash tests/cc/run.sh tests/cc/test_snapshot.sh` / Expected: FAIL

- [ ] **Step 3: 구현** — 임시 인덱스 `GIT_INDEX_FILE="$(cc_active_dir)/snap.index"`(active 가 없으면 `mktemp`)로 `git read-tree HEAD`(HEAD 없으면 `git read-tree --empty`) → `git add -A` → `git write-tree`. 끝나면 임시 인덱스 삭제.

- [ ] **Step 4: 통과 확인** — Run: `bash tests/cc/run.sh tests/cc/test_snapshot.sh tests/cc/test_state.sh` / Expected: PASS

- [ ] **Step 5: Commit** — `git commit -m "feat(cc): 사용자 인덱스를 건드리지 않는 작업 트리 스냅샷"`

---

### Task 3: 프로세스 그룹과 신원 검증

**Files:**
- Create: `plugins/yultopia/lib/cc/proc.sh`, `tests/cc/test_proc.sh`

**Interfaces:**
- Produces: `cc_spawn_group <logfile> CMD...` → 새 세션·프로세스 그룹으로 실행하고 리더 PID(=PGID)를 stdout 으로. stdin 은 `/dev/null`.
- Produces: `cc_proc_identity <pid>` → `"<lstart>|<command 앞 200자>"` 출력, 프로세스 없으면 exit 1, `ps` 실패면 exit 2.
- Produces: `cc_proc_alive_verified <pid> <identity>` → 0 살아 있고 일치 / 1 확실히 없음(없거나 신원 불일치=재사용) / 2 불확실(`ps` 실패 등).
- Produces: `cc_kill_group_verified <pgid> <identity>` → 검증 통과 시 `kill -TERM -- -<pgid>`, 3초 후 남아 있으면 `-KILL`. 검증 실패면 아무것도 죽이지 않고 1.

- [ ] **Step 1: 실패하는 테스트 작성**

```bash
test_spawn_creates_new_group() {
  pg=$(cc_spawn_group "$TMP/log" bash -c 'sleep 30 & sleep 30')
  assert_eq "$(ps -o pgid= -p "$pg" | tr -d ' ')" "$pg"
}
test_kill_group_kills_children() {
  pg=$(cc_spawn_group "$TMP/log" bash -c 'sleep 30 & echo $! > '"$TMP"'/child; sleep 30'); sleep 1
  id=$(cc_proc_identity "$pg"); cc_kill_group_verified "$pg" "$id"; sleep 1
  assert_code_of 1 kill -0 "$pg"; assert_code_of 1 kill -0 "$(cat "$TMP/child")"
}
test_kill_refuses_identity_mismatch() { …다른 sleep 프로세스 PID 에 틀린 identity 로 kill → exit 1, 그 프로세스 살아 있음… }
test_alive_verified_reports_dead_pid() { …끝난 PID → 1… }
test_alive_verified_reports_reused_pid() { …살아 있는 PID + 다른 시작 시각 identity → 1… }
```

- [ ] **Step 2: 실패 확인** — Run: `bash tests/cc/run.sh tests/cc/test_proc.sh` / Expected: FAIL

- [ ] **Step 3: 구현** — 새 그룹은 `perl -MPOSIX -e 'POSIX::setsid() or exit 126; exec @ARGV or exit 127' -- CMD... </dev/null >>"$logfile" 2>&1 &` 후 `$!`. 신원은 `ps -o lstart= -p` 와 `ps -o command= -p`.

- [ ] **Step 4: 통과 확인** — Run: `bash tests/cc/run.sh tests/cc/test_proc.sh` / Expected: PASS

- [ ] **Step 5: Commit** — `git commit -m "feat(cc): 프로세스 그룹 실행과 신원 검증 종료"`

---

### Task 4: Codex 출력 스키마 + PM 프롬프트 + 치환

**Files:**
- Create: `plugins/yultopia/lib/cc/pm-output.schema.json`, `plugins/yultopia/lib/cc/render.sh`
- Create: `plugins/yultopia/lib/cc/prompts/pm-plan.md`, `pm-review.md`, `pm-message.md`, `pm-format-retry.md`
- Test: `tests/cc/test_prompts.sh`

**Interfaces:**
- Produces: `cc_render <template_path> <out_path>` — 템플릿의 `{{NAME}}` 을 환경변수 `CC_T_NAME` 값으로 바꿈. 값에 줄바꿈·특수문자가 있어도 그대로. 정의되지 않은 자리표시자가 남으면 exit 1.
- Produces: 스키마 필드 (모든 속성 required, `additionalProperties:false`, 선택 값은 `null` 허용 — Codex 구조화 출력 요건):
  - `verdict`: enum `plan|approve|reject|done|ask_user`
  - `summary`: string
  - `plan`: `null` 또는 `{"overview": string, "milestones": [{"id": integer, "title": string, "done_criteria": string}]}`
  - `milestone`: integer 또는 null
  - `instruction`: string 또는 null
  - `findings`: array of `{"file": string, "line": integer|null, "issue": string, "evidence": string}`
  - `question`: string 또는 null
- Produces: 템플릿 자리표시자 — `pm-plan.md`: `{{BRIEF}}`; `pm-review.md`: `{{REPORT}}`, `{{MILESTONE}}`, `{{MILESTONE_BASE_TREE}}`, `{{REVIEW_TREE}}`, `{{TASK_BASE_TREE}}`, `{{VERIFY_DIR}}`; `pm-message.md`: `{{MESSAGE}}`; `pm-format-retry.md`: 없음.

- [ ] **Step 1: 실패하는 테스트 작성**

```bash
test_schema_is_strict() {
  s=plugins/yultopia/lib/cc/pm-output.schema.json
  # properties 를 가진 모든 객체: required 가 properties 키 전체와 같고 additionalProperties 가 false
  assert_eq "$(jq '[.. | objects | select(has("properties"))] | all((.required|sort)==(.properties|keys|sort) and .additionalProperties==false)' "$s")" "true"
  assert_eq "$(jq -c '.properties.verdict.enum' "$s")" '["plan","approve","reject","done","ask_user"]'
}
test_render_preserves_special_chars() {
  CC_T_BRIEF=$'따옴표 " \' 달러 $HOME 백틱 `ls` \n둘째 줄' cc_render "$TPL_DIR/pm-plan.md" "$TMP/out"
  assert_contains "$(cat "$TMP/out")" $'달러 $HOME 백틱 `ls` \n둘째 줄'
}
test_render_fails_on_missing_placeholder() { …CC_T_BRIEF 없이 pm-plan 렌더 → exit 1… }
test_prompts_state_pm_rules() {
  p=$(cat plugins/yultopia/lib/cc/prompts/pm-plan.md)
  assert_contains "$p" "파일을 만들거나 고치지"      # 쓰기 금지
  assert_contains "$p" "마일스톤"                    # 마일스톤 단위
  assert_contains "$p" "AGENTS.md"                   # 중점 점검 항목
  assert_contains "$(cat plugins/yultopia/lib/cc/prompts/pm-review.md)" "테스트를 다시 돌리지"
}
```

- [ ] **Step 2: 실패 확인** — Run: `bash tests/cc/run.sh tests/cc/test_prompts.sh` / Expected: FAIL

- [ ] **Step 3: 스키마 작성** — 위 필드 그대로.

- [ ] **Step 4: 프롬프트 작성** — XML 블록 문체(`<role>`, `<task>`, `<operating_rules>`, `<review_method>`, `<structured_output_contract>`, `<grounding_rules>`), 한국어. 반드시 담을 내용(스펙 4-5):
  - `pm-plan.md`: 역할(PM·지시자·검수자, 직접 구현 금지, **어떤 도구로도 프로젝트 파일을 만들거나 고치지 말 것**, 사용자 지시 최우선) / 정리본 `{{BRIEF}}` / 첫 응답에 전체 계획·마일스톤(잘게 쪼개지 말 것)·완료 기준·1번 마일스톤 지시를 `verdict:"plan"` 으로 / 지시문 구성(목표, 수정 범위, 지킬 것, 금지, 검증 명령, 완료 기준) / `AGENTS.md` 의 `## Yultopia 중점 점검 항목` 을 검수 우선순위로 / 정리본 밖 위험 작업이 필요하면 `ask_user`.
  - `pm-review.md`: Claude 보고 `{{REPORT}}` / 이번 마일스톤 변경은 `git diff {{MILESTONE_BASE_TREE}} {{REVIEW_TREE}}`, 누적은 `git diff {{TASK_BASE_TREE}} {{REVIEW_TREE}}` 로 직접 확인 / 검증 출력 원문은 `{{VERIFY_DIR}}` / **테스트·빌드를 다시 돌리지 말 것, 권한 오류로 실패한 명령을 근거로 반려하지 말 것** / 보고를 믿지 말고 diff·파일로 확인, 근거 없는 지적 금지, 추정은 추정 표시 / 판정: 마일스톤 `{{MILESTONE}}` 승인이면 다음 지시(`approve`), 보완이면 `reject`, 마지막 마일스톤이면 전체 최종 검수까지 해서 `done` 또는 `reject`.
  - `pm-message.md`: `{{MESSAGE}}` 는 사용자 지시 또는 사용자 답변 또는 Claude 반대 의견임을 밝히고, 사용자 지시는 최우선으로 반영해 같은 스키마로 답하라.
  - `pm-format-retry.md`: 직전 답을 내용 변경 없이 스키마에 맞는 JSON 하나로만 다시 출력하라.

- [ ] **Step 5: render 구현** — `perl` 로 `{{(\w+)}}` 를 `$ENV{"CC_T_$1"}` 로 치환, 남은 자리표시자 있으면 exit 1.

- [ ] **Step 6: 통과 확인** — Run: `bash tests/cc/run.sh tests/cc/test_prompts.sh` / Expected: PASS

- [ ] **Step 7: Commit** — `git commit -m "feat(cc): Codex PM 프롬프트와 출력 스키마"`

---

### Task 5: Codex 호출 (정상 흐름)

**Files:**
- Create: `tests/cc/fake-codex` (실행 권한), `plugins/yultopia/lib/cc/call.sh`, `tests/cc/test_call.sh`
- Modify: `plugins/yultopia/bin/cc-codex.sh` (`call`, `_supervise` 연결)

**Interfaces:**
- Consumes: `cc_spawn_group`, `cc_proc_identity`, `cc_render`, `cc_snapshot_tree`, `cc_state_update`
- Produces: `cc-codex.sh call <plan|review|message>` — 프롬프트 생성(`plan`=brief, `review`=`active/report.md`+트리, `message`=`active/message.md`) → `calls_total` 증가 → `running` 기록 → `_supervise` 를 새 그룹으로 띄우고 즉시 한 줄 출력.
- Produces: `cc_codex_argv <exec|resume> <session_id|-> <call_dir>` — 아래 인자를 NUL 구분 또는 줄 단위로 출력:
  - exec: `exec --json -s read-only --output-schema <schema> -o <call_dir>/result.json -`
  - resume: `exec resume --json -c sandbox_mode="read-only" --output-schema <schema> -o <call_dir>/result.json <session_id> -`
  - 저장소 루트에서 실행, stdin 은 `<call_dir>/prompt.md`, stdout 은 `events.jsonl`, stderr 는 `stderr.log`.
- Produces (감독 프로세스가 결과 처리 후 state 반영):
  - 첫 `thread.started` 이벤트의 `thread_id` → `session_id`
  - `turn.completed.usage.{input_tokens,cached_input_tokens,output_tokens}` 합산 → `tokens`
  - 이벤트가 올 때마다 `last_activity_at` 갱신 (폴링 간격 `CC_POLL_SECS`)
  - verdict 별: `plan` → `milestone=1`, `milestones_total`, `milestone_base_tree=task_base_tree`, `phase=working` / `approve` → `milestone=result.milestone`, `milestone_base_tree=running.review_tree`, `rejects_in_row=0`, `phase=working`, `result.plan` 이 null 이 아니면 `milestones_total` 갱신 / `reject` → `rejects_in_row+1`, `phase=working` / `done` → `phase=done` / `ask_user` → `phase=asking`
  - `last_call={status:"ok", verdict}`, `running=null`, `status` 파일에 `ok`

**가짜 codex 동작** (`FAKE_CODEX_SEQ` 로 호출 순서별 모드 지정, 예 `fail_fast,ok`; 기본 `ok`):
- 매 호출마다 `$FAKE_CODEX_LOG/<n>.argv`(인자 한 줄씩), `<n>.stdin`(받은 stdin) 기록
- `ok`: exec 이면 `{"type":"thread.started","thread_id":"fake-thread-1"}` 출력, `turn.completed`(usage 100/20/10) 출력, `-o` 파일에 `FAKE_CODEX_RESULT`(기본: 유효한 plan JSON) 기록, exit 0
- `invalid_json`: `-o` 에 `not json` 기록, exit 0
- `fail_fast`: stderr 에 오류 한 줄, exit 1
- `hang`: 자식 `sleep 1000 &` 을 만들고 자신도 대기 (그룹 종료 테스트용)
- `slow`: `FAKE_CODEX_DELAY` 초 후 `ok`

- [ ] **Step 1: 가짜 codex 와 실패하는 테스트 작성**

```bash
test_plan_call_creates_session_and_applies_plan() {
  start_task                       # make_repo + init (도우미)
  run_cc call plan; assert_code 0; assert_contains "$OUT" "[cc] Codex 호출 시작"
  wait_until_status_file 1          # calls/1/status 생길 때까지 (최대 10초)
  assert_eq "$(state .session_id)" "fake-thread-1"
  assert_eq "$(state .milestone)" "1"; assert_eq "$(state .phase)" "working"
  assert_eq "$(state .tokens.output)" "10"; assert_eq "$(state .running)" "null"
}
test_codex_argv_is_read_only_without_model_overrides() {
  start_task; run_cc call plan; wait_until_status_file 1
  printf '%s' "$REVIEW_REPORT" > "$(cc_path report)"; run_cc call review; wait_until_status_file 2
  a1=$(cat "$FAKE_CODEX_LOG/1.argv"); a2=$(cat "$FAKE_CODEX_LOG/2.argv")
  assert_contains "$a1" "read-only"; assert_contains "$a2" 'sandbox_mode="read-only"'
  assert_contains "$a2" "fake-thread-1"
  for a in "$a1" "$a2"; do                     # argv 는 한 줄에 인자 하나
    assert_eq "$(printf '%s\n' "$a" | grep -cx -e '-m' -e '--model')" "0"
    assert_not_contains "$a" "model"           # model=, model_reasoning_effort 모두 차단 (sandbox_mode 는 "model" 을 포함하지 않음)
  done
}
test_prompt_reaches_codex_stdin_intact() { …brief 에 특수문자·여러 줄·10KB 텍스트 → 1.stdin 에 그대로 포함… }
test_call_stdout_has_no_event_log() { …OUT 이 한 줄이고 "thread.started" 를 포함하지 않음… }
test_review_records_trees_and_approve_moves_milestone() {
  …FAKE_CODEX_RESULT 를 approve(milestone 2)로 → state.milestone 2, milestone_base_tree == calls/2 의 review_tree, rejects_in_row 0… }
test_call_refuses_while_running() { …FAKE_CODEX_SEQ=hang → call plan → 두 번째 call → assert_code 6, 한 줄 "실행 중"… }
test_call_refuses_at_max_calls() { …state.calls_total=20 으로 설정 → call → 6, "호출 상한 20회"… }
```

- [ ] **Step 2: 실패 확인** — Run: `bash tests/cc/run.sh tests/cc/test_call.sh` / Expected: FAIL

- [ ] **Step 3: 구현** — `call` 은 거부 조건(실행 중, `calls_total >= CC_MAX_CALLS`, review 이면서 `rejects_in_row >= CC_MAX_REJECTS`) 확인 → `review` 면 `cc_snapshot_tree` 로 `review_tree` 생성 → 렌더 → `calls/<n>/prompt.md` → `_supervise <n>` 를 `cc_spawn_group "$(active)/supervisor.log"` 로 실행 → `running` 기록(감독 프로세스 신원 포함). `_supervise` 는 codex 를 자식으로 실행하고 `codex_pid`·`codex_identity` 기록, 폴링하며 활동 시각 갱신, 종료 후 결과 검증(jq 로 필수 키·verdict enum 확인)과 state 반영.

- [ ] **Step 4: 통과 확인** — Run: `bash tests/cc/run.sh tests/cc/test_call.sh` / Expected: PASS

- [ ] **Step 5: Commit** — `git commit -m "feat(cc): codex exec/resume 호출과 감독 프로세스"`

---

### Task 6: 실패 정책 (재시도·시간 상한·반려 3회)

**Files:**
- Modify: `plugins/yultopia/lib/cc/call.sh`, `plugins/yultopia/bin/cc-codex.sh` (`ack-rejects`)
- Test: `tests/cc/test_call_failures.sh`

**Interfaces:**
- Consumes: Task 5 의 `_supervise`, 가짜 codex 모드
- Produces: 감독 프로세스 정책
  - 실행 후 `CC_FAST_FAIL_SECS` 안에 비정상 종료하고 result 가 없으면 → 같은 인자로 **1회** 재실행. 또 실패 → `status=error`
  - result 가 JSON 이 아니거나 스키마 키가 틀리면 → `session_id` 가 있으면 `pm-format-retry.md` 로 resume **1회**. 또 틀림 → `status=invalid_json`
  - 경과가 `CC_CALL_TIMEOUT_SECS` 를 넘으면 → codex 프로세스(자식 포함) 종료, **재시도 없음**, `status=timeout`
  - 재실행·형식 재요청도 `calls_total` 에 포함
  - 실패 시 `running=null`, `phase=failed`, `last_call.message` 에 한국어 한 줄
- Produces: `cc-codex.sh ack-rejects` → `rejects_in_row=0` (사용자가 계속하라고 했을 때만 SKILL 이 호출)

- [ ] **Step 1: 실패하는 테스트 작성**

```bash
test_fast_failure_retries_once_then_succeeds() { FAKE_CODEX_SEQ=fail_fast,ok; start_task; run_cc call plan; wait_until_status_file 1
  assert_eq "$(cat "$CALL1/status")" "ok"; assert_eq "$(ls "$FAKE_CODEX_LOG"/*.argv | wc -l | tr -d ' ')" "2"; assert_eq "$(state .calls_total)" "2"; }
test_fast_failure_twice_reports_error() { FAKE_CODEX_SEQ=fail_fast,fail_fast; …status error, 호출 2회만, phase failed… }
test_invalid_json_requests_format_once() { FAKE_CODEX_SEQ=invalid_json,ok; …2번째 argv 가 resume + fake-thread-1, 2.stdin 이 pm-format-retry 내용, status ok… }
test_invalid_json_twice_reports_invalid_json() { FAKE_CODEX_SEQ=invalid_json,invalid_json; …status invalid_json… }
test_timeout_kills_group_and_does_not_retry() {
  FAKE_CODEX_SEQ=hang; CC_CALL_TIMEOUT_SECS=3; start_task; run_cc call plan; wait_until_status_file 1
  assert_eq "$(cat "$CALL1/status")" "timeout"; assert_eq "$(ls "$FAKE_CODEX_LOG"/*.argv | wc -l | tr -d ' ')" "1"
  assert_no_process_matching "sleep 1000"                 # 가짜 codex 의 자식까지 종료
}
test_timeout_enforced_without_waiter() { …wait 를 한 번도 부르지 않아도 위와 같이 timeout… }
test_review_refused_after_three_rejects() { …reject 결과 3번 → 네 번째 call review → 6, "연속 반려 3회"; ack-rejects 후 call review → 0… }
```

- [ ] **Step 2: 실패 확인** — Run: `bash tests/cc/run.sh tests/cc/test_call_failures.sh` / Expected: FAIL

- [ ] **Step 3: 구현** — 위 정책을 `_supervise` 에 추가.

- [ ] **Step 4: 통과 확인** — Run: `bash tests/cc/run.sh tests/cc/test_call.sh tests/cc/test_call_failures.sh` / Expected: PASS

- [ ] **Step 5: Commit** — `git commit -m "feat(cc): 재시도·20분 상한·연속 반려 제한"`

---

### Task 7: 대기와 중단

**Files:**
- Create: `plugins/yultopia/lib/cc/wait.sh`, `tests/cc/test_wait.sh`
- Modify: `plugins/yultopia/bin/cc-codex.sh` (`wait`)

**Interfaces:**
- Consumes: `cc_kill_group_verified`, `cc_proc_alive_verified`, state 의 `running`·`last_call`
- Produces: `cc-codex.sh wait [--max SECS]` (기본 `CC_WAIT_MAX_SECS`)
  - 시작 시 `waiter={pid:$$, identity, started_at}` 기록, 종료 시(EXIT trap) `waiter=null`, `waiter_last_seen_at=now`
  - 완료(ok) → `result.json` 을 `jq -c` 한 줄로 출력, exit 0
  - 실패(timeout/error/invalid_json) → `[cc] …` 한 줄, exit 3 (timeout 문구: `[cc] Codex 시간 초과(20분) — 자동 재시도하지 않았습니다`)
  - 최대 대기 도달 → `[cc] Codex 실행 중 · 호출 N · 경과 M분 · 마지막 활동 S초 전` 한 줄, exit 2
  - INT/TERM 수신 → `running` 의 그룹을 검증 후 종료, `last_call.status=interrupted`, `running=null`, `phase=interrupted`, `[cc] 중단됨: Codex 종료` 한 줄, exit 130
  - 실행 중 호출도 결과도 없으면 `[cc] 기다릴 Codex 호출이 없습니다`, exit 3

- [ ] **Step 1: 실패하는 테스트 작성**

```bash
test_wait_returns_single_json_line_on_success() { start_task; run_cc call plan; run_cc wait --max 20
  assert_code 0; assert_eq "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "1"; assert_eq "$(printf '%s' "$OUT" | jq -r .verdict)" "plan"; }
test_wait_returns_status_line_when_still_running() { FAKE_CODEX_SEQ=slow FAKE_CODEX_DELAY=10; …wait --max 2 → code 2, 한 줄 "Codex 실행 중"… }
test_wait_never_prints_event_log() { …OUT 에 "thread.started", "turn.completed" 없음… }
test_sigterm_to_wait_kills_codex_group() {
  FAKE_CODEX_SEQ=hang; start_task; run_cc call plan
  bash plugins/yultopia/bin/cc-codex.sh wait --max 60 > "$TMP/w" & wp=$!; sleep 2; kill -TERM "$wp"; wait "$wp"
  assert_eq "$?" "130"; assert_no_process_matching "sleep 1000"
  assert_eq "$(state .last_call.status)" "interrupted"; assert_eq "$(state .running)" "null"
}
test_sigint_to_wait_kills_codex_group() { …위와 같고 kill -INT… }
test_wait_records_waiter_last_seen() { …wait 종료 후 waiter null, waiter_last_seen_at 최근… }
```

- [ ] **Step 2: 실패 확인** — Run: `bash tests/cc/run.sh tests/cc/test_wait.sh` / Expected: FAIL

- [ ] **Step 3: 구현** — `CC_POLL_SECS` 간격으로 `calls/<id>/status` 확인.

- [ ] **Step 4: 통과 확인** — Run: `bash tests/cc/run.sh tests/cc/test_wait.sh` / Expected: PASS

- [ ] **Step 5: Commit** — `git commit -m "feat(cc): 대기 명령과 중단 시 Codex 그룹 종료"`

---

### Task 8: 고아 확인·14일 정리·preflight·discard

**Files:**
- Create: `plugins/yultopia/lib/cc/housekeeping.sh`, `tests/cc/test_housekeeping.sh`
- Modify: `plugins/yultopia/bin/cc-codex.sh` (`check-orphan`, `cleanup-stale`, `preflight`, `discard`, `finish` 에 실행 중 거부 추가)

**Interfaces:**
- Consumes: `cc_proc_alive_verified`, `cc_kill_group_verified`, `cc_delete_active`, `cc_age_secs`
- Produces: `cc_running_state` → `none | alive | dead | uncertain` (감독 프로세스 또는 codex 중 하나라도 검증상 살아 있으면 alive. `running` 이 null 이면 none. 기록은 있는데 둘 다 확실히 없으면 dead → 이때 `running=null`, `last_call.status=interrupted` 로 정리)
- Produces: `cc_is_orphan` → 0 고아: `cc_running_state=alive` 이고 (waiter 없음 또는 waiter 검증상 죽음) 이고 `now - (waiter_last_seen_at 없으면 running.started_at) > CC_ORPHAN_GRACE_SECS`
- Produces: `cc-codex.sh check-orphan [--kill]` — 고아면 `[cc] 기다리는 대기 명령 없이 Codex가 실행 중입니다 (호출 N, 경과 M분)` 출력 후 10. `--kill` 이면 검증 종료 후 `[cc] 남아 있던 Codex를 종료했습니다` 출력, 10.
- Produces: `cc-codex.sh cleanup-stale` — 스펙 5-4 그대로:
  - `last_activity_at` 없음·형식 오류·state 읽기 실패 → 삭제 안 함, `[cc] 오래된 /cc 기록 상태를 확인할 수 없어 지우지 않았습니다` 
  - 14일(`CC_STALE_DAYS`) 이하 → 아무 출력 없음
  - 14일 초과 + `cc_running_state` 가 `none` 또는 `dead` + 경로 안전 → 삭제, `[cc] 오래된 /cc 중단 기록을 정리했습니다`
  - 14일 초과 + `alive` → `[cc] 오래된 /cc 기록이 있지만 Codex가 아직 실행 중이라 지우지 않았습니다`
  - 14일 초과 + `uncertain` 또는 경로 비정상 → 지우지 않고 이유 한 줄
- Produces: `cc-codex.sh preflight` — 순서: git 저장소(`not_git`) → jq(`no_jq`) → codex 설치(`no_codex`) → `codex login status` 성공(`not_logged_in`) → `cleanup-stale` 결과를 `stale_notice` 에 → 고아면 `code:"orphan_running"` → active 있으면 `code:"active_present"` + `active:{phase,milestone,milestones_total,last_activity_at}` → 없으면 `git status --porcelain`(무시 파일 제외) 비어 있지 않으면 `code:"dirty"` + `dirty_files`(최대 10개) → `code:"ready"`. `ok` 는 ready 일 때만 true.
- Produces: `discard` / `finish` — `cc_running_state=alive` 면 6 과 `[cc] Codex가 실행 중입니다. 먼저 종료하세요` 한 줄, 아니면 `cc_delete_active`.

- [ ] **Step 1: 실패하는 테스트 작성**

```bash
test_orphan_detected_when_no_waiter() { FAKE_CODEX_SEQ=hang CC_ORPHAN_GRACE_SECS=1; start_task; run_cc call plan; sleep 3
  run_cc check-orphan; assert_code 10; assert_contains "$OUT" "대기 명령 없이"; }
test_not_orphan_while_waiter_alive() { …wait 를 백그라운드로 돌리는 중 check-orphan → 0… }
test_check_orphan_kill_terminates_group() { …--kill → 10, sleep 1000 없음, running null… }
test_stale_deletes_when_codex_dead() { start_task; set_state '.last_activity_at="2026-09-01T00:00:00Z"'; run_cc cleanup-stale
  assert_contains "$OUT" "오래된 /cc 중단 기록을 정리했습니다"; assert_no_path "$ACTIVE"; }
test_stale_keeps_when_codex_alive() { …hang 실행 중 + 과거 last_activity_at → 삭제 안 함, "아직 실행 중"… }
test_stale_keeps_when_activity_unreadable() { …last_activity_at 삭제 → 삭제 안 함, "확인할 수 없어"… }
test_stale_uses_last_activity_not_mtime() { …touch -t 202601010000 로 파일 mtime 을 아주 과거로, last_activity_at 은 지금 → 삭제 안 함, 출력 없음… }
test_preflight_refuses_dirty_tree_with_files() { …untracked a.txt, 수정된 README → code dirty, dirty_files 에 두 파일, ok false, exit 7… }
test_preflight_ignores_gitignored_files() { …무시 목록 파일만 있음 → ready… }
test_preflight_reports_active_present() { …init 후 preflight → active_present, active.phase planning… }
test_preflight_not_git() { …git 저장소 아닌 폴더 → not_git… }
test_discard_refuses_while_codex_running() { …hang 중 discard → 6, active 그대로… }
test_only_one_active_after_discard_and_restart() { …init → discard → init → yultopia-cc 안에 active 하나만… }
```

- [ ] **Step 2: 실패 확인** — Run: `bash tests/cc/run.sh tests/cc/test_housekeeping.sh` / Expected: FAIL

- [ ] **Step 3: 구현** — Interfaces 의 판정 순서 그대로. 고아 판정 기준 시각은 `waiter_last_seen_at` 이 없으면 `running.started_at`. `cc_running_state` 가 `dead` 를 확인하면 그 자리에서 state 를 정리한다. dirty 검사는 `git status --porcelain --untracked-files=all`.

- [ ] **Step 4: 통과 확인** — Run: `bash tests/cc/run.sh` (전체) / Expected: PASS

- [ ] **Step 5: Commit** — `git commit -m "feat(cc): 고아 확인, 14일 정리, 시작 전 확인"`

---

### Task 9: 훅 (SessionStart 정리, UserPromptSubmit 고아 확인)

**Files:**
- Create: `plugins/yultopia/bin/cc-hook.sh`, `tests/cc/test_hooks.sh`
- Modify: `plugins/yultopia/hooks/hooks.json`

**Interfaces:**
- Consumes: `cc-codex.sh cleanup-stale`, `cc_is_orphan`
- Produces: `cc-hook.sh session-start` — stdin 훅 JSON 의 `cwd` 로 이동, git 저장소가 아니거나 active 가 없으면 출력 없이 exit 0. `cleanup-stale` 출력이 있으면 `{"systemMessage":"<그 한 줄>"}` 출력. 프로세스를 죽이지 않는다. **어떤 경우에도 exit 0.**
- 훅 공통 제약 (사용자 결정): Codex 를 부르지 않는다 / 네트워크를 쓰지 않는다 / 활성 `/cc` 작업이 없으면 아무것도 출력하지 않고 즉시 끝난다 / 프로세스를 직접 죽이지 않는다 / 오류가 나도 사용자 메시지·세션 시작을 막지 않는다 / 최대한 빨리 끝난다 / 예전 codex-review 훅처럼 메시지마다 긴 작업을 시작하지 않는다.
- Produces: `cc-hook.sh prompt-submit` — active 가 없으면 즉시 exit 0. 활성 작업이 있을 때만 고아 확인 정보를 Claude 에게 전달한다. 고아면 `{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"[yultopia cc] 기다리는 대기 명령 없이 Codex가 실행 중입니다 (호출 N, 경과 M분). 사용자 메시지에 맞춰 `cc-codex.sh check-orphan --kill` 로 종료하거나 `cc-codex.sh wait` 로 다시 기다리세요."}}`. 죽이지 않는다. 항상 exit 0.
- Produces: hooks.json — SessionStart 에 기존 `inject-handoff.sh` 다음으로 `"\"${CLAUDE_PLUGIN_ROOT}\"/bin/cc-hook.sh session-start"`(timeout 10), UserPromptSubmit 에 `"\"${CLAUDE_PLUGIN_ROOT}\"/bin/cc-hook.sh prompt-submit"`(timeout 5).

- [ ] **Step 1: 실패하는 테스트 작성**

```bash
test_session_start_hook_silent_without_active() { repo=$(make_repo); out=$(printf '{"cwd":"%s","source":"startup"}' "$repo" | bash "$HOOK" session-start); assert_eq "$?" "0"; assert_eq "$out" ""; }
test_session_start_hook_reports_stale_cleanup() { …과거 last_activity_at → 출력 jq -r .systemMessage 에 "정리했습니다", active 없음… }
test_session_start_hook_exits_zero_on_garbage() { …stdin "not json", cwd 없는 경로, 심볼릭 링크 active → 모두 exit 0… }
test_prompt_submit_hook_flags_orphan_without_killing() { …hang + grace 1 → additionalContext 에 "check-orphan --kill", sleep 1000 여전히 살아 있음… }
test_prompt_submit_hook_fast_outside_git() { …git 아닌 폴더 → 출력 없음, exit 0… }
test_prompt_submit_hook_fast_without_active() { …active 없는 저장소에서 10회 실행 총 소요가 2초 미만, 출력 없음… }
test_prompt_submit_hook_never_calls_codex() { …CC_CODEX_BIN 을 호출되면 표식 파일을 남기는 가짜로 바꾸고 고아 상태에서 실행 → 표식 파일 없음… }
test_prompt_submit_hook_exits_zero_on_garbage() { …stdin "not json", 깨진 state.json → exit 0… }
test_hooks_json_keeps_handoff_and_adds_cc() {
  h=plugins/yultopia/hooks/hooks.json
  assert_contains "$(jq -r '.hooks.SessionStart[].hooks[].command' "$h")" "inject-handoff.sh"
  assert_contains "$(jq -r '.hooks.SessionStart[].hooks[].command' "$h")" "cc-hook.sh session-start"
  assert_contains "$(jq -r '.hooks.UserPromptSubmit[].hooks[].command' "$h")" "cc-hook.sh prompt-submit"
  assert_eq "$(jq -r '.hooks.Stop' "$h")" "null"
}
```

- [ ] **Step 2: 실패 확인** — Run: `bash tests/cc/run.sh tests/cc/test_hooks.sh` / Expected: FAIL

- [ ] **Step 3: 구현** — `cc-hook.sh` 는 lib 를 source 하고 본문 전체를 서브셸로 감싸 오류·stderr 를 삼키고 마지막에 `exit 0`. stdin JSON 을 jq 로 못 읽으면 조용히 끝낸다. active 존재 확인 전에는 git 명령 하나(`rev-parse --absolute-git-dir`) 외에 아무것도 하지 않는다.

- [ ] **Step 4: 통과 확인** — Run: `bash tests/cc/run.sh` / Expected: PASS

- [ ] **Step 5: Commit** — `git commit -m "feat(cc): 세션 시작 정리와 메시지마다 고아 확인 훅"`

---

### Task 10: `/yultopia:cc` SKILL.md

**Files:**
- Create: `plugins/yultopia/skills/cc/SKILL.md`
- Test: `tests/cc/test_skill.sh`

**Interfaces:**
- Consumes: `cc-codex.sh` 하위 명령 계약 전체 (위 표)
- Produces: frontmatter — `name: cc`, `description`(영어 한 줄: Claude interviews the user, then runs a Codex-as-PM milestone loop), `disable-model-invocation: true`, `argument-hint: "[하고 싶은 것 — 대충 말해도 됨]"`, `allowed-tools: Bash(cc-codex.sh:*)`
- 정리본·보고·메시지 파일은 `cc-codex.sh path <name>` 으로 경로를 얻은 뒤 Write 도구로 쓴다(셸 heredoc 대신. 권한 확인을 줄이기 위해). 단 `init` 은 stdin 으로 받는다.

본문 절 (각 절에 스펙 해당 내용을 Claude 지시문으로. 문구는 구현자가 쓰되 아래 규칙은 빠짐없이):

1. **이 세션의 원칙** — 사용자 말이 Codex 지시보다 우선 / 쉬운 한국어 / `cc-codex.sh` 출력 외에 Codex 로그를 열거나 붙여 넣지 않는다 / 커밋·푸시는 사용자가 시킬 때만.
2. **시작** — `$ARGUMENTS` 를 출발점으로(없으면 "무엇을 할까요?") / `cc-codex.sh preflight` 결과 `code` 별 대응: `not_git`·`no_jq`·`no_codex`·`not_logged_in` 안내 후 종료 / `dirty` 는 `dirty_files` 를 보여주고 "기존 변경과 /cc 변경을 구분할 수 없어 시작할 수 없다"고 설명한 뒤 **묻지 않고** 종료 / `stale_notice` 있으면 그 한 줄 전달 / `orphan_running` 은 알리고 `check-orphan --kill` 후 다시 preflight / `active_present` 는 이어 하기·버리기 질문 → 이어 하기면 단계(phase)별로 재개, 버리기면 `discard` 후 preflight 재실행.
3. **인터뷰** — 질문 하나씩, 코드·문서로 알 수 있는 건 직접 확인, 정리본 항목(목표, 완료 기준, 범위, 사용자가 정한 방향, 제약·금지, 미리 허락한 위험 작업, 검증 방법) / 위험 작업 보이면 꼭 짚어 묻기 / 정리본을 보여주고 승인받으면 `cc-codex.sh init` 에 heredoc 으로 전달.
4. **계획** — `call plan` → 대기 루프 → `plan` 결과의 요약·마일스톤을 한 줄씩 보여주고 **승인 없이** 1번 시작. 단 계획이 정리본의 목표·범위를 바꾸면 시작하지 않고 묻는다.
5. **마일스톤 작업** — 그 마일스톤을 끝까지 구현(중간에 Codex 부르지 않음) / 검증 명령 출력 원문을 `cc-codex.sh path verify` 폴더 안 `m<번호>-<이름>.log` 로 저장(`명령 > 경로 2>&1`) / `cc-codex.sh path report` 경로에 짧은 보고(바뀐 파일, 핵심 변경 1~2줄, 검증 결과 한 줄 + 로그 경로, 못 한 것·리스크, 반대 의견) / `call review` → 대기 루프.
6. **판정별 처리** — `approve`/`reject`: 정리본 대조 규칙(스펙 3-3: 미리 허락한 위험 작업은 진행, 없는 위험 작업·목표/범위 변경은 멈추고 질문, 범위 안 작은 단계는 진행, 중간 승인은 `path brief` 정리본에 추가) / 기술적으로 틀린 지시는 구현하지 않고 보고에 반대 이유, Codex가 같은 지시를 고집하면 사용자에게 질문 / 계획이 바뀌면 한 줄 보고 / `ask_user`: "Codex 질문:" 으로 그대로 묻고 답을 `path message` 에 써서 `call message` / 사용자의 방향 수정도 정리본에 반영 후 `call message`.
7. **멈춤** — `call` 이 6(반려 3회)이면 반복 반려 내용을 요약해 묻고, 계속하라면 `ack-rejects` / 호출 상한 20회면 묻는다 / `wait` 가 3 이면 그 한 줄을 전하고 멈춘다(시간 초과는 재시도하지 않는다).
8. **대기와 보고** — `cc-codex.sh wait` 를 반복 호출(Bash timeout 600000ms). exit 2 면 그 한 줄을 사용자에게 보여주고 다시 `wait` / 단계가 바뀔 때마다 `[cc 2/3] …` 한 줄 / 직접 구현이 길어지면 도구 호출 사이에 약 10분마다 한 줄.
9. **중단 후** — 훅이 `[yultopia cc] … 실행 중` 을 알려 주면 사용자 말에 따라 `check-orphan --kill` 또는 `wait` / 사용자가 Esc 후 방향을 바꾸면 정리본 반영 후 `call message`.
10. **완료** — `done` 이면 결과 보고(마일스톤별 결과, 바뀐 파일, 검증, 남은 지적, `cc-codex.sh status` 의 토큰 사용량) → "완료로 할까요? 커밋할까요?" → 완료면 `finish`, 추가 수정이면 `path message` 에 써서 `call message` 로 새 마일스톤.

- [ ] **Step 1: 실패하는 테스트 작성**

```bash
test_skill_frontmatter() { f=plugins/yultopia/skills/cc/SKILL.md
  assert_contains "$(sed -n 1,8p "$f")" "name: cc"; assert_contains "$(sed -n 1,8p "$f")" "disable-model-invocation: true"; }
test_skill_uses_only_existing_subcommands() {
  for sub in $(grep -o 'cc-codex\.sh [a-z-]*' plugins/yultopia/skills/cc/SKILL.md | awk '{print $2}' | sort -u); do
    assert_contains "preflight init path status call wait ack-rejects check-orphan cleanup-stale discard finish" "$sub"
  done
}
test_skill_states_core_rules() { s=$(cat plugins/yultopia/skills/cc/SKILL.md)
  assert_contains "$s" "묻지 않고"; assert_contains "$s" "승인 없이"; assert_contains "$s" "ack-rejects"; assert_contains "$s" "finish"; }
```

- [ ] **Step 2: 실패 확인** — Run: `bash tests/cc/run.sh tests/cc/test_skill.sh` / Expected: FAIL

- [ ] **Step 3: SKILL.md 작성**

- [ ] **Step 4: 통과 확인** — Run: `bash tests/cc/run.sh` / Expected: PASS

- [ ] **Step 5: Commit** — `git commit -m "feat(cc): /yultopia:cc 스킬 절차"`

---

### Task 11: 문서와 버전

**Files:**
- Modify: `README.md`, `plugins/yultopia/README.md`, `plugins/yultopia/.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`
- Test: `tests/cc/test_docs.sh`

- [ ] **Step 1: 실패하는 테스트 작성**

```bash
test_versions_are_2_1_0() {
  assert_eq "$(jq -r .version plugins/yultopia/.claude-plugin/plugin.json)" "2.1.0"
  assert_eq "$(jq -r '.plugins[0].version' .claude-plugin/marketplace.json)" "2.1.0"
}
test_readme_documents_cc_and_keeps_collab() { r=$(cat README.md)
  assert_contains "$r" "/yultopia:cc"; assert_contains "$r" "/yultopia:collab"; assert_contains "$r" "Codex CLI"; }
```

- [ ] **Step 2: 실패 확인** — Run: `bash tests/cc/run.sh tests/cc/test_docs.sh` / Expected: FAIL

- [ ] **Step 3: 문서 수정** — 루트 README: 요구사항 표에 Codex CLI(선택, `/yultopia:cc` 에만 필요, 로그인 필요), 스킬 표에 `/yultopia:cc`(자동: Claude 인터뷰 → Codex PM 마일스톤 검수)와 `/yultopia:collab`(수동, 복붙) 차이, 작업 트리가 깨끗할 때만 시작, 상태는 `.git/yultopia-cc/` 에 하나만, 14일 정리. 플러그인 README 구성 목록에 cc·cc-codex.sh·cc-hook.sh·lib/cc 추가. 설명 문구에 "Codex PM 자동 협업" 추가. 버전 2.1.0.

- [ ] **Step 4: 통과 확인** — Run: `bash tests/cc/run.sh` / Expected: PASS

- [ ] **Step 5: Commit** — `git commit -m "docs: /yultopia:cc 안내와 버전 2.1.0"`

---

### Task 12: 실제 Codex smoke test (최대 3회)

**Files:**
- Create: `tests/cc/smoke-real-codex.sh`

**Interfaces:**
- Consumes: 실제 `codex`(사용자 설정 그대로, 모델·추론 강도 지정 없음), `cc-codex.sh` 전체
- Produces: 단계별 `PASS/FAIL` 출력. 임시 저장소에서만 실행하고 끝나면 임시 저장소 삭제. **Codex 호출은 정확히 최대 3회** (재시도·형식 재요청이 일어나면 그 자리에서 중단하고 FAIL 로 보고해 3회를 넘기지 않는다: `CC_MAX_CALLS=3` 로 실행).

- [ ] **Step 1: 스크립트 작성** — 세 단계:
  1. 세션 시작: 짧은 정리본("README.md 에 한 줄 추가하는 작업. 마일스톤 1개.")으로 `init` → `call plan` → `wait --max 540` 반복 → `session_id` 가 비어 있지 않음, 결과가 스키마 키를 모두 가짐, `tokens.output > 0`, `events.jsonl` 에 `thread.started`·`turn.completed` 존재 확인. 이벤트 이름이 다르면 FAIL 과 함께 실제 이벤트 type 목록을 출력(→ Task 5 추출 코드 수정 근거).
  2. 같은 세션 재개: `message.md` 에 "직전 계획의 마일스톤 개수를 summary 에 숫자로 적어라. 그리고 셸에서 `touch cc-smoke-write-test` 를 실행해 보고 결과를 summary 에 적어라." → `call message` → 대기 → argv 가 resume + 같은 세션 ID, summary 에 마일스톤 개수 포함, 저장소에 `cc-smoke-write-test` **없음**(읽기 전용 강제).
  3. 중단 확인: `message.md` 에 오래 걸릴 요청(예: "저장소 전체를 아주 자세히 다시 검토하라") → `call message` → `wait` 를 백그라운드로 띄우고 20초 뒤 SIGINT → 10초 안에 codex 프로세스 없음, `last_call.status=interrupted`.

- [ ] **Step 2: 실행** — Run: `bash tests/cc/smoke-real-codex.sh` / Expected: 세 단계 모두 PASS. FAIL 이면 원인을 고친 뒤 **해당 단계만** 다시 실행(추가 호출 전에 사용자에게 알린다).

- [ ] **Step 3: Commit** — `git commit -m "test(cc): 실제 Codex smoke test"`

---

## 구현 후 사용자 확인 (자동화하지 않음)

1. Claude 를 다시 시작한 뒤 `/yultopia:cc` 를 실행해 남아 있는 active 에서 이어 하기가 되는지 1회 확인 (스펙 8-3).
2. (선택) `wait` 중 Esc 를 눌러 Codex 가 바로 꺼지는지, 안 꺼지면 다음 메시지에서 훅 안내가 뜨는지 확인. Claude Code 가 Esc 때 보내는 신호를 테스트로 알 수 없어서 넣은 확인이다.
3. 확인이 끝나면 사용 중인 설치본 `~/.claude/skills/yultopia` 동기화 여부를 사용자에게 묻고, 승인 시 백업 후 동기화.
