import 'dart:async';
import 'dart:convert';

import 'package:diff_note/api.dart';
import 'package:diff_note/manual_controller.dart';
import 'package:diff_note/screens/check_list_screen.dart';
import 'package:diff_note/screens/common.dart';
import 'package:diff_note/screens/input_screen.dart';
import 'package:diff_note/screens/manual_screen.dart';
import 'package:diff_note/screens/open_checks_screen.dart';
import 'package:diff_note/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moon_design/moon_design.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'home.dart';

// アプリの状態を1か所（NoteStore）に持ち、書いたあとに取り直さない（ADR 0020・設計書 0020 の B1）

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

const _salt = '- 塩 小さじ1';
const _pepper = '- 胡椒 少々';

/// キッチン（m1）と、ほかのノートを more 冊。受けた通信を requests に残す
class _Server {
  _Server({int more = 2}) {
    notes['m1'] = _plain(noteJson('m1', 'キッチン', lines: [_salt, _pepper]));
    for (var i = 0; i < more; i++) {
      notes['x$i'] = _plain(noteJson('x$i', 'ほかのノート$i', lines: ['- 行$i']));
    }
  }

  /// 中の一覧に行を足せるよう、JSON を通して型の付かない形にする
  static Map<String, dynamic> _plain(Map<String, dynamic> j) => jsonDecode(jsonEncode(j));

  final notes = <String, Map<String, dynamic>>{};

  /// 受けた通信（「GET /home」など）。届いた順
  final requests = <String>[];
  List<String> get reads => [for (final r in requests) if (r.startsWith('GET ')) r];

  /// あれば、GET /manuals/:id はこれが済むまで返さない。返す状態は、受けた時点のもの
  Completer<void>? noteGate;

  /// あれば、直接編集はこれが済むまで書き込まず、返さない
  Completer<void>? editGate;

  /// 消された（GET /manuals/:id が 404 になる）ノート
  final gone = <String>{};

  /// 次の直接編集で送られた本文
  final edits = <Map<String, dynamic>>[];

  var _n = 0;
  String _at() => '2026-11-10T00:00:${(_n++).toString().padLeft(2, '0')}.000Z';

  late final api = Api(client: MockClient(_handle), baseUrl: 'http://api');

  /// ほかの人（佐藤店長）が、そのノートの先頭に1行足した
  void othersAddFirst(String id, String text) {
    final n = notes[id]!;
    final at = _at();
    (n['utterances'] as List)
        .add({'id': 'uo$at', 'text': text, 'speaker': '佐藤店長', 'saidAt': '2026-11-10', 'fromEdit': true, 'editedBy': 'sato', 'createdAt': at});
    (n['patches'] as List).add({'id': 'po$at', 'utteranceId': 'uo$at', 'op': 'insert', 'line': null, 'text': text, 'summary': '追記', 'status': 'applied', 'createdAt': at, 'appliedAt': at});
    (n['lines'] as List).insert(0, {'text': text, 'patchId': 'po$at'});
  }

  /// 応答ごとに写しを返す。返した後にサーバーの中身が変わっても、前の応答は変わらない
  Map<String, dynamic> _copy(String id) => jsonDecode(jsonEncode(notes[id]));

  Future<http.Response> _handle(http.Request req) async {
    final path = req.url.path;
    requests.add('${req.method} $path');
    if (path == '/home') return _json(homeJson([for (final id in notes.keys) _copy(id)]));
    final id = req.url.pathSegments.length > 1 ? req.url.pathSegments[1] : '';
    if (req.method == 'GET' && path == '/manuals/$id') {
      if (gone.contains(id)) return _json({'error': 'ノートが見つかりません'}, 404);
      final read = _copy(id);
      await noteGate?.future;
      return _json(read);
    }
    if (path == '/manuals/$id/edits') {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      edits.add(body);
      await editGate?.future;
      final n = notes[id]!;
      final at = _at();
      final lines = n['lines'] as List;
      (n['utterances'] as List)
          .add({'id': body['utteranceId'], 'text': body['text'], 'speaker': '自分', 'saidAt': '2026-11-10', 'fromEdit': true, 'createdAt': at});
      (n['patches'] as List).add({'id': body['patchId'], 'utteranceId': body['utteranceId'], 'op': body['op'], 'line': body['line'], 'text': body['text'], 'summary': '', 'status': 'applied', 'createdAt': at, 'appliedAt': at});
      final i = body['line'] == null ? lines.length - 1 : lines.indexWhere((l) => l['text'] == body['line']);
      switch (body['op']) {
        case 'insert':
          lines.insert(i + 1, {'text': body['text'], 'patchId': body['patchId']});
        case 'replace':
          lines[i] = {'text': body['text'], 'patchId': body['patchId']};
        case 'delete':
          lines.removeAt(i);
      }
      return _json(_copy(id), 201);
    }
    if (path.endsWith('/check')) {
      final pid = req.url.pathSegments[3];
      final n = notes[id]!;
      final p = (n['patches'] as List).firstWhere((p) => p['id'] == pid);
      // 「塩 小さじ2」だけが、元の「塩 小さじ1」と食い違う
      final contradiction = p['text'] == '- 塩 小さじ2';
      (n['checks'] as List).add({
        'id': 'c-$pid',
        'patchId': pid,
        'utteranceId': p['utteranceId'],
        'kind': contradiction ? 'contradiction' : 'addition',
        'conflictLine': contradiction ? _salt : null,
        'reason': '量が違う',
        'resolution': null,
      });
      return _json(_copy(id));
    }
    if (path.endsWith('/resolve')) {
      final b = jsonDecode(req.body) as Map<String, dynamic>;
      final c = (notes[id]!['checks'] as List).firstWhere((c) => c['id'] == req.url.pathSegments[3]);
      c['resolution'] = {'utteranceId': 'u-ans', 'patchId': null, 'decidedBy': b['decidedBy'], 'decidedAt': b['decidedAt'], 'text': b['text'], 'note': b['note']};
      return _json(_copy(id));
    }
    if (req.method == 'POST' && path == '/memos') return _json({'id': 'memo1', ...jsonDecode(req.body)}, 201);
    if (req.method == 'POST' && path == '/utterances') {
      // 田中さんの「塩は小さじ1/2」をキッチンに記録し、元の「塩 小さじ1」と食い違った
      final n = notes['m1']!;
      final at = _at();
      (n['utterances'] as List).add({'id': 'u-rec', 'text': '塩は小さじ1/2', 'speaker': '田中さん', 'saidAt': '2026-11-10', 'createdAt': at});
      (n['patches'] as List).add({'id': 'p-rec', 'utteranceId': 'u-rec', 'op': 'replace', 'line': _salt, 'text': '- 塩 小さじ1/2', 'summary': '', 'status': 'proposed', 'createdAt': at, 'appliedAt': null});
      (n['checks'] as List).add({'id': 'c-rec', 'patchId': 'p-rec', 'utteranceId': 'u-rec', 'kind': 'contradiction', 'conflictLine': _salt, 'reason': '量が違う', 'resolution': null});
      return _json({
        'text': '塩は小さじ1/2',
        'results': [
          {'manualId': 'm1', 'utteranceId': 'u-rec', 'state': _copy('m1')},
        ],
      }, 201);
    }
    return _json({'error': '見つかりません'}, 404);
  }
}

/// 広い画面（サイドバーが出る）で入力ページを開く
Future<void> _pumpInput(WidgetTester tester, _Server server) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: appTheme(), home: InputScreen(api: server.api)));
  await tester.pumpAndSettle();
}

Finder _sidebarItem(String title) => find.widgetWithText(MoonMenuItem, title);

/// サイドバーのそのノートの横の、あとで確認の件数
Finder _sidebarCount(String title, int n) => find.descendant(of: _sidebarItem(title), matching: find.text('$n'));

/// サイドバーからノートを開く。サイドバーからは動きなしで移る
Future<void> _openFromSidebar(WidgetTester tester, String title) async {
  await tester.tap(_sidebarItem(title));
  await tester.pump();
}

/// 本文に出ている行を上から順に。マークダウンの「- 」は「・」で出る
List<String> _shownLines(WidgetTester tester) {
  final texts = find.descendant(of: find.byType(LineText), matching: find.byType(Text)).evaluate().toList()
    ..sort((a, b) => tester.getTopLeft(find.byElementPredicate((e) => e == a)).dy.compareTo(
        tester.getTopLeft(find.byElementPredicate((e) => e == b)).dy));
  return [for (final e in texts) (e.widget as Text).data ?? (e.widget as Text).textSpan!.toPlainText()];
}

Future<void> _resume(WidgetTester tester) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final more in [2, 9]) {
    testWidgets('開いたときの通信は GET /home の1本だけで、ノートの数（${more + 1} 冊）によらない', (tester) async {
      final server = _Server(more: more);
      await _pumpInput(tester, server);

      expect(server.requests, ['GET /home']);
      // サイドバー・入力ページ・自分の名前は、その1本から描く
      expect(_sidebarItem('ほかのノート${more - 1}'), findsOneWidget);
      expect(find.widgetWithText(MoonMenuItem, 'demo'), findsOneWidget);
      expect(find.text('あとで確認'), findsWidgets);
    });
  }

  testWidgets('store にあるノートを開くと、読み込み中を挟まずに出し、裏で GET /manuals/:id を1本だけ読んで、変わっていれば出す', (tester) async {
    final server = _Server();
    await _pumpInput(tester, server);
    server.requests.clear();
    // 開いたあとに、ほかの人が先頭に1行足していた
    server.othersAddFirst('m1', '- 手を洗う');
    server.noteGate = Completer();

    await _openFromSidebar(tester, 'キッチン');
    expect(find.byType(ManualScreen), findsOneWidget);
    expect(find.byType(Loading), findsNothing);
    expect(_shownLines(tester), ['・塩 小さじ1', '・胡椒 少々']);
    expect(server.requests, ['GET /manuals/m1']);

    server.noteGate!.complete();
    await tester.pumpAndSettle();
    expect(_shownLines(tester), ['・手を洗う', '・塩 小さじ1', '・胡椒 少々']);
    expect(server.requests, ['GET /manuals/m1']);
  });

  testWidgets('行を直して確かめても取り直さず、確かめの応答で、ノートの画面・サイドバー・入力ページの「あとで確認」がそろう', (tester) async {
    final server = _Server();
    await _pumpInput(tester, server);
    await _openFromSidebar(tester, 'キッチン');
    await tester.pumpAndSettle();
    server.requests.clear();

    await tester.tap(find.widgetWithText(MoonOutlinedButton, '行を足す'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), '- 塩 小さじ2');
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('保存する'));
    await tester.pumpAndSettle(const Duration(seconds: 10));

    expect(server.requests, [
      'POST /manuals/m1/edits',
      'POST /manuals/m1/patches/${server.edits.single['patchId']}/check',
    ]);
    expect(find.text('あとで確認 1 件'), findsOneWidget);
    expect(_sidebarCount('キッチン', 1), findsOneWidget);

    // サイドバーで入力ページに戻っても読み直さず、「あとで確認」に同じ件数が出ている
    await tester.tap(_sidebarItem('言われたことを記録'));
    await tester.pumpAndSettle();
    expect(server.reads, isEmpty);
    expect(find.descendant(of: find.byType(OpenChecksList), matching: find.text('あとで確認 1 件')), findsOneWidget);
  });

  testWidgets('記録しても取り直さず、記録の応答で、入力ページの「あとで確認」とサイドバーの件数がそろう', (tester) async {
    final server = _Server();
    await _pumpInput(tester, server);
    server.requests.clear();
    expect(_sidebarCount('キッチン', 1), findsNothing);

    await tester.enterText(find.byType(MoonTextArea), '田中さんから、塩は小さじ1/2でいいと言われた');
    await tester.pump();
    await tester.tap(find.widgetWithText(MoonFilledButton, 'ノートと照らし合わせる'));
    await tester.pumpAndSettle();

    expect(server.requests, ['POST /memos', 'POST /utterances']);
    expect(find.descendant(of: find.byType(OpenChecksList), matching: find.text('あとで確認 1 件')), findsOneWidget);
    expect(_sidebarCount('キッチン', 1), findsOneWidget);
  });

  testWidgets('編集欄を開いている間に、ほかの人の編集で行がずれた取り直しが届いても、欄の行に保存し、欄を閉じてから出す', (tester) async {
    final server = _Server();
    await _pumpInput(tester, server);
    server.othersAddFirst('m1', '- 手を洗う');
    server.noteGate = Completer();
    await _openFromSidebar(tester, 'キッチン');
    await tester.pumpAndSettle();

    // 2行目（胡椒）を直す欄を開いてから、先頭に1行足された状態が届く
    await tester.tap(find.text('・胡椒 少々'));
    await tester.pumpAndSettle();
    server.noteGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('・手を洗う'), findsNothing);
    expect(_shownLines(tester), ['・塩 小さじ1']);
    expect(find.widgetWithText(MoonTextInput, _pepper), findsOneWidget);

    await tester.enterText(find.byType(EditableText), '- 胡椒 ひとつまみ');
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('保存する'));
    await tester.pumpAndSettle(const Duration(seconds: 10));
    expect(server.edits.single, allOf(containsPair('op', 'replace'), containsPair('line', _pepper)));
    expect(_shownLines(tester), ['・手を洗う', '・塩 小さじ1', '・胡椒 ひとつまみ']);
  });

  testWidgets('編集欄を開いている間にアプリに戻ってきて読み直しても、欄を閉じるまで出さない', (tester) async {
    final server = _Server();
    await _pumpInput(tester, server);
    await _openFromSidebar(tester, 'キッチン');
    await tester.pumpAndSettle();
    await tester.tap(find.text('・胡椒 少々'));
    await tester.pumpAndSettle();

    server.othersAddFirst('m1', '- 手を洗う');
    server.requests.clear();
    await _resume(tester);
    expect(server.requests, ['GET /home']);
    expect(_shownLines(tester), ['・塩 小さじ1']);
    expect(find.widgetWithText(MoonTextInput, _pepper), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(_shownLines(tester), ['・手を洗う', '・塩 小さじ1', '・胡椒 少々']);
  });

  testWidgets('アプリに戻ってきたら GET /home を1本読み直し、ほかの人の変更を出す', (tester) async {
    final server = _Server();
    await _pumpInput(tester, server);
    await tester.tap(_sidebarItem('あとで確認'));
    await tester.pumpAndSettle();
    expect(find.byType(OpenChecksScreen), findsOneWidget);
    expect(find.text('食い違いは、いまはありません'), findsOneWidget);
    server.requests.clear();

    // ほかの人がキッチンに記録し、食い違いが1件できた
    server.notes['m1'] = noteJson('m1', 'キッチン', lines: [_salt], open: 1);
    await _resume(tester);

    expect(server.requests, ['GET /home']);
    expect(find.descendant(of: find.byType(OpenChecksList), matching: find.text('あとで確認 1 件')), findsOneWidget);
    expect(_sidebarCount('キッチン', 1), findsOneWidget);
  });

  testWidgets('読み直している間に書き込んだノートは、読み直しの古い応答で戻さない', (tester) async {
    final server = _Server();
    await _pumpInput(tester, server);
    // 開いたときの読み直しを、行を足して届くまで待たせる
    server.noteGate = Completer();
    await _openFromSidebar(tester, 'キッチン');
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(MoonOutlinedButton, '行を足す'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), '- 醤油 大さじ1');
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('保存する'));
    await tester.pumpAndSettle(const Duration(seconds: 10));
    expect(_shownLines(tester), ['・塩 小さじ1', '・胡椒 少々', '・醤油 大さじ1']);

    // 足す前に読んだ状態が届く
    server.noteGate!.complete();
    await tester.pumpAndSettle();
    expect(_shownLines(tester), ['・塩 小さじ1', '・胡椒 少々', '・醤油 大さじ1']);
    expect(server.api.store.note('m1')!.lines.map((l) => l.text), [_salt, _pepper, '- 醤油 大さじ1']);
  });

  test('行の編集を送っている間に確定しても、確定の応答は編集を待たずに出し、送っている行も消さない', () async {
    final server = _Server();
    server.notes['m1'] = _Server._plain(noteJson('m1', 'キッチン', lines: [_salt], open: 1));
    final c = ManualController(server.api, 'm1');
    await c.load();
    server.editGate = Completer();
    final edit = c.edit('insert', text: '- 醤油 大さじ1');
    expect(c.saving, isTrue);

    await c.resolve('m1-c0', decidedBy: '店長', decidedAt: '2026-11-10', text: _salt, note: 'そのまま');
    expect(c.state!.checks.single.resolution?.decidedBy, '店長');
    expect(c.state!.lines.map((l) => l.text), [_salt, '- 醤油 大さじ1']);

    server.editGate!.complete();
    expect(await edit.saved, isTrue);
    expect(c.state!.checks.single.resolution?.decidedBy, '店長');
    expect(c.state!.lines.map((l) => l.text), [_salt, '- 醤油 大さじ1']);
  });

  testWidgets('開いたノートが消されていたら、古い内容を出さずに「見つかりません」を出し、サイドバーからも外す', (tester) async {
    final server = _Server();
    await _pumpInput(tester, server);
    server.gone.add('m1');

    await _openFromSidebar(tester, 'キッチン');
    await tester.pumpAndSettle();
    expect(find.text('読み込めませんでした：ノートが見つかりません'), findsOneWidget);
    expect(_shownLines(tester), isEmpty);
    expect(_sidebarItem('キッチン'), findsNothing);
  });

  testWidgets('画面を閉じれば、閉じずに捨てたコントローラー（入力ページから開いた確認リスト）も store に残らない', (tester) async {
    final server = _Server();
    server.notes['m1'] = _Server._plain(noteJson('m1', 'キッチン', lines: [_salt], open: 1));
    await _pumpInput(tester, server);
    await tester.tap(find.descendant(of: find.byType(OpenChecksList), matching: find.text('キッチン')));
    await tester.pumpAndSettle();
    expect(find.byType(CheckListScreen), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    // ignore: invalid_use_of_protected_member
    expect(server.api.store.hasListeners, isFalse);
  });
}
