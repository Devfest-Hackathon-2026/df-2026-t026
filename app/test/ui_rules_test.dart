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

void main() {
  test('画面のコードが UI ルールに沿っている', () {
    final violations = <String>[];
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart') && f.path != 'lib/theme.dart');
    for (final f in files) {
      // コメント中の語は検査しない。行の位置は保つ
      final src = f.readAsStringSync().replaceAll(RegExp(r'//.*$', multiLine: true), '');
      final rules = {..._rules, if (f.path != _shadowAllowed) '影': _shadow};
      for (final MapEntry(key: name, value: re) in rules.entries) {
        for (final m in re.allMatches(src)) {
          final line = src.substring(0, m.start).split('\n').length;
          violations.add('${f.path}:$line $name: ${m[0]!.split('\n').first}');
        }
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  // iPhone（WebKit）は 16px 未満の入力欄にフォーカスすると画面を拡大して戻さない（調査17）。
  // 入力欄の文字の大きさを決めるなら、入力欄の文字（k.text.input、16px 以上）だけにする。付けなければテーマの既定（16px 以上）になる
  test('入力欄に文字の大きさを付けるなら、入力欄の文字（text.input）だけ', () {
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
        final style = RegExp(r'\btextStyle:\s*([^,\n]+)').firstMatch(args)?.group(1);
        if (style != null && !style.contains('.text.input')) {
          violations.add('${f.path}:${src.substring(0, m.start).split('\n').length} ${m[1]} の textStyle: $style');
        }
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });
}
