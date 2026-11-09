import 'dart:convert';
import 'dart:typed_data';

import 'package:diff_note/api.dart';
import 'package:diff_note/screens/common.dart';
import 'package:diff_note/screens/manual_screen.dart';
import 'package:diff_note/screens/new_manual_screen.dart';
import 'package:diff_note/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moon_design/moon_design.dart';

import 'input_font.dart';

final _blank = {
  'manual': {'id': 'm1', 'title': '自分用メモ', 'base': '', 'createdAt': '2026-11-08T00:00:00Z'},
  'lines': [],
  'utterances': [],
  'patches': [],
  'checks': [],
};

http.Response _json(Object body, int status) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

Future<void> _pump(WidgetTester tester, Widget screen, {double height = 900}) async {
  tester.view.physicalSize = Size(1280, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: appTheme(), home: screen));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('本文を空のままでも、題名だけで白紙から始め、そのまま開いて書ける', (tester) async {
    Map<String, dynamic>? sent;
    final client = MockClient((req) async {
      if (req.method == 'POST') sent = jsonDecode(req.body) as Map<String, dynamic>;
      return _json(_blank, req.method == 'POST' ? 201 : 200);
    });
    await _pump(tester, NewManualScreen(api: Api(client: client, baseUrl: 'http://api')));
    expectInputFontsAtLeast16(tester, count: 2); // 題名・最初の本文

    // 題名が無いうちは押せない
    final blank = find.widgetWithText(MoonFilledButton, '白紙から始める');
    expect(tester.widget<MoonFilledButton>(blank).onTap, isNull);

    await tester.enterText(find.byType(EditableText).first, '自分用メモ');
    await tester.pump();
    expect(tester.widget<MoonFilledButton>(blank).onTap, isNotNull);

    await tester.tap(blank);
    await tester.pumpAndSettle();
    expect(sent, {'title': '自分用メモ', 'body': ''});
    expect(find.byType(ManualScreen), findsOneWidget);
    expect(find.widgetWithText(MoonTextButton, '行を足す'), findsOneWidget);
  });

  testWidgets('貼った平文を AI に整えさせ、案をモーダルで見てから受け入れると、整えた本文で作る', (tester) async {
    const formatted = '## 仕込み\n- 野菜を切る\n- 塩は小さじ1';
    final sent = <String, Object?>{};
    final client = MockClient((req) async {
      if (req.method == 'POST') sent[req.url.path] = jsonDecode(req.body);
      if (req.url.path == '/format') return _json({'text': formatted}, 200);
      return _json(_blank, req.method == 'POST' ? 201 : 200);
    });
    // 案と作るボタンまでが1画面に収まる高さにする
    await _pump(tester, NewManualScreen(api: Api(client: client, baseUrl: 'http://api')), height: 1600);
    final format = find.widgetWithText(MoonOutlinedButton, 'マークダウンに整える');
    String body() => tester.widget<EditableText>(find.byType(EditableText).at(1)).controller.text;

    // 本文が空のうちは整えられない
    expect(tester.widget<MoonOutlinedButton>(format).onTap, isNull);
    await tester.enterText(find.byType(EditableText).first, 'キッチン');
    await tester.enterText(find.byType(EditableText).at(1), '仕込み\n野菜を切る 塩は小さじ1');
    await tester.pump();

    await tester.tap(format);
    await tester.pumpAndSettle();
    expect(sent['/format'], {'text': '仕込み\n野菜を切る 塩は小さじ1'});
    // 案はモーダルで見せるだけで、本文はまだ変えない。増減の印を付けず、ノートと同じ見た目で3行並べる
    expect(find.text('AI が整えた案'), findsOneWidget);
    expect(body(), '仕込み\n野菜を切る 塩は小さじ1');
    expect(find.byType(LineText), findsNWidgets(3));
    expect(find.text('+'), findsNothing);

    // やめると本文は変わらない
    await tester.tap(find.widgetWithText(MoonTextButton, 'やめる'));
    await tester.pumpAndSettle();
    expect(find.text('AI が整えた案'), findsNothing);
    expect(body(), '仕込み\n野菜を切る 塩は小さじ1');

    await tester.tap(format);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MoonFilledButton, 'この形にする'));
    await tester.pumpAndSettle();
    expect(body(), formatted);
    expect(find.text('AI が整えた案'), findsNothing);

    // 今の本文も、同じ見た目のモーダルで見られる
    await tester.tap(find.widgetWithText(MoonOutlinedButton, 'ノートの形で見る'));
    await tester.pumpAndSettle();
    expect(find.byType(LineText), findsNWidgets(3));
    await tester.tap(find.widgetWithText(MoonOutlinedButton, '閉じる'));
    await tester.pumpAndSettle();
    expect(find.byType(LineText), findsNothing);

    await tester.tap(find.widgetWithText(MoonFilledButton, 'この内容で作る'));
    await tester.pumpAndSettle();
    expect(sent['/manuals'], {'title': 'キッチン', 'body': formatted});
  });

  testWidgets('PDF を選ぶと、読み取った文で本文を置き換え、空の題名には AI の題名を入れる', (tester) async {
    final sent = <String, Object?>{};
    final client = MockClient((req) async {
      if (req.method == 'POST') sent[req.url.path] = jsonDecode(req.body);
      if (req.url.path == '/read') return _json({'title': 'キッチンマニュアル', 'text': '仕込み\n野菜を切る'}, 200);
      return _json(_blank, req.method == 'POST' ? 201 : 200);
    });
    var picked = [(name: 'manual.pdf', type: '', bytes: Uint8List.fromList([37, 80, 68, 70]))];
    await _pump(
      tester,
      NewManualScreen(api: Api(client: client, baseUrl: 'http://api'), pickFiles: () async => picked),
      height: 1600,
    );
    String text(int i) => tester.widget<EditableText>(find.byType(EditableText).at(i)).controller.text;
    Future<void> pick() async {
      // メニューを挟まず、押すとすぐ選ぶ
      await tester.tap(find.widgetWithText(MoonOutlinedButton, 'ファイルから読み取る'));
      await tester.pumpAndSettle();
    }

    await tester.enterText(find.byType(EditableText).at(1), '書きかけ');
    await pick();
    expect(sent['/read'], {
      'files': [
        {'mimeType': 'application/pdf', 'data': 'JVBERg=='},
      ],
    });
    expect(text(0), 'キッチンマニュアル');
    expect(text(1), '仕込み\n野菜を切る');

    // 入れてある題名は変えない
    await tester.enterText(find.byType(EditableText).first, '仕込み');
    await pick();
    expect(text(0), '仕込み');

    // 受け付けない形式は送らない
    sent.clear();
    picked = [(name: 'memo.txt', type: 'text/plain', bytes: Uint8List.fromList([1]))];
    await tester.tap(find.widgetWithText(MoonOutlinedButton, 'ファイルから読み取る'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(sent, isEmpty);
    expect(find.textContaining('読み取れるのは PDF と画像'), findsOneWidget);
    // 知らせが消えるまで待つ
    await tester.pumpAndSettle(const Duration(seconds: 10));
  });

  testWidgets('長い本文も、ノートの形で見るモーダルからはみ出さず、中を送って読める', (tester) async {
    final client = MockClient((_) async => _json(_blank, 200));
    await _pump(tester, NewManualScreen(api: Api(client: client, baseUrl: 'http://api')), height: 1600);
    await tester.enterText(find.byType(EditableText).at(1), [for (var i = 1; i <= 200; i++) '- 決まり$i'].join('\n'));
    await tester.pump();

    await tester.tap(find.widgetWithText(MoonOutlinedButton, 'ノートの形で見る'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    Finder inModal(Finder f) => find.descendant(of: find.byType(MoonModal), matching: f);
    await tester.dragUntilVisible(
        inModal(find.textContaining('決まり200')), inModal(find.byType(SingleChildScrollView)), const Offset(0, -300));
    expect(find.widgetWithText(MoonOutlinedButton, '閉じる').hitTestable(), findsOneWidget);
  });

  testWidgets('白紙のノートは、直接書くか記録すると書き足されることを案内する', (tester) async {
    final client = MockClient((_) async => _json(_blank, 200));
    await _pump(tester, ManualScreen(api: Api(client: client, baseUrl: 'http://api'), manualId: 'm1'));

    expect(find.textContaining('まだ白紙です'), findsOneWidget);
  });
}
