import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// .claude/rules/flutter-ui.md のうち、機械で確かめられるものだけを検査する。リテラルは theme.dart にだけ書いてよい
final _rules = {
  '使わない Material の部品': RegExp(
      r'\b(Card|ListTile|AppBar|TabBar|Tab|Chip|ActionChip|ElevatedButton|FilledButton|OutlinedButton|TextButton|IconButton|FloatingActionButton|TextField|Radio|RadioListTile|RadioGroup|AlertDialog|SnackBar|CircularProgressIndicator|LinearProgressIndicator|CircleAvatar|Divider|VerticalDivider)\s*[.(<]'),
  'showDialog・ScaffoldMessenger': RegExp(r'\b(showDialog|ScaffoldMessenger)\b'),
  'lucide 以外のアイコン': RegExp(r'\b(Icons|MoonIcons)\.'),
  'グラデーション・ぼかし': RegExp(r'\b(LinearGradient|RadialGradient|SweepGradient|BackdropFilter|ImageFilter)\b'),
  '絵文字': RegExp(r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]', unicode: true),
  '色のリテラル': RegExp(r'\bColor\(0x|\bColors\.'),
  '数値の余白・角丸・文字サイズ':
      RegExp(r'EdgeInsets(Directional)?\.\w+\([^)]*[1-9]|SizedBox\((width|height): *[1-9]|Radius\.circular\(|fontSize: *\d'),
};

/// 影は付箋（common.dart の StickyNote）にだけ付けてよい
final _shadow = RegExp(r'\bBoxShadow\b');
const _shadowAllowed = 'lib/screens/common.dart';

/// 例外：下のタブバー（狭い画面）だけ、後ろが透けるガラス（ぼかしと色の鮮やかさの BackdropFilter・ImageFilter）を許す
/// （2026-11-09 決定。.claude/rules/flutter-ui.md の構成の節）。グラデーションは許さない
const _blurTrial = 'lib/screens/tab_bar.dart';
final _gradientOnly = RegExp(r'\b(LinearGradient|RadialGradient|SweepGradient)\b');

/// 下のタブバーの影はトークン（theme.dart の tabBarShadow）で持つ。theme.dart は検査の外なので、使ってよいのは tab_bar.dart だけと確かめる
final _tabBarShadow = RegExp(r'\btabBarShadow\b');

/// 1つのファイルの違反。Windows ではパスの区切りが `\` になるので、`/` にそろえてから例外のファイルと比べる
List<String> _violations(String filePath, String source) {
  final path = filePath.replaceAll(r'\', '/');
  if (path == 'lib/theme.dart') return [];
  // コメント中の語は検査しない。行の位置は保つ
  final src = source.replaceAll(RegExp(r'//.*$', multiLine: true), '');
  final rules = {
    ..._rules,
    if (path != _shadowAllowed) '影': _shadow,
    if (path == _blurTrial) 'グラデーション・ぼかし': _gradientOnly,
    if (path != _blurTrial) 'タブバーの影（tab_bar.dart だけ）': _tabBarShadow,
  };
  return [
    for (final MapEntry(key: name, value: re) in rules.entries)
      for (final m in re.allMatches(src)) '$path:${src.substring(0, m.start).split('\n').length} $name: ${m[0]!.split('\n').first}',
  ];
}

void main() {
  test('画面のコードが UI ルールに沿っている', () {
    final violations = [
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')))
        ..._violations(f.path, f.readAsStringSync()),
    ];
    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('パスの区切りが \\ でも（Windows）、例外のファイルを見分ける', () {
    expect(_violations(r'lib\theme.dart', 'Color(0xFF000000)'), isEmpty);
    expect(_violations(r'lib\screens\common.dart', 'BoxShadow('), isEmpty);
    expect(_violations(r'lib\screens\tab_bar.dart', 'BackdropFilter(filter: ImageFilter.blur(), child: tabBarShadow)'), isEmpty);
    expect(_violations(r'lib\screens\home_screen.dart', 'BoxShadow('), ['lib/screens/home_screen.dart:1 影: BoxShadow']);
  });

  // iPhone（WebKit）は 16px 未満の入力欄にフォーカスすると画面を拡大して戻さない（調査17）。
  // 入力欄の文字の大きさを決めるなら、入力欄の文字（k.text.input・inputArea、16px 以上）だけにする。付けなければテーマの既定（16px 以上）になる
  test('入力欄に文字の大きさを付けるなら、入力欄の文字（text.input・inputArea）だけ', () {
    final call = RegExp(r'\b(MoonTextInput|MoonTextArea)\(');
    final violations = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final src = f.readAsStringSync().replaceAll(RegExp(r'//.*$', multiLine: true), '');
      for (final m in call.allMatches(src)) {
        // 呼び出しの引数を、かっこの対応で切り出す
        var depth = 0, i = m.end - 1;
        for (; i < src.length; i++) {
          if (src[i] == '(') depth++;
          if (src[i] == ')' && --depth == 0) break;
        }
        final args = src.substring(m.end, i);
        // 引数のいちばん外側の style:・textStyle: だけを見る（中の Text(style: …) などは入力欄の文字ではない）
        var d = 0;
        for (var j = 0; j < args.length; j++) {
          final ch = args[j];
          if ('([{'.contains(ch)) d++;
          if (')]}'.contains(ch)) d--;
          if (d != 0) continue;
          final named = RegExp(r'^(textStyle|style):\s*([^,\n]+)').firstMatch(args.substring(j));
          if (named != null && (j == 0 || !RegExp(r'\w').hasMatch(args[j - 1])) && !named.group(2)!.contains('.text.input')) {
            violations.add('${f.path}:${src.substring(0, m.start).split('\n').length} ${m[1]} の ${named.group(1)}: ${named.group(2)}');
          }
        }
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  // moon_design の入力欄は、読み上げ用の情報に「使える」が無く、Flutter の Web 版が disabled の欄にする。
  // 読み上げソフトからも打てるよう、common.dart の typable で包む
  test('moon_design の入力欄は、typable で包む', () {
    final call = RegExp(r'\b(MoonTextInput|MoonTextArea)\(');
    final violations = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final src = f.readAsStringSync().replaceAll(RegExp(r'//.*$', multiLine: true), '');
      for (final m in call.allMatches(src)) {
        if (!src.substring(0, m.start).endsWith('typable(')) violations.add('${f.path}: ${m[0]}');
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });
}
