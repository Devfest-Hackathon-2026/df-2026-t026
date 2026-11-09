import 'dart:convert';

import 'package:diff_note/api.dart';
import 'package:diff_note/manual_controller.dart';
import 'package:diff_note/models.dart';
import 'package:diff_note/screens/check_screen.dart';
import 'package:diff_note/screens/common.dart';
import 'package:diff_note/screens/manual_screen.dart';
import 'package:diff_note/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moon_design/moon_design.dart';

// ノートの共有（ADR 0013）

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

/// かなで（demo）のノート。佐藤店長（sato）が行を1つ直し、田中さんの発言が1件食い違っている。
/// shared なら、佐藤店長として共有されたノートを見ている
class _Server {
  _Server({required this.shared});
  final bool shared;
  final people = <Map<String, dynamic>>[];
  final sent = <String>[];

  Map<String, dynamic> get state => {
        'manual': {'id': 'm1', 'title': 'キッチン', 'base': '- 塩 小さじ1', 'createdAt': '2026-11-01T00:00:00Z'},
        'lines': [
          {'text': '- 塩 小さじ1', 'patchId': null},
          {'text': '- だしは煮干し', 'patchId': 'p1'},
        ],
        'utterances': [
          {'id': 'u1', 'text': '- だしは煮干し', 'speaker': '佐藤店長', 'saidAt': '2026-11-09', 'fromEdit': true, 'editedBy': 'sato', 'createdAt': '2026-11-09T00:00:00Z'},
          {'id': 'u2', 'text': '塩は小さじ1/2でいい', 'speaker': '田中さん', 'saidAt': '2026-11-03', 'fromEdit': false, 'createdAt': '2026-11-03T00:00:00Z'},
        ],
        'patches': [
          {'id': 'p1', 'utteranceId': 'u1', 'op': 'insert', 'line': '- 塩 小さじ1', 'text': '- だしは煮干し', 'summary': '追記', 'status': 'applied', 'createdAt': '2026-11-09T00:00:00Z', 'appliedAt': '2026-11-09T00:00:00Z'},
          {'id': 'p2', 'utteranceId': 'u2', 'op': 'replace', 'line': '- 塩 小さじ1', 'text': '- 塩 小さじ1/2', 'summary': '', 'status': 'proposed', 'createdAt': '2026-11-03T00:00:00Z', 'appliedAt': null},
        ],
        'checks': [
          {
            'id': 'c1',
            'patchId': 'p2',
            'utteranceId': 'u2',
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
          },
        ],
        'owner': 'demo',
        'sharedBy': shared ? {'id': 'demo', 'name': 'かなで'} : null,
      };

  late final client = MockClient((req) async {
    final path = req.url.path;
    if (req.method != 'GET') sent.add('${req.method} $path ${req.body}');
    if (path == '/me') return _json({'id': shared ? 'sato' : 'demo', 'name': shared ? '佐藤店長' : 'かなで', 'icon': null});
    if (path == '/manuals') return _json([]);
    if (path == '/shared') {
      return _json(shared
          ? [
              {'id': 'm1', 'title': 'キッチン', 'sharedBy': {'id': 'demo', 'name': 'かなで'}, 'sharedAt': '2026-11-09T00:00:00Z'},
            ]
          : []);
    }
    if (path == '/manuals/m1/shares' && req.method == 'POST') {
      final id = (jsonDecode(req.body) as Map)['userId'] as String;
      if (id == 'nobody') return _json({'error': 'ID「nobody」のアカウントはありません。ID を確かめてください'}, 404);
      people.add({'id': id, 'name': id == 'haruto' ? 'はると' : id});
      return _json(people, 201);
    }
    if (path.startsWith('/manuals/m1/shares/') && req.method == 'DELETE') {
      people.removeWhere((p) => p['id'] == path.split('/').last);
      return _json(people);
    }
    if (path == '/manuals/m1/shares') return _json(people);
    if (path.startsWith('/manuals/m1')) return _json(state, req.method == 'POST' && path.endsWith('/edits') ? 201 : 200);
    return _json([]);
  });

  Api get api => Api(client: client, baseUrl: 'http://api');
}

Future<_Server> _pump(WidgetTester tester, {required bool shared, Size size = const Size(1440, 900)}) async {
  final server = _Server(shared: shared);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: appTheme(), home: ManualScreen(api: server.api, manualId: 'm1')));
  await tester.pumpAndSettle();
  return server;
}

Finder _outlined(String label) => find.widgetWithText(MoonOutlinedButton, label);

void main() {
  testWidgets('持ち主：上部バーの「共有」からログイン ID で相手を足し、外せる', (tester) async {
    final server = await _pump(tester, shared: false);
    expect(find.textContaining('から共有'), findsNothing);
    expect(find.text('共有されたノート'), findsNothing);

    await tester.tap(_outlined('共有'));
    await tester.pumpAndSettle();
    expect(find.text('まだ誰にも共有していません'), findsOneWidget);

    await tester.enterText(find.byType(EditableText), ' haruto ');
    await tester.pump();
    await tester.tap(find.widgetWithText(MoonFilledButton, '共有する'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(server.sent.last, 'POST /manuals/m1/shares {"userId":"haruto"}');
    expect(find.text('はると（haruto）'), findsOneWidget);
    expect(find.text('haruto に共有しました。相手のサイドバーに出ます'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 10));

    // 無い ID は、どうすればいいかを出す
    await tester.enterText(find.byType(EditableText), 'nobody');
    await tester.pump();
    await tester.tap(find.widgetWithText(MoonFilledButton, '共有する'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('ID「nobody」のアカウントはありません。ID を確かめてください'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 10));

    await tester.tap(find.widgetWithText(MoonTextButton, '外す'));
    await tester.pumpAndSettle();
    expect(server.sent.last, startsWith('DELETE /manuals/m1/shares/haruto'));
    expect(find.text('まだ誰にも共有していません'), findsOneWidget);
  });

  testWidgets('持ち主：狭い画面でも、上部バーに「共有」を出す', (tester) async {
    await _pump(tester, shared: false, size: const Size(400, 800));
    expect(_outlined('共有'), findsOneWidget);
    expect(_outlined('履歴'), findsNothing);
  });

  testWidgets('共有された人：持ち主が分かり、サイドバーに出る。共有と書き込む前の確認は出さず、行は直せる', (tester) async {
    final server = await _pump(tester, shared: true);
    expect(find.text('かなで から共有'), findsOneWidget);
    expect(_outlined('共有'), findsNothing);
    expect(_outlined('履歴'), findsOneWidget);
    // サイドバーの「共有されたノート」に、持ち主の名前つきで出る
    expect(find.text('共有されたノート'), findsOneWidget);
    expect(find.descendant(of: find.widgetWithText(MoonMenuItem, 'キッチン'), matching: find.text('かなで')), findsOneWidget);
    // 共有された人が直した行には、誰が直したかを出す
    expect(find.descendant(of: find.byType(Speaker), matching: find.text('佐藤店長')), findsOneWidget);

    // 発言の付箋を押しても、言われたことを見せるだけ
    await tester.tap(find.text('塩は小さじ1/2でいい'));
    await tester.pumpAndSettle();
    expect(find.text('「塩は小さじ1/2でいい」'), findsOneWidget);
    expect(find.text('ノートに書き込む'), findsNothing);
    await tester.tap(_outlined('閉じる'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(MoonOutlinedButton, '行を足す'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), '- 火を止めてから味噌を溶く');
    await tester.pump();
    await tester.tap(find.widgetWithText(MoonFilledButton, '保存する'));
    await tester.pumpAndSettle();
    expect(server.sent.first, startsWith('POST /manuals/m1/edits'));
    // 書いたあとの食い違いの確かめも、共有された人の画面から呼ぶ
    expect(server.sent[1], startsWith('POST /manuals/m1/patches/'));
    await tester.pumpAndSettle(const Duration(seconds: 10));
  });

  testWidgets('狭い画面の共有された人には、上部バーに何も出さない', (tester) async {
    await _pump(tester, shared: true, size: const Size(400, 800));
    expect(_outlined('共有'), findsNothing);
  });

  for (final shared in [false, true]) {
    testWidgets('確認のページ：聞いた結果を記録するのは持ち主だけ（${shared ? '共有された人' : '持ち主'}）', (tester) async {
      final server = _Server(shared: shared);
      final c = ManualController(server.api, 'm1', ManualState.fromJson(server.state));
      tester.view.physicalSize = const Size(400, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(theme: appTheme(), home: CheckScreen(c: c, checkId: 'c1')));
      await tester.pumpAndSettle();
      expect(_outlined('聞いた結果を記録する'), shared ? findsNothing : findsOneWidget);
      expect(find.text('聞いた結果は、ノートの持ち主の かなで が記録します'), shared ? findsOneWidget : findsNothing);
      // 誰に確認するかと聞き方は、共有された人にも見せる
      expect(find.text('どちらですか？'), findsOneWidget);
    });
  }
}
