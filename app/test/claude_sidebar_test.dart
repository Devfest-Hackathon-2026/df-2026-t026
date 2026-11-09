import 'dart:convert';

import 'package:diff_note/api.dart';
import 'package:diff_note/screens/check_list_screen.dart';
import 'package:diff_note/screens/common.dart';
import 'package:diff_note/screens/home_screen.dart';
import 'package:diff_note/screens/new_manual_screen.dart';
import 'package:diff_note/screens/open_checks_screen.dart';
import 'package:diff_note/screens/profile_screen.dart';
import 'package:diff_note/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moon_design/moon_design.dart';

// サイドバーを Claude 型に作り直す（実装18a・PC）

http.Response _json(Object body) => http.Response.bytes(utf8.encode(jsonEncode(body)), 200);

/// 食い違いを n 件かかえたノート
Map<String, dynamic> _state(String id, String title, int open) => {
      'manual': {'id': id, 'title': title, 'base': '- 塩 小さじ1', 'createdAt': '2026-11-01T00:00:00Z'},
      'lines': [
        {'text': '- 塩 小さじ1', 'patchId': null},
      ],
      'utterances': [
        for (var i = 0; i < open; i++)
          {'id': '$id-u$i', 'text': '塩は$i', 'speaker': '田中さん', 'saidAt': '2026-11-03', 'fromEdit': false, 'createdAt': '2026-11-03T10:00:00Z'},
      ],
      'patches': [
        for (var i = 0; i < open; i++)
          {'id': '$id-p$i', 'utteranceId': '$id-u$i', 'op': 'replace', 'line': '- 塩 小さじ1', 'text': '- 塩 $i', 'summary': '', 'status': 'pending', 'createdAt': '2026-11-03T10:00:00Z', 'appliedAt': null},
      ],
      'checks': [
        for (var i = 0; i < open; i++)
          {
            'id': '$id-c$i',
            'patchId': '$id-p$i',
            'utteranceId': '$id-u$i',
            'kind': 'contradiction',
            'conflictLine': '- 塩 小さじ1',
            'sameLine': null,
            'reason': '量が違う',
            'ask': {'candidates': [], 'question': 'どちらですか？'},
            'resolution': null,
          },
      ],
    };

/// 自分は かなで。キッチン（あとで確認 1）・ホール（2）・洗い場（0）に、notes 冊のノートを足す
Api _api({int more = 0}) {
  final manuals = [
    ('m1', 'キッチン', 1),
    ('m2', 'ホール', 2),
    ('m3', '洗い場', 0),
    for (var i = 0; i < more; i++) ('x$i', 'ほかのノート$i', 0),
  ];
  return Api(
    client: MockClient((req) async {
      final path = req.url.path;
      if (path == '/me') return _json({'id': 'kanade', 'name': 'かなで', 'icon': null});
      if (path == '/manuals') {
        return _json([
          for (final (id, title, open) in manuals) {'id': id, 'title': title, 'utteranceCount': open, 'openCount': open},
        ]);
      }
      for (final (id, title, open) in manuals) {
        if (path == '/manuals/$id') return _json(_state(id, title, open));
      }
      return _json([]);
    }),
    baseUrl: 'http://api',
  );
}

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// 広い幅で、サイドバーの出るノート一覧から始める
Future<void> _pump(WidgetTester tester, {int more = 0}) async {
  _size(tester, const Size(1440, 900));
  await tester.pumpWidget(MaterialApp(theme: appTheme(), home: HomeScreen(api: _api(more: more))));
  await tester.pumpAndSettle();
}

Finder _menu(String label) => find.widgetWithText(MoonMenuItem, label);

/// サイドバーの「ノート」の右の＋（読み上げ名「ノートを作る」）。ノート一覧の画面の「ノートを作る」ボタンとは別
Finder _plus() => find.byWidgetPredicate((w) => w is MoonButton && w.semanticLabel == 'ノートを作る');

void main() {
  testWidgets('PC のサイドバーは上から「言われたことを記録」→「あとで確認」→「ノート」と＋→全部のノート→自分。自分はいちばん下', (tester) async {
    await _pump(tester);

    final tops = [
      for (final f in [
        _menu('言われたことを記録'),
        _menu('あとで確認'),
        _menu('ノート'),
        _menu('キッチン'),
        _menu('ホール'),
        _menu('洗い場'),
        _menu('かなで'),
      ])
        tester.getRect(f).top,
    ];
    for (var i = 1; i < tops.length; i++) {
      expect(tops[i], greaterThan(tops[i - 1]), reason: '$i 番目の並び');
    }
    // 自分はいちばん下に固定（画面の下の端から余白 sm だけ上）
    final k = appTheme().extension<AppTokens>()!;
    expect(tester.getRect(_menu('かなで')).bottom, closeTo(900 - k.space.sm, 1));
    // メニューに「ノート」と「ノートを作る」の項目は別に無い（小見出しと＋だけ）
    expect(_menu('ノートを作る'), findsNothing);
    expect(_plus(), findsOneWidget);
    // 項目の高さはそろっている（アイコンの有る項目・無い項目・自分）
    expect({for (final f in [_menu('言われたことを記録'), _menu('あとで確認'), _menu('キッチン'), _menu('かなで')]) tester.getSize(f).height},
        {k.sidebarRow});
  });

  testWidgets('「あとで確認」の件数は、全部のノートのあとで確認の合計', (tester) async {
    await _pump(tester);
    expect(find.descendant(of: _menu('あとで確認'), matching: find.text('3')), findsOneWidget);
    expect(find.descendant(of: _menu('ホール'), matching: find.text('2')), findsOneWidget);
    expect(find.descendant(of: _menu('洗い場'), matching: find.byType(StatusTag)), findsNothing);
  });

  testWidgets('＋を押すとノートを作る画面へ', (tester) async {
    await _pump(tester);
    await tester.tap(_plus());
    await tester.pumpAndSettle();
    expect(find.byType(NewManualScreen), findsOneWidget);
  });

  testWidgets('小見出し「ノート」を押すとノート一覧へ', (tester) async {
    _size(tester, const Size(1440, 900));
    await tester.pumpWidget(MaterialApp(theme: appTheme(), home: ProfileScreen(api: _api())));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ノート').first);
    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);
    // 一覧にいる間は小見出しが選択中の地色
    final k = appTheme().extension<AppTokens>()!;
    expect(tester.widget<MoonMenuItem>(_menu('ノート')).backgroundColor, k.colors.shell);
  });

  testWidgets('「あとで確認」を押すと、全部のノートのあとで確認をまとめた画面へ。そこから確認リストを開ける', (tester) async {
    await _pump(tester);
    await tester.tap(_menu('あとで確認'));
    await tester.pumpAndSettle();

    expect(find.byType(OpenChecksScreen), findsOneWidget);
    final k = appTheme().extension<AppTokens>()!;
    expect(tester.widget<MoonMenuItem>(_menu('あとで確認')).backgroundColor, k.colors.shell);
    final list = find.byType(OpenChecksList);
    expect(find.descendant(of: list, matching: find.text('あとで確認 1 件')), findsOneWidget);
    expect(find.descendant(of: list, matching: find.text('あとで確認 2 件')), findsOneWidget);
    // あとで確認の無いノートは並べない
    expect(find.descendant(of: list, matching: find.text('洗い場')), findsNothing);

    await tester.tap(find.descendant(of: list, matching: find.text('ホール')));
    await tester.pumpAndSettle();
    expect(find.byType(CheckListScreen), findsOneWidget);
    expect(find.text('あとで確認（2）'), findsOneWidget);
  });

  testWidgets('ノートが多いときは、ノートの並びの所だけスクロールし、上の項目と自分は動かない', (tester) async {
    await _pump(tester, more: 30);
    final record = tester.getRect(_menu('言われたことを記録'));
    final me = tester.getRect(_menu('かなで'));
    final eighth = tester.getRect(_menu('ほかのノート8'));

    await tester.drag(_menu('キッチン'), const Offset(0, -300));
    await tester.pumpAndSettle();

    expect(tester.getRect(_menu('言われたことを記録')), record);
    expect(tester.getRect(_menu('かなで')), me);
    // ドラッグの遊び（数 px）があるので、200 以上動いたことを見る
    expect(tester.getRect(_menu('ほかのノート8')).top, lessThan(eighth.top - 200));
  });
}
