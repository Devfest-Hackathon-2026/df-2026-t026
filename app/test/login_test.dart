import 'dart:async';
import 'dart:convert';

import 'package:diff_note/api.dart';
import 'package:diff_note/screens/common.dart';
import 'package:diff_note/screens/input_screen.dart';
import 'package:diff_note/screens/profile_screen.dart';
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

/// taro と hana の2人のサーバー。トークンごとに、その人の自分・ノート・未整理メモ・通知を返す。
/// taroGate があれば、taro の GET /home と POST /memos は、受けてからそれが済むまで返さない
class _Users {
  final tokens = <String, String>{'token-taro': 'taro'};
  var _issued = 0;
  Completer<void>? taroGate;

  /// GET /home を受けた回数と、true の間は GET /home を 500 にする
  var homes = 0;
  var failHome = false;

  static final _taro = homeJson(
    [noteJson('m1', 'キッチン', open: 1)],
    me: {'id': 'taro', 'name': 'たろう', 'icon': null},
    memos: [
      {'id': 'memo1', 'at': '2026-11-10T01:00:00.000Z', 'text': 'たろうのメモ'},
    ],
    notices: {
      'seenAt': null,
      'items': [
        {
          'id': 'u9',
          'kind': 'edit',
          'manualId': 'm1',
          'title': 'キッチン',
          'by': {'id': 'sato', 'name': '佐藤店長'},
          'at': '2026-11-10T02:00:00.000Z',
          'op': 'insert',
          'line': null,
          'text': '- 手を洗う',
        },
      ],
    },
  );
  static final _hana = homeJson([noteJson('m2', 'ホール')], me: {'id': 'hana', 'name': 'はな', 'icon': null});

  late final client = MockClient((req) async {
    final token = req.headers['Authorization']?.replaceFirst('Bearer ', '');
    if (req.url.path == '/login') {
      final id = jsonDecode(req.body)['id'] as String;
      final t = 'token-$id-${++_issued}';
      tokens[t] = id;
      return _json({'token': t}, 200);
    }
    final user = tokens[token];
    if (user == null) return _json({'error': 'ログインしてください'}, 401);
    if (req.url.path == '/logout') {
      tokens.remove(token);
      return _json({'ok': true}, 200);
    }
    if (req.url.path == '/home') homes++;
    if (user == 'taro') await taroGate?.future;
    if (req.url.path == '/home' && failHome) return _json({'error': '混んでいます'}, 500);
    if (req.url.path == '/home') return _json(user == 'taro' ? _taro : _hana, 200);
    if (req.url.path == '/memos') return _json({'id': 'memo-$user', ...jsonDecode(req.body) as Map<String, dynamic>}, 201);
    return _json(user == 'taro' ? noteJson('m1', 'キッチン', open: 1) : noteJson('m2', 'ホール'), 200);
  });
}

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

  testWidgets('名前とアイコンのページでログアウトすると、サーバーでトークンを止め、ブラウザからも消して、ログインの欄に戻る', (tester) async {
    SharedPreferences.setMockInitialValues({tokenKey: 'token-1'});
    var live = true;
    final client = MockClient((req) async {
      if (req.url.path == '/logout' && req.headers['Authorization'] == 'Bearer token-1') {
        live = false;
        return _json({'ok': true}, 200);
      }
      if (!live || req.headers['Authorization'] != 'Bearer token-1') return _json({'error': 'ログインしてください'}, 401);
      if (req.url.path == '/home') return _json(homeJson([], me: {'id': 'taro', 'name': 'たろう', 'icon': null}), 200);
      return _json([], 200);
    });
    final api = Api(client: client, baseUrl: 'http://api', token: 'token-1');
    await tester.pumpWidget(MaterialApp(theme: appTheme(), home: InputScreen(api: api)));
    await tester.pumpAndSettle();
    tester.state<NavigatorState>(find.byType(Navigator)).push(MaterialPageRoute(builder: (_) => ProfileScreen(api: api)));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(MoonOutlinedButton, 'ログアウトする'));
    await tester.pumpAndSettle();
    expect(live, isFalse);
    expect(api.token, isNull);
    expect((await SharedPreferences.getInstance()).getString(tokenKey), isNull);
    expect(find.text('ログインしてください'), findsOneWidget);
    // 前の画面には戻れない
    expect(tester.state<NavigatorState>(find.byType(Navigator)).canPop(), isFalse);
  });

  testWidgets('ログアウトすると store を空にしてログインの欄を出し、別の ID でログインし直しても前の人の中身を一瞬も出さない', (tester) async {
    SharedPreferences.setMockInitialValues({tokenKey: 'token-taro'});
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final users = _Users();
    final api = Api(client: users.client, baseUrl: 'http://api', token: 'token-taro');
    await tester.pumpWidget(MaterialApp(theme: appTheme(), home: InputScreen(api: api)));
    await tester.pumpAndSettle();
    expect(find.text('キッチン'), findsWidgets);
    expect(find.text('たろうのメモ'), findsOneWidget);
    await tester.enterText(find.byType(MoonTextArea), '書きかけ');
    await tester.pump();

    tester.state<NavigatorState>(find.byType(Navigator)).push(MaterialPageRoute(builder: (_) => ProfileScreen(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MoonOutlinedButton, 'ログアウトする'));
    await tester.pumpAndSettle();

    final store = api.store;
    expect([store.me, store.notes, store.notices], [null, null, null]);
    expect(store.memos, isEmpty);
    expect(find.text('ログインしてください'), findsOneWidget);
    expect(find.text('キッチン'), findsNothing);
    expect(find.text('たろう'), findsNothing);

    await tester.enterText(find.byType(MoonTextInput).at(0), 'hana');
    await tester.enterText(find.byType(MoonTextInput).at(1), 'pass-hana');
    await tester.tap(find.widgetWithText(MoonFilledButton, 'ログインする'));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('キッチン'), findsNothing);
      expect(find.text('たろうのメモ'), findsNothing);
    }
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(MoonMenuItem), matching: find.text('ホール')), findsOneWidget);
    expect(find.descendant(of: find.byType(MoonMenuItem), matching: find.text('はな')), findsOneWidget);
    // 前の人の通知の数・あとで確認の数・書きかけも出さない
    expect(find.descendant(of: find.byType(MoonMenuItem), matching: find.byType(StatusTag)), findsNothing);
    expect(find.text('書きかけ'), findsNothing);
  });

  test('ログアウトの前に読み始めた読み込みと書き込みの応答が、別の人でログインし直したあとに届いても入れない', () async {
    final users = _Users();
    final api = Api(client: users.client, baseUrl: 'http://api', token: 'token-taro');
    await api.store.load();
    expect([for (final n in api.store.notes!) n.id], ['m1']);

    users.taroGate = Completer();
    final stale = api.store.load();
    final memo = api.addMemo(DateTime.utc(2026, 11, 10), 'たろうが送っていたメモ');
    await api.logout();
    await api.login('hana', 'pass-hana');
    await api.store.load();
    expect([for (final n in api.store.notes!) n.id], ['m2']);

    users.taroGate!.complete();
    await stale;
    await expectLater(memo, throwsA(isA<ApiException>()));
    expect([for (final n in api.store.notes!) n.id], ['m2']);
    expect(api.store.me?.id, 'hana');
    expect(api.store.memos, isEmpty);
    expect(api.store.notices?.items, isEmpty);
    expect(api.store.error, isNull);
  });

  testWidgets('ほかのタブでログアウトして読み直しが 401 になったら、ログインの欄の横に前の人のノートと名前を出さない', (tester) async {
    SharedPreferences.setMockInitialValues({tokenKey: 'token-taro'});
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final users = _Users();
    final api = Api(client: users.client, baseUrl: 'http://api', token: 'token-taro');
    await tester.pumpWidget(MaterialApp(theme: appTheme(), home: InputScreen(api: api)));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(MoonMenuItem), matching: find.text('キッチン')), findsWidgets);

    // ほかのタブでログアウトした。戻ってきて読み直すと 401
    users.tokens.remove('token-taro');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('ログインしてください'), findsOneWidget);
    expect(find.text('キッチン'), findsNothing);
    expect(find.text('たろう'), findsNothing);
    expect([api.store.me, api.store.notes, api.store.notices], [null, null, null]);
    expect(api.store.memos, isEmpty);
  });

  test('ログインできたら、前の人の中身を消してから読む（ログアウトを通らずに別の人が入ったときも出さない）', () async {
    final users = _Users();
    final api = Api(client: users.client, baseUrl: 'http://api', token: 'token-taro');
    await api.store.load();
    expect(api.store.me?.id, 'taro');

    await api.login('hana', 'pass-hana');
    expect([api.store.me, api.store.notes, api.store.notices], [null, null, null]);
    await api.store.load();
    expect([for (final n in api.store.notes!) n.id], ['m2']);
  });

  test('読み直しが 401 以外で失敗したら、1度読めた表示を残す', () async {
    final users = _Users();
    final api = Api(client: users.client, baseUrl: 'http://api', token: 'token-taro');
    await api.store.load();
    users.failHome = true;
    await api.store.load();
    expect(api.store.error, isA<ApiException>());
    expect([for (final n in api.store.notes!) n.id], ['m1']);
    expect(api.store.me?.id, 'taro');
  });

  test('ログアウトの前に始まった読み込みが遅れて終わっても、次の人の読み込みを読み込み中のまま扱い、もう1本読まない', () async {
    final users = _Users();
    final api = Api(client: users.client, baseUrl: 'http://api', token: 'token-taro');
    await api.store.load();

    users.taroGate = Completer();
    final stale = api.store.load();
    await api.logout();
    await api.login('hana', 'pass-hana');
    final hana = api.store.load();
    users.taroGate!.complete();
    await stale;
    // 前の読み込みが終わっても、hana の読み込みはまだ読み込み中のまま。同じものを待ち、もう1本は読まない
    final again = api.store.load();
    expect(identical(again, hana), isTrue);
    await hana;
    // 読んだのは、taro の2本と hana の1本だけ
    expect(users.homes, 3);
  });
}
