import 'package:diff_note/screens/common.dart';
import 'package:diff_note/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

// #120：比較の表の見出しが片方だけ2行に折れても、左右の段（見出しの帯と本文）をそろえる

Future<void> _pump(WidgetTester tester, {required double width, required String leftLabel, required String rightLabel}) async {
  await tester.pumpWidget(MaterialApp(
    theme: appTheme(),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: ConflictPair(leftLabel: leftLabel, left: '- 塩 小さじ1', rightLabel: rightLabel, right: '- 塩 小さじ1/2'),
        ),
      ),
    ),
  ));
}

void main() {
  // 幅 390 の確認のページでは、比較の表の幅はおよそ 326（左右の余白を除く）
  for (final (width, left, right) in const [
    (326.0, 'ノート', '田中さん（11/3）'),
    (480.0, '資料「キッチンの手順書（2026年版）」p.3', '田中さん（11/3）'),
  ]) {
    testWidgets('見出し「$left」「$right」が幅 $width で片方だけ折れても、左右の本文の頭をそろえる', (tester) async {
      await _pump(tester, width: width, leftLabel: left, rightLabel: right);
      // 片方だけ2行に折れている（そろえる前は、ここで本文の頭がずれた）
      double labelHeight(String label) {
        final p = tester.renderObject<RenderParagraph>(find.text(label));
        return p.getMinIntrinsicHeight(p.size.width);
      }
      expect(labelHeight(left) == labelHeight(right), isFalse, reason: '見出しの行数が同じで、確かめになっていない');
      expect(tester.getTopLeft(find.text('塩 小さじ1')).dy, tester.getTopLeft(find.text('塩 小さじ1/2')).dy);
    });
  }
}
