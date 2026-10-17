# render.sh - 프롬프트 템플릿 치환 (source 전용, bash 3.2 호환)

# cc_render <template_path> <out_path>
# 템플릿의 {{NAME}} 을 환경변수 CC_T_NAME 값으로 바꾼다. 값은 글자 그대로 쓴다.
# 정의되지 않은 자리표시자가 있으면 out 파일을 만들지 않고 1 을 돌려준다.
cc_render() {
  local tpl="$1" out="$2" tmp
  [ -f "$tpl" ] || { cc_err "템플릿 없음: $tpl" 2>/dev/null || echo "템플릿 없음: $tpl" >&2; return 1; }
  tmp="$out.tmp.$$"
  if ! perl -0777 -e '
      binmode(STDIN); binmode(STDOUT);
      local $/; my $t = <STDIN>; my @miss;
      $t =~ s/\{\{(\w+)\}\}/ exists $ENV{"CC_T_$1"} ? $ENV{"CC_T_$1"} : do { push @miss, $1; "" } /ge;
      if (@miss) { print STDERR "치환값 없음: ", join(",", @miss), "\n"; exit 1 }
      print $t;
    ' < "$tpl" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$out" || { rm -f "$tmp"; return 1; }
}
