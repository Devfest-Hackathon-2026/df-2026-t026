import 'dart:async';
import 'dart:convert';

import 'package:diff_note/api.dart';
import 'package:diff_note/screens/common.dart';
import 'package:diff_note/screens/input_screen.dart';
import 'package:diff_note/screens/manual_screen.dart';
import 'package:diff_note/screens/notices_screen.dart';
import 'package:diff_note/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moon_design/moon_design.dart';

import 'home.dart';

// 共有した相手が答えた・直したことを、持ち主に通知で知らせる（ADR 0020）。
// 通知は GET /home で store に読み、サイドバーの数も store から出す（ADR 0021）

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

/// 自分はかなで。佐藤店長が前に答え（見た後）、そのあと行を直した（まだ見ていない）。
/// ノート m1 は行の直接編集を受け、応答は送った行を足した状態
class _Server {
  var seenAt = '2026-11-10T01:00:00.000Z';
  final requests = <String>[];
  final lines = <Map<String, dynamic>>[];

  /// あとから届いた通知（新しい順の先頭に入る）
  final later = <Map<String, dynamic>>[];

  /// あれば、GET /home は中身を読んでから、これが済むまで返さない
  Completer<void>? homeGate;

  Map<String, dynamic> get note => {
        ...noteJson('m1', 'キッチン'),
        'lines': lines,
      };

  Map<String, dynamic> get notices => {
        'seenAt': seenAt,
        'items': [
          ...later,
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
      };

  late final client = MockClient((req) async {
    requests.add('${req.method} ${req.url.path}');
    switch (req.url.path) {
      case '/home':
        final body = homeJson([note], me: {'id': 'demo', 'name': 'かなで', 'icon': null}, notices: notices);
        await homeGate?.future;
        return _json(body);
      case '/notices/seen':
        seenAt = '2026-11-10T09:00:00.000Z';
        return http.Response('', 204);
      case '/manuals/m1':
        return _json(note);
      case '/manuals/m1/edits':
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        lines.add({'text': body['text'], 'patchId': body['patchId']});
        return _json(note, 201);
    }
    return _json({'error': '見つかりません'}, 404);
  });
}

void _wide(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Finder get _me => find.widgetWithText(MoonMenuItem, 'かなで');

void main() {
  testWidgets('自分の右に新しい通知の数が出て、押すと通知が並び、見たら数が消える。通知からノートを開ける', (tester) async {
    _wide(tester);
    final server = _Server();
    await tester.pumpWidget(
        MaterialApp(theme: appTheme(), home: InputScreen(api: Api(client: server.client, baseUrl: 'http://api'))));
    await tester.pumpAndSettle();
    expect(find.descendant(of: _me, matching: find.text('1')), findsOneWidget);

    await tester.tap(_me);
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
    expect(find.descendant(of: _me, matching: find.text('1')), findsNothing);
    expect(find.text('新しい'), findsOneWidget);
    // 通知は開いたときに読んだ store から出し、ページを開いても読み直さない
    expect(server.requests.where((r) => r.startsWith('GET')), ['GET /home']);

    await tester.tap(find.text('佐藤店長がノートを編集しました'));
    await tester.pumpAndSettle();
    expect(find.byType(ManualScreen), findsOneWidget);
    expect(server.requests, contains('GET /manuals/m1'));
  });

  testWidgets('戻ってきたときの読み直しの途中に見たことにしても、その読み直しで届いた通知は出し、「新しい」を付ける', (tester) async {
    _wide(tester);
    final server = _Server();
    final api = Api(client: server.client, baseUrl: 'http://api');
    await tester.pumpWidget(MaterialApp(theme: appTheme(), home: InputScreen(api: api)));
    await tester.pumpAndSettle();

    // 戻ってきて読み直している間に、佐藤店長がもう1行直していた。読み直しはまだ返らない
    server.later.add({
      'id': 'u10',
      'kind': 'edit',
      'manualId': 'm1',
      'title': 'キッチン',
      'by': {'id': 'sato', 'name': '佐藤店長'},
      'at': '2026-11-10T03:00:00.000Z',
      'op': 'delete',
      'line': '- 塩 小さじ1/2',
      'text': '',
    });
    server.homeGate = Completer();
    api.store.load();
    await tester.pump();

    await tester.tap(_me);
    await tester.pumpAndSettle();
    expect(server.requests, contains('POST /notices/seen'));
    expect(find.text('「塩 小さじ1/2」を消した'), findsNothing);

    server.homeGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('「塩 小さじ1/2」を消した'), findsOneWidget);
    expect(find.text('新しい'), findsNWidgets(2));
  });

  testWidgets('まだ読めていないときに開いたら、読んでから「新しい」を付け、そのあとで見たことにする', (tester) async {
    _wide(tester);
    final server = _Server();
    await tester.pumpWidget(
        MaterialApp(theme: appTheme(), home: NoticesScreen(api: Api(client: server.client, baseUrl: 'http://api'))));
    await tester.pumpAndSettle();
    expect(server.requests, ['GET /home', 'POST /notices/seen']);
    expect(find.text('佐藤店長がノートを編集しました'), findsOneWidget);
    expect(find.text('新しい'), findsOneWidget);
    expect(find.descendant(of: _me, matching: find.text('1')), findsNothing);
  });

  testWidgets('自分で行を書いても、通知もノートも読み直さず、新しい通知の数はそのまま', (tester) async {
    _wide(tester);
    final server = _Server();
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(),
      home: ManualScreen(api: Api(client: server.client, baseUrl: 'http://api'), manualId: 'm1'),
    ));
    await tester.pumpAndSettle();
    expect(find.descendant(of: _me, matching: find.text('1')), findsOneWidget);
    server.requests.clear();

    // 見出しは確かめないので、送るのは行の編集の1本だけ
    await tester.tap(find.widgetWithText(MoonOutlinedButton, '行を足す'));
    await tester.pumpAndSettle();
    tester.testTextInput.enterText('## 仕込み');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(server.requests, ['POST /manuals/m1/edits']);
    expect(find.text('仕込み'), findsWidgets);
    expect(find.descendant(of: _me, matching: find.text('1')), findsOneWidget);
  });

  testWidgets('通知が無ければ、何が出るかを案内する', (tester) async {
    final client = MockClient((req) async => switch (req.url.path) {
          '/home' => _json(homeJson([], me: {'id': 'demo', 'name': 'かなで', 'icon': null})),
          '/notices/seen' => http.Response('', 204),
          _ => _json([]),
        });
    _wide(tester);
    await tester.pumpWidget(MaterialApp(theme: appTheme(), home: InputScreen(api: Api(client: client, baseUrl: 'http://api'))));
    await tester.pumpAndSettle();
    expect(find.descendant(of: _me, matching: find.byType(StatusTag)), findsNothing);
    await tester.tap(_me);
    await tester.pumpAndSettle();
    expect(find.text('ノートを共有した人が確認に答えたり、行を直したりすると、ここに出ます'), findsOneWidget);
  });
}
