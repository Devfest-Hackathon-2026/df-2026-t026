import 'dart:async';
import 'dart:convert';

import 'package:diff_note/api.dart';
import 'package:diff_note/manual_controller.dart';
import 'package:diff_note/models.dart';
import 'package:diff_note/screens/check_list_screen.dart';
import 'package:diff_note/screens/history_screen.dart';
import 'package:diff_note/screens/home_screen.dart';
import 'package:diff_note/screens/manual_screen.dart';
import 'package:diff_note/screens/tab_bar.dart';
import 'package:diff_note/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moon_design/moon_design.dart';

// ノートを消す（ADR 0014・実装23）

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

/// かなでのノート キッチン（m1。あとで確認 1）と ホール（m2）。shared ならキッチンは人から共有されたもの
class _Server {
  _Server({this.shared = false});
  final bool shared;

  /// DELETE の返し方。既定は 204（本文は空）
  Future<http.Response> Function() onDelete = () async => http.Response('', 204);
  final deletes = <String>[];
  var deleted = false;

  Map<String, dynamic> state(String id) => {
        'manual': {'id': id, 'title': id == 'm1' ? 'キッチン' : 'ホール', 'base': '- 塩 小さじ1', 'createdAt': '2026-11-01T00:00:00Z'},
        'lines': [
          {'text': '- 塩 小さじ1', 'patchId': null},
        ],
        'utterances': [
          if (id == 'm1')
            {'id': 'u1', 'text': '塩は小さじ1/2', 'speaker': '田中さん', 'saidAt': '2026-11-03', 'fromEdit': false, 'createdAt': '2026-11-03T00:00:00Z'},
        ],
        'patches': [
          if (id == 'm1')
            {'id': 'p1', 'utteranceId': 'u1', 'op': 'replace', 'line': '- 塩 小さじ1', 'text': '- 塩 小さじ1/2', 'summary': '', 'status': 'proposed', 'createdAt': '2026-11-03T00:00:00Z', 'appliedAt': null},
        ],
        'checks': [
          if (id == 'm1')
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
        'owner': shared && id == 'm1' ? 'sato' : 'kanade',
        'me': 'kanade',
        'sharedBy': shared && id == 'm1' ? {'id': 'sato', 'name': '佐藤店長'} : null,
      };

  late final client = MockClient((req) async {
    final path = req.url.path;
    if (req.method == 'DELETE' && path == '/manuals/m1') {
      deletes.add(path);
      final res = await onDelete();
      if (res.statusCode == 204) deleted = true;
      return res;
    }
    if (path == '/me') return _json({'id': 'kanade', 'name': 'かなで', 'icon': null});
    if (path == '/shared') return _json([]);
    if (path == '/manuals') {
      return _json([
        if (!deleted) {'id': 'm1', 'title': 'キッチン', 'utteranceCount': 1, 'openCount': 1},
        {'id': 'm2', 'title': 'ホール', 'utteranceCount': 0, 'openCount': 0},
      ]);
    }
    if (path == '/manuals/m1' && deleted) return _json({'error': 'ノートが見つかりません'}, 404);
    if (path.startsWith('/manuals/m1')) return _json(state('m1'));
    if (path.startsWith('/manuals/m2')) return _json(state('m2'));
    return _json([]);
  });

  late final api = Api(client: client, baseUrl: 'http://api');
}

/// 最初の画面（入力ページの代わり）。ここから一覧・ノートを開く
class _First extends StatelessWidget {
  const _First(this.open);
  final Widget Function() open;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: MoonFilledButton(
            label: const Text('開く'),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => open())),
          ),
        ),
      );
}

Future<_Server> _pump(WidgetTester tester, {bool shared = false, Size size = const Size(1440, 900), Widget Function(_Server)? from}) async {
  final server = _Server(shared: shared);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: appTheme(),
    home: _First(() => from?.call(server) ?? ManualScreen(api: server.api, manualId: 'm1')),
  ));
  await tester.tap(find.text('開く'));
  await tester.pumpAndSettle();
  return server;
}

/// 知らせ（MoonToast）
Finder _toast(String text) => find.text(text);

Finder _more() => find.byWidgetPredicate((w) => w is MoonButton && w.semanticLabel == 'その他');
Finder _deleteButton() => find.widgetWithText(MoonFilledButton, '消す');

Future<void> _openDialog(WidgetTester tester) async {
  await tester.tap(_more());
  await tester.pumpAndSettle();
  await tester.tap(find.text('ノートを消す'));
  await tester.pumpAndSettle();
}

void main() {
  for (final size in const [Size(390, 844), Size(1440, 900)]) {
    testWidgets('持ち主には上部バーの「…」（その他）に「ノートを消す」が出る（$size）', (tester) async {
      await _pump(tester, size: size);
      expect(_more(), findsOneWidget);
      // 「共有」の右に並ぶ
      expect(tester.getRect(_more()).left, greaterThan(tester.getRect(find.widgetWithText(MoonOutlinedButton, '共有')).right));
      expect(find.text('ノートを消す'), findsNothing);
      await tester.tap(_more());
      await tester.pumpAndSettle();
      expect(find.text('ノートを消す'), findsOneWidget);
    });

    testWidgets('共有されたノートでは「…」も「ノートを消す」も出ない（$size）', (tester) async {
      await _pump(tester, shared: true, size: size);
      expect(find.byType(ManualScreen), findsOneWidget);
      expect(_more(), findsNothing);
      expect(find.text('ノートを消す'), findsNothing);
    });
  }

  testWidgets('確かめのダイアログ：題名・本文（ノートの題名入り）・「消す」は赤・「やめる」', (tester) async {
    await _pump(tester);
    await _openDialog(tester);
    expect(find.text('このノートを消しますか？'), findsOneWidget);
    expect(find.text('「キッチン」と、資料・記録・確認・履歴がすべて消えます。共有している人からも見えなくなります。元に戻せません。'), findsOneWidget);
    final k = appTheme().extension<AppTokens>()!;
    expect(tester.widget<MoonFilledButton>(_deleteButton()).backgroundColor, k.colors.removed);
    expect(find.widgetWithText(MoonOutlinedButton, 'やめる'), findsOneWidget);
  });

  testWidgets('「やめる」を押すと何も起きない（DELETE を送らず、ノートのまま）', (tester) async {
    final server = await _pump(tester);
    await _openDialog(tester);
    await tester.tap(find.widgetWithText(MoonOutlinedButton, 'やめる'));
    await tester.pumpAndSettle();
    expect(server.deletes, isEmpty);
    expect(find.text('このノートを消しますか？'), findsNothing);
    expect(find.byType(ManualScreen), findsOneWidget);
  });

  for (final size in const [Size(390, 844), Size(1440, 900)]) {
    testWidgets('「消す」を押すと DELETE を1回送り、ノート一覧へ戻って「ノートを消しました」。一覧から消える（$size）', (tester) async {
      final server = await _pump(tester, size: size);
      await _openDialog(tester);
      await tester.tap(_deleteButton());
      await tester.pump();
      // ダイアログが閉じる動きのあとで知らせが出る
      await tester.pump(const Duration(seconds: 1));
      expect(_toast('ノートを消しました'), findsOneWidget);
      // 知らせが消えるのを待つ（MoonToast はタイマーをアプリ全体で1つ持つので、残すと次のテストの知らせが出ない）
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      expect(server.deletes, ['/manuals/m1']);
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(ManualScreen, skipOffstage: false), findsNothing);
      expect(find.text('キッチン'), findsNothing);
      expect(find.text('ホール'), findsWidgets);
      // 一覧は最初の画面の上に1枚だけ。戻ると最初の画面
      await tester.tap(find.bySemanticsLabel('戻る'));
      await tester.pumpAndSettle();
      expect(find.text('開く'), findsOneWidget);
    });
  }

  testWidgets('一覧から開いたノートを消しても、一覧は1枚だけになる', (tester) async {
    await _pump(tester, from: (s) => HomeScreen(api: s.api));
    await tester.tap(find.text('キッチン').last);
    await tester.pumpAndSettle();
    expect(find.byType(ManualScreen), findsOneWidget);

    await _openDialog(tester);
    await tester.tap(_deleteButton());
    await tester.pumpAndSettle();
    // 知らせが消えるのを待つ（MoonToast はタイマーをアプリ全体で1つ持つので、残すと次のテストの知らせが出ない）
    await tester.pump(const Duration(seconds: 5));
    expect(find.byType(HomeScreen, skipOffstage: false), findsOneWidget);
    expect(find.text('キッチン'), findsNothing);
  });

  testWidgets('下に確認リストを積んだ所（あとで確認 → 確認リスト → ノート）から消しても、一覧へ戻り確認リストは残らない', (tester) async {
    await _pump(
      tester,
      size: const Size(390, 844),
      from: (s) => CheckListScreen(c: ManualController(s.api, 'm1', ManualState.fromJson(s.state('m1')))),
    );
    expect(find.byType(CheckListScreen), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(NoteTabBar), matching: find.text('ノート')));
    await tester.pumpAndSettle();
    expect(find.byType(ManualScreen), findsOneWidget);

    await _openDialog(tester);
    await tester.tap(_deleteButton());
    await tester.pumpAndSettle();
    // 知らせが消えるのを待つ（MoonToast はタイマーをアプリ全体で1つ持つので、残すと次のテストの知らせが出ない）
    await tester.pump(const Duration(seconds: 5));
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(CheckListScreen, skipOffstage: false), findsNothing);
    expect(find.byType(ManualScreen, skipOffstage: false), findsNothing);
  });

  testWidgets('履歴を開いてノートに戻ってから消しても、履歴は残らない', (tester) async {
    await _pump(tester, size: const Size(390, 844));
    await tester.tap(find.descendant(of: find.byType(NoteTabBar), matching: find.text('履歴')));
    await tester.pumpAndSettle();
    expect(find.byType(HistoryScreen), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(NoteTabBar), matching: find.text('ノート')));
    await tester.pumpAndSettle();

    await _openDialog(tester);
    await tester.tap(_deleteButton());
    await tester.pumpAndSettle();
    // 知らせが消えるのを待つ（MoonToast はタイマーをアプリ全体で1つ持つので、残すと次のテストの知らせが出ない）
    await tester.pump(const Duration(seconds: 5));
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(HistoryScreen, skipOffstage: false), findsNothing);
  });

  testWidgets('失敗したら知らせて、ノートは残る（画面もそのまま）', (tester) async {
    final server = await _pump(tester);
    server.onDelete = () async => http.Response('<html>500</html>', 500);
    await _openDialog(tester);
    await tester.tap(_deleteButton());
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(_toast('エラーが起きました（500）'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('このノートを消しますか？'), findsNothing);
    expect(find.byType(ManualScreen), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
  });

  testWidgets('消している間は「消しています…」で、「消す」も「やめる」も押せない（二重に送らない）', (tester) async {
    final server = await _pump(tester);
    final done = Completer<http.Response>();
    server.onDelete = () => done.future;
    await _openDialog(tester);
    await tester.tap(_deleteButton());
    await tester.pump();

    expect(find.text('消しています…'), findsOneWidget);
    expect(tester.widget<MoonFilledButton>(find.widgetWithText(MoonFilledButton, '消しています…')).onTap, isNull);
    expect(tester.widget<MoonOutlinedButton>(find.widgetWithText(MoonOutlinedButton, 'やめる')).onTap, isNull);
    await tester.tap(find.widgetWithText(MoonFilledButton, '消しています…'), warnIfMissed: false);
    await tester.pump();
    expect(server.deletes, hasLength(1));

    done.complete(http.Response('', 204));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(server.deletes, hasLength(1));
  });

  testWidgets('消している間にダイアログの外を押しても閉じず、消し終わると一覧へ移る', (tester) async {
    final server = await _pump(tester);
    final done = Completer<http.Response>();
    server.onDelete = () => done.future;
    await _openDialog(tester);
    await tester.tap(_deleteButton());
    await tester.pump();
    await tester.tapAt(const Offset(5, 5));
    await tester.pump();
    expect(find.text('消しています…'), findsOneWidget);

    done.complete(http.Response('', 204));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  test('deleteManual：204 の空の本文で落ちず、changes が増える（サイドバーや一覧が読み直す）', () async {
    final api = Api(client: MockClient((req) async => http.Response('', 204)), baseUrl: 'http://api');
    final before = api.changes.value;
    await api.deleteManual('m1');
    expect(api.changes.value, before + 1);
  });

  test('deleteManual：持ち主でない・無いときの 404 は ApiException「ノートが見つかりません」', () async {
    final api = Api(client: MockClient((req) async => _json({'error': 'ノートが見つかりません'}, 404)), baseUrl: 'http://api');
    await expectLater(api.deleteManual('m1'), throwsA(isA<ApiException>().having((e) => e.message, 'message', 'ノートが見つかりません')));
  });
}
