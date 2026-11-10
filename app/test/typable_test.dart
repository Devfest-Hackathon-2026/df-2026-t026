import 'dart:ui' show Tristate;

import 'package:diff_note/screens/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moon_design/moon_design.dart';

void main() {
  // Flutter の Web 版は、読み上げ用の情報に「使える」が無い入力欄を disabled にし、読み上げソフトから打てなくする
  testWidgets('typable で包んだ moon_design の入力欄は、読み上げ用の情報で「使える」になる', (tester) async {
    final semantics = tester.ensureSemantics();
    for (final input in [MoonTextInput(controller: TextEditingController()), MoonTextArea(controller: TextEditingController())]) {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(extensions: [MoonTheme(tokens: MoonTokens.light)]),
        home: Scaffold(body: typable(input)),
      ));
      final flags = tester.getSemantics(find.byType(EditableText)).getSemanticsData().flagsCollection;
      expect(flags.isTextField, isTrue);
      expect(flags.isEnabled, Tristate.isTrue);
    }
    semantics.dispose();
  });
}
