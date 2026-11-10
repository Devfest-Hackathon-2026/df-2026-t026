import 'dart:async';
import 'dart:convert';

import 'package:diff_note/api.dart';
import 'package:diff_note/screens/common.dart';
import 'package:diff_note/screens/manual_screen.dart';
import 'package:diff_note/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moon_design/moon_design.dart';

import 'input_font.dart';

const _salt = '- 塩 小さじ1';

/// 直接編集を受けるだけの、メモリ上の小さなサーバー。発言と差分には、アプリが送った ID を使う
class _Server {
  final lines = <Map<String, dynamic>>[
    {'text': _salt, 'patchId': null},
  ];
  final utterances = <Map<String, dynamic>>[];
  final patches = <Map<String, dynamic>>[];
  final checks = <Map<String, dynamic>>[];

  /// 届いた直接編集の本文。届いた順
  final sent = <Map<String, dynamic>>[];

  /// 確かめた差分の ID。確かめた順
  final checked = <String>[];

  /// あれば、直接編集・確かめの応答をこれが済むまで返さない
  Completer<void>? editGate;
  Completer<void>? checkGate;

  /// 次の直接編集を断る。'network' ならつながらない、Map なら衝突（409）
  Object? failNext;

  /// 次の直接編集の前に、ほかの人がした編集
  void Function()? before;

  var _n = 0;

  /// 応答ごとに写しを返す。返した後にサーバーの中身が変わっても、前の応答は変わらない
  Map<String, dynamic> get state => jsonDecode(jsonEncode({
        'owner': 'demo',
        'me': 'demo',
        'manual': {'id': 'm1', 'title': 'キッチン', 'base': _salt, 'createdAt': '2026-11-01T00:00:00Z'},
        'lines': lines,
        'utterances': utterances,
        'patches': patches,
        'checks': checks,
      }));

  /// ほかの人（佐藤店長）が先頭に1行足した
  void othersAddFirst(String text) {
    utterances.add({'id': 'uo', 'text': text, 'speaker': '佐藤店長', 'saidAt': '2026-11-10', 'fromEdit': true, 'editedBy': 'sato', 'createdAt': '2026-11-10T00:00:00Z'});
    patches.add({'id': 'po', 'utteranceId': 'uo', 'op': 'insert', 'line': null, 'text': text, 'summary': '追記', 'status': 'applied', 'createdAt': '2026-11-10T00:00:00Z', 'appliedAt': '2026-11-10T00:00:00Z'});
    lines.insert(0, {'text': text, 'patchId': 'po'});
  }

  late final client = MockClient((req) async {
    final path = req.url.path;
    if (req.method == 'POST' && path == '/manuals/m1/edits') {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      sent.add(body);
      await editGate?.future;
      switch (failNext) {
        case 'network':
          failNext = null;
          throw http.ClientException('つながらない');
        case final Map<String, dynamic> conflict:
          failNext = null;
          return _json({'error': 'ほかの人が先にこの行を直しました', 'conflict': conflict}, 409);
      }
      before?.call();
      before = null;
      final id = body['patchId'] as String;
      final at = '2026-11-10T00:00:${(_n++).toString().padLeft(2, '0')}.000Z';
      utterances.add({'id': body['utteranceId'], 'text': body['text'], 'speaker': '自分', 'saidAt': '2026-11-10', 'fromEdit': true, 'createdAt': at});
      patches.add({'id': id, 'utteranceId': body['utteranceId'], 'op': body['op'], 'line': body['line'], 'text': body['text'], 'summary': '', 'status': 'applied', 'createdAt': at, 'appliedAt': at});
      // 末尾に足すときは line が null。文で探すと見つからず、先頭に入ってしまう
      final i = body['line'] == null ? lines.length - 1 : lines.indexWhere((l) => l['text'] == body['line']);
      switch (body['op']) {
        case 'delete':
          lines.removeAt(i);
        case 'insert':
          lines.insert(i + 1, {'text': body['text'], 'patchId': id});
        case 'replace':
          lines[i] = {'text': body['text'], 'patchId': id};
      }
      return _json(state, 201);
    }
    if (req.method == 'POST' && path.endsWith('/check')) {
      final id = req.url.pathSegments[3];
      checked.add(id);
      // 確かめは時間がかかる。返す状態は、確かめを始めたときに読んだもの
      final read = state;
      await checkGate?.future;
      final patch = patches.firstWhere((p) => p['id'] == id);
      // 「塩 小さじ2」だけが、元の「塩 小さじ1」と食い違う
      final contradiction = patch['text'] == '- 塩 小さじ2';
      final chk = {
        'id': 'c-$id',
        'patchId': id,
        'utteranceId': patch['utteranceId'],
        'kind': contradiction ? 'contradiction' : 'addition',
        'conflictLine': contradiction ? _salt : null,
        'sameLine': null,
        'reason': '量が違う',
        'ask': {
          'candidates': [
            {'who': '店長', 'why': '決める立場'},
          ],
          'question': 'どちらですか？',
        },
        'resolution': null,
      };
      checks.add(chk);
      (read['checks'] as List).add(chk);
      return _json(read, 200);
    }
    if (path == '/manuals/m1') return _json(state, 200);
    return _json([], 200);
  });
}

http.Response _json(Object body, int status) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

Future<_Server> _pump(WidgetTester tester) async {
  final server = _Server();
  tester.view.physicalSize = const Size(800, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: appTheme(),
    home: ManualScreen(api: Api(client: server.client, baseUrl: 'http://api'), manualId: 'm1'),
  ));
  await tester.pumpAndSettle();
  return server;
}

/// 開いている欄に、打つ所を移さずに書いて Enter を押す（Enter のあとも打つ所が欄にあることも確かめる）
Future<void> _typeAndEnter(WidgetTester tester, String text) async {
  tester.testTextInput.enterText(text);
  await tester.pump();
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pump();
}

Finder get _editor => find.byType(MoonTextInput);

String _draft(WidgetTester tester) => tester.widget<EditableText>(find.byType(EditableText)).controller.text;

bool _focused(WidgetTester tester) => tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus;

final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

/// 本文に出ている行を上から順に。マークダウンの「- 」は「・」で出る
List<String> _shownLines(WidgetTester tester) {
  final texts = find.descendant(of: find.byType(LineText), matching: find.byType(Text)).evaluate().toList()
    ..sort((a, b) => tester.getTopLeft(find.byElementPredicate((e) => e == a)).dy.compareTo(
        tester.getTopLeft(find.byElementPredicate((e) => e == b)).dy));
  return [for (final e in texts) (e.widget as Text).data ?? (e.widget as Text).textSpan!.toPlainText()];
}

void main() {
  testWidgets('末尾に行を書き足すと、すぐ出て、食い違えば確認リストに入ったと知らせる', (tester) async {
    final server = await _pump(tester);

    await tester.tap(find.widgetWithText(MoonOutlinedButton, '行を足す'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), '- 塩 小さじ2');
    await tester.pump();
    await tester.tap(find.widgetWithText(MoonFilledButton, '保存する'));
    await tester.pump(const Duration(milliseconds: 500));

    final body = server.sent.single;
    expect(body, {
      'op': 'insert',
      'line': null,
      'text': '- 塩 小さじ2',
      'today': isA<String>(),
      'utteranceId': matches(_uuid),
      'patchId': matches(_uuid),
    });
    expect(server.checked, [body['patchId']]);
    expect(find.text('・塩 小さじ2'), findsWidgets);
    expect(find.text('「塩 小さじ1」と食い違っています。確認リストに入れました'), findsOneWidget);
    expect(find.text('食い違い'), findsOneWidget);
    // 直接書いた行は、口頭の記録として数えない
    expect(find.text('記録 0 件'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 10));

    // 食い違っている行を押すと、口頭の指示と同じ確認リストに「自分」が書いた行として並ぶ
    await tester.tap(find.text('食い違い'));
    await tester.pumpAndSettle();
    expect(find.text('塩 小さじ1 ／ 塩 小さじ2'), findsOneWidget);
    expect(find.text('自分'), findsWidgets);
  });

  testWidgets('行を押すとその場で書き換え・消しができる', (tester) async {
    final server = await _pump(tester);

    await tester.tap(find.text('・塩 小さじ1'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(MoonTextInput, _salt), findsOneWidget);
    expectInputFontsAtLeast16(tester, count: 1); // 行を直接書き換える欄

    await tester.tap(find.widgetWithText(MoonOutlinedButton, 'この行を消す'));
    await tester.pumpAndSettle();

    expect(server.sent.single['op'], 'delete');
    expect(server.sent.single['line'], _salt);
    expect(find.text('・塩 小さじ1'), findsNothing);
    // 消しただけなら確かめない
    expect(server.checked, isEmpty);
  });

  testWidgets('保存した瞬間（応答の前）に行が出て、届くまでの間だけ「保存しています…」が出る', (tester) async {
    final server = await _pump(tester);
    server.editGate = Completer();
    expect(find.text('保存しています…'), findsNothing);

    await tester.tap(find.widgetWithText(MoonOutlinedButton, '行を足す'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), '- 胡椒 少々');
    await tester.pump();
    await tester.tap(find.widgetWithText(MoonFilledButton, '保存する'));
    await tester.pump();

    expect(server.sent, hasLength(1));
    expect(find.text('・胡椒 少々'), findsOneWidget);
    expect(find.text('保存しています…'), findsOneWidget);
    // 「保存する」は欄を閉じる
    expect(_editor, findsNothing);
    // 確かめは、編集が届いてから
    expect(find.text('食い違いがないか確かめています'), findsOneWidget);
    expect(server.checked, isEmpty);

    server.editGate!.complete();
    await tester.pumpAndSettle(const Duration(seconds: 10));
    expect(find.text('保存しています…'), findsNothing);
    expect(find.text('・胡椒 少々'), findsOneWidget);
    expect(server.checked, hasLength(1));
  });

  testWidgets('Enter で保存すると、書いた行のすぐ下に次の欄が開き、空のまま Enter か Esc で閉じる', (tester) async {
    final server = await _pump(tester);

    await tester.tap(find.text('・塩 小さじ1'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), '- 塩 小さじ1/2');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(server.sent.single, containsPair('op', 'replace'));
    // 書き換えた行の下に、空の「下に足す」欄が開き、打つ所はその欄にある
    expect(_editor, findsOneWidget);
    expect(_draft(tester), '');
    expect(_focused(tester), isTrue);
    expect(find.widgetWithText(MoonOutlinedButton, 'この行を消す'), findsNothing);
    expect(_shownLines(tester), ['・塩 小さじ1/2']);
    expect(tester.getTopLeft(_editor).dy, greaterThan(tester.getTopLeft(find.text('・塩 小さじ1/2')).dy));

    await _typeAndEnter(tester, '- 胡椒 少々');
    expect(_shownLines(tester), ['・塩 小さじ1/2', '・胡椒 少々']);
    expect(_editor, findsOneWidget);
    expect(_focused(tester), isTrue);
    expect(tester.getTopLeft(_editor).dy, greaterThan(tester.getTopLeft(find.text('・胡椒 少々')).dy));

    // 空のまま Enter で閉じる
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle(const Duration(seconds: 10));
    expect(_editor, findsNothing);
    expect(server.sent, hasLength(2));

    // Esc でも閉じ、何も送らない
    await tester.tap(find.widgetWithText(MoonOutlinedButton, '行を足す'));
    await tester.pumpAndSettle();
    tester.testTextInput.enterText('- 書きかけ');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(_editor, findsNothing);
    expect(find.text('・書きかけ'), findsNothing);
    expect(server.sent, hasLength(2));
    await tester.pumpAndSettle(const Duration(seconds: 10));
  });

  testWidgets('続けて2行書くと、1本ずつ書いた順に送り、それぞれにアプリが作った ID を付ける', (tester) async {
    final server = await _pump(tester);
    server.editGate = Completer();

    await tester.tap(find.widgetWithText(MoonOutlinedButton, '行を足す'));
    await tester.pumpAndSettle();
    await _typeAndEnter(tester, '- 胡椒 少々');
    await _typeAndEnter(tester, '- 醤油 大さじ1');
    expect(_shownLines(tester), ['・塩 小さじ1', '・胡椒 少々', '・醤油 大さじ1']);
    // 前の編集が届くまで、次は送らない
    expect(server.sent.map((b) => b['text']), ['- 胡椒 少々']);

    server.editGate!.complete();
    await tester.pump();
    await tester.pump();
    expect(server.sent.map((b) => b['text']), ['- 胡椒 少々', '- 醤油 大さじ1']);
    final ids = [for (final b in server.sent) ...[b['utteranceId'], b['patchId']]];
    expect(ids, everyElement(matches(_uuid)));
    expect(ids.toSet(), hasLength(4));
    // 末尾に足し続けたので、どちらも末尾への追記
    expect(server.sent.map((b) => b['line']), [null, null]);
    await tester.pumpAndSettle(const Duration(seconds: 10));
    // 確かめも書いた順に、1本ずつ
    expect(server.checked, [server.sent[0]['patchId'], server.sent[1]['patchId']]);
  });

  testWidgets('前の編集の応答が遅れて届いても、あとから書いた行は消えない', (tester) async {
    final server = await _pump(tester);
    server.editGate = Completer();

    await tester.tap(find.widgetWithText(MoonOutlinedButton, '行を足す'));
    await tester.pumpAndSettle();
    await _typeAndEnter(tester, '- 胡椒 少々');
    await _typeAndEnter(tester, '- 醤油 大さじ1');
    // 1行目だけの状態が届く
    server.editGate!.complete();
    server.editGate = Completer();
    await tester.pump();
    await tester.pump();
    expect(server.sent, hasLength(2));
    expect(_shownLines(tester), ['・塩 小さじ1', '・胡椒 少々', '・醤油 大さじ1']);
    expect(find.text('保存しています…'), findsOneWidget);

    // 欄を閉じても、まだ送っている編集があるうちは、古い応答を入れない
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(_shownLines(tester), ['・塩 小さじ1', '・胡椒 少々', '・醤油 大さじ1']);

    server.editGate!.complete();
    await tester.pumpAndSettle(const Duration(seconds: 10));
    expect(_shownLines(tester), ['・塩 小さじ1', '・胡椒 少々', '・醤油 大さじ1']);
    expect(find.text('保存しています…'), findsNothing);
  });

  testWidgets('欄を開いたまま、ほかの人の編集で行がずれた応答が届いても、書いた行の下に足す', (tester) async {
    final server = await _pump(tester);
    // 自分の書き換えより先に、ほかの人が先頭に1行足していた
    server.before = () => server.othersAddFirst('- 手を洗う');

    await tester.tap(find.text('・塩 小さじ1'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), '- 塩 小さじ1/2');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle(const Duration(seconds: 10));
    // 応答には先頭の行があるが、欄を開いている間は出さない（出すと欄の番号が1つずれる）
    expect(server.sent, hasLength(1));
    expect(_shownLines(tester), ['・塩 小さじ1/2']);
    expect(find.text('・手を洗う'), findsNothing);

    await _typeAndEnter(tester, '- 胡椒 少々');
    await tester.pumpAndSettle(const Duration(seconds: 10));
    expect(server.sent[1], allOf(containsPair('op', 'insert'), containsPair('line', '- 塩 小さじ1/2')));

    // 欄を閉じたら、最新の状態を出す
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle(const Duration(seconds: 10));
    expect(_shownLines(tester), ['・手を洗う', '・塩 小さじ1/2', '・胡椒 少々']);
  });

  testWidgets('ほかの画面やダイアログに移るときは、欄を閉じる', (tester) async {
    await _pump(tester);
    await tester.tap(find.widgetWithText(MoonOutlinedButton, '行を足す'));
    await tester.pumpAndSettle();
    expect(_editor, findsOneWidget);
    await tester.tap(find.widgetWithText(MoonOutlinedButton, '共有'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MoonOutlinedButton, '閉じる'));
    await tester.pumpAndSettle();
    expect(_editor, findsNothing);
  });

  testWidgets('つながらなくて保存できなければ、行を戻し、書いた文を元の場所の欄に入れ直す', (tester) async {
    final server = await _pump(tester);
    server.failNext = 'network';

    await tester.tap(find.text('・塩 小さじ1'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), '- 塩 小さじ2');
    await tester.tap(find.widgetWithText(MoonFilledButton, '保存する'));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.textContaining('保存できませんでした（サーバーにつながりません）。直した 1 行を元に戻しました'), findsOneWidget);
    expect(_shownLines(tester), isEmpty, reason: '書き換える欄が元の行の場所に開いている');
    expect(find.widgetWithText(MoonTextInput, '- 塩 小さじ2'), findsOneWidget);
    expect(find.widgetWithText(MoonOutlinedButton, 'この行を消す'), findsOneWidget);
    expect(find.text('保存しています…'), findsNothing);
    expect(server.checked, isEmpty);

    // そのまま保存し直せる
    await tester.tap(find.widgetWithText(MoonFilledButton, '保存する'));
    await tester.pumpAndSettle(const Duration(seconds: 10));
    expect(server.sent.map((b) => (b['op'], b['line'], b['text'])), [
      ('replace', _salt, '- 塩 小さじ2'),
      ('replace', _salt, '- 塩 小さじ2'),
    ]);
    expect(_shownLines(tester), ['・塩 小さじ2']);
  });

  testWidgets('続けて書いている途中で前の編集が届かなければ、後ろの編集もまとめて戻し、何行戻したかを出す', (tester) async {
    final server = await _pump(tester);
    server.editGate = Completer();
    server.failNext = 'network';

    // 行の「下に行を足す」から書き始めると、欄は行の番号で場所を覚える
    await tester.tap(find.text('・塩 小さじ1'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MoonTextButton, '下に行を足す'));
    await tester.pumpAndSettle();
    await _typeAndEnter(tester, '- 胡椒 少々');
    await _typeAndEnter(tester, '- 醤油 大さじ1');
    tester.testTextInput.enterText('- 書きかけ');
    await tester.pump();
    expect(_shownLines(tester), ['・塩 小さじ1', '・胡椒 少々', '・醤油 大さじ1']);

    server.editGate!.complete();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('直した 2 行を元に戻しました'), findsOneWidget);
    expect(_shownLines(tester), ['・塩 小さじ1']);
    // 後ろの編集は送らない。書いている欄は文面ごと残し、残った行の下に合わせ直す
    expect(server.sent, hasLength(1));
    expect(_editor, findsOneWidget);
    expect(_draft(tester), '- 書きかけ');
    expect(tester.getTopLeft(_editor).dy, greaterThan(tester.getTopLeft(find.text('・塩 小さじ1')).dy));
    expect(find.text('保存しています…'), findsNothing);

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle(const Duration(seconds: 10));
    expect(server.sent.last, allOf(containsPair('op', 'insert'), containsPair('line', _salt), containsPair('text', '- 書きかけ')));
    expect(_shownLines(tester), ['・塩 小さじ1', '・書きかけ']);
  });

  testWidgets('ほかの人が先に同じ行を直していたら、先に出した書き換えを戻して選ぶダイアログを出す', (tester) async {
    final server = await _pump(tester);
    server.failNext = {'line': _salt, 'theirs': '- 塩 小さじ1/2', 'after': null, 'by': '佐藤店長', 'at': '2026-11-10'};

    await tester.tap(find.text('・塩 小さじ1'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), '- 塩 小さじ2');
    await tester.tap(find.widgetWithText(MoonFilledButton, '保存する'));
    await tester.pumpAndSettle();

    expect(find.text('ほかの人が先にこの行を直しました'), findsOneWidget);
    expect(_shownLines(tester), ['・塩 小さじ1']);
    expect(server.checked, isEmpty);
    await tester.pumpAndSettle(const Duration(seconds: 10));
  });

  testWidgets('確かめの応答は、確かめた確認だけを足し、確かめている間に書いた行を消さない', (tester) async {
    final server = await _pump(tester);
    server.checkGate = Completer();

    await tester.tap(find.widgetWithText(MoonOutlinedButton, '行を足す'));
    await tester.pumpAndSettle();
    await _typeAndEnter(tester, '- 塩 小さじ2');
    await tester.pump();
    expect(server.checked, hasLength(1));
    // 確かめている間に、次の行を書いて届ける
    await _typeAndEnter(tester, '- 胡椒 少々');
    await tester.pump();
    expect(server.sent, hasLength(2));
    expect(find.text('食い違いがないか確かめています'), findsNWidgets(2));

    // 1行目の確かめの応答は、2行目を書く前に読んだ状態
    server.checkGate!.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('食い違い'), findsOneWidget);
    expect(_shownLines(tester), ['・塩 小さじ1', '・塩 小さじ2', '・胡椒 少々']);

    // 欄を閉じると、取っておいた2行目の応答（確かめより前に読んだもの）が入るが、確かめた結果は残す
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle(const Duration(seconds: 10));
    expect(_shownLines(tester), ['・塩 小さじ1', '・塩 小さじ2', '・胡椒 少々']);
    expect(find.text('食い違い'), findsOneWidget);
    expect(server.checked, hasLength(2));
  });
}
