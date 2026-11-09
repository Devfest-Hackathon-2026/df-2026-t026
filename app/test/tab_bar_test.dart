import 'dart:convert';

import 'package:diff_note/api.dart';
import 'package:diff_note/manual_controller.dart';
import 'package:diff_note/models.dart';
import 'package:diff_note/screens/check_list_screen.dart';
import 'package:diff_note/screens/history_screen.dart';
import 'package:diff_note/screens/manual_screen.dart';
import 'package:diff_note/screens/tab_bar.dart';
import 'package:diff_note/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 塩の量が食い違い、あとで確認が1件ある
Map<String, dynamic> _note() => {
      'manual': {'id': 'm1', 'title': 'キッチン', 'base': '- 塩 小さじ1', 'createdAt': '2026-11-01T00:00:00Z'},
      'lines': [
        {'text': '- 塩 小さじ1', 'patchId': null},
      ],
      'utterances': [
        {'id': 'u1', 'text': '塩は小さじ1/2', 'speaker': '田中さん', 'saidAt': '2026-11-03', 'fromEdit': false, 'createdAt': '2026-11-03T10:00:00Z'},
      ],
      'patches': [
        {
          'id': 'p1',
          'utteranceId': 'u1',
          'op': 'replace',
          'line': '- 塩 小さじ1',
          'text': '- 塩 小さじ1/2',
          'summary': '',
          'status': 'proposed',
          'createdAt': '2026-11-03T10:00:00Z',
          'appliedAt': null,
        },
      ],
      'checks': [
        {
          'id': 'c1',
          'patchId': 'p1',
          'utteranceId': 'u1',
          'kind': 'contradiction',
          'conflictLine': '- 塩 小さじ1',
          'sameLine': null,
          'reason': '量が違う',
          'ask': {'candidates': [], 'question': 'どちらですか？'},
          'resolution': null,
        },
      ],
    };

Api _api() => Api(client: MockClient((_) async => http.Response.bytes(utf8.encode(jsonEncode(_note())), 200)), baseUrl: 'http://api');

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Finder _tab(String label) => find.descendant(of: find.byType(NoteTabBar), matching: find.text(label));

void main() {
  testWidgets('狭い画面：下のタブバーでノート・確認リスト・履歴を、横から出てくる動きなしで行き来する', (tester) async {
    _size(tester, const Size(390, 844));
    await tester.pumpWidget(MaterialApp(theme: appTheme(), home: ManualScreen(api: _api(), manualId: 'm1')));
    await tester.pumpAndSettle();

    expect(find.byType(NoteTabBar), findsOneWidget);
    // 確認リストのタブに、あとで確認の件数を出す
    expect(find.descendant(of: find.byType(NoteTabBar), matching: find.text('1')), findsOneWidget);

    await tester.tap(_tab('確認リスト'));
    await tester.pump(); // 動きが無いので、1枚目の描画で切り替わっている
    expect(find.byType(CheckListScreen), findsOneWidget);
    expect(find.byType(ManualScreen, skipOffstage: true), findsNothing);

    await tester.tap(_tab('履歴'));
    await tester.pump();
    expect(find.byType(HistoryScreen), findsOneWidget);
    // 確認リストは履歴に入れ替わり、積み重ならない
    expect(find.byType(CheckListScreen, skipOffstage: false), findsNothing);

    await tester.tap(_tab('ノート'));
    await tester.pump();
    expect(find.byType(ManualScreen), findsOneWidget);
    expect(find.byType(HistoryScreen, skipOffstage: false), findsNothing);
  });

  testWidgets('広い画面（サイドバーが出る幅）ではタブバーを出さない', (tester) async {
    _size(tester, const Size(1440, 900));
    await tester.pumpWidget(MaterialApp(theme: appTheme(), home: ManualScreen(api: _api(), manualId: 'm1')));
    await tester.pumpAndSettle();
    expect(find.byType(NoteTabBar), findsNothing);
  });

  testWidgets('ノートの外（入力ページなど）から開いた確認リストでは、ノートのタブでそのノートに入れ替える', (tester) async {
    _size(tester, const Size(390, 844));
    final api = _api();
    final c = ManualController(api, 'm1', ManualState.fromJson(_note()));
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: GestureDetector(
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CheckListScreen(c: c))),
              child: const Text('入力ページ'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('入力ページ'));
    await tester.pumpAndSettle();
    expect(find.byType(CheckListScreen), findsOneWidget);

    await tester.tap(_tab('ノート'));
    await tester.pumpAndSettle();
    expect(find.byType(ManualScreen), findsOneWidget);
    expect(find.byType(CheckListScreen, skipOffstage: false), findsNothing);
    // 入力ページへは戻れる（ノートを入力ページの上に開いている）
    expect(find.text('入力ページ', skipOffstage: false), findsOneWidget);
  });
}
