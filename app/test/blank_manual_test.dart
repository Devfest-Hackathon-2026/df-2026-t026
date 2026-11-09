import 'dart:convert';

import 'package:diff_note/api.dart';
import 'package:diff_note/screens/manual_screen.dart';
import 'package:diff_note/screens/new_manual_screen.dart';
import 'package:diff_note/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moon_design/moon_design.dart';

import 'input_font.dart';

final _blank = {
  'manual': {'id': 'm1', 'title': '自分用メモ', 'base': '', 'createdAt': '2026-11-08T00:00:00Z'},
  'lines': [],
  'utterances': [],
  'patches': [],
  'checks': [],
};

http.Response _json(Object body, int status) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

Future<void> _pump(WidgetTester tester, Widget screen) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: appTheme(), home: screen));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('本文を空のままでも、題名だけで白紙から始め、そのまま開いて書ける', (tester) async {
    Map<String, dynamic>? sent;
    final client = MockClient((req) async {
      if (req.method == 'POST') sent = jsonDecode(req.body) as Map<String, dynamic>;
      return _json(_blank, req.method == 'POST' ? 201 : 200);
    });
    await _pump(tester, NewManualScreen(api: Api(client: client, baseUrl: 'http://api')));
    expectInputFontsAtLeast16(tester, count: 2); // 題名・最初の本文

    // 題名が無いうちは押せない
    final blank = find.widgetWithText(MoonFilledButton, '白紙から始める');
    expect(tester.widget<MoonFilledButton>(blank).onTap, isNull);

    await tester.enterText(find.byType(EditableText).first, '自分用メモ');
    await tester.pump();
    expect(tester.widget<MoonFilledButton>(blank).onTap, isNotNull);

    await tester.tap(blank);
    await tester.pumpAndSettle();
    expect(sent, {'title': '自分用メモ', 'body': ''});
    expect(find.byType(ManualScreen), findsOneWidget);
    expect(find.widgetWithText(MoonTextButton, '行を足す'), findsOneWidget);
  });

  testWidgets('白紙のノートは、直接書くか記録すると書き足されることを案内する', (tester) async {
    final client = MockClient((_) async => _json(_blank, 200));
    await _pump(tester, ManualScreen(api: Api(client: client, baseUrl: 'http://api'), manualId: 'm1'));

    expect(find.textContaining('まだ白紙です'), findsOneWidget);
  });
}
