import 'dart:convert';

import 'package:diff_note/api.dart';
import 'package:diff_note/screens/common.dart';
import 'package:diff_note/screens/check_screen.dart';
import 'package:diff_note/screens/history_screen.dart';
import 'package:diff_note/screens/home_screen.dart';
import 'package:diff_note/screens/manual_screen.dart';
import 'package:diff_note/screens/new_manual_screen.dart';
import 'package:diff_note/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:moon_design/moon_design.dart';

// 違和感メモの小さな直し（実装17）

Api _emptyApi() => Api(client: MockClient((_) async => http.Response('[]', 200)), baseUrl: 'http://api');

http.Response _json(Object body) => http.Response.bytes(utf8.encode(jsonEncode(body)), 200);

/// 自分は かなで、ノートは無い（サイドバーを出すため）
Api _meApi() => Api(
    client: MockClient((req) async => req.url.path == '/me'
        ? _json({'id': 'kanade', 'name': 'かなで', 'icon': null})
        : _json([])),
    baseUrl: 'http://api');

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// 塩の量の食い違いを店長に確認して 1/2 に決めた（確認して決めた行が1つある）
Map<String, dynamic> _confirmed() => {
      'manual': {'id': 'm1', 'title': 'キッチン', 'base': '- 塩 小さじ1', 'createdAt': '2026-11-01T00:00:00Z'},
      'lines': [
        {'text': '- 塩 小さじ1/2', 'patchId': 'p2'},
      ],
      'utterances': [
        {'id': 'u1', 'text': '塩は小さじ1/2', 'speaker': '田中さん', 'saidAt': '2026-11-03', 'fromEdit': false, 'createdAt': '2026-11-03T10:00:00Z'},
        {'id': 'u2', 'text': '1/2で統一', 'speaker': '店長', 'saidAt': '2026-11-07', 'fromEdit': false, 'createdAt': '2026-11-07T10:00:00Z'},
      ],
      'patches': [
        {'id': 'p1', 'utteranceId': 'u1', 'op': 'replace', 'line': '- 塩 小さじ1', 'text': '- 塩 小さじ1/2', 'summary': '', 'status': 'discarded', 'createdAt': '2026-11-03T10:00:00Z', 'appliedAt': null},
        {'id': 'p2', 'utteranceId': 'u2', 'op': 'replace', 'line': '- 塩 小さじ1', 'text': '- 塩 小さじ1/2', 'summary': '', 'status': 'applied', 'createdAt': '2026-11-07T10:00:00Z', 'appliedAt': '2026-11-07T10:00:00Z'},
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
          'resolution': {'utteranceId': 'u2', 'patchId': null, 'decidedBy': '店長', 'decidedAt': '2026-11-07', 'text': '- 塩 小さじ1/2', 'note': '1/2で統一'},
        },
      ],
    };

Api _confirmedApi() => Api(client: MockClient((_) async => _json(_confirmed())), baseUrl: 'http://api');

Finder _inTopBar(Finder f) => find.descendant(of: find.byType(TopBar), matching: f);

void main() {
  group('上部バー（違和感 #11）', () {
    for (final size in const [Size(390, 844), Size(1000, 900)]) {
      testWidgets('サイドバーの出ない幅（$size）では、パンくずを出さず、いまの画面の名前だけ', (tester) async {
        _size(tester, size);
        await tester.pumpWidget(MaterialApp(theme: appTheme(), home: NewManualScreen(api: _emptyApi())));
        await tester.pumpAndSettle();
        expect(_inTopBar(find.text('ノートを作る')), findsOneWidget);
        expect(_inTopBar(find.text('DiffNote（仮）')), findsNothing);
        expect(_inTopBar(find.text(' / ')), findsNothing);
      });
    }

    testWidgets('広い幅（サイドバーが出る）では、パンくずは今のまま', (tester) async {
      _size(tester, const Size(1440, 900));
      await tester.pumpWidget(MaterialApp(theme: appTheme(), home: NewManualScreen(api: _emptyApi())));
      await tester.pumpAndSettle();
      expect(_inTopBar(find.text('DiffNote（仮）')), findsOneWidget);
      expect(_inTopBar(find.text(' / ')), findsOneWidget);
      expect(_inTopBar(find.text('ノートを作る')), findsOneWidget);
    });
  });

  testWidgets('サイドバーの「言われたことを記録」の左にペンのアイコン。文字の頭は自分の名前とそろう（違和感 #4）', (tester) async {
    _size(tester, const Size(1440, 900));
    await tester.pumpWidget(MaterialApp(theme: appTheme(), home: NewManualScreen(api: _meApi())));
    await tester.pumpAndSettle();
    final record = find.widgetWithText(MoonMenuItem, '言われたことを記録');
    expect(find.descendant(of: record, matching: find.byIcon(LucideIcons.squarePen)), findsOneWidget);
    final name = find.descendant(of: find.widgetWithText(MoonMenuItem, 'かなで'), matching: find.text('かなで'));
    expect(tester.getTopLeft(find.text('言われたことを記録')).dx, closeTo(tester.getTopLeft(name).dx, 1));
  });

  group('サイドバーからの移動に動きを付けない（違和感 #1）', () {
    /// 最初の画面（入力ページの代わり）の上に、ふつうの横から出る動きで「ノートを作る」を開いた状態
    Future<void> openNewManualOnTop(WidgetTester tester) async {
      _size(tester, const Size(1440, 900));
      final api = _meApi();
      await tester.pumpWidget(MaterialApp(
        theme: appTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: GestureDetector(
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => NewManualScreen(api: api))),
              child: const Text('最初の画面'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('最初の画面'));
      await tester.pumpAndSettle();
      expect(find.byType(NewManualScreen), findsOneWidget);
    }

    testWidgets('サイドバーの「ノート」：時間を進めなくても、すぐノート一覧になり、前の画面は残らない', (tester) async {
      await openNewManualOnTop(tester);
      await tester.tap(find.widgetWithText(MoonMenuItem, 'ノート'));
      // 時間は進めない（ふつうの動きなら 300ms かかる）。1枚目は Hero の下調べで画面に出ないことがあるので2枚まで見る
      await tester.pump();
      await tester.pump();
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(NewManualScreen, skipOffstage: false), findsNothing);
      // 動いている途中の画面が無い（いちばん上の画面がそのまま全部見えている）
      expect(tester.getTopLeft(find.byType(HomeScreen)).dx, 0);
    });

    testWidgets('サイドバーの「言われたことを記録」：時間を進めなくても、すぐ最初の画面に戻り、戻る動きが無い', (tester) async {
      await openNewManualOnTop(tester);
      await tester.tap(find.widgetWithText(MoonMenuItem, '言われたことを記録'));
      await tester.pump();
      expect(find.text('最初の画面'), findsOneWidget);
      expect(find.byType(NewManualScreen, skipOffstage: false), findsNothing);
    });
  });

  group('ノートの行の小さい確認印をやめる', () {
    for (final size in const [Size(390, 844), Size(1440, 900)]) {
      testWidgets('確認して決めた行は、小さい確認印でなく「店長 11/7 に確認」。押すと確認の記録（大きい確認印）を開く（$size）', (tester) async {
        _size(tester, size);
        await tester.pumpWidget(MaterialApp(theme: appTheme(), home: ManualScreen(api: _confirmedApi(), manualId: 'm1')));
        await tester.pumpAndSettle();
        final manual = find.byType(ManualScreen);
        expect(find.descendant(of: manual, matching: find.byType(ConfirmStamp)), findsNothing);
        // 広い画面では右の「記録した発言」にも店長の付箋が出るので、本文（先に並ぶ）の方を見る
        final who = find.descendant(of: manual, matching: find.widgetWithText(Speaker, '店長')).first;
        expect(find.ancestor(of: who, matching: find.byType(StickyNote)), findsNothing);
        expect(find.descendant(of: manual, matching: find.text('に確認')), findsOneWidget);

        await tester.tap(who);
        await tester.pumpAndSettle();
        // 確認の記録には、大きい確認印が残っている（広い画面では確認リストの右、狭い画面では確認のページ）
        final big = tester.widgetList<ConfirmStamp>(find.byType(ConfirmStamp)).where((s) => !s.compact);
        expect(big, isNotEmpty);
        if (size.width < 900) expect(find.byType(CheckScreen), findsOneWidget);
      });
    }

    testWidgets('履歴でも、確定した版に小さい確認印を出さず、誰に確認したかを文で出す', (tester) async {
      _size(tester, const Size(1440, 900));
      await tester.pumpWidget(MaterialApp(theme: appTheme(), home: ManualScreen(api: _confirmedApi(), manualId: 'm1')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MoonOutlinedButton, '履歴'));
      await tester.pumpAndSettle();
      final history = find.byType(HistoryScreen);
      expect(find.descendant(of: history, matching: find.byType(ConfirmStamp)), findsNothing);
      expect(find.descendant(of: history, matching: find.textContaining('11/7 に確認')), findsWidgets);
    });
  });
}
