import 'dart:convert';

import 'package:diff_note/api.dart';
import 'package:diff_note/screens/common.dart';
import 'package:diff_note/screens/home_screen.dart';
import 'package:diff_note/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// 調査18 の A4・実装22: サーバーが JSON でない本文を返したときも、画面が受けられる ApiException にする

Api _api(http.Response Function() res) => Api(client: MockClient((_) async => res()), baseUrl: 'http://api');

void main() {
  test('失敗（5xx）で本文が HTML のときは、ApiException「エラーが起きました（状態）」', () async {
    final api = _api(() => http.Response('<html><body>503 Service Unavailable</body></html>', 503));
    await expectLater(
      api.getManual('m1'),
      throwsA(isA<ApiException>().having((e) => e.message, 'message', 'エラーが起きました（503）').having((e) => e.status, 'status', 503)),
    );
  });

  test('成功（2xx）なのに本文が JSON でないときも、ApiException', () async {
    final api = _api(() => http.Response('ok', 200));
    await expectLater(
      api.getManual('m1'),
      throwsA(isA<ApiException>().having((e) => e.message, 'message', 'エラーが起きました（200）')),
    );
  });

  test('失敗の本文が JSON で error があれば、今までどおりその文を出す', () async {
    final api = _api(() => http.Response.bytes(utf8.encode('{"error":"見つかりません"}'), 404));
    await expectLater(
      api.getManual('m1'),
      throwsA(isA<ApiException>().having((e) => e.message, 'message', '見つかりません').having((e) => e.status, 'status', 404)),
    );
  });

  testWidgets('読み込む画面（ノート一覧）では、英語の FormatException でなく日本語で「読み込めませんでした」を出し、もう一度読み込める', (tester) async {
    var calls = 0;
    final api = Api(
      client: MockClient((req) async {
        calls++;
        return calls == 1
            ? http.Response('<html>502 Bad Gateway</html>', 502)
            : http.Response('{"me":{"id":"demo","name":"demo","icon":null},"notes":[],"memos":[]}', 200);
      }),
      baseUrl: 'http://api',
    );
    await tester.pumpWidget(MaterialApp(theme: appTheme(), home: HomeScreen(api: api)));
    await tester.pumpAndSettle();

    expect(find.byType(LoadFailed), findsOneWidget);
    expect(find.text('読み込めませんでした：エラーが起きました（502）'), findsOneWidget);
    expect(find.textContaining('FormatException'), findsNothing);

    await tester.tap(find.text('もう一度読み込む'));
    await tester.pumpAndSettle();
    expect(find.byType(LoadFailed), findsNothing);
  });
}
