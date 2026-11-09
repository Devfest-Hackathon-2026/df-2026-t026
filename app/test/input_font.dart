import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// 画面にある入力欄の文字が、すべて 16px 以上か。
/// iPhone（WebKit）は 16px 未満の入力欄にフォーカスすると画面を拡大して戻さないため（調査17）
void expectInputFontsAtLeast16(WidgetTester tester, {required int count}) {
  final fields = tester.widgetList<EditableText>(find.byType(EditableText, skipOffstage: false)).toList();
  expect(fields.length, greaterThanOrEqualTo(count), reason: '確かめたい入力欄が画面に出ていない');
  for (final f in fields) {
    expect(f.style.fontSize, greaterThanOrEqualTo(16), reason: '入力欄の文字が 16px 未満（${f.controller.text}）');
  }
}
