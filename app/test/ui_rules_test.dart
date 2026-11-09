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

/// 試作の例外：下のタブバーの後ろのぼかしが、スマホで重くないかを見るためだけに、このファイルでぼかしを許す
/// （グラデーションは許さない）。採らないと決めたら、この例外ごと消す
const _blurTrial = 'lib/screens/tab_bar.dart';
final _gradientOnly = RegExp(r'\b(LinearGradient|RadialGradient|SweepGradient)\b');

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
      final rules = {
        ..._rules,
        if (f.path != _shadowAllowed) '影': _shadow,
        if (f.path == _blurTrial) 'グラデーション・ぼかし': _gradientOnly,
      };
      for (final MapEntry(key: name, value: re) in rules.entries) {
        for (final m in re.allMatches(src)) {
          final line = src.substring(0, m.start).split('\n').length;
          violations.add('${f.path}:$line $name: ${m[0]!.split('\n').first}');
        }
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });
}
