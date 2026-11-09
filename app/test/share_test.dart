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

// ノートの共有（ADR 0013）と、共有した全員での編集（ADR 0016）

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

/// かなで（demo）のノート。佐藤店長（sato）が行を1つ直し、田中さんの発言が1件食い違っている。
/// shared なら、佐藤店長として共有されたノートを見ている
class _Server {
  _Server({required this.shared});
  final bool shared;
  final people = <Map<String, dynamic>>[];
  final sent = <String>[];

  /// 次の直接編集で返す衝突。返したら空にする
  Map<String, dynamic>? conflict;

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
              {'id': 'm1', 'title': 'キッチン', 'sharedBy': {'id': 'demo', 'name': 'かなで'}, 'sharedAt': '2026-11-09T00:00:00Z', 'openCount': 1},
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
    if (path == '/manuals/m1/edits' && conflict != null) {
      final x = conflict!;
      conflict = null;
      return _json({'error': 'ほかの人が先にこの行を直しました', 'conflict': x}, 409);
    }
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

  testWidgets('共有された人：持ち主が分かり、サイドバーに件数つきで出る。共有と書き込む前の確認もでき、行も直せる。消すことはできない', (tester) async {
    final server = await _pump(tester, shared: true);
    expect(find.text('かなで から共有'), findsOneWidget);
    expect(_outlined('履歴'), findsOneWidget);
    expect(find.bySemanticsLabel('その他'), findsNothing);
    // サイドバーの「共有されたノート」に、持ち主の名前と、あとで確認の件数つきで出る
    expect(find.text('共有されたノート'), findsOneWidget);
    final item = find.widgetWithText(MoonMenuItem, 'キッチン');
    expect(find.descendant(of: item, matching: find.text('かなで')), findsOneWidget);
    expect(find.descendant(of: item, matching: find.text('1')), findsOneWidget);
    expect(find.descendant(of: find.widgetWithText(MoonMenuItem, 'あとで確認'), matching: find.text('1')), findsOneWidget);
    // 共有された人が直した行には、誰が直したかを出す
    expect(find.descendant(of: find.byType(Speaker), matching: find.text('佐藤店長')), findsOneWidget);

    // 共有のモーダルには持ち主を出す
    await tester.tap(_outlined('共有'));
    await tester.pumpAndSettle();
    expect(find.text('持ち主：かなで（demo）'), findsOneWidget);
    await tester.tap(_outlined('閉じる'));
    await tester.pumpAndSettle();

    // 発言の付箋から、書き込む前の確認を開ける
    await tester.tap(find.text('塩は小さじ1/2でいい'));
    await tester.pumpAndSettle();
    expect(find.text('ノートに書き込む前の確認'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('閉じる'));
    await tester.pumpAndSettle();
    expect(find.text('ノートに書き込む前の確認'), findsNothing);

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

  testWidgets('狭い画面の共有された人にも、上部バーに「共有」を出す', (tester) async {
    await _pump(tester, shared: true, size: const Size(400, 800));
    expect(_outlined('共有'), findsOneWidget);
    expect(find.bySemanticsLabel('その他'), findsNothing);
  });

  // 食い違っている行は押すと確認リストを開くので、食い違っていない行を直す
  Future<void> rewrite(WidgetTester tester, String text) async {
    await tester.tap(find.text('・だしは煮干し'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), text);
    await tester.pump();
    await tester.tap(find.widgetWithText(MoonFilledButton, '保存する'));
    await tester.pumpAndSettle();
  }

  Map<String, dynamic> lastEdit(_Server server) {
    final sent = server.sent.lastWhere((x) => x.startsWith('POST /manuals/m1/edits '));
    return jsonDecode(sent.substring('POST /manuals/m1/edits '.length)) as Map<String, dynamic>;
  }

  testWidgets('同じ行をほかの人が先に直していたら、相手と自分の直しを並べ、「自分のにする」で相手の行を書き換える', (tester) async {
    final server = await _pump(tester, shared: true);
    server.conflict = {'line': '- だしは煮干し', 'theirs': '- だしは昆布', 'after': null, 'by': 'かなで', 'at': '2026-11-10'};
    await rewrite(tester, '- だしはかつお');
    expect(find.text('ほかの人が先にこの行を直しました'), findsOneWidget);
    expect(find.text('かなで（11/10）'), findsOneWidget);
    expect(find.descendant(of: find.byType(ConflictPair), matching: find.text('だしは昆布')), findsOneWidget);
    expect(find.descendant(of: find.byType(ConflictPair), matching: find.text('だしはかつお')), findsOneWidget);

    // 外を押しても閉じない
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('ほかの人が先にこの行を直しました'), findsOneWidget);

    await tester.tap(find.widgetWithText(MoonFilledButton, '自分のにする'));
    await tester.pumpAndSettle();
    expect(find.text('ほかの人が先にこの行を直しました'), findsNothing);
    expect(lastEdit(server), allOf(containsPair('op', 'replace'), containsPair('line', '- だしは昆布'), containsPair('text', '- だしはかつお')));
    await tester.pumpAndSettle(const Duration(seconds: 10));
  });

  testWidgets('相手が消していた行は「消しました」と出し、「自分のにする」で元の場所に足す。「相手のままにする」なら何も送らない', (tester) async {
    final server = await _pump(tester, shared: true);
    final gone = {'line': '- だしは煮干し', 'theirs': null, 'after': '- 塩 小さじ1', 'by': 'かなで', 'at': '2026-11-10'};
    server.conflict = {...gone};
    await rewrite(tester, '- だしはかつお');
    expect(find.text('消しました'), findsOneWidget);
    await tester.tap(find.widgetWithText(MoonFilledButton, '自分のにする'));
    await tester.pumpAndSettle();
    expect(lastEdit(server), allOf(containsPair('op', 'insert'), containsPair('line', '- 塩 小さじ1'), containsPair('text', '- だしはかつお')));
    await tester.pumpAndSettle(const Duration(seconds: 10));

    server.conflict = {...gone};
    await rewrite(tester, '- だしはあご');
    final before = server.sent.length;
    await tester.tap(_outlined('相手のままにする'));
    await tester.pumpAndSettle();
    expect(find.text('ほかの人が先にこの行を直しました'), findsNothing);
    expect(server.sent.length, before);
  });

  testWidgets('相手と同じ直しだったら、選ばせずに読み直すだけにする', (tester) async {
    final server = await _pump(tester, shared: true);
    server.conflict = {'line': '- だしは煮干し', 'theirs': '- だしはかつお', 'after': null, 'by': 'かなで', 'at': '2026-11-10'};
    await rewrite(tester, '- だしはかつお');
    expect(find.text('ほかの人が先にこの行を直しました'), findsNothing);
    expect(server.sent.where((x) => x.startsWith('POST /manuals/m1/edits')), hasLength(1));
  });

  Future<_Server> pumpCheck(WidgetTester tester, {required bool shared, Map<String, dynamic>? resolution}) async {
    final server = _Server(shared: shared);
    final state = server.state;
    if (resolution != null) (state['checks'] as List).first['resolution'] = resolution;
    final c = ManualController(server.api, 'm1', ManualState.fromJson(state));
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: appTheme(), home: CheckScreen(c: c, checkId: 'c1')));
    await tester.pumpAndSettle();
    return server;
  }

  testWidgets('確認のページ（持ち主）：誰に確認するか・聞き方の例を出し、聞いた結果を記録する', (tester) async {
    await pumpCheck(tester, shared: false);
    expect(find.text('誰に確認する？'), findsOneWidget);
    expect(find.text('どちらですか？'), findsOneWidget);
    expect(_outlined('聞いた結果を記録する'), findsOneWidget);
    expect(find.text('答えて確定する'), findsNothing);
  });

  testWidgets('確認のページ（共有された人）：誰に確認するか・聞き方の例は出さず、自分の答えとして確定する', (tester) async {
    final server = await pumpCheck(tester, shared: true);
    expect(find.text('誰に確認する？'), findsNothing);
    expect(find.text('どちらですか？'), findsNothing);
    expect(find.text('決める立場'), findsNothing);
    expect(_outlined('聞いた結果を記録する'), findsNothing);
    expect(find.text('確認した相手'), findsNothing);
    // AI の理由は見せる
    expect(find.text('量が違う'), findsOneWidget);

    await tester.tap(find.text('ノートのまま'));
    await tester.pump();
    await tester.tap(find.widgetWithText(MoonFilledButton, '答えて確定する'));
    await tester.pump(const Duration(milliseconds: 500));
    final sent = server.sent.singleWhere((x) => x.startsWith('POST /manuals/m1/checks/c1/resolve'));
    final body = jsonDecode(sent.substring(sent.indexOf('{'))) as Map<String, dynamic>;
    expect(body.containsKey('decidedBy'), isFalse);
    expect(body['text'], '- 塩 小さじ1');
    await tester.pumpAndSettle(const Duration(seconds: 10));
  });

  testWidgets('本人が答えて決めた確認は「が決定」、聞いた結果の記録は「に確認」と出す', (tester) async {
    Map<String, dynamic> res({String? answeredBy}) => {
          'utteranceId': 'u2',
          'patchId': null,
          'decidedBy': '佐藤店長',
          'answeredBy': ?answeredBy,
          'decidedAt': '2026-11-10',
          'text': '- 塩 小さじ1',
          'note': '小さじ1のまま',
        };
    await pumpCheck(tester, shared: false, resolution: res(answeredBy: 'sato'));
    expect(find.text('11/10 佐藤店長が決定：小さじ1のまま'), findsOneWidget);
    expect(find.text('決定'), findsOneWidget);

    await pumpCheck(tester, shared: false, resolution: res());
    expect(find.text('11/10 佐藤店長に確認：小さじ1のまま'), findsOneWidget);
    expect(find.text('決定'), findsNothing);
  });
}
