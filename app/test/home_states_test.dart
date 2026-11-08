import 'dart:convert';

import 'package:diff_note/api.dart';
import 'package:diff_note/screens/home_screen.dart';
import 'package:diff_note/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moon_design/moon_design.dart';

http.Response _json(Object body, int status) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

Future<void> _pumpHome(WidgetTester tester, MockClient client) async {
  await tester.pumpWidget(MaterialApp(theme: appTheme(), home: HomeScreen(api: Api(client: client, baseUrl: 'http://api'))));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('マニュアルが無いときは、登録への案内を出す', (tester) async {
    await _pumpHome(tester, MockClient((_) async => _json([], 200)));

    expect(find.text('まだマニュアルがありません'), findsOneWidget);
    expect(find.text('マニュアルを登録'), findsOneWidget);
  });

  testWidgets('読み込みに失敗したら理由を出し、もう一度読み込める', (tester) async {
    var calls = 0;
    await _pumpHome(
      tester,
      MockClient((_) async => ++calls == 1
          ? _json({'error': 'サーバーの調子が悪いです'}, 500)
          : _json([
              {'id': 'm1', 'title': 'キッチン', 'utteranceCount': 2, 'openCount': 1},
            ], 200)),
    );
    expect(find.text('読み込めませんでした：サーバーの調子が悪いです'), findsOneWidget);

    await tester.tap(find.widgetWithText(MoonOutlinedButton, 'もう一度読み込む'));
    await tester.pumpAndSettle();
    expect(find.text('キッチン'), findsOneWidget);
    expect(find.text('確認待ち 1 件'), findsOneWidget);
  });
}
