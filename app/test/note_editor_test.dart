import 'dart:convert';

import 'package:diff_note/api.dart';
import 'package:diff_note/screens/manual_screen.dart';
import 'package:diff_note/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moon_design/moon_design.dart';

/// 直接編集を受けるだけの、メモリ上の小さなサーバー
class _Server {
  final lines = <Map<String, dynamic>>[
    {'text': '- 塩 小さじ1', 'patchId': null},
  ];
  final utterances = <Map<String, dynamic>>[];
  final patches = <Map<String, dynamic>>[];
  final checks = <Map<String, dynamic>>[];
  final sent = <Map<String, dynamic>>[];

  Map<String, dynamic> get state => {
        'manual': {'id': 'm1', 'title': 'キッチン', 'base': '- 塩 小さじ1', 'createdAt': '2026-11-01T00:00:00Z'},
        'lines': lines,
        'utterances': utterances,
        'patches': patches,
        'checks': checks,
      };

  late final client = MockClient((req) async {
    if (req.method == 'POST' && req.url.path == '/manuals/m1/edits') {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      sent.add(body);
      final id = 'p${patches.length + 1}';
      utterances.add({'id': 'u$id', 'text': body['text'], 'speaker': '自分', 'saidAt': '2026-11-08', 'fromEdit': true, 'createdAt': '2026-11-08T00:00:00Z'});
      patches.add({'id': id, 'utteranceId': 'u$id', 'op': body['op'], 'line': body['line'], 'text': body['text'], 'summary': '', 'status': 'applied'});
      final i = lines.indexWhere((l) => l['text'] == body['line']);
      if (body['op'] == 'delete') lines.removeAt(i);
      if (body['op'] == 'insert') lines.insert(i + 1, {'text': body['text'], 'patchId': id});
      if (body['op'] == 'replace') lines[i] = {'text': body['text'], 'patchId': id};
      return _json(state, 201);
    }
    if (req.method == 'POST' && req.url.path.endsWith('/check')) {
      final p = patches.last;
      checks.add({
        'id': 'c1',
        'patchId': p['id'],
        'utteranceId': p['utteranceId'],
        'kind': 'contradiction',
        'conflictLine': '- 塩 小さじ1',
        'sameLine': null,
        'reason': '量が違う',
        'ask': {
          'candidates': [
            {'who': '店長', 'why': '決める立場'},
          ],
          'question': 'どちらですか？',
        },
        'resolution': null,
      });
      return _json(state, 200);
    }
    return _json(state, 200);
  });
}

http.Response _json(Object body, int status) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

Future<_Server> _pump(WidgetTester tester) async {
  final server = _Server();
  tester.view.physicalSize = const Size(800, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: appTheme(),
    home: ManualScreen(api: Api(client: server.client, baseUrl: 'http://api'), manualId: 'm1'),
  ));
  await tester.pumpAndSettle();
  return server;
}

void main() {
  testWidgets('末尾に行を書き足すと、すぐ出て、食い違えば確認リストに入ったと知らせる', (tester) async {
    final server = await _pump(tester);

    await tester.tap(find.widgetWithText(MoonTextButton, '行を書き足す'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), '- 塩 小さじ2');
    await tester.pump();
    await tester.tap(find.widgetWithText(MoonFilledButton, '行を足す'));
    await tester.pump(const Duration(milliseconds: 500));

    expect(server.sent.single, {'op': 'insert', 'line': null, 'text': '- 塩 小さじ2', 'today': isA<String>()});
    expect(find.text('・塩 小さじ2'), findsWidgets);
    expect(find.text('「塩 小さじ1」と食い違っています。確認リストに入れました'), findsOneWidget);
    expect(find.text('食い違い'), findsOneWidget);
    // 直接書いた行は、口頭の記録として数えない
    expect(find.text('記録 0 件'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 10));

    // 食い違っている行を押すと、口頭の指示と同じ確認リストに「自分」が書いた行として並ぶ
    await tester.tap(find.text('食い違い'));
    await tester.pumpAndSettle();
    expect(find.text('塩 小さじ1 ／ 塩 小さじ2'), findsOneWidget);
    expect(find.text('自分'), findsWidgets);
  });

  testWidgets('行を押すとその場で書き換え・消しができる', (tester) async {
    final server = await _pump(tester);

    await tester.tap(find.text('・塩 小さじ1'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(MoonTextInput, '- 塩 小さじ1'), findsOneWidget);

    await tester.tap(find.widgetWithText(MoonOutlinedButton, 'この行を消す'));
    await tester.pumpAndSettle();

    expect(server.sent.single['op'], 'delete');
    expect(server.sent.single['line'], '- 塩 小さじ1');
    expect(find.text('・塩 小さじ1'), findsNothing);
    // 消しただけなら確かめない
    expect(server.checks, isEmpty);
  });
}
