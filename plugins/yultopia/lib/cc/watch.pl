#!/usr/bin/perl
# watch.pl - /cc 의 Codex 수정 감시 도우미 (2026-10-18 보안 수정 R33/R34). snapshot.sh 가 부른다.
#   파일을 직접 읽는다. git 을 부르는 것은 gitcfg-record 의 include 읽기뿐이다 (Codex 실행 전, 믿을 수 있을 때만).
#   내용은 해시만 계산하고 어디에도(객체 저장소 포함) 쓰지 않는다.
#
#   ignored-manifest <sha1|sha256> <patterns> <out> <exclude> (<앞부분> <저장소 폴더> <목록 파일|->)...
#       <exclude>(공백 구분, "a/b/" = 경로 중간에 이어진 폴더 이름 a, b. 어느 깊이든) 아래의 경로는 먼저 뺀다.
#       목록 파일: 그 저장소에서 `git ls-files -z -o -i --exclude-standard`. 경로는 <앞부분>(하위 모듈이면 "sub/")을 붙여 하나로 모은다.
#       목록이 "-" 면 믿을 수 없게 된 하위 모듈: 그 안을 보지 않고 <앞부분> 경로 하나를 "160000 untrusted-submodule" 로 둔다.
#       감시 대상만 골라 <out> 에
#       "경로<TAB>모드 해시" 를 NUL 로 끝내 경로순으로 쓰고, <out> 내용의 sha1 을 stdout 에 한 줄로.
#       감시 대상: <patterns>(공백 구분) 중 "/" 로 끝나지 않는 것은 경로의 마지막 이름에, "/" 로 끝나는 것(의존성 폴더)은
#       경로 중간의 폴더 이름에 맞춘다 (깊이 상관없음. * 와 ? 는 / 를 넘지 않는다).
#       해시는 git 과 같은 blob id (git hash-object --no-filters 와 같은 값). 심볼릭 링크는 따라가지 않고 링크 대상 문자열의
#       blob id (모드 120000). git 이 "경로/" 로 내는 중첩 저장소는 안을 보지 않고 "160000 repo". 읽을 수 없으면 "<모드> unreadable".
#       목록을 만든 뒤 사라진 파일은 넣지 않는다.
#   ignored-diff <pre> <pre-sha1> <post>
#       <pre> 내용의 sha1 이 <pre-sha1> 과 다르면(기록과 다른 파일) 2. 같으면 두 manifest 를 비교해 더해지거나 없어지거나
#       바뀐 경로가 있으면 {"total":N,"shown":[처음 10개]} 한 줄, 없으면 빈 출력. 0
#   gitcfg-record <top> <gitdir> <commondir>
#       git 설정 지문 JSON 한 줄: {"v":1,"top","gitdir","common","files":{경로: 값}}. 대상:
#       <top>/.git 자체(폴더면 장치·inode, 파일이면 내용, 링크면 대상), commondir/config, (common)dir/config.worktree,
#       info/attributes, info/exclude, <gitdir>/modules 바로 아래 폴더들과 그 아래 모든 하위 모듈 git 디렉터리(HEAD 가 있는 폴더)의
#       config·config.worktree·info/attributes·info/exclude, 그리고 이 설정 파일들의 include.path / includeIf.*.path 대상
#       (git config --file 로 읽고, 대상 안의 include 도 따라간다. 없는 대상도 "없음" 으로 남긴다: 나중에 생기면 바뀐 것)
#   gitcfg-verify
#       stdin: gitcfg-record 의 JSON. git 을 부르지 않고 기록된 파일과 지금 다시 찾은 하위 모듈 git 디렉터리를 다시 계산한다.
#       같으면 0 (출력 없음), 다르면 1 과 {"total":N,"shown":[처음 10개]} (저장소 안이면 저장소 기준 경로), 입력 오류 2
use strict;
use warnings;
BEGIN { @INC = grep { defined && $_ ne '.' } @INC }
use Digest::SHA;
use JSON::PP;
use Cwd ();
use Fcntl qw(O_RDONLY O_NONBLOCK);

my $mode = shift @ARGV // '';

sub sanitize { my $s = shift; $s =~ s/[\x00-\x1f\x7f]/?/g; return $s }
sub summary {
  my ($list) = @_;
  my @shown = map { sanitize($_) } @$list[0 .. ($#$list < 9 ? $#$list : 9)];
  return JSON::PP->new->canonical(1)->encode({ total => scalar(@$list), shown => \@shown });
}
# open_regular <경로> : 일반 파일일 때만 읽기 핸들 (FIFO·장치 등은 열면서 막히지 않게 O_NONBLOCK 으로 열고 핸들로 다시 확인)
sub open_regular {
  my $p = shift;
  sysopen(my $fh, $p, O_RDONLY | O_NONBLOCK) or return undef;
  return undef unless -f $fh;
  binmode $fh;
  return $fh;
}
sub file_sha1 {
  my $p = shift;
  my $fh = open_regular($p) or return undef;
  my $d = Digest::SHA->new(1);
  $d->addfile($fh);
  return $d->hexdigest;
}

# ---- ignored-manifest / ignored-diff ----
sub glob_re {
  my $g = shift;
  my $re = join '', map { $_ eq '*' ? '[^/]*' : $_ eq '?' ? '[^/]' : quotemeta($_) } split /([*?])/, $g;
  return qr/\A$re\z/s;
}
sub blob_id {   # <alg> <bytes>
  my ($alg, $data) = @_;
  my $d = Digest::SHA->new($alg);
  $d->add('blob ' . length($data) . "\0");
  $d->add($data);
  return $d->hexdigest;
}
sub file_blob_id {   # <alg> <path> : 파일 내용의 blob id (undef = 읽을 수 없음)
  my ($alg, $p) = @_;
  my $fh = open_regular($p) or return undef;
  my $size = (stat($fh))[7];
  defined $size or return undef;
  my $d = Digest::SHA->new($alg);
  $d->add("blob $size\0");
  $d->addfile($fh);
  return $d->hexdigest;
}
sub read_manifest {
  my $p = shift;
  my $fh = open_regular($p) or return undef;
  local $/ = "\0";
  my %m;
  while (my $r = <$fh>) {
    chomp $r;
    next if $r eq '';
    my $i = rindex($r, "\t");
    return undef if $i < 0;
    $m{substr($r, 0, $i)} = substr($r, $i + 1);
  }
  return \%m;
}

if ($mode eq 'ignored-manifest') {
  my ($fmt, $patterns, $out, $exclude, @triples) = @ARGV;
  defined $out && @triples && @triples % 3 == 0 or exit 2;
  my $alg = ($fmt // '') eq 'sha256' ? 256 : 1;
  my (@name_re, @dir_re, @excl);
  for my $p (split ' ', $patterns // '') {
    if ($p =~ s{/\z}{}) { push @dir_re, glob_re($p) } else { push @name_re, glob_re($p) }
  }
  # 뺄 폴더: "a/b/" = 경로 중간에 이어진 폴더 이름 a, b (어느 깊이든). 그 아래는 감시하지 않는다
  for my $p (split ' ', $exclude // '') {
    $p =~ s{/\z}{};
    push @excl, [map { glob_re($_) } split m{/}, $p] if $p ne '';
  }
  my %m;
  # 저장소마다 (앞부분, 폴더, 목록 파일). 목록이 "-" 면 믿을 수 없게 된 하위 모듈: 그 안을 보지 않고 경로 하나로 둔다
  while (@triples) {
   my ($prefix, $dir, $list) = splice(@triples, 0, 3);
   if ($list eq '-') { (my $k = $prefix) =~ s{/\z}{}; $m{$k} = '160000 untrusted-submodule'; next }
   chdir($dir) or exit 1;
   open(my $in, '<', $list) or exit 1;
   binmode $in;
   local $/ = "\0";
   while (my $path = <$in>) {
    chomp $path;
    next if $path eq '';
    my $repo = ($path =~ s{/\z}{});
    my @parts = split m{/}, $prefix . $path, -1;
    my $base = pop @parts;
    my @dirs = $repo ? (@parts, $base) : @parts;
    my $skip = 0;
    EXCL: for my $e (@excl) {
      my $k = scalar @$e;
      for my $i (0 .. $#dirs - $k + 1) {
        my $ok = 1;
        for my $j (0 .. $k - 1) { if ($dirs[$i + $j] !~ $e->[$j]) { $ok = 0; last } }
        if ($ok) { $skip = 1; last EXCL }
      }
    }
    next if $skip;
    my $hit = 0;
    DIRS: for my $c (@parts) { for my $re (@dir_re) { if ($c =~ $re) { $hit = 1; last DIRS } } }
    if (!$hit) { for my $re (@name_re) { if ($base =~ $re) { $hit = 1; last } } }
    if (!$hit && $repo) { for my $re (@dir_re) { if ($base =~ $re) { $hit = 1; last } } }
    next unless $hit;
    my $tok;
    if ($repo) {
      next unless -d $path;
      $tok = '160000 repo';
    } elsif (-l $path) {
      my $t = readlink($path);
      $tok = defined $t ? '120000 ' . blob_id($alg, $t) : '120000 unreadable';
    } elsif (-f _) {
      my $m = ((stat(_))[2] & 0100) ? '100755' : '100644';
      my $h = file_blob_id($alg, $path);
      $tok = "$m " . (defined $h ? $h : 'unreadable');
    } elsif (-e _) {
      $tok = 'other';
    } else {
      next;    # 목록을 만든 뒤 사라졌다
    }
    $m{$prefix . $path} = $tok;
   }
   close $in;
  }
  my $tmp = "$out.tmp.$$";
  open(my $o, '>', $tmp) or exit 1;
  binmode $o;
  print {$o} "$_\t$m{$_}\0" for sort keys %m;
  close($o) or do { unlink $tmp; exit 1 };
  rename($tmp, $out) or do { unlink $tmp; exit 1 };
  my $sum = file_sha1($out);
  defined $sum or exit 1;
  print "$sum\n";
  exit 0;
}

if ($mode eq 'ignored-diff') {
  my ($pre, $sum, $post) = @ARGV;
  defined $post or exit 2;
  my $have = file_sha1($pre);
  exit 2 unless defined $have && $have eq ($sum // '');
  my $ma = read_manifest($pre) or exit 2;
  my $mb = read_manifest($post) or exit 2;
  my %all = (%$ma, %$mb);
  my @changed = grep { !exists $ma->{$_} || !exists $mb->{$_} || $ma->{$_} ne $mb->{$_} } sort keys %all;
  print summary(\@changed), "\n" if @changed;
  exit 0;
}

# ---- gitcfg-record / gitcfg-verify ----
sub tok {   # 설정 파일·폴더의 지금 값 (링크는 대상과 따라간 내용)
  my $p = shift;
  my $pre = '';
  if (-l $p) { my $t = readlink($p); $pre = 'l:' . (defined $t ? $t : '?') . ':' }
  return $pre . '-' unless -e $p;
  return $pre . 'd' if -d _;
  return $pre . 'special' unless -f _;
  my $h = file_sha1($p);
  return $pre . (defined $h ? "f:$h" : 'unreadable');
}
sub dotgit_tok {   # 작업 트리 루트의 .git 자체: 바꿔치기(다른 폴더·파일·링크)를 알아보도록
  my $p = shift;
  return 'l:' . (readlink($p) // '?') if -l $p;
  return '-' unless -e $p;
  if (-d _) { my @s = stat(_); return "d:$s[0]:$s[1]" }
  return 'special' unless -f _;
  my $h = file_sha1($p);
  return defined $h ? "f:$h" : 'unreadable';
}
# scan_modules 가 깊이·개수 제한에 닿았거나 폴더를 읽지 못했다 (조용히 넘기지 않고 확인 실패로 본다: Codex 보안 검수 1차 2)
my $SCAN_ERROR = 0;
my $SCAN_COUNT = 0;
sub scan_modules {   # <gitdir>/modules : (설정 파일들, 그 밖의 파일들, 폴더들)
  my $root = shift;
  my (@cfg, @plain, @dirs);
  my $walk;
  $walk = sub {
    my ($d, $depth) = @_;
    return if -l $d || !-d $d;
    if ($depth > 12 || ++$SCAN_COUNT > 5000) { $SCAN_ERROR = 1; return }
    my $dh;
    unless (opendir($dh, $d)) { $SCAN_ERROR = 1; return }
    my @names = sort grep { $_ ne '.' && $_ ne '..' } readdir($dh);
    closedir $dh;
    for my $n (@names) {
      my $c = "$d/$n";
      if (-l $c) { push @dirs, $c; next }    # 링크는 따라가지 않고 그 자체를 기록한다 (값은 tok: 링크 대상 포함)
      next unless -d $c;
      if (-e "$c/HEAD") {
        push @dirs, $c;
        push @cfg, "$c/config", "$c/config.worktree";
        push @plain, "$c/info/attributes", "$c/info/exclude";
        $walk->("$c/modules", $depth + 1);
      } else {
        $walk->($c, $depth + 1);
      }
    }
  };
  if (-d $root && !-l $root) {
    if (opendir(my $dh, $root)) {
      push @dirs, map { "$root/$_" } grep { $_ ne '.' && $_ ne '..' && -d "$root/$_" } sort readdir($dh);
      closedir $dh;
    } else {
      $SCAN_ERROR = 1;
    }
    $walk->($root, 0);
  }
  return (\@cfg, \@plain, \@dirs);
}
sub norm_join {   # include 대상 경로 (상대 경로는 그 설정 파일의 폴더 기준, ~/ 는 HOME)
  my ($v, $cfgfile) = @_;
  my $p;
  if ($v =~ m{\A~/}) { $p = ($ENV{HOME} // '') . substr($v, 1) }
  elsif ($v =~ m{\A/}) { $p = $v }
  else { (my $dir = $cfgfile) =~ s{/[^/]*\z}{}; $p = "$dir/$v" }
  (my $dir = $p) =~ s{/[^/]*\z}{};
  (my $base = $p) =~ s{\A.*/}{};
  if ($dir ne '' && -d $dir) { my $r = Cwd::abs_path($dir); return "$r/$base" if defined $r }
  return $p;
}
sub includes_of {   # <설정 파일> : include.path / includeIf.*.path 값들 (git config --file, 실행 전에만)
  my $c = shift;
  my @out;
  open(my $fh, '-|', 'git', 'config', '--no-includes', '--file', $c, '-z', '--get-regexp', '^include(if\..*)?\.path$')
    or return ();
  binmode $fh;
  local $/ = "\0";
  while (my $r = <$fh>) {
    chomp $r;
    my $i = index($r, "\n");
    next if $i < 0;
    my $v = substr($r, $i + 1);
    push @out, norm_join($v, $c) if $v ne '';
  }
  close $fh;
  return @out;
}
sub uniq { my %s; return grep { !$s{$_}++ } @_ }
sub display {
  my ($p, $top) = @_;
  return substr($p, length($top) + 1) if index($p, "$top/") == 0;
  return $p;
}

if ($mode eq 'gitcfg-record') {
  my ($top, $gd, $cd) = @ARGV;
  defined $cd && $top ne '' && $gd ne '' && $cd ne '' or exit 2;
  my %f;
  my @cfg = uniq("$cd/config", "$gd/config.worktree", "$cd/config.worktree");
  my @plain = uniq("$gd/info/attributes", "$cd/info/attributes", "$gd/info/exclude", "$cd/info/exclude");
  my ($mcfg, $mplain, $mdirs) = scan_modules("$gd/modules");
  push @cfg, @$mcfg;
  exit 2 if $SCAN_ERROR;
  push @plain, @$mplain;
  $f{$_} = tok($_) for @plain, @$mdirs;
  my %seen;
  my @queue = @cfg;
  my $n = 0;
  while (@queue && $n++ < 1000) {
    my $c = shift @queue;
    next if $seen{$c}++;
    $f{$c} = tok($c);
    push @queue, includes_of($c) if -f $c;
  }
  $f{"$top/.git"} = dotgit_tok("$top/.git");
  print JSON::PP->new->canonical(1)->encode({ v => 1, top => $top, gitdir => $gd, common => $cd, files => \%f }), "\n";
  exit 0;
}

if ($mode eq 'gitcfg-verify') {
  local $/;
  binmode STDIN;
  my $in = <STDIN>;
  my $fp = eval { JSON::PP->new->decode($in // '') };
  exit 2 unless ref($fp) eq 'HASH' && ref($fp->{files}) eq 'HASH';
  # 경로는 바이트 문자열로 기록했다. decode 결과는 내부 표현이 UTF-8 일 수 있어 그대로 파일 이름으로 쓰면 한글 경로를 찾지
  #   못한다: 바이트 문자열로 되돌린다 (되돌릴 수 없으면 기록이 이상한 것)
  my $bytes = sub { my $s = shift; return undef if !defined $s || ref $s; return utf8::downgrade($s, 1) ? $s : undef };
  my ($top, $gd) = ($bytes->($fp->{top}), $bytes->($fp->{gitdir}));
  exit 2 unless defined $top && defined $gd && $top ne '' && $gd ne '';
  my %stored;
  for my $k (keys %{ $fp->{files} }) {
    my ($bk, $bv) = ($bytes->($k), $bytes->($fp->{files}{$k}));
    exit 2 unless defined $bk && defined $bv;
    $stored{$bk} = $bv;
  }
  my %cur;
  for my $k (keys %stored) { $cur{$k} = ($k eq "$top/.git") ? dotgit_tok($k) : tok($k) }
  my ($mcfg, $mplain, $mdirs) = scan_modules("$gd/modules");
  exit 2 if $SCAN_ERROR;
  for my $k (@$mcfg, @$mplain, @$mdirs) { $cur{$k} = tok($k) unless exists $cur{$k} }
  my %all = (%stored, %cur);
  my @changed = grep { !exists $stored{$_} || !defined $stored{$_} || ref($stored{$_}) || $stored{$_} ne $cur{$_} } sort keys %all;
  exit 0 unless @changed;
  print summary([map { display($_, $top) } @changed]), "\n";
  exit 1;
}

# ---- 외부 격리 기록 (Codex 보안 검수 2차, R36) ----
#   qkey <경로> : 경로 문자열의 sha256 (기록 파일 이름)
#   qfind <기록 폴더> <시작 폴더> : 시작 폴더와 그 위 폴더마다 <기록 폴더>/<sha256>.json 이 있는지 본다.
#       찾으면 0 과 "기록 파일\n그 폴더" (가장 가까운 것), 없으면 1, 기록 폴더를 읽을 수 없으면 2
if ($mode eq 'qkey') {
  my $p = shift @ARGV;
  defined $p && $p ne '' or exit 2;
  print Digest::SHA::sha256_hex($p), "\n";
  exit 0;
}
if ($mode eq 'qfind') {
  my ($qdir, $d) = @ARGV;
  defined $d && $d =~ m{\A/} or exit 2;
  exit 2 unless -d $qdir && -r _ && -x _;
  while (1) {
    my $f = "$qdir/" . Digest::SHA::sha256_hex($d) . ".json";
    if (-e $f || -l $f) { print "$f\n$d"; exit 0 }
    last if $d eq '/';
    $d =~ s{/[^/]*\z}{};
    $d = '/' if $d eq '';
  }
  exit 1;
}

exit 2;
