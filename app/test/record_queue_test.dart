import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:diff_note/api.dart';
import 'package:diff_note/models.dart';
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

// 記録を待たせない（設計書 0021 の C2）：押したらすぐ入力欄を空け、裏で押した順に1件ずつ照らし合わせる

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

/// ホール。記録した発言は書き込む行の無いもの
Map<String, dynamic> _hall() => {
      'owner': 'demo',
      'me': 'demo',
      'manual': {'id': 'm2', 'title': 'ホール', 'base': '- レジは現金とカードのみ', 'createdAt': '2026-11-01T00:00:00Z'},
      'lines': [
        {'text': '- レジは現金とカードのみ', 'patchId': null},
      ],
      'utterances': [
        {'id': 'u2', 'text': '前の記録', 'speaker': '田中さん', 'saidAt': '2026-11-04', 'createdAt': '2026-11-04T10:00:00Z'},
      ],
      'patches': [],
      'checks': [],
    };

/// 入力ページのサーバーの代わり。POST /utterances は test が返すまで待たせ、同時にいくつ送られたかを数える
class _Server {
  final memos = <Map<String, dynamic>>[];
  final intakes = <({Map<String, dynamic> body, Completer<http.Response> reply})>[];
  var _inFlight = 0;
  var maxInFlight = 0;
  var _memoCount = 0;

  /// あれば、POST /memos はこれが終わるまで待ち、エラーが入っていればそれを返す
  Completer<http.Response?>? memoGate;

  /// GET /home を読んだ回数
  var homes = 0;

  late final api = Api(client: MockClient(_handle), baseUrl: 'http://api');

  Future<http.Response> _handle(http.Request req) async {
    final path = req.url.path;
    if (req.method == 'POST' && path == '/utterances') {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final reply = Completer<http.Response>();
      intakes.add((body: body, reply: reply));
      maxInFlight = math.max(maxInFlight, ++_inFlight);
      final res = await reply.future;
      _inFlight--;
      if (res.statusCode == 201) memos.removeWhere((m) => (body['memoIds'] ?? []).contains(m['id']));
      return res;
    }
    if (path == '/home') {
      homes++;
      return _json(homeJson([_hall()], memos: [...memos]));
    }
    if (req.method == 'DELETE' && path.startsWith('/memos/')) {
      memos.removeWhere((m) => m['id'] == req.url.pathSegments[1]);
      return http.Response('', 204);
    }
    if (path == '/memos') {
      if (await memoGate?.future case final failed?) return failed;
      final m = {'id': 'memo${++_memoCount}', ...jsonDecode(req.body) as Map<String, dynamic>};
      memos.add(m);
      return _json(m, 201);
    }
    return _json(_hall());
  }

  /// i 番目の照らし合わせに、関係するノートが無かった結果を返す。サーバーと同じく、記録していないのでメモは消さない
  void missed(int i) => intakes[i].reply.complete(_json({'text': intakes[i].body['text'], 'results': []}));

  /// i 番目の照らし合わせに、記録できた結果を返す
  void recorded(int i) => intakes[i].reply.complete(_json({
        'text': intakes[i].body['text'],
        'results': [
          {'manualId': 'm2', 'utteranceId': 'u2', 'state': _hall()},
        ],
      }, 201));
}

Future<void> _pump(WidgetTester tester, _Server server,
    {Size size = const Size(1200, 1400), List<PickedFile> picked = const []}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: appTheme(),
    home: InputScreen(api: server.api, pickFiles: () async => picked),
  ));
  await tester.pumpAndSettle();
}

final _area = find.byType(MoonTextArea);
final _send = find.widgetWithText(MoonFilledButton, 'ノートと照らし合わせる');
const _waiting = '照らし合わせています…';
const _kept = 'ノートは変えずに、言われた記録として残しました';

String _typed(WidgetTester tester) => tester.widget<MoonTextArea>(_area).controller!.text;

/// 書いて押す。照らし合わせの返事は待たない
Future<void> _press(WidgetTester tester, String text) async {
  await tester.enterText(_area, text);
  await tester.pump();
  await tester.tap(_send);
  await tester.pump();
}

/// 待っている記録の付箋
Finder _note(String text) => find.ancestor(of: find.text(text), matching: find.byType(StickyNote));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('押すとすぐ入力欄が空き、返るまで入力欄の下に「照らし合わせています…」の付箋を出し、その間も次を書ける', (tester) async {
    final server = _Server();
    await _pump(tester, server);
    await _press(tester, '田中さんから、お冷やはすぐ出すと言われた');

    expect(_typed(tester), isEmpty);
    final note = _note('田中さんから、お冷やはすぐ出すと言われた');
    expect(note, findsOneWidget);
    expect(find.descendant(of: note, matching: find.text(_waiting)), findsOneWidget);
    // 進んでいることの知らせなので、タグにせず小さい文字で添える（「聞き取り中」と同じ）
    expect(find.ancestor(of: find.text(_waiting), matching: find.byType(StatusTag)), findsNothing);
    expect(tester.widget<Text>(find.text(_waiting)).style, appTheme().extension<AppTokens>()!.text.small);
    // 結果のカードが出る所（入力欄のすぐ下）に出す
    expect(tester.getRect(note).top, greaterThan(tester.getRect(_area).bottom));
    // ボタンは読み込み中にせず、入力欄も止めない
    expect(find.text('ノートと照らし合わせています…'), findsNothing);
    expect(tester.widget<MoonTextArea>(_area).readOnly, isFalse);
    // 文面はもう未整理メモとしてサーバーにあり、途中でタブを閉じても残る。待っている間は未整理メモに出さない
    expect([for (final m in server.memos) m['text']], ['田中さんから、お冷やはすぐ出すと言われた']);
    expect(find.text('未整理メモ'), findsNothing);
    expect(server.intakes.single.body['memoIds'], [server.memos.single['id']]);
    expect(server.intakes.single.body['write'], isTrue);
    // アプリに戻ってきて未整理メモを読み直し、サーバーから戻ってきても、待っている間は出さない
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('未整理メモ'), findsNothing);
    expect(note, findsOneWidget);

    await tester.enterText(_area, 'レジ締めは店長');
    await tester.pump();
    expect(tester.widget<MoonFilledButton>(_send).onTap, isNotNull);

    server.recorded(0);
    await tester.pumpAndSettle();
    expect(find.text(_waiting), findsNothing);
    expect(find.text(_kept), findsOneWidget);
    expect(server.memos, isEmpty);
    // 書いている途中の文はそのまま
    expect(_typed(tester), 'レジ締めは店長');
  });

  testWidgets('続けて押した記録は、前の照らし合わせが返ってから、押した順に1件ずつ送る', (tester) async {
    final server = _Server();
    await _pump(tester, server);
    await _press(tester, '塩は小さじ1/2');
    await _press(tester, '塩は小さじ1');

    // 文面はどちらもすぐメモに置くが、照らし合わせは1本だけ
    expect(server.memos, hasLength(2));
    expect(server.intakes, hasLength(1));
    expect(server.intakes[0].body['text'], '塩は小さじ1/2');
    // どちらも待っている付箋に出し、新しいものを先（広い画面では左）に並べる
    expect(find.text(_waiting), findsNWidgets(2));
    final newer = tester.getRect(_note('塩は小さじ1'));
    final older = tester.getRect(_note('塩は小さじ1/2'));
    expect(newer.top == older.top ? newer.left < older.left : newer.top < older.top, isTrue);

    server.recorded(0);
    await tester.pumpAndSettle();
    expect(server.intakes, hasLength(2));
    expect(server.intakes[1].body['text'], '塩は小さじ1');
    expect(server.intakes[1].body['memoIds'], [server.memos.single['id']]);
    expect(find.text(_waiting), findsOneWidget);

    server.recorded(1);
    await tester.pumpAndSettle();
    expect(server.maxInFlight, 1);
    expect(find.text(_waiting), findsNothing);
  });

  testWidgets('文面を未整理メモに置けなければ、送らずに入力欄へ戻す。待つ間に書いた文は消さない', (tester) async {
    final server = _Server()..memoGate = Completer();
    await _pump(tester, server);
    await _press(tester, '塩は小さじ1/2');
    expect(_typed(tester), isEmpty);
    await tester.enterText(_area, 'つづき');
    await tester.pump();

    server.memoGate!.complete(_json({'error': 'サーバーにつながりません'}, 503));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('サーバーにつながりません'), findsOneWidget);
    expect(_typed(tester), '塩は小さじ1/2\nつづき');
    expect(find.text(_waiting), findsNothing);
    expect(server.intakes, isEmpty);
    await tester.pumpAndSettle(const Duration(seconds: 10));
  });

  testWidgets('ファイルだけの記録はメモを作らずに送り、失敗したらファイルを入力欄に戻す', (tester) async {
    final server = _Server();
    await _pump(tester, server, picked: [(name: '手順.pdf', type: 'application/pdf', bytes: Uint8List(8))]);
    await tester.tap(find.bySemanticsLabel('ファイルを添える'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ファイルを選ぶ'));
    await tester.pumpAndSettle();
    await tester.tap(_send);
    await tester.pump();

    // 未整理メモは文字しか持てないので作らない。待っている付箋にはファイルの名前を出す
    expect(server.memos, isEmpty);
    expect(server.intakes.single.body.containsKey('memoIds'), isFalse);
    expect(find.widgetWithText(MoonTag, '手順.pdf'), findsNothing);
    expect(find.descendant(of: _note('手順.pdf'), matching: find.text(_waiting)), findsOneWidget);

    server.intakes.single.reply.complete(_json({'error': '読み取れませんでした'}, 422));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('読み取れませんでした'), findsOneWidget);
    expect(find.text(_waiting), findsNothing);
    expect(find.widgetWithText(MoonTag, '手順.pdf'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 10));
  });

  testWidgets('ファイルだけの記録で関係するノートが無く、記録先を選んで送り直して失敗したら、読み取った文面のカードを戻す', (tester) async {
    final server = _Server();
    await _pump(tester, server, picked: [(name: '手順.pdf', type: 'application/pdf', bytes: Uint8List(8))]);
    await tester.tap(find.bySemanticsLabel('ファイルを添える'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ファイルを選ぶ'));
    await tester.pumpAndSettle();
    await tester.tap(_send);
    await tester.pump();
    server.intakes[0].reply.complete(_json({'text': '傘は入口に置く', 'results': []}));
    await tester.pumpAndSettle();
    expect(find.text('関係するノートが見つかりませんでした'), findsOneWidget);
    // メモは無いので、未整理メモに残しているとは言わない
    expect(find.text('未整理メモに残しています'), findsNothing);

    await tester.tap(find.widgetWithText(MoonFilledButton, '記録先を選ぶ'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(MoonModal), matching: find.text('ホール')));
    await tester.pump();
    await tester.tap(find.widgetWithText(MoonFilledButton, '選んだノートと照らし合わせる'));
    await tester.pumpAndSettle();
    // 読み取った文面だけを、選んだノート宛てに送る
    expect(server.intakes[1].body['text'], '傘は入口に置く');
    expect(server.intakes[1].body['manualIds'], ['m2']);
    expect(server.intakes[1].body['files'], isEmpty);
    expect(find.text('関係するノートが見つかりませんでした'), findsNothing);
    expect(find.descendant(of: _note('傘は入口に置く'), matching: find.text(_waiting)), findsOneWidget);

    server.intakes[1].reply.complete(_json({'error': '混んでいます'}, 503));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('混んでいます'), findsOneWidget);
    expect(find.text('関係するノートが見つかりませんでした'), findsOneWidget);
    expect(find.text('「傘は入口に置く」'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 10));
  });

  testWidgets('次を書いている途中に結果が返っても、結果のカードの所まで送らない', (tester) async {
    final server = _Server();
    await _pump(tester, server, size: const Size(1280, 657));
    await _press(tester, '塩は小さじ1/2');
    await tester.enterText(_area, 'つづき');
    await tester.pump();
    final before = tester.getRect(_area).top;

    server.recorded(0);
    await tester.pumpAndSettle();
    expect(find.text(_kept), findsOneWidget);
    expect(tester.getRect(_area).top, before);
  });

  group('関係するノートが無かったカードは、その文面のメモがほかから記録された・消されたら外す（同じ発言を2回入れない）', () {
    const text = '傘は入口に置く';
    const missedTitle = '関係するノートが見つかりませんでした';

    Future<_Server> missedOnce(WidgetTester tester) async {
      final server = _Server();
      await _pump(tester, server);
      await _press(tester, text);
      server.missed(0);
      await tester.pumpAndSettle();
      expect(find.text(missedTitle), findsOneWidget);
      expect(find.text('未整理メモに残しています'), findsOneWidget);
      return server;
    }

    testWidgets('未整理メモのほうから記録したら', (tester) async {
      final server = await missedOnce(tester);
      // 未整理メモを入力欄に入れて記録する。サーバーはそのメモを消す
      await tester.tap(find.text(text));
      await tester.pump();
      await tester.tap(_send);
      await tester.pump();
      expect(server.intakes[1].body['memoIds'], contains('memo1'));
      server.recorded(1);
      await tester.pumpAndSettle();

      expect(find.text(missedTitle), findsNothing);
      expect(find.widgetWithText(MoonFilledButton, '記録先を選ぶ'), findsNothing);
    });

    testWidgets('未整理メモを消したら', (tester) async {
      await missedOnce(tester);
      await tester.tap(find.bySemanticsLabel('メモを消す'));
      await tester.pumpAndSettle();

      expect(find.text(missedTitle), findsNothing);
      expect(find.text('未整理メモに残しています'), findsNothing);
    });
  });

  testWidgets('照らし合わせの応答の形が違っても知らせ、後ろの記録は止めずに送る。サーバーで記録できていたメモは読み直して消す', (tester) async {
    final server = _Server();
    await _pump(tester, server);
    await _press(tester, '塩は小さじ1/2');
    await _press(tester, '塩は小さじ1');
    expect(server.intakes, hasLength(1));

    // 記録はできた（201）が、応答の形が違う
    server.intakes[0].reply.complete(_json({'text': '塩は小さじ1/2', 'results': [{'manualId': 'm2'}]}, 201));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(find.text('サーバーの応答を読めませんでした。記録できていなければ、文面は未整理メモに残ります'), findsOneWidget);
    expect(server.intakes, hasLength(2));
    expect(find.text(_waiting), findsOneWidget);

    server.recorded(1);
    await tester.pumpAndSettle(const Duration(seconds: 10));
    expect(find.text(_waiting), findsNothing);
    expect(find.text(_kept), findsOneWidget);
    // 記録できていた1件目のメモは、読み直して未整理メモに出さない
    expect(find.text('塩は小さじ1/2'), findsNothing);
  });

  testWidgets('文面を置く応答の形が違っても知らせ、入力欄へ戻し、次の記録は送れる', (tester) async {
    final server = _Server()..memoGate = Completer();
    await _pump(tester, server);
    await _press(tester, '塩は小さじ1/2');

    server.memoGate!.complete(_json([], 201));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(find.text('サーバーの応答を読めませんでした。もう一度送ってください'), findsOneWidget);
    expect(_typed(tester), '塩は小さじ1/2');
    expect(find.text(_waiting), findsNothing);
    expect(server.intakes, isEmpty);
    await tester.pumpAndSettle(const Duration(seconds: 10));

    server.memoGate = null;
    await tester.tap(_send);
    await tester.pump();
    expect(server.intakes.single.body['text'], '塩は小さじ1/2');
    server.recorded(0);
    await tester.pumpAndSettle();
    expect(find.text(_kept), findsOneWidget);
  });

  testWidgets('サーバーは記録したのに応答が途中で切れたら、読み直して、消えたメモを未整理メモに残さない', (tester) async {
    final server = _Server();
    await _pump(tester, server);
    await _press(tester, '塩は小さじ1/2');
    final before = server.homes;

    // サーバーは記録してメモを消したが、応答は届かなかった
    server.memos.clear();
    server.intakes[0].reply.complete(http.Response('<html>502 Bad Gateway</html>', 502));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('エラーが起きました（502）'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 10));

    expect(server.homes, before + 1);
    expect(find.text(_waiting), findsNothing);
    expect(find.text('塩は小さじ1/2'), findsNothing);
    expect(find.text('未整理メモ'), findsNothing);
  });
}
