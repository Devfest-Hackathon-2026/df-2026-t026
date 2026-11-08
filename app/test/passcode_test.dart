import 'dart:convert';

import 'package:diff_note/api.dart';
import 'package:diff_note/screens/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(Object body, int status) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

void main() {
  testWidgets('合言葉を聞かれ、合っていれば一覧が出て、ブラウザに覚えておく', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final client = MockClient((req) async => switch (req.headers['X-Passcode']) {
          null => _json({'error': '合言葉を入れてください'}, 401),
          'open-sesame-1' => _json([
              {'id': 'm1', 'title': 'キッチン', 'utteranceCount': 0, 'openCount': 0},
            ], 200),
          _ => _json({'error': '合言葉が違います'}, 401),
        });
    await tester.pumpWidget(MaterialApp(home: HomeScreen(api: Api(client: client, baseUrl: 'http://api'))));
    await tester.pumpAndSettle();
    expect(find.text('合言葉を入れてください'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'open-sesame');
    await tester.tap(find.text('入る'));
    await tester.pumpAndSettle();
    expect(find.text('合言葉が違います'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'open-sesame-1');
    await tester.tap(find.text('入る'));
    await tester.pumpAndSettle();
    expect(find.text('キッチン'), findsOneWidget);
    expect((await SharedPreferences.getInstance()).getString(passcodeKey), 'open-sesame-1');
  });
}
