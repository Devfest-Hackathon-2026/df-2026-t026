import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// .claude/rules/flutter-ui.md のうち、機械で確かめられるものだけを検査する。リテラルは theme.dart にだけ書いてよい
final _rules = {
  '使わない Material の部品': RegExp(
      r'\b(Card|ListTile|AppBar|TabBar|Tab|Chip|ActionChip|ElevatedButton|FilledButton|OutlinedButton|TextButton|IconButton|FloatingActionButton|TextField|Radio|RadioListTile|RadioGroup|AlertDialog|SnackBar|CircularProgressIndicator|LinearProgressIndicator|CircleAvatar|Divider|VerticalDivider)\s*[.(<]'),
  'showDialog・ScaffoldMessenger': RegExp(r'\b(showDialog|ScaffoldMessenger)\b'),
  'lucide 以外のアイコン': RegExp(r'\b(Icons|MoonIcons)\.'),
  // ポップ方針（design/pop-ui）で、影・グラデーション・ぼかしは「ポップな部品」に限って解禁した
  '色のリテラル': RegExp(r'\bColor\(0x|\bColors\.'),
  '数値の余白・角丸・文字サイズ':
      RegExp(r'EdgeInsets(Directional)?\.\w+\([^)]*[1-9]|SizedBox\((width|height): *[1-9]|Radius\.circular\(|fontSize: *\d'),
};

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
      for (final MapEntry(key: name, value: re) in _rules.entries) {
        for (final m in re.allMatches(src)) {
          final line = src.substring(0, m.start).split('\n').length;
          violations.add('${f.path}:$line $name: ${m[0]!.split('\n').first}');
        }
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });
}
