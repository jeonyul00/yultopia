# test_put.sh - Task 10 (Ruling R25): cc-codex.sh put <brief|report|message> / put verify <name>
#   상태는 .git 안에 있어 SKILL 이 Write 도구를 쓸 수 없다. 그래서 stdin 을 받아 active 안 파일로 원자적으로 쓴다.

# ---- 이 파일 전용 도우미 (test_ 로 시작하지 않게) ----
put_lines() { printf '%s\n' "$1" | wc -l | tr -d ' '; }
put_no_temp_left() {
  local n
  n=$( { ls -A "$ACTIVE"; ls -A "$ACTIVE/verify" 2>/dev/null; } | grep -c '^\.put\.')
  assert_eq "$n" "0" "남은 임시 파일"
}
# 실행 중인 호출이 있으면 그 감독 프로세스 그룹을 끝낸다 (테스트 정리용, 자기 그룹은 건드리지 않음)
put_reap() {
  local pg mypg i=0
  pg=$(jq -r '.running.pgid // empty' "$ACTIVE/state.json" 2>/dev/null)
  case "$pg" in ''|*[!0-9]*|0|1) return 0 ;; esac
  mypg=$(ps -o pgid= -p $$ | tr -d ' ')
  [ "$pg" = "$mypg" ] && return 0
  kill -KILL -- "-$pg" 2>/dev/null
  while kill -0 -- "-$pg" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
}
# 따옴표, $, 백틱, 역슬래시, 한글, 빈 줄, CR, 끝 줄바꿈 없음
put_special_content() {
  printf '목표: "로그인" 잠금 $HOME `whoami` \\n 역슬래시\n\n탭\t끝\r\nEOF\n마지막 줄 줄바꿈 없음'
}

# ---- 정상 흐름 ----
test_put_brief_round_trip_preserves_bytes() {
  start_task "my repo 한글"
  put_special_content > "$TMP/expected"
  run_cc put brief < "$TMP/expected"; assert_code 0
  assert_eq "$OUT" "[cc] brief 저장됨"
  cmp -s "$TMP/expected" "$ACTIVE/brief.md" || _fail "brief.md 내용이 바뀜"
  put_no_temp_left
}
test_put_report_and_message_go_to_their_files() {
  start_task
  printf '보고 내용\n' | run_cc put report; assert_code 0
  assert_eq "$OUT" "[cc] report 저장됨"
  printf '사용자 지시\n' | run_cc put message; assert_code 0
  assert_eq "$OUT" "[cc] message 저장됨"
  assert_eq "$(cat "$(cc_path report)")" "보고 내용"
  assert_eq "$(cat "$(cc_path message)")" "사용자 지시"
  put_no_temp_left
}
test_put_brief_overwrites_previous_brief() {
  start_task
  assert_eq "$(cat "$ACTIVE/brief.md")" "목표: 기본 정리본"
  printf '목표: 고친 정리본\n미리 허락한 위험 작업: users 테이블 컬럼 추가\n' | run_cc put brief; assert_code 0
  assert_eq "$(cat "$ACTIVE/brief.md")" $'목표: 고친 정리본\n미리 허락한 위험 작업: users 테이블 컬럼 추가'
}
test_put_large_input_round_trip() {
  start_task
  perl -e 'for my $i (1..40000) { print "줄 $i: \"x\" \$y `z` 한글 abcdefghijklmnopqrstuvwxyz\n" }' > "$TMP/big"
  [ "$(wc -c < "$TMP/big")" -gt 2000000 ] || _fail "입력이 충분히 크지 않음"
  run_cc put report < "$TMP/big"; assert_code 0
  cmp -s "$TMP/big" "$ACTIVE/report.md" || _fail "큰 입력이 그대로 저장되지 않음"
  put_no_temp_left
}
test_put_verify_writes_into_verify_dir() {
  start_task
  printf 'ok 1 - 테스트\nexit=0\n' > "$TMP/expected"
  run_cc put verify m1-test.log < "$TMP/expected"; assert_code 0
  assert_contains "$OUT" "[cc] verify/m1-test.log 저장됨"
  assert_eq "$(put_lines "$OUT")" "1"
  cmp -s "$TMP/expected" "$ACTIVE/verify/m1-test.log" || _fail "검증 출력이 그대로 저장되지 않음"
  put_no_temp_left
}
test_put_verify_line_shows_exit_code_when_last_line_has_it() {
  start_task
  { echo "FAIL a"; echo "exit=1"; } | run_cc put verify m2-test.log; assert_code 0
  assert_eq "$OUT" "[cc] verify/m2-test.log 저장됨 (exit=1)"
  printf 'no exit line\n' | run_cc put verify m2-lint.log; assert_code 0
  assert_eq "$OUT" "[cc] verify/m2-lint.log 저장됨"
}
test_put_verify_creates_missing_verify_dir() {
  start_task
  rm -rf "$ACTIVE/verify"
  printf 'exit=0\n' | run_cc put verify m1.log; assert_code 0
  assert_file_exists "$ACTIVE/verify/m1.log"
  [ -d "$ACTIVE/verify" ] && [ ! -L "$ACTIVE/verify" ] || _fail "verify 가 일반 폴더가 아님"
}
test_put_brief_is_what_call_plan_sends() {
  start_task
  put_special_content > "$TMP/expected"
  run_cc put brief < "$TMP/expected"; assert_code 0
  # prompt.md 는 call 이 돌아오기 전에 만들어진다: 호출이 끝나길 기다리지 않는다
  run_cc call plan; assert_code 0
  grep -qF '목표: "로그인" 잠금 $HOME `whoami`' "$CALL1/prompt.md" || _fail "프롬프트에 put 한 정리본이 없음"
  grep -qF '마지막 줄 줄바꿈 없음' "$CALL1/prompt.md" || _fail "프롬프트에 정리본 끝부분이 없음"
  put_reap
}

# ---- 거부 ----
test_put_rejects_empty_stdin() {
  start_task
  run_cc put report < /dev/null; assert_code 1
  assert_eq "$(put_lines "$OUT")" "1"
  assert_no_path "$ACTIVE/report.md"
  before=$(cat "$ACTIVE/brief.md")
  printf '' | run_cc put brief; assert_code 1
  assert_eq "$(cat "$ACTIVE/brief.md")" "$before"
  run_cc put verify m1.log < /dev/null; assert_code 1
  assert_no_path "$ACTIVE/verify/m1.log"
  put_no_temp_left
}
test_put_rejects_unknown_names_and_usage() {
  start_task
  before=$(cat "$ACTIVE/state.json")
  for name in state state.json calls brief.md "" verify/x ../brief; do
    printf 'x\n' | run_cc put "$name"; assert_code 1
    assert_eq "$(put_lines "$OUT")" "1" "put [$name]"
  done
  printf 'x\n' | run_cc put; assert_code 1
  printf 'x\n' | run_cc put report extra; assert_code 1
  printf 'x\n' | run_cc put verify; assert_code 1
  printf 'x\n' | run_cc put verify a.log extra; assert_code 1
  assert_eq "$(cat "$ACTIVE/state.json")" "$before"
  assert_no_path "$ACTIVE/report.md"
}
test_put_verify_rejects_bad_file_names() {
  start_task
  long=$(printf 'a%.0s' $(seq 1 101))
  ok100=$(printf 'b%.0s' $(seq 1 100))
  for name in "" "." ".." "../x" "../../outside.log" "a/b" "/abs.log" ".hidden" "-x.log" "_x.log" \
              "a b.log" "m1-테스트.log" "a*b" $'a\nb' "$long"; do
    printf 'x\n' | run_cc put verify "$name"; assert_code 1
    assert_eq "$(put_lines "$OUT")" "1" "put verify [$name]"
  done
  assert_eq "$(ls -A "$ACTIVE/verify" | wc -l | tr -d ' ')" "0" "verify 에 파일이 생김"
  assert_no_path "$ACTIVE/x"
  assert_no_path "$TMP/outside.log"
  # 경계: 100자, 점·밑줄·하이픈은 허용
  printf 'x\n' | run_cc put verify "$ok100"; assert_code 0
  printf 'x\n' | run_cc put verify "M1_a.b-c.log"; assert_code 0
  assert_file_exists "$ACTIVE/verify/M1_a.b-c.log"
}
test_put_without_active_exits_5() {
  repo=$(make_repo); cd "$repo"
  printf 'x\n' | run_cc put report; assert_code 5
  assert_eq "$(put_lines "$OUT")" "1"
  printf 'x\n' | run_cc put verify m1.log; assert_code 5
  assert_no_path "$(git rev-parse --absolute-git-dir)/yultopia-cc"
}

# ---- 경로 안전 ----
test_put_refuses_symlinked_active() {
  start_task
  gd=$(git rev-parse --absolute-git-dir)
  mv "$gd/yultopia-cc/active" "$TMP/elsewhere"
  ln -s "$TMP/elsewhere" "$gd/yultopia-cc/active"
  printf 'x\n' | run_cc put report; assert_code 1
  assert_eq "$(put_lines "$OUT")" "1"
  assert_no_path "$TMP/elsewhere/report.md"
  printf 'x\n' | run_cc put verify m1.log; assert_code 1
  assert_no_path "$TMP/elsewhere/verify/m1.log"
  [ -L "$gd/yultopia-cc/active" ] || _fail "심볼릭 링크가 사라짐"
}
test_put_refuses_symlinked_parent() {
  start_task
  gd=$(git rev-parse --absolute-git-dir)
  mv "$gd/yultopia-cc" "$TMP/elsewhere"
  ln -s "$TMP/elsewhere" "$gd/yultopia-cc"
  printf 'x\n' | run_cc put message; assert_code 1
  assert_no_path "$TMP/elsewhere/active/message.md"
}
test_put_does_not_follow_symlinked_target_file() {
  start_task
  echo "바깥 파일" > "$TMP/outside.txt"
  ln -s "$TMP/outside.txt" "$ACTIVE/report.md"
  printf '새 보고\n' | run_cc put report; assert_code 0
  assert_eq "$(cat "$TMP/outside.txt")" "바깥 파일"
  [ ! -L "$ACTIVE/report.md" ] || _fail "report.md 가 아직 심볼릭 링크"
  assert_eq "$(cat "$ACTIVE/report.md")" "새 보고"
}
test_put_verify_refuses_symlinked_verify_dir() {
  start_task
  mkdir -p "$TMP/outdir"
  rm -rf "$ACTIVE/verify"
  ln -s "$TMP/outdir" "$ACTIVE/verify"
  printf 'x\n' | run_cc put verify m1.log; assert_code 1
  assert_eq "$(put_lines "$OUT")" "1"
  assert_no_path "$TMP/outdir/m1.log"
  assert_eq "$(ls -A "$TMP/outdir" | wc -l | tr -d ' ')" "0"
  put_no_temp_left
}
test_put_verify_does_not_write_into_directory_target() {
  start_task
  mkdir "$ACTIVE/verify/m1.log"
  printf 'x\n' | run_cc put verify m1.log; assert_code 1
  assert_eq "$(put_lines "$OUT")" "1"
  [ -d "$ACTIVE/verify/m1.log" ] || _fail "폴더가 사라짐"
  assert_eq "$(ls -A "$ACTIVE/verify/m1.log" | wc -l | tr -d ' ')" "0" "폴더 안에 파일이 생김"
  put_no_temp_left
}
test_put_verify_does_not_follow_symlink_to_directory() {
  start_task
  mkdir -p "$TMP/outdir"
  ln -s "$TMP/outdir" "$ACTIVE/verify/m1.log"
  printf 'x\n' | run_cc put verify m1.log
  assert_code 0
  [ -f "$ACTIVE/verify/m1.log" ] && [ ! -L "$ACTIVE/verify/m1.log" ] || _fail "링크가 일반 파일로 바뀌지 않음"
  assert_eq "$(cat "$ACTIVE/verify/m1.log")" "x"
  assert_eq "$(ls -A "$TMP/outdir" | wc -l | tr -d ' ')" "0" "링크된 바깥 폴더에 파일이 생김"
  put_no_temp_left
}
