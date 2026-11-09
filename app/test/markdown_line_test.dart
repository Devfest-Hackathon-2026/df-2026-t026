import 'package:diff_note/screens/common.dart';
import 'package:diff_note/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _k = appTheme().extension<AppTokens>()!;

Future<RichText> _pump(WidgetTester tester, String line) async {
  await tester.pumpWidget(MaterialApp(theme: appTheme(), home: Scaffold(body: LineText(line))));
  return tester.widget<RichText>(find.byType(RichText));
}

/// 行全体の文字スタイル（Text.rich が既定の文字スタイルで包んだ内側）
TextStyle? _lineStyle(RichText r) => (r.text as TextSpan).children!.single.style;

/// text の部分の文字スタイル（親から受け継ぐ分は含めない）
TextStyle? _styleOf(RichText r, String text) {
  TextStyle? found;
  r.text.visitChildren((s) {
    if (s is TextSpan && s.text == text) found = s.style;
    return found == null;
  });
  return found;
}

void main() {
  test('文の中に出す形は、行頭と行の中のマークダウンの印を外す', () {
    expect(plain('## 味噌汁'), '味噌汁');
    expect(plain('### 仕込み'), '仕込み');
    expect(plain('- **塩** 小さじ1'), '塩 小さじ1');
    expect(plain('  * `250g` まで'), '250g まで');
    expect(plain('1. [手順書](https://example.com)を見る'), '手順書を見る');
    expect(plain('> 火を止めてから ~~溶く~~'), '火を止めてから 溶く');
    expect(plain('温度 < 60度 & "強火"'), '温度 < 60度 & "強火"');
    expect(plain('- だしは昆布\n- **塩** 小さじ1'), 'だしは昆布\n塩 小さじ1');
  });

  test('見出しは「# 」〜「###### 」だけで、空白のない「#」は本文', () {
    expect(isHeading('# 店'), isTrue);
    expect(isHeading('###### 細目'), isTrue);
    expect(isHeading('#3番テーブルは予約席'), isFalse);
    expect(isRule('---'), isTrue);
    expect(isRule('* * *'), isTrue);
    expect(isRule('- 塩'), isFalse);
  });

  testWidgets('見出しは # の数で大きさを変える', (tester) async {
    expect(_lineStyle(await _pump(tester, '# 店'))!.fontSize, _k.text.display.fontSize);
    expect(_lineStyle(await _pump(tester, '## 味噌汁'))!.fontSize, _k.text.title.fontSize);
    final h3 = await _pump(tester, '### 仕込み');
    expect(_lineStyle(h3)!.fontSize, _k.text.heading.fontSize);
    expect(h3.text.toPlainText(), '仕込み');
  });

  testWidgets('箇条書きは「・」、番号はそのまま、行の中の太字・リンクは文字の形で示す', (tester) async {
    final bullet = await _pump(tester, '- **塩** 小さじ1');
    expect(bullet.text.toPlainText(), '・塩 小さじ1');
    expect(_styleOf(bullet, '塩')!.fontWeight, FontWeight.w700);

    expect((await _pump(tester, '1. 手を洗う')).text.toPlainText(), '1. 手を洗う');

    final link = await _pump(tester, '[手順書](https://example.com)を見る');
    expect(link.text.toPlainText(), '手順書を見る');
    expect(_styleOf(link, '手順書')!.color, _k.colors.action);
  });

  testWidgets('字下げした項目は入れ子として下げ、区切り線は罫線にする', (tester) async {
    await _pump(tester, '  - 粗塩でもよい');
    final pad = tester.widget<Padding>(find.ancestor(of: find.byType(RichText), matching: find.byType(Padding)).first);
    expect(pad.padding, EdgeInsets.only(left: _k.space.lg));

    await tester.pumpWidget(MaterialApp(theme: appTheme(), home: const Scaffold(body: LineText('---'))));
    expect(find.byType(RichText), findsNothing);
  });

  testWidgets('表のように複数行にまたがる書き方は、記号のまま出す', (tester) async {
    expect((await _pump(tester, '| 品 | 量 |')).text.toPlainText(), '| 品 | 量 |');
  });
}
