import 'package:diff_note/api.dart';
import 'package:diff_note/screens/new_manual_screen.dart';
import 'package:diff_note/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moon_design/moon_design.dart';

// moon_design 1.1.0 の MoonTextArea は、expands を付けると文字を欄の縦の真ん中に置く。
// 文字・カーソルが欄の上（余白の分だけ下）から始まり、書いても下へずれないことを確かめる

void main() {
  for (final size in const [Size(390, 844), Size(1440, 900)]) {
    testWidgets('ノートを作る：最初の本文の欄は、空のときも書いたあとも左上から始まる（$size）', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: appTheme(),
        home: NewManualScreen(api: Api(client: MockClient((_) async => http.Response('[]', 200)), baseUrl: 'http://api')),
      ));
      await tester.pumpAndSettle();

      final area = find.byType(MoonTextArea);
      final field = find.descendant(of: area, matching: find.byType(EditableText));
      final box = tester.getRect(area);
      // 余白（既定の 16）の分だけ下。真ん中なら 140 前後になる
      expect(tester.getRect(field).top - box.top, lessThanOrEqualTo(17));
      expect(tester.getRect(field).left - box.left, lessThanOrEqualTo(17));

      await tester.enterText(field, '## 味噌汁\n- 塩 小さじ1');
      await tester.pumpAndSettle();
      expect(tester.getRect(field).top - box.top, lessThanOrEqualTo(17));

      // 欄の高さを超えて書いても、欄は伸びず中でスクロールする
      await tester.enterText(field, List.generate(40, (i) => '- 行 $i').join('\n'));
      await tester.pumpAndSettle();
      expect(tester.getRect(area).height, box.height);
      expect(tester.getRect(field).bottom, lessThanOrEqualTo(box.bottom));
    });
  }
}
