import 'package:diff_note/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moon_design/moon_design.dart';

import 'input_font.dart';

// 入力欄の文字は 16px 以上（iPhone の自動拡大を防ぐ。調査17）。
// 画面ごとの入力欄は、各画面のテストで expectInputFontsAtLeast16 を呼んで確かめている。ここでは既定と日付の入力を見る

void main() {
  testWidgets('入力欄の文字のトークンと、Moon の入力欄の既定（textStyle を付けないとき）が 16px 以上', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
        theme: appTheme(),
        home: Builder(builder: (c) {
          ctx = c;
          return const SizedBox.shrink();
        })));
    final k = ctx.tokens;
    expect(k.text.input.fontSize, greaterThanOrEqualTo(16));
    expect(k.text.inputArea.fontSize, greaterThanOrEqualTo(16));
    final moon = Theme.of(ctx).extension<MoonTheme>()!;
    final sizes = moon.textInputTheme.sizes;
    for (final (name, s) in [('sm', sizes.sm), ('md', sizes.md), ('lg', sizes.lg), ('xl', sizes.xl)]) {
      expect(s.textStyle.fontSize, greaterThanOrEqualTo(16), reason: 'MoonTextInput $name');
    }
    expect(moon.textAreaTheme.properties.textStyle.fontSize, greaterThanOrEqualTo(16), reason: 'MoonTextArea');
  });

  testWidgets('textStyle を付けない MoonTextInput・MoonTextArea も、実際に 16px 以上で出る', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(),
      home: Scaffold(
        body: Column(children: [
          for (final size in MoonTextInputSize.values) MoonTextInput(textInputSize: size, hintText: '$size'),
          const MoonTextArea(height: 100),
        ]),
      ),
    ));
    expectInputFontsAtLeast16(tester, count: MoonTextInputSize.values.length + 1);
  });

  testWidgets('日付を選ぶダイアログで、日付を打ち込む欄も 16px 以上', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: GestureDetector(
            onTap: () => showDatePicker(
              context: context,
              initialDate: DateTime(2026, 11, 9),
              firstDate: DateTime(2020),
              lastDate: DateTime(2026, 12, 31),
              initialEntryMode: DatePickerEntryMode.input,
            ),
            child: const Text('日付'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('日付'));
    await tester.pumpAndSettle();
    expectInputFontsAtLeast16(tester, count: 1);
  });
}
