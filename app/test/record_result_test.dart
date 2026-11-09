import 'dart:convert';

import 'package:diff_note/api.dart';
import 'package:diff_note/manual_controller.dart';
import 'package:diff_note/models.dart';
import 'package:diff_note/screens/common.dart';
import 'package:diff_note/screens/input_screen.dart';
import 'package:diff_note/screens/open_checks_screen.dart';
import 'package:diff_note/screens/record_result.dart';
import 'package:diff_note/screens/review_dialog.dart';
import 'package:diff_note/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:moon_design/moon_design.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 入力ページで記録した後、トーストの代わりに入力欄の下に出す結果のカード（#112）

const _half = '- 塩 小さじ1/2';
const _one = '- 塩 小さじ1';
const _record = '11/7 店長に確認：1/2で統一';
const _showText = '11/7 に店長に確認して、「塩 小さじ1/2」に決まっています（1/2で統一）。';

const _wide = Size(1440, 1400);
/// スマホの幅。カードと下の「あとで確認」を1画面に収めて位置を比べられるよう、縦は長くする
const _narrow = Size(390, 2000);

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

Map<String, dynamic> _said(String id, String? speaker, String day, String text) =>
    {'id': id, 'text': text, 'speaker': speaker, 'saidAt': day, 'createdAt': '${day}T10:00:00Z'};

Map<String, dynamic> _patch(String id, String u, String day, String op, String? line, String text,
        {String status = 'proposed'}) =>
    {
      'id': id,
      'utteranceId': u,
      'op': op,
      'line': line,
      'text': text,
      'summary': '',
      'status': status,
      'createdAt': '${day}T10:00:00Z',
      'appliedAt': status == 'applied' ? '${day}T10:00:00Z' : null,
    };

Map<String, dynamic> _check(String id, String patchId, String u, String kind,
        {String? conflictLine, String? sameLine, Map<String, dynamic>? resolution}) =>
    {
      'id': id,
      'patchId': patchId,
      'utteranceId': u,
      'kind': kind,
      'conflictLine': conflictLine,
      'sameLine': sameLine,
      'reason': '理由',
      'ask': null,
      'resolution': resolution,
    };

Map<String, dynamic> _note(String id, String title, List<String> lines,
        {required List<Map<String, dynamic>> utterances,
        required List<Map<String, dynamic>> patches,
        required List<Map<String, dynamic>> checks}) =>
    {
      'owner': 'demo',
      'me': 'demo',
      'manual': {'id': id, 'title': title, 'base': lines.join('\n'), 'createdAt': '2026-11-01T00:00:00Z'},
      'lines': [
        for (final l in lines) {'text': l, 'patchId': null},
      ],
      'utterances': utterances,
      'patches': patches,
      'checks': checks,
    };

/// まだ誰にも確認していない食い違い。田中さんの「小さじ1/2」がノートの「小さじ1」と食い違う
Map<String, dynamic> _kitchen() => _note('m1', 'キッチン', [_one],
    utterances: [_said('u1', '田中さん', '2026-11-03', '塩は小さじ1/2でいい')],
    patches: [_patch('p1', 'u1', '2026-11-03', 'replace', _one, _half)],
    checks: [_check('c1', 'p1', 'u1', 'contradiction', conflictLine: _one)]);

/// 田中さんの「小さじ1/2」を 11/7 に店長に確認して 1/2 に決めた。そのあと 11/10 に佐藤さんが「小さじ1」と言った。
/// answered なら、店長が共有されたノートで自分で答えて決めた（ADR 0017）
Map<String, dynamic> _confirmed({bool answered = false}) {
  final j = _note('m1', 'キッチン', [_half],
      utterances: [
        _said('u1', '田中さん', '2026-11-03', '塩は小さじ1/2でいい'),
        _said('a1', '店長', '2026-11-07', '1/2で統一'),
        _said('u3', '佐藤さん', '2026-11-10', '塩は小さじ1だよ'),
      ],
      patches: [
        _patch('p1', 'u1', '2026-11-03', 'replace', _one, _half, status: 'discarded'),
        _patch('p2', 'a1', '2026-11-07', 'replace', _one, _half, status: 'applied'),
        _patch('p3', 'u3', '2026-11-10', 'replace', _half, _one),
      ],
      checks: [
        _check('c1', 'p1', 'u1', 'contradiction', conflictLine: _one, resolution: {
          'utteranceId': 'a1',
          'patchId': 'p2',
          'decidedBy': '店長',
          'answeredBy': answered ? 'tencho' : null,
          'decidedAt': '2026-11-07',
          'text': _half,
          'note': '1/2で統一',
        }),
        _check('c2', 'p3', 'u3', 'contradiction', conflictLine: _half),
      ]);
  (j['lines'] as List).first['patchId'] = 'p2';
  return j;
}

const _hallLines = ['- レジは現金とカードのみ', '- お冷やはすぐ出す'];

/// ホールに、言われたことを照らし合わせた結果。kinds の分類の差分を1つずつ作る
Map<String, dynamic> _hall(List<String> kinds) {
  final patches = <Map<String, dynamic>>[];
  final checks = <Map<String, dynamic>>[];
  for (final (i, kind) in kinds.indexed) {
    final id = 'p$i';
    patches.add(switch (kind) {
      'addition' => _patch(id, 'u2', '2026-11-04', 'insert', _hallLines.last, '- おしぼりも一緒に出す'),
      'qualification' =>
        _patch(id, 'u2', '2026-11-04', 'replace', _hallLines.first, '- レジは現金とカードのみ。団体はまとめて会計'),
      _ => _patch(id, 'u2', '2026-11-04', 'insert', _hallLines.last, _hallLines.last),
    });
    checks.add(_check('c$i', id, 'u2', kind, sameLine: kind == 'same' ? _hallLines.last : null));
  }
  return _note('m2', 'ホール', _hallLines,
      utterances: [_said('u2', '田中さん', '2026-11-04', 'お冷やはすぐ出す')], patches: patches, checks: checks);
}

/// 入力ページのサーバーの代わり。POST /utterances は intakes を前から1つずつ返し、書き込み・記録の道を残す
class _Server {
  _Server(this.intakes);

  /// 照らし合わせるたびに返す、1冊ごとの（照らし合わせた直後の状態, 記録した発言）
  final List<List<(Map<String, dynamic>, String)>> intakes;
  final posted = <String>[];

  /// 一覧と GET で返すノート。照らし合わせると、照らし合わせた直後の状態に置き換わる。
  /// テストで書き換えると、ほかの画面で確定した・ノートを消したことにできる
  final notes = {'m1': _kitchen(), 'm2': _hall([])};

  late final api = Api(client: MockClient(_handle), baseUrl: 'http://api');

  Future<http.Response> _handle(http.Request req) async {
    final path = req.url.path;
    if (req.method == 'POST' && path == '/utterances') {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final results = intakes.removeAt(0);
      for (final (s, _) in results) {
        notes[s['manual']['id']] = s;
      }
      return _json({
        'text': body['text'],
        'results': [
          for (final (s, u) in results) {'manualId': s['manual']['id'], 'utteranceId': u, 'state': s},
        ],
      }, 201);
    }
    if (req.method == 'POST') posted.add(path);
    if (path == '/shared' || path == '/memos') return _json([]);
    if (path == '/manuals') {
      return _json([
        for (final s in notes.values)
          {'id': s['manual']['id'], 'title': s['manual']['title'], 'utteranceCount': 1, 'openCount': 0},
      ]);
    }
    return _json(notes[req.url.pathSegments[1]]!);
  }
}

Future<_Server> _pump(WidgetTester tester, List<List<(Map<String, dynamic>, String)>> intakes,
    {Size size = _wide}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final server = _Server(intakes);
  await tester.pumpWidget(MaterialApp(theme: appTheme(), home: InputScreen(api: server.api)));
  await tester.pumpAndSettle();
  return server;
}

Future<void> _recordText(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(MoonTextArea), text);
  await tester.pump();
  await tester.tap(find.widgetWithText(MoonFilledButton, 'ノートと照らし合わせる'));
  await tester.pumpAndSettle();
}

final _card = find.byType(RecordResultCard);
Finder _inCard(Finder f) => find.descendant(of: _card, matching: f);

final _k = appTheme().extension<AppTokens>()!;

/// カードの見た目の要素。食い違いがあれば黄で塗った見せ場の形、無ければ白い落ち着いた形か
void _expectLook(WidgetTester tester, String title, {required bool conflicted}) {
  final sheet = tester.widget<PaperSheet>(_inCard(find.byType(PaperSheet)).first);
  final heading = tester.widget<Text>(_inCard(find.text(title)));
  final filled = _inCard(find.widgetWithText(MoonFilledButton, '確かめる'));
  final text = _inCard(find.widgetWithText(MoonTextButton, '確かめる'));
  if (conflicted) {
    expect(sheet.tint, (bg: _k.colors.pendingBg, line: _k.colors.pending));
    expect(heading.style, _k.text.display);
    expect(filled, findsOneWidget);
    expect(text, findsNothing);
  } else {
    expect(sheet.tint, isNull);
    expect(heading.style, _k.text.title);
    expect(filled, findsNothing);
    expect(text, findsOneWidget);
  }
}

/// 確かめるで開いたダイアログの中
Finder _inModal(Finder f) => find.descendant(of: find.byType(MoonModal), matching: f);

/// 分類のタグと、その右の行の文が同じ高さに並んでいるか
void _expectLine(WidgetTester tester, String tag, String text) {
  final t = tester.getCenter(_inCard(find.text(tag)));
  final l = tester.getCenter(_inCard(find.text(text)));
  expect((t.dy - l.dy).abs(), lessThan(4), reason: '$tag と $text が同じ行にない');
  expect(t.dx, lessThan(l.dx));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final size in const [_wide, _narrow]) {
    testWidgets('食い違いは、ノートと言われたことを入力欄のすぐ下に並べて出し、消えずに残る（$size）', (tester) async {
      final server = await _pump(tester, [
        [(_kitchen(), 'u1')],
      ], size: size);
      await _recordText(tester, '田中さんから、塩は小さじ1/2でいいと言われた');
      expect(tester.takeException(), isNull);

      // 確認は開かない。食い違いは書き込まない
      expect(find.text('ノートに書き込む前の確認'), findsNothing);
      expect(server.posted, isEmpty);
      expect(_inCard(find.text('ノートと食い違っています')), findsOneWidget);
      expect(_inCard(find.text('キッチン')), findsOneWidget);
      final pair = tester.widget<ConflictPair>(_inCard(find.byType(ConflictPair)));
      expect((pair.leftLabel, pair.left, pair.rightLabel, pair.right), ('ノート', _one, '田中さん（11/3）', _half));
      // 広い幅では左右、狭い幅では上下に並べる
      final note = tester.getTopLeft(_inCard(find.text('塩 小さじ1')));
      final said = tester.getTopLeft(_inCard(find.text('塩 小さじ1/2')));
      if (size == _wide) {
        expect(said.dy, note.dy);
        expect(said.dx, greaterThan(note.dx));
      } else {
        expect(said.dy, greaterThan(note.dy));
        expect(said.dx, note.dx);
      }
      // 確定済みの記録と食い違ったのではないので、確認印も見せる文も出さない
      expect(_inCard(find.byType(ConfirmStamp)), findsNothing);
      expect(find.text('記録を見せる'), findsNothing);
      expect(_inCard(find.text('確認リストに入れました')), findsOneWidget);

      // 入力欄のすぐ下、「あとで確認」より上に、ページの中に出す（#112 のように下の行に重ならない）
      final card = tester.getRect(_card);
      expect(card.top, greaterThan(tester.getRect(find.byType(MoonTextArea)).bottom));
      expect(card.bottom, lessThan(tester.getRect(find.byType(OpenChecksList)).top));
      // 「あとで確認」の見出しに、全部の件数を黄の札で添える
      final total = tester.getRect(find.text('全部で 1 件'));
      expect(total.top, greaterThan(card.bottom));
      expect(total.bottom, lessThan(tester.getRect(find.byType(OpenChecksList)).top));
      // 前の知らせのように数秒で消えない
      await tester.pump(const Duration(seconds: 10));
      expect(_card, findsOneWidget);
      // 食い違いは見せ場：黄で塗り、見出しを大きく、「確かめる」を主のボタンにする
      _expectLook(tester, 'ノートと食い違っています', conflicted: true);

      // 「確かめる」で、書き込む前の確認と同じダイアログを開く。振り分けはもう済んでいるので題名は「記録した結果」
      await tester.tap(_inCard(find.widgetWithText(MoonFilledButton, '確かめる')));
      await tester.pumpAndSettle();
      expect(find.text('記録した結果'), findsOneWidget);
      expect(find.text('ノートに書き込む前の確認'), findsNothing);
      // 確定済みの記録と食い違ったのではないので、ダイアログにも確認印は出さない
      expect(_inModal(find.byType(ConfirmStamp)), findsNothing);
    });
  }

  for (final size in const [_wide, _narrow]) {
    testWidgets('確定済みの決定と食い違ったら、見出しでそう言い、確認印と記録を見せる文を添える（$size）', (tester) async {
      await _pump(tester, [
        [(_confirmed(), 'u3')],
      ], size: size);
      await _recordText(tester, '佐藤さんから、塩は小さじ1だと言われた');
      expect(tester.takeException(), isNull);

      const title = '店長に確認済みの決定と食い違っています';
      expect(_inCard(find.text(title)), findsOneWidget);
      // 主のボタンは「確かめる」のまま
      _expectLook(tester, title, conflicted: true);
      final pair = tester.widget<ConflictPair>(_inCard(find.byType(ConflictPair)));
      expect((pair.left, pair.rightLabel, pair.right), (_half, '佐藤さん（11/10）', _one));
      final stamp = tester.widget<ConfirmStamp>(_inCard(find.byType(ConfirmStamp)));
      expect((stamp.who, stamp.day, stamp.decided), ('店長', '2026-11-07', false));
      // 確認印はほかより大きく、見出しの横（狭い幅では上）に押す
      final stampRect = tester.getRect(_inCard(find.byType(ConfirmStamp)));
      final titleRect = tester.getRect(_inCard(find.text(title)));
      expect(stampRect.width, moreOrLessEquals(_k.stampDiameterLarge, epsilon: 1));
      expect(stampRect.width, greaterThan(_k.stampDiameter));
      if (size == _wide) {
        expect(stampRect.left, greaterThan(titleRect.right));
        expect(stampRect.top, lessThan(titleRect.bottom));
      } else {
        expect(stampRect.bottom, lessThanOrEqualTo(titleRect.top));
      }
      expect(stampRect.bottom, lessThan(tester.getRect(_inCard(find.byType(ConflictPair))).top));
      expect(_inCard(find.text(_record)), findsOneWidget);
      expect(_inCard(find.text('記録を見せる')), findsOneWidget);
      // 確認のページと同じ組み立ての文。比較の文と同じ大きさの太字で目立たせる
      expect(_inCard(find.text(_showText)), findsOneWidget);
      expect(tester.widget<Text>(_inCard(find.text(_showText))).style, _k.text.title);
      // 比較の下に、確定の記録、見せる文の順
      expect(tester.getRect(_inCard(find.byType(ConflictPair))).bottom,
          lessThan(tester.getTopLeft(_inCard(find.text(_record))).dy));
      expect(tester.getTopLeft(_inCard(find.text(_record))).dy, lessThan(tester.getTopLeft(_inCard(find.text(_showText))).dy));

      String? copied;
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'];
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.tap(_inCard(find.byWidgetPredicate((w) => w is MoonButton && w.semanticLabel == '記録を見せる文をコピーする')));
      await tester.pump();
      expect(copied, _showText);
      await tester.pump(const Duration(seconds: 10)); // コピーのトーストが消えるのを待つ
    });
  }

  for (final size in const [_wide, _narrow]) {
    testWidgets('確定済みの決定と食い違ったときに「確かめる」で開く画面は「記録した結果」で、確認のページと同じ確認印と記録を出す（$size）',
        (tester) async {
      await _pump(tester, [
        [(_confirmed(), 'u3')],
      ], size: size);
      await _recordText(tester, '佐藤さんから、塩は小さじ1だと言われた');
      await tester.tap(_inCard(find.widgetWithText(MoonFilledButton, '確かめる')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      expect(find.text('記録した結果'), findsOneWidget);
      expect(find.text('ノートに書き込む前の確認'), findsNothing);
      final record = _inModal(find.byType(ConfirmedRecord));
      expect(record, findsOneWidget);
      final stamp = tester.widget<ConfirmStamp>(find.descendant(of: record, matching: find.byType(ConfirmStamp)));
      expect((stamp.who, stamp.day, stamp.decided), ('店長', '2026-11-07', false));
      expect(find.descendant(of: record, matching: find.text(_record)), findsOneWidget);
      // 比較のすぐ下に出す
      expect(tester.getRect(_inModal(find.byType(ConflictPair))).bottom, lessThan(tester.getRect(record).top));
    });
  }

  testWidgets('発言者が分からず書き込む前に開いた確認は、書き込み終えても題名を変えない', (tester) async {
    tester.view.physicalSize = _wide;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final before = _hall(['addition']);
    (before['utterances'] as List).first['speaker'] = null;
    final named = _hall(['addition']);
    final written = _hall(['addition']);
    ((written['patches'] as List).first as Map<String, dynamic>)['status'] = 'applied';
    final api = Api(
      client: MockClient((req) async => switch (req.method) {
            'PATCH' => _json(named),
            'POST' when req.url.path.endsWith('/apply') => _json(written),
            _ => _json([]),
          }),
      baseUrl: 'http://api',
    );
    final c = ManualController(api, 'm2', ManualState.fromJson(before));
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => MoonOutlinedButton(
            label: const Text('開く'),
            onTap: () => showReview(context, [(c: c, utteranceId: 'u2')]),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('開く'));
    await tester.pumpAndSettle();
    expect(find.text('ノートに書き込む前の確認'), findsOneWidget);

    await tester.enterText(_inModal(find.byType(MoonTextInput)), '田中さん');
    await tester.pump();
    await tester.tap(find.widgetWithText(MoonFilledButton, 'ノートに書き込む'));
    await tester.pumpAndSettle();
    expect(c.state!.patchesOf('u2').single.status, 'applied');
    expect(find.text('ノートに書き込む前の確認'), findsOneWidget);
    expect(find.text('記録した結果'), findsNothing);
  });

  testWidgets('教える人が自分で答えて決めたものと食い違ったら、決めたと言い、印も「決定」にする', (tester) async {
    await _pump(tester, [
      [(_confirmed(answered: true), 'u3')],
    ]);
    await _recordText(tester, '佐藤さんから、塩は小さじ1だと言われた');

    expect(_inCard(find.text('店長が決めたことと食い違っています')), findsOneWidget);
    expect(tester.widget<ConfirmStamp>(_inCard(find.byType(ConfirmStamp))).decided, isTrue);
    expect(_inCard(find.text('11/7 店長が決定：1/2で統一')), findsOneWidget);
    expect(_inCard(find.text('11/7 に店長が決めて、「塩 小さじ1/2」に決まっています（1/2で統一）。')), findsOneWidget);
  });

  testWidgets('書き込んだ行と同じ内容は、分類と行を1行ずつ出し、書き込む・記録だけ残すは今まで通り', (tester) async {
    final server = await _pump(tester, [
      [(_hall(['same', 'addition', 'qualification']), 'u2')],
    ]);
    await _recordText(tester, '田中さんから、お冷やはすぐ出す。おしぼりも一緒に');
    expect(tester.takeException(), isNull);

    expect(server.posted, ['/manuals/m2/patches/p0/discard', '/manuals/m2/patches/p1/apply', '/manuals/m2/patches/p2/apply']);
    expect(_inCard(find.text('ノートに2行書き込みました')), findsOneWidget);
    expect(_inCard(find.text('ホール')), findsOneWidget);
    _expectLine(tester, '追記', 'おしぼりも一緒に出す');
    _expectLine(tester, '条件付きの補足', 'レジは現金とカードのみ。団体はまとめて会計');
    _expectLine(tester, '同じ内容', 'お冷やはすぐ出す');
    // 書き込んだ行を先に、同じ内容を後に並べる
    expect(tester.getTopLeft(_inCard(find.text('同じ内容'))).dy,
        greaterThan(tester.getTopLeft(_inCard(find.text('条件付きの補足'))).dy));
    expect(_inCard(find.byType(ConflictPair)), findsNothing);
    expect(_inCard(find.text('確認リストに入れました')), findsNothing);
    // 食い違いが無ければ、白いカードに今までの大きさの見出しと文字の「確かめる」のまま。確認印も出さない
    _expectLook(tester, 'ノートに2行書き込みました', conflicted: false);
    expect(_inCard(find.byType(ConfirmStamp)), findsNothing);
  });

  testWidgets('同じ内容だけなら、ノートと同じだったと言う', (tester) async {
    final server = await _pump(tester, [
      [(_hall(['same']), 'u2')],
    ]);
    await _recordText(tester, '田中さんから、お冷やはすぐ出す');

    expect(server.posted, ['/manuals/m2/patches/p0/discard']);
    expect(_inCard(find.text('ノートと同じ内容でした（記録として残しました）')), findsOneWidget);
    _expectLine(tester, '同じ内容', 'お冷やはすぐ出す');
    _expectLook(tester, 'ノートと同じ内容でした（記録として残しました）', conflicted: false);
  });

  for (final size in const [_wide, _narrow]) {
    testWidgets('複数のノートにまたがるときは、ノートの題名で分ける（$size）', (tester) async {
      await _pump(tester, [
        [(_kitchen(), 'u1'), (_hall(['addition']), 'u2')],
      ], size: size);
      await _recordText(tester, '田中さんから、塩は小さじ1/2、おしぼりも一緒に出すと言われた');
      expect(tester.takeException(), isNull);

      expect(_inCard(find.text('ノートと食い違っています')), findsOneWidget);
      double top(Finder f) => tester.getTopLeft(_inCard(f)).dy;
      final kitchen = top(find.text('キッチン'));
      final pair = top(find.byType(ConflictPair));
      final hall = top(find.text('ホール'));
      final added = top(find.text('おしぼりも一緒に出す'));
      expect(kitchen < pair && pair < hall && hall < added, isTrue);
    });
  }

  testWidgets('次に記録すると、前の結果は新しい結果に入れ替わる', (tester) async {
    await _pump(tester, [
      [(_kitchen(), 'u1')],
      [(_hall(['addition']), 'u2')],
    ]);
    await _recordText(tester, '田中さんから、塩は小さじ1/2でいいと言われた');
    expect(_inCard(find.text('ノートと食い違っています')), findsOneWidget);

    await _recordText(tester, '田中さんから、おしぼりも一緒に出すと言われた');
    expect(_card, findsOneWidget);
    expect(_inCard(find.text('ノートに1行書き込みました')), findsOneWidget);
    expect(find.text('ノートと食い違っています'), findsNothing);
    expect(_inCard(find.byType(ConflictPair)), findsNothing);
  });

  testWidgets('結果は閉じられる', (tester) async {
    await _pump(tester, [
      [(_hall(['addition']), 'u2')],
    ]);
    await _recordText(tester, '田中さんから、おしぼりも一緒に出すと言われた');
    expect(_card, findsOneWidget);

    await tester.tap(_inCard(find.byWidgetPredicate((w) => w is MoonButton && w.semanticLabel == '結果を閉じる')));
    await tester.pumpAndSettle();
    expect(_card, findsNothing);
    expect(find.text('ノートに1行書き込みました'), findsNothing);
  });

  testWidgets('発言者が分からず確認を開いたときは、今まで通り確認だけを出し、結果のカードは出さない', (tester) async {
    final hall = _hall(['addition']);
    (hall['utterances'] as List).first['speaker'] = null;
    await _pump(tester, [
      [(hall, 'u2')],
    ]);
    await _recordText(tester, 'おしぼりも一緒に出す');
    expect(find.text('ノートに書き込む前の確認'), findsOneWidget);

    await tester.tap(find.descendant(of: find.byType(MoonModal), matching: find.widgetWithIcon(MoonButton, LucideIcons.x)));
    await tester.pumpAndSettle();
    expect(find.text('ノートに書き込む前の確認'), findsNothing);
    expect(_card, findsNothing);
  });

  // #119：記録したらカードの所まで送る。古くなったカードは残さず、ほかの画面から戻ったら入力欄から始める
  const pc = Size(1280, 657);

  /// カードの見出しと比較が、上部バーの下から画面の下の端までに見えているか
  void expectCardShown(WidgetTester tester, Size size) {
    expect(tester.getRect(_inCard(find.text('ノートと食い違っています'))).top,
        greaterThanOrEqualTo(tester.getRect(find.byType(TopBar)).bottom));
    expect(tester.getRect(_inCard(find.byType(ConflictPair))).bottom, lessThanOrEqualTo(size.height));
  }

  for (final size in const [pc, Size(390, 844)]) {
    testWidgets('記録すると、結果のカードの見出しと比較が見える所まで送る（$size）', (tester) async {
      await _pump(tester, [
        [(_kitchen(), 'u1')],
      ], size: size);
      await _recordText(tester, '田中さんから、塩は小さじ1/2でいいと言われた');
      expectCardShown(tester, size);
    });
  }

  /// 記録して、時間を進めずに数枚描く。送る動きはまだ進まない
  Future<void> recordWithoutTime(WidgetTester tester) async {
    await tester.enterText(find.byType(MoonTextArea), '田中さんから、塩は小さじ1/2でいいと言われた');
    await tester.pump();
    await tester.tap(find.widgetWithText(MoonFilledButton, 'ノートと照らし合わせる'));
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(_card, findsOneWidget);
  }

  testWidgets('ふだんは、カードの所まで動いて送る', (tester) async {
    await _pump(tester, [
      [(_kitchen(), 'u1')],
    ], size: pc);
    await recordWithoutTime(tester);
    expect(tester.getRect(_inCard(find.byType(ConflictPair))).bottom, greaterThan(pc.height));
    await tester.pumpAndSettle();
    expectCardShown(tester, pc);
  });

  testWidgets('動きを減らす設定なら、動かさずにカードの所へ移る', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await _pump(tester, [
      [(_kitchen(), 'u1')],
    ], size: pc);
    await recordWithoutTime(tester);
    expectCardShown(tester, pc);
  });

  testWidgets('カードの食い違いをほかの画面で確定したら、読み直したときにカードを消す', (tester) async {
    final server = await _pump(tester, [
      [(_kitchen(), 'u1')],
    ]);
    await _recordText(tester, '田中さんから、塩は小さじ1/2でいいと言われた');

    // 読み直しても、食い違いがまだ確認待ちなら残す
    server.api.changes.value++;
    await tester.pumpAndSettle();
    expect(_card, findsOneWidget);

    final settled = _kitchen();
    ((settled['checks'] as List).first as Map<String, dynamic>)['resolution'] = {
      'utteranceId': 'a1',
      'patchId': null,
      'decidedBy': '店長',
      'answeredBy': null,
      'decidedAt': '2026-11-10',
      'text': _half,
      'note': '1/2で統一',
    };
    server.notes['m1'] = settled;
    server.api.changes.value++;
    await tester.pumpAndSettle();
    expect(_card, findsNothing);
    expect(find.text('ノートと食い違っています'), findsNothing);
  });

  testWidgets('カードのノートが消されたら、読み直したときにカードを消す', (tester) async {
    final server = await _pump(tester, [
      [(_hall(['addition']), 'u2')],
    ]);
    await _recordText(tester, '田中さんから、おしぼりも一緒に出すと言われた');

    // 食い違いの無いカードは、読み直しても残す
    server.api.changes.value++;
    await tester.pumpAndSettle();
    expect(_card, findsOneWidget);

    server.notes.remove('m2');
    server.api.changes.value++;
    await tester.pumpAndSettle();
    expect(_card, findsNothing);
  });

  testWidgets('ほかの画面からサイドバーで戻ると、入力欄が見える位置から始める。ダイアログを閉じただけでは動かさない', (tester) async {
    await _pump(tester, [
      [(_kitchen(), 'u1')],
    ], size: pc);
    final area = find.byType(MoonTextArea);
    final start = tester.getRect(area).top;
    await _recordText(tester, '田中さんから、塩は小さじ1/2でいいと言われた');
    final scrolled = tester.getRect(area).top;
    expect(scrolled, lessThan(start));

    // 「確かめる」の確認を開いて閉じても、カードの所に留まる
    await tester.tap(_inCard(find.widgetWithText(MoonFilledButton, '確かめる')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(MoonModal), matching: find.widgetWithIcon(MoonButton, LucideIcons.x)));
    await tester.pumpAndSettle();
    expect(tester.getRect(area).top, scrolled);

    await tester.tap(find.widgetWithText(MoonMenuItem, 'あとで確認'));
    await tester.pumpAndSettle();
    expect(find.byType(OpenChecksScreen), findsOneWidget);
    await tester.tap(find.widgetWithText(MoonMenuItem, '言われたことを記録'));
    await tester.pumpAndSettle();
    expect(find.byType(OpenChecksScreen), findsNothing);
    expect(tester.getRect(area).top, start);
    // 食い違いはまだ確認待ちなので、カードは残っている
    expect(_card, findsOneWidget);
  });
}
