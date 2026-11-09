import 'dart:convert';

import 'package:diff_note/api.dart';
import 'package:diff_note/screens/common.dart';
import 'package:diff_note/screens/home_screen.dart';
import 'package:diff_note/screens/manual_screen.dart';
import 'package:diff_note/screens/search_screen.dart';
import 'package:diff_note/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moon_design/moon_design.dart';

http.Response _json(Object body) => http.Response.bytes(utf8.encode(jsonEncode(body)), 200);

Map<String, dynamic> _state(String id, String title, List<String> lines, {bool shared = false}) => {
      'manual': {'id': id, 'title': title, 'base': lines.join('\n'), 'createdAt': '2026-11-01T00:00:00Z'},
      'lines': [
        for (final l in lines) {'text': l, 'patchId': null},
      ],
      'utterances': [],
      'patches': [],
      'checks': [],
      if (shared) 'sharedBy': {'id': 'haruto', 'name': 'はると'},
    };

/// 自分のノート2冊（キッチン・ホール）と、共有されたノート1冊（洗い場）
Api _api() {
  final states = {
    'm1': _state('m1', 'キッチン', ['## 下ごしらえ', '- 塩 小さじ1', '---', '- 砂糖 大さじ2']),
    'm2': _state('m2', 'ホール', ['- **塩**をテーブルに置く', for (var i = 0; i < 60; i++) '- 段取り$i', '- 閉店後に床を拭く']),
    's1': _state('s1', '洗い場', ['- Soap を使う'], shared: true),
  };
  return Api(
    client: MockClient((req) async {
      final path = req.url.path;
      if (path == '/me') return _json({'id': 'tester', 'name': 'テスト', 'icon': null});
      if (path == '/manuals') {
        return _json([
          for (final id in ['m1', 'm2']) {'id': id, 'title': states[id]!['manual']['title'], 'utteranceCount': 0, 'openCount': 0},
        ]);
      }
      if (path == '/shared') {
        return _json([
          {'id': 's1', 'title': '洗い場', 'sharedBy': {'id': 'haruto', 'name': 'はると'}, 'openCount': 0},
        ]);
      }
      for (final MapEntry(:key, :value) in states.entries) {
        if (path == '/manuals/$key') return _json(value);
      }
      return _json([]);
    }),
    baseUrl: 'http://api',
  );
}

Future<void> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: appTheme(), home: SearchScreen(api: _api())));
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, String q) async {
  await tester.enterText(find.byType(MoonTextInput), q);
  await tester.pumpAndSettle();
}

// サイドバーにも同じ題名が並ぶので、結果は白い面の中だけを見る
Finder _inResults(String text) =>
    find.descendant(of: find.byType(PaperSheet), matching: find.text(text, findRichText: true));

void main() {
  testWidgets('サイドバーの「ノートを探す」は「あとで確認」の下にあり、押すと探す画面へ', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: appTheme(), home: HomeScreen(api: _api())));
    await tester.pumpAndSettle();

    final item = find.widgetWithText(MoonMenuItem, 'ノートを探す');
    expect(tester.getRect(item).top, greaterThan(tester.getRect(find.widgetWithText(MoonMenuItem, 'あとで確認')).top));
    await tester.tap(item);
    await tester.pumpAndSettle();
    expect(find.byType(SearchScreen), findsOneWidget);
  });

  testWidgets('言葉を入れる前は何も並べない', (tester) async {
    await _pump(tester);
    expect(_inResults('塩 小さじ1'), findsNothing);
  });

  testWidgets('本文から探し、当たった行をノートごとに並べる。マークダウンの印は外して見せる', (tester) async {
    await _pump(tester);
    await _type(tester, '塩');

    expect(_inResults('キッチン'), findsOneWidget);
    expect(_inResults('塩 小さじ1'), findsOneWidget);
    expect(_inResults('ホール'), findsOneWidget);
    expect(_inResults('塩をテーブルに置く'), findsOneWidget);
    // 当たらない行・ノートは出さない
    expect(_inResults('砂糖 大さじ2'), findsNothing);
    expect(_inResults('洗い場'), findsNothing);
  });

  testWidgets('題名だけ当たったノートも出す。英字は大文字・小文字を区別せず、共有されたノートも探す', (tester) async {
    await _pump(tester);
    await _type(tester, 'ホール');
    expect(_inResults('ホール'), findsOneWidget);
    expect(_inResults('塩をテーブルに置く'), findsNothing);

    await _type(tester, 'soap');
    expect(_inResults('洗い場'), findsOneWidget);
    expect(_inResults('Soap を使う'), findsOneWidget);
  });

  testWidgets('マークダウンの印や区切り線には当てない', (tester) async {
    await _pump(tester);
    await _type(tester, '-');
    expect(find.text('「-」が書かれたノートはありません'), findsOneWidget);
  });

  testWidgets('当たった行を押すと、そのノートを開いてその行まで送り、探した言葉に地を付ける', (tester) async {
    await _pump(tester);
    await _type(tester, '床');
    await tester.tap(_inResults('閉店後に床を拭く'));
    await tester.pumpAndSettle();
    expect(find.byType(ManualScreen), findsOneWidget);

    // 本文の下の方の行でも、画面の中に見えている
    final line = find.text('・閉店後に床を拭く', findRichText: true);
    expect(tester.getRect(line).top, inInclusiveRange(0, 900));
    final k = appTheme().extension<AppTokens>()!;
    final spans = <TextSpan>[];
    tester.widget<RichText>(line).text.visitChildren((s) {
      if (s is TextSpan && s.text != null) spans.add(s);
      return true;
    });
    expect([for (final s in spans) if (s.style?.backgroundColor == k.colors.found) s.text], ['床']);
  });
}
