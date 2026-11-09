import 'dart:async';
import 'dart:convert';

import 'package:diff_note/api.dart';
import 'package:diff_note/screens/common.dart';
import 'package:diff_note/screens/input_screen.dart';
import 'package:diff_note/screens/open_checks_screen.dart';
import 'package:diff_note/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moon_design/moon_design.dart';
import 'package:shared_preferences/shared_preferences.dart';

// #92: 入力ページの「あとで確認」とサイドバーの件数が食い違う

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

/// キッチンに食い違いが2件。resolve を受けた分は確認済みにし、一覧の openCount も同じ所から数える。
/// POST /utterances は intake が返すまで待たせる（記録の処理中）。failList が true の間は一覧が 500 になる
class _Server {
  final resolved = <String>{};
  Completer<void>? intake;
  var failList = false;

  int get open => 2 - resolved.length;

  Map<String, dynamic> state({bool recorded = false}) => {
        'owner': 'demo',        'me': 'demo',        'manual': {'id': 'm1', 'title': 'キッチン', 'base': '- 塩 小さじ1', 'createdAt': '2026-11-01T00:00:00Z'},
        'lines': [
          {'text': '- 塩 小さじ1', 'patchId': null},
        ],
        'utterances': [
          for (var i = 0; i < 2; i++)
            {'id': 'u$i', 'text': '塩は$i', 'speaker': '田中さん', 'saidAt': '2026-11-03', 'createdAt': '2026-11-03T10:0$i:00Z'},
          if (recorded)
            {'id': 'u9', 'text': 'お冷やはすぐ出す', 'speaker': '田中さん', 'saidAt': '2026-11-04', 'createdAt': '2026-11-04T10:00:00Z'},
        ],
        'patches': [
          for (var i = 0; i < 2; i++)
            {
              'id': 'p$i',
              'utteranceId': 'u$i',
              'op': 'replace',
              'line': '- 塩 小さじ1',
              'text': '- 塩 $i',
              'summary': '',
              'status': 'proposed',
              'createdAt': '2026-11-03T10:00:00Z',
              'appliedAt': null,
            },
        ],
        'checks': [
          for (var i = 0; i < 2; i++)
            {
              'id': 'c$i',
              'patchId': 'p$i',
              'utteranceId': 'u$i',
              'kind': 'contradiction',
              'conflictLine': '- 塩 小さじ1',
              'reason': '量が違う',
              'ask': {
                'candidates': [
                  {'who': '店長', 'why': 'お店のやり方を決める立場なので'},
                ],
                'question': 'どちらですか？',
              },
              'resolution': resolved.contains('c$i')
                  ? {
                      'utteranceId': 'u$i',
                      'patchId': 'p$i',
                      'decidedBy': '店長',
                      'decidedAt': '2026-11-07',
                      'text': '- 塩 $i',
                      'note': '塩 $i',
                    }
                  : null,
            },
        ],
      };

  MockClient client() => MockClient((req) async {
        final path = req.url.path;
        if (path == '/me') return _json({'id': 'kanade', 'name': 'かなで', 'icon': null});
        if (path == '/shared' || path == '/memos') return _json([]);
        if (path == '/manuals') {
          if (failList) return _json({'error': '混んでいます'}, 500);
          return _json([
            {'id': 'm1', 'title': 'キッチン', 'utteranceCount': 2, 'openCount': open, 'createdAt': '2026-11-01T00:00:00Z'},
          ]);
        }
        if (req.method == 'POST' && path.endsWith('/resolve')) {
          resolved.add(req.url.pathSegments[3]);
          return _json(state());
        }
        if (req.method == 'POST' && path == '/utterances') {
          await intake?.future;
          return _json({
            'text': 'お冷やはすぐ出す',
            'results': [
              {'manualId': 'm1', 'utteranceId': 'u9', 'state': state(recorded: true)},
            ],
          }, 201);
        }
        return _json(state());
      });
}

Future<Api> _pump(WidgetTester tester, _Server server) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final api = Api(client: server.client(), baseUrl: 'http://api');
  await tester.pumpWidget(MaterialApp(theme: appTheme(), home: InputScreen(api: api)));
  await tester.pumpAndSettle();
  return api;
}

/// 入力ページの「あとで確認」の節で、キッチンの行に出ている件数
Finder _row(int n) => find.descendant(of: find.byType(OpenChecksList), matching: find.text('あとで確認 $n 件'));

/// サイドバーのキッチンの横の件数。ノートが1冊なので、上の「あとで確認」の合計と同じ数が2つ出る
Finder _sidebar(int n) => find.widgetWithText(StatusTag, '$n');

/// サイドバーから「あとで確認」→ キッチンの確認リストへ進み、いちばん新しい食い違いを確認済みにして、
/// サイドバーの「言われたことを記録」で入力ページに戻る
Future<void> _resolveElsewhere(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(MoonMenuItem, 'あとで確認'));
  await tester.pumpAndSettle();
  await tester.tap(find.descendant(of: find.byType(OpenChecksList), matching: find.text('キッチン')));
  await tester.pumpAndSettle();
  final start = find.widgetWithText(MoonOutlinedButton, '聞いた結果を記録する');
  await tester.ensureVisible(start);
  await tester.tap(start);
  await tester.pumpAndSettle();
  final confirm = find.widgetWithText(MoonFilledButton, '確認済みにする');
  await tester.ensureVisible(confirm);
  await tester.tap(confirm);
  await tester.pumpAndSettle();
  await tester.pump(const Duration(seconds: 10)); // 確定のトーストが消えるのを待つ
  await tester.tap(find.widgetWithText(MoonMenuItem, '言われたことを記録'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('ほかの画面で確認済みにしてサイドバーから戻ると、入力ページの「あとで確認」もサイドバーと同じ件数になる', (tester) async {
    final server = _Server();
    await _pump(tester, server);
    expect(_row(2), findsOneWidget);
    expect(_sidebar(2), findsNWidgets(2));

    await _resolveElsewhere(tester);

    expect(server.resolved, ['c1']);
    expect(_sidebar(1), findsNWidgets(2));
    expect(_row(1), findsOneWidget);
    expect(_row(2), findsNothing);
  });

  testWidgets('記録の処理を待っている間も、入力ページの「あとで確認」とサイドバーは同じ件数を出す', (tester) async {
    final server = _Server();
    await _pump(tester, server);
    await _resolveElsewhere(tester);

    server.intake = Completer();
    await tester.enterText(find.byType(MoonTextArea), 'お冷やはすぐ出す');
    await tester.pump();
    await tester.tap(find.widgetWithText(MoonFilledButton, 'ノートと照らし合わせる'));
    await tester.pump();
    // 照らし合わせの最中
    expect(_sidebar(1), findsNWidgets(2));
    expect(_row(1), findsOneWidget);

    server.intake!.complete();
    await tester.pumpAndSettle();
    expect(_sidebar(1), findsNWidgets(2));
    expect(_row(1), findsOneWidget);
    await tester.pump(const Duration(seconds: 10)); // 記録のトーストが消えるのを待つ
  });

  testWidgets('ほかの画面での変更のあと読み直せなくても、入力ページは書きかけを残したまま前の表示を出す', (tester) async {
    final server = _Server();
    final api = await _pump(tester, server);
    await tester.enterText(find.byType(MoonTextArea), '書きかけ');
    await tester.pump();

    server.failList = true;
    await api.resolve('m1', 'c0', decidedBy: '店長', decidedAt: '2026-11-07', text: '- 塩 0', note: '塩 0');
    await tester.pumpAndSettle();

    expect(find.byType(LoadFailed), findsNothing);
    expect(_row(2), findsOneWidget);
    expect(tester.widget<MoonTextArea>(find.byType(MoonTextArea)).controller!.text, '書きかけ');
  });
}
