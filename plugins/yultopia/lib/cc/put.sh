# put.sh - cc-codex.sh put <brief|report|message> / put verify <파일이름> (Ruling R25). source 전용 (bash 3.2 호환).
#   common.sh, state.sh 뒤에 불러온다.
#
# 왜: 상태 폴더는 <git-dir>/yultopia-cc/active 라서 Claude Code 가 Write/Edit 도구로 쓰지 못한다(.git 은 보호 경로).
#   SKILL 은 정리본·보고·메시지를 heredoc 으로, 검증 출력은 파이프로 이 명령의 stdin 에 넘긴다.
#   임의 명령을 대신 실행하는 기능은 두지 않는다 (allowed-tools 를 좁게 유지).
#
# 쓰는 방법
#   - active 경로 안전 검사(cc_active_path_safe)를 통과해야 한다. active 가 없으면 5 (status 와 같음).
#   - stdin 을 active 안 임시 파일(mktemp: 새로 만들고 기존 파일·링크를 따라가지 않음)에 받고, 비어 있으면 저장하지 않는다(1).
#   - rename(2) 으로 제자리에 놓는다 (원자적. 읽는 쪽은 옛 내용이나 새 내용 중 하나만 본다).
#     rename 은 대상이 심볼릭 링크면 링크 자체를 바꾸고 따라가지 않으며, 대상이 폴더면 실패한다.
#     그래서 active 밖이나 폴더 안으로 쓰는 일이 없다. mv 는 폴더(또는 폴더를 가리키는 링크) 안으로 옮기므로 쓰지 않는다.
#   - verify 파일 이름은 ^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$ 만 (슬래시·..·공백·한글·줄바꿈 없음).
#     verify 폴더가 심볼릭 링크이거나 폴더가 아니면 거부한다. 없으면 만든다.
#   - 성공하면 "[cc] <이름> 저장됨" 한 줄. verify 는 마지막 줄이 exit=<숫자> 이면 " (exit=<숫자>)" 를 붙인다
#     (검증 명령의 종료 코드를 Claude 가 출력 원문을 다시 읽지 않고 알 수 있도록).
#   - 오류는 한 줄 (Ruling R7). 입력 이름은 줄에 넣지 않는다 (줄바꿈이 섞인 이름도 한 줄로 끝나도록).

_CC_PUT_TMP=""

_cc_put_cleanup() {
  [ -n "$_CC_PUT_TMP" ] && rm -f "$_CC_PUT_TMP"
  _CC_PUT_TMP=""
}

# 0 = verify 에 쓸 수 있는 파일 이름. perl 정규식은 로캘과 상관없이 ASCII 범위로 본다 (\z: 끝 줄바꿈도 허용 안 함)
_cc_put_valid_name() {
  perl -e 'exit($ARGV[0] =~ /\A[A-Za-z0-9][A-Za-z0-9._-]{0,99}\z/ ? 0 : 1)' -- "$1"
}

# cc-codex.sh put <brief|report|message>  /  put verify <파일이름>   (내용은 stdin)
cc_cmd_put() {
  local kind="${1:-}" rel label a target last suffix=""
  case "$kind:$#" in
    brief:1|report:1|message:1)
      rel="$kind.md"; label=$kind ;;
    verify:2)
      _cc_put_valid_name "$2" || {
        cc_line "[cc] 검증 출력 파일 이름이 올바르지 않습니다 (영문·숫자로 시작, 영문·숫자와 . _ - 만, 100자 이하)."
        return 1
      }
      rel="verify/$2"; label="verify/$2" ;;
    *)
      cc_line "[cc] 사용법: put <brief|report|message> 또는 put verify <파일이름> (내용은 stdin 으로)"
      return 1 ;;
  esac
  cc_active_exists || { cc_line "[cc] 진행 중인 작업이 없습니다."; return 5; }
  cc_active_path_safe || { cc_line "[cc] 상태 폴더 경로가 비정상입니다."; return 1; }
  a=$(cc_active_dir) || { cc_line "[cc] git 저장소가 아닙니다."; return 1; }
  if [ "$kind" = verify ]; then
    if [ ! -e "$a/verify" ] && [ ! -L "$a/verify" ]; then
      mkdir "$a/verify" 2>/dev/null || { cc_line "[cc] 검증 출력 폴더를 만들지 못했습니다."; return 1; }
    fi
    if [ -L "$a/verify" ] || [ ! -d "$a/verify" ]; then
      cc_line "[cc] 검증 출력 폴더 경로가 비정상입니다."
      return 1
    fi
  fi
  target="$a/$rel"
  trap '_cc_put_cleanup' EXIT
  _CC_PUT_TMP=$(mktemp "$a/.put.XXXXXX" 2>/dev/null) || {
    _CC_PUT_TMP=""; cc_line "[cc] 임시 파일을 만들지 못했습니다."; return 1; }
  if ! cat > "$_CC_PUT_TMP"; then
    _cc_put_cleanup; cc_line "[cc] 입력을 받지 못해 저장하지 않았습니다."; return 1
  fi
  if [ ! -s "$_CC_PUT_TMP" ]; then
    _cc_put_cleanup; cc_line "[cc] 내용이 비어 있어 저장하지 않았습니다."; return 1
  fi
  if [ "$kind" = verify ]; then
    last=$(tail -n 1 "$_CC_PUT_TMP" 2>/dev/null)
    case "$last" in
      exit=|exit=*[!0-9]*) ;;
      exit=*) suffix=" ($last)" ;;
    esac
  fi
  if ! perl -e 'rename($ARGV[0], $ARGV[1]) or exit 1' -- "$_CC_PUT_TMP" "$target" 2>/dev/null; then
    _cc_put_cleanup; cc_line "[cc] $label 을(를) 저장하지 못했습니다."; return 1
  fi
  _CC_PUT_TMP=""
  cc_line "[cc] $label 저장됨$suffix"
}
