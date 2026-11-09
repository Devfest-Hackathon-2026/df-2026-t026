import 'dart:convert';

import 'package:diff_note/api.dart';
import 'package:diff_note/models.dart';
import 'package:diff_note/screens/common.dart';
import 'package:diff_note/screens/input_screen.dart';
import 'package:diff_note/screens/profile_screen.dart';
import 'package:diff_note/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moon_design/moon_design.dart';

import 'input_font.dart';

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

// 1×1 の PNG
final _png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=');

/// 自分は kanade（名前は未設定）、ノートは無い。PUT /me は送った内容を sent に残して返す
MockClient _client(List<Map<String, dynamic>> sent) => MockClient((req) async {
      if (req.url.path == '/me' && req.method == 'PUT') {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        sent.add(body);
        return _json({'id': 'kanade', ...body});
      }
      if (req.url.path == '/me') return _json({'id': 'kanade', 'name': 'kanade', 'icon': null});
      if (req.url.path == '/manuals') return _json([]);
      return _json({'error': '見つかりません'}, 404);
    });

void main() {
  testWidgets('名前とアイコンを変えて保存する。アイコンは外せ、画像でないものは選べない', (tester) async {
    final sent = <Map<String, dynamic>>[];
    var picked = (name: 'メモ.pdf', type: '', bytes: _png);
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(),
      home: ProfileScreen(api: Api(client: _client(sent), baseUrl: 'http://api'), pickImage: () async => picked),
    ));
    await tester.pumpAndSettle();
    expect(find.text('ログイン ID：kanade'), findsOneWidget);
    expectInputFontsAtLeast16(tester, count: 1); // 名前
    expect(find.widgetWithText(MoonTextButton, 'アイコンを外す'), findsNothing);

    await tester.tap(find.widgetWithText(MoonOutlinedButton, 'アイコンを選ぶ'));
    await tester.pump(const Duration(milliseconds: 500)); // トーストは少し遅れて出る
    expect(find.text('アイコンにできるのは PNG・JPEG・WebP の画像です'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10)); // トーストが消えるのを待つ

    picked = (name: '顔.PNG', type: '', bytes: _png);
    await tester.tap(find.widgetWithText(MoonOutlinedButton, 'アイコンを選ぶ'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(MoonTextInput), ' かなで ');
    await tester.tap(find.widgetWithText(MoonFilledButton, '保存する'));
    await tester.pumpAndSettle();
    expect(sent.last, {
      'name': 'かなで',
      'icon': {'mimeType': 'image/png', 'data': base64Encode(_png)},
    });
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('名前とアイコンを保存しました'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));

    await tester.tap(find.widgetWithText(MoonTextButton, 'アイコンを外す'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MoonFilledButton, '保存する'));
    await tester.pumpAndSettle();
    expect(sent.last, {'name': 'かなで', 'icon': null});
    await tester.pump(const Duration(seconds: 10));

    // 名前を空にしたら保存できない
    await tester.enterText(find.byType(MoonTextInput), ' ');
    await tester.pump();
    expect(tester.widget<MoonFilledButton>(find.widgetWithText(MoonFilledButton, '保存する')).onTap, isNull);
  });

  testWidgets('広い画面ではサイドバーのいちばん上の自分の名前から開く', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: appTheme(), home: InputScreen(api: Api(client: _client([]), baseUrl: 'http://api'))));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('名前とアイコンを変える'), findsNothing);

    await tester.tap(find.widgetWithText(MoonMenuItem, 'kanade'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(PageTitle), matching: find.text('名前とアイコン')), findsOneWidget);
  });

  testWidgets('狭い画面では、上部バーの三本線から出るメニューのいちばん下の自分の名前から開く', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: appTheme(), home: InputScreen(api: Api(client: _client([]), baseUrl: 'http://api'))));
    await tester.pumpAndSettle();
    // 上部バーの右の自分のアイコンはやめた（メニューから行ける）
    expect(find.bySemanticsLabel('名前とアイコンを変える'), findsNothing);

    await tester.tap(find.byWidgetPredicate((w) => w is MoonButton && w.semanticLabel == 'メニュー'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MoonMenuItem, 'kanade'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(PageTitle), matching: find.text('名前とアイコン')), findsOneWidget);
  });

  test('アイコンが無ければ null、あれば画像のバイト列にする', () {
    expect(Me.fromJson({'id': 'kanade', 'name': 'かなで', 'icon': null}).icon, isNull);
    final me = Me.fromJson({
      'id': 'kanade',
      'name': 'かなで',
      'icon': {'mimeType': 'image/jpeg', 'data': base64Encode(_png)},
    });
    expect(me.icon?.mimeType, 'image/jpeg');
    expect(me.icon?.bytes, _png);
  });
}
