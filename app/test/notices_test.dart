import 'dart:convert';

import 'package:diff_note/api.dart';
import 'package:diff_note/screens/common.dart';
import 'package:diff_note/screens/input_screen.dart';
import 'package:diff_note/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moon_design/moon_design.dart';

// 共有した相手が答えた・直したことを、持ち主に通知で知らせる（ADR 0020）

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

/// 自分はかなで。佐藤店長が前に答え（見た後）、そのあと行を直した（まだ見ていない）
class _Server {
  var seenAt = '2026-11-10T01:00:00.000Z';
  final requests = <String>[];

  late final client = MockClient((req) async {
    requests.add('${req.method} ${req.url.path}');
    switch (req.url.path) {
      case '/me':
        return _json({'id': 'demo', 'name': 'かなで', 'icon': null});
      case '/manuals' || '/shared':
        return _json([]);
      case '/notices/seen':
        seenAt = '2026-11-10T09:00:00.000Z';
        return http.Response('', 204);
      case '/notices':
        return _json({
          'seenAt': seenAt,
          'items': [
            {
              'id': 'u9',
              'kind': 'edit',
              'manualId': 'm1',
              'title': 'キッチン',
              'by': {'id': 'sato', 'name': '佐藤店長'},
              'at': '2026-11-10T02:00:00.000Z',
              'op': 'replace',
              'line': '- 炊けたら10分蒸らす',
              'text': '- 炊けたら15分蒸らす',
            },
            {
              'id': 'c1',
              'kind': 'answer',
              'manualId': 'm1',
              'title': 'キッチン',
              'by': {'id': 'sato', 'name': '佐藤店長'},
              'at': '2026-11-10T00:30:00.000Z',
              'line': '- 塩 小さじ1',
              'text': '- 塩 小さじ1/2',
              'note': '1/2で統一',
            },
          ],
        });
    }
    return _json({'error': '見つかりません'}, 404);
  });
}

void main() {
  testWidgets('自分の右に新しい通知の数が出て、押すと通知が並び、見たら数が消える。通知からノートを開ける', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = _Server();
    await tester.pumpWidget(
        MaterialApp(theme: appTheme(), home: InputScreen(api: Api(client: server.client, baseUrl: 'http://api'))));
    await tester.pumpAndSettle();
    final me = find.widgetWithText(MoonMenuItem, 'かなで');
    expect(find.descendant(of: me, matching: find.text('1')), findsOneWidget);

    await tester.tap(me);
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(PageTitle), matching: find.text('通知')), findsOneWidget);
    expect(find.text('佐藤店長がノートを編集しました'), findsOneWidget);
    expect(find.text('「炊けたら10分蒸らす」→「炊けたら15分蒸らす」'), findsOneWidget);
    expect(find.text('佐藤店長が回答しました'), findsOneWidget);
    expect(find.text('「塩 小さじ1」→「塩 小さじ1/2」（1/2で統一）'), findsOneWidget);
    // 前に見たときより後の、行の直しだけが新しい
    expect(find.text('新しい'), findsOneWidget);
    expect(server.requests, contains('POST /notices/seen'));
    // 見たので、自分の右の数は消える。開いているページの「新しい」は残す
    expect(find.descendant(of: find.widgetWithText(MoonMenuItem, 'かなで'), matching: find.text('1')), findsNothing);
    expect(find.text('新しい'), findsOneWidget);

    await tester.tap(find.text('佐藤店長がノートを編集しました'));
    await tester.pumpAndSettle();
    expect(server.requests, contains('GET /manuals/m1'));
  });

  testWidgets('通知が無ければ、何が出るかを案内する', (tester) async {
    final client = MockClient((req) async => switch (req.url.path) {
          '/me' => _json({'id': 'demo', 'name': 'かなで', 'icon': null}),
          '/notices' => _json({'seenAt': null, 'items': []}),
          '/notices/seen' => http.Response('', 204),
          _ => _json([]),
        });
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: appTheme(), home: InputScreen(api: Api(client: client, baseUrl: 'http://api'))));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MoonMenuItem, 'かなで'));
    await tester.pumpAndSettle();
    expect(find.text('ノートを共有した人が確認に答えたり、行を直したりすると、ここに出ます'), findsOneWidget);
  });
}
