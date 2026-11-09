import 'dart:convert';

import 'package:diff_note/api.dart';
import 'package:diff_note/screens/common.dart';
import 'package:diff_note/screens/home_screen.dart';
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
}
