import 'dart:convert';

import 'package:diff_note/api.dart';
import 'package:diff_note/screens/common.dart';
import 'package:diff_note/screens/input_screen.dart';
import 'package:diff_note/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moon_design/moon_design.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'home.dart';
import 'input_font.dart';

http.Response _json(Object body, int status) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

void main() {
  testWidgets('ログインを求められ、配った ID とパスワードが合えば入力ページが出て、トークンをブラウザに覚えておく', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final client = MockClient((req) async {
      if (req.url.path == '/login') {
        final body = jsonDecode(req.body);
        return body['id'] == 'taro' && body['password'] == 'pass-taro'
            ? _json({'token': 'token-1'}, 200)
            : _json({'error': 'ID かパスワードが違います'}, 401);
      }
      if (req.headers['Authorization'] != 'Bearer token-1') return _json({'error': 'ログインしてください'}, 401);
      if (req.url.path == '/home') return _json(homeJson([noteJson('m1', 'キッチン')]), 200);
      return _json({
        'owner': 'demo',        'me': 'demo',        'manual': {'id': 'm1', 'title': 'キッチン', 'base': '', 'createdAt': '2026-11-01T00:00:00Z'},
        'lines': [],
        'utterances': [],
        'patches': [],
        'checks': [],
      }, 200);
    });
    await tester.pumpWidget(MaterialApp(theme: appTheme(), home: InputScreen(api: Api(client: client, baseUrl: 'http://api'))));
    await tester.pumpAndSettle();
    expect(find.text('ログインしてください'), findsOneWidget);
    // 初めて開いた人にも、ログインの前に何の道具かが分かる
    expect(find.text(appPurpose), findsOneWidget);
    expectInputFontsAtLeast16(tester, count: 2); // ID・パスワード

    final id = find.byType(MoonTextInput).at(0);
    final password = find.byType(MoonTextInput).at(1);
    await tester.enterText(id, 'taro');
    await tester.enterText(password, 'pass-hanako');
    await tester.tap(find.widgetWithText(MoonFilledButton, 'ログインする'));
    await tester.pumpAndSettle();
    expect(find.text('ID かパスワードが違います'), findsOneWidget);
    expect(find.text('ログインしてください'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10)); // 失敗のトーストが消えるのを待つ

    await tester.enterText(password, 'pass-taro');
    await tester.tap(find.widgetWithText(MoonFilledButton, 'ログインする'));
    await tester.pumpAndSettle();
    expect(find.text('言われたことを記録'), findsOneWidget);
    expect((await SharedPreferences.getInstance()).getString(tokenKey), 'token-1');
  });

  testWidgets('広い画面でログインしたら、サイドバーにすぐノートが並ぶ(ほかの画面を開き直さなくてよい)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final client = MockClient((req) async {
      if (req.url.path == '/login') return _json({'token': 'token-1'}, 200);
      if (req.headers['Authorization'] != 'Bearer token-1') return _json({'error': 'ログインしてください'}, 401);
      if (req.url.path == '/home') {
        return _json(homeJson([noteJson('m1', 'キッチン')], me: {'id': 'taro', 'name': 'たろう', 'icon': null}), 200);
      }
      return _json({
        'owner': 'demo',        'me': 'demo',        'manual': {'id': 'm1', 'title': 'キッチン', 'base': '', 'createdAt': '2026-11-01T00:00:00Z'},
        'lines': [],
        'utterances': [],
        'patches': [],
        'checks': [],
      }, 200);
    });
    await tester.pumpWidget(MaterialApp(theme: appTheme(), home: InputScreen(api: Api(client: client, baseUrl: 'http://api'))));
    await tester.pumpAndSettle();
    expect(find.text('ログインしてください'), findsOneWidget);
    expect(find.descendant(of: find.byType(MoonMenuItem), matching: find.text('キッチン')), findsNothing);

    await tester.enterText(find.byType(MoonTextInput).at(0), 'taro');
    await tester.enterText(find.byType(MoonTextInput).at(1), 'pass');
    await tester.tap(find.widgetWithText(MoonFilledButton, 'ログインする'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(MoonMenuItem), matching: find.text('キッチン')), findsOneWidget);
  });
}
