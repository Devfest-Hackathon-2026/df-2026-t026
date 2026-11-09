import 'dart:convert';

import 'package:diff_note/api.dart';
import 'package:diff_note/manual_controller.dart';
import 'package:diff_note/models.dart';
import 'package:diff_note/screens/check_list_screen.dart';
import 'package:diff_note/screens/check_screen.dart';
import 'package:diff_note/screens/common.dart';
import 'package:diff_note/screens/history_screen.dart';
import 'package:diff_note/screens/manual_screen.dart';
import 'package:diff_note/screens/material_screen.dart';
import 'package:diff_note/screens/materials_screen.dart';
import 'package:diff_note/screens/record_result.dart';
import 'package:diff_note/screens/review_dialog.dart';
import 'package:diff_note/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moon_design/moon_design.dart';

// 確認で資料の箇所を見せる（ADR 0019 の設計書 §8.4・§10.4〜§10.6、PR4）。
// 田中さんの「味噌汁の塩は小さじ1/2」が、資料「店舗マニュアル」p.2 の「味噌汁の塩は小さじ1」（60行目）と食い違う

http.Response _json(Object? body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

const _narrow = Size(390, 844);
const _wide = Size(1440, 900);

const _salt = '- 塩 小さじ1';
const _mat = '- 味噌汁の塩は小さじ1';
const _half = '- 味噌汁の塩は小さじ1/2';
const _two = '- 味噌汁の塩は小さじ2';
const _where = '資料「店舗マニュアル」p.2';
const _ref = {'materialId': 'mat1', 'title': '店舗マニュアル', 'page': 2, 'lineNo': 60};

final _k = appTheme().extension<AppTokens>()!;

Map<String, dynamic> _said(String id, String speaker, String day, String text, {bool fromEdit = false}) =>
    {'id': id, 'text': text, 'speaker': speaker, 'saidAt': day, 'fromEdit': fromEdit, 'createdAt': '${day}T10:00:00Z'};

Map<String, dynamic> _patch(String id, String u, String day, String text, {String status = 'proposed'}) => {
      'id': id,
      'utteranceId': u,
      'op': 'insert',
      'line': null,
      'text': text,
      'summary': '',
      'status': status,
      'createdAt': '${day}T10:00:00Z',
      'appliedAt': status == 'applied' ? '${day}T10:00:00Z' : null,
    };

Map<String, dynamic> _check(String id, String patchId, String u,
        {String kind = 'contradiction', String? line = _mat, Object? materialRef = _ref, Map<String, dynamic>? resolution}) =>
    {
      'id': id,
      'patchId': patchId,
      'utteranceId': u,
      'kind': kind,
      'conflictLine': kind == 'contradiction' ? line : null,
      'sameLine': kind == 'same' ? line : null,
      'reason': '量が違います',
      'ask': kind == 'contradiction'
          ? {
              'candidates': [
                {'who': '店長', 'why': 'お店のやり方を決める立場なので'},
              ],
              'question': 'どちらに合わせればよいですか？',
            }
          : null,
      'resolution': resolution,
      'materialRef': materialRef,
    };

Map<String, dynamic> _resolution(String text, {String note = '資料の通り'}) =>
    {'utteranceId': 'a1', 'patchId': null, 'decidedBy': '店長', 'decidedAt': '2026-11-07', 'text': text, 'note': note};

/// キッチンのノート。既定の本文には、資料と同じ文の行がある（同じ PDF からノートも作ったとき。ADR 0012）
Map<String, dynamic> _state({
  List<Map<String, dynamic>>? lines,
  required List<Map<String, dynamic>> utterances,
  required List<Map<String, dynamic>> patches,
  required List<Map<String, dynamic>> checks,
}) =>
    {
      'owner': 'kanade',
      'me': 'kanade',
      'manual': {'id': 'm1', 'title': 'キッチン', 'base': '$_salt\n$_mat', 'createdAt': '2026-11-01T00:00:00Z'},
      'lines': lines ??
          [
            {'text': _salt, 'patchId': null},
            {'text': _mat, 'patchId': null},
          ],
      'utterances': utterances,
      'patches': patches,
      'checks': checks,
    };

/// 口頭の記録が資料と食い違った。書き込んでいないので、ノートには田中さんの行が無い
Map<String, dynamic> _oral() => _state(
      utterances: [_said('u1', '田中さん', '2026-11-03', '味噌汁の塩は小さじ1/2でいい')],
      patches: [_patch('p1', 'u1', '2026-11-03', _half)],
      checks: [_check('c1', 'p1', 'u1')],
    );

/// ノートに直接書いた「小さじ1/2」の行が、資料と食い違った
Map<String, dynamic> _edited() => _state(
      lines: [
        {'text': _salt, 'patchId': null},
        {'text': _half, 'patchId': 'p1'},
      ],
      utterances: [_said('u1', 'かなで', '2026-11-03', _half, fromEdit: true)],
      patches: [_patch('p1', 'u1', '2026-11-03', _half, status: 'applied')],
      checks: [_check('c1', 'p1', 'u1')],
    );

/// 田中さんの「小さじ1/2」を、11/7 に店長に確認して「資料のまま」に決めた（ノートは変えていない）
Map<String, dynamic> _kept() => _state(
      utterances: [
        _said('u1', '田中さん', '2026-11-03', '味噌汁の塩は小さじ1/2でいい'),
        _said('a1', '店長', '2026-11-07', '資料の通り'),
      ],
      patches: [_patch('p1', 'u1', '2026-11-03', _half, status: 'discarded')],
      checks: [_check('c1', 'p1', 'u1', resolution: _resolution(_mat))],
    );

/// 田中さんの「小さじ1/2」を、11/7 に店長に確認して資料と違う「小さじ1/2」に決め、ノートに書いた
Map<String, dynamic> _changed() => _state(
      lines: [
        {'text': _salt, 'patchId': null},
        {'text': _half, 'patchId': 'p2'},
      ],
      utterances: [
        _said('u1', '田中さん', '2026-11-03', '味噌汁の塩は小さじ1/2でいい'),
        _said('a1', '店長', '2026-11-07', '1/2で統一'),
      ],
      patches: [
        _patch('p1', 'u1', '2026-11-03', _half, status: 'discarded'),
        _patch('p2', 'a1', '2026-11-07', _half, status: 'applied'),
      ],
      checks: [
        _check('c1', 'p1', 'u1', resolution: {..._resolution(_half, note: '1/2で統一'), 'patchId': 'p2'}),
      ],
    );

/// base の確定のあと、11/10 に佐藤さんが言った said が、また資料の同じ行と食い違った（c2）
Map<String, dynamic> _saidAgain(Map<String, dynamic> base, String said) => base
  ..['utterances'].add(_said('u3', '佐藤さん', '2026-11-10', plain(said)))
  ..['patches'].add(_patch('p3', 'u3', '2026-11-10', said))
  ..['checks'].add(_check('c2', 'p3', 'u3'));

/// 送られた内容で c2 を確定した状態
Map<String, dynamic> _resolvedWith(Map<String, dynamic> j, Map<String, dynamic> body) {
  (j['utterances'] as List).add(_said('a2', body['decidedBy'], body['decidedAt'], body['note']));
  (j['checks'] as List).last['resolution'] = {
    'utteranceId': 'a2',
    'patchId': null,
    'decidedBy': body['decidedBy'],
    'decidedAt': body['decidedAt'],
    'text': body['text'],
    'note': body['note'],
  };
  return j;
}

/// 店舗マニュアル（2ページ、60行目が p.2 の「味噌汁の塩は小さじ1」）と、衛生の手引き（貼り付けた文）
List<Map<String, dynamic>> _materials() => [
      {
        'id': 'mat1',
        'title': '店舗マニュアル',
        'pageCount': 2,
        'tokens': 900,
        'createdAt': '2026-11-10T10:00:00.000Z',
        'addedBy': {'id': 'kanade', 'name': 'かなで'},
        'lines': [
          {'page': 1, 'text': '## 開店前'},
          for (var i = 2; i <= 58; i++) {'page': 1, 'text': '- 決まり$i'},
          {'page': 2, 'text': '## 味噌汁'},
          {'page': 2, 'text': _mat},
          {'page': 2, 'text': '- 決まり61'},
        ],
      },
      {
        'id': 'mat2',
        'title': '衛生の手引き',
        'pageCount': null,
        'tokens': 40,
        'createdAt': '2026-11-09T10:00:00.000Z',
        'lines': [
          {'page': null, 'text': '- 手を洗う'},
        ],
      },
    ];

Map<String, dynamic> _summary(Map<String, dynamic> m) => {
      for (final k in const ['id', 'title', 'pageCount', 'tokens', 'createdAt', 'addedBy']) k: m[k],
      'lineCount': (m['lines'] as List).length,
    };

class _Server {
  _Server(this.state, {this.afterResolve});
  Map<String, dynamic> state;

  /// 確定したあとに返す状態。無ければ同じ状態を返す
  final Map<String, dynamic> Function(Map<String, dynamic> body)? afterResolve;
  Map<String, dynamic>? resolved;

  /// 直接編集の確かめ（POST /patches/:id/check）で返す状態
  Map<String, dynamic>? afterEdit;
  Map<String, dynamic>? afterCheck;
  final materials = _materials();

  late final api = Api(
    client: MockClient((req) async {
      final path = req.url.path;
      if (path == '/me') return _json({'id': 'kanade', 'name': 'かなで', 'icon': null});
      if (path == '/shared') return _json([]);
      if (path == '/manuals') return _json([{'id': 'm1', 'title': 'キッチン', 'utteranceCount': 1, 'openCount': 1}]);
      if (path == '/manuals/m1/materials') return _json([for (final m in materials) _summary(m)]);
      if (path.startsWith('/manuals/m1/materials/')) {
        final m = materials.where((m) => m['id'] == path.split('/').last).firstOrNull;
        return m == null ? _json({'error': '資料が見つかりません'}, 404) : _json({..._summary(m), 'lines': m['lines']});
      }
      if (path.endsWith('/resolve')) {
        resolved = jsonDecode(req.body);
        if (afterResolve != null) state = afterResolve!(resolved!);
        return _json(state);
      }
      if (path == '/manuals/m1/edits') return _json(state = afterEdit!, 201);
      if (path.endsWith('/check')) return _json(state = afterCheck!);
      if (path == '/manuals/m1') return _json(state);
      return _json([]);
    }),
    baseUrl: 'http://api',
  );

  late final controller = ManualController(api, 'm1', ManualState.fromJson(state));
}

/// 最初の画面。ここから積むので、開いた画面には戻る矢印が出る。settings で「ノートの上」の印を付けて積める
class _First extends StatelessWidget {
  const _First(this.open, this.settings);
  final Widget Function() open;
  final RouteSettings? settings;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: MoonFilledButton(
            label: const Text('開く'),
            onTap: () => Navigator.push(context, MaterialPageRoute(settings: settings, builder: (_) => open())),
          ),
        ),
      );
}

Future<_Server> _pump(
  WidgetTester tester,
  Map<String, dynamic> state,
  Widget Function(ManualController c) screen, {
  Size size = _wide,
  RouteSettings? settings,
  Map<String, dynamic> Function(Map<String, dynamic> body)? afterResolve,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final server = _Server(state, afterResolve: afterResolve);
  await tester.pumpWidget(MaterialApp(theme: appTheme(), home: _First(() => screen(server.controller), settings)));
  await tester.tap(find.widgetWithText(MoonFilledButton, '開く'));
  await tester.pumpAndSettle();
  return server;
}

/// 狭い画面は確認のページ、広い画面は確認リスト（右に詳細）で開く
Widget _checkPage(ManualController c, Size size, String checkId) =>
    size.width < 900 ? CheckScreen(c: c, checkId: checkId) : CheckListScreen(c: c, initialCheckId: checkId);

/// 行の左余白の色線の色。その行の文（LineText が「・」に直した形）から探す
Iterable<Color?> _bars(WidgetTester tester, String shown) {
  final row = find.ancestor(of: find.text(shown), matching: find.byType(IntrinsicHeight)).first;
  return tester.widgetList<Container>(find.descendant(of: row, matching: find.byType(Container))).map((c) => c.color);
}

Future<void> _openForm(WidgetTester tester) async {
  final start = find.widgetWithText(MoonOutlinedButton, '聞いた結果を記録する');
  await tester.ensureVisible(start);
  await tester.tap(start);
  await tester.pumpAndSettle();
}

Future<void> _confirm(WidgetTester tester) async {
  final confirm = find.widgetWithText(MoonFilledButton, '確認済みにする');
  await tester.ensureVisible(confirm);
  await tester.pumpAndSettle();
  await tester.tap(confirm);
  await tester.pumpAndSettle();
  await tester.pump(const Duration(seconds: 10)); // 確定のトーストが消えるのを待つ
}

void main() {
  group('ノートの状態（models.dart）', () {
    ManualState s(Map<String, dynamic> j) => ManualState.fromJson(j);
    ManualLine line(ManualState st, String text) => st.lines.firstWhere((l) => l.text == text);

    test('materialRef を読む。無い確認（前からある確認）はノートの行が相手', () {
      final st = s(_oral());
      expect(st.checks.single.materialRef?.label, _where);
      expect(st.checks.single.materialRef?.lineNo, 60);
      final old = _oral();
      (old['checks'] as List).single.remove('materialRef');
      expect(s(old).checks.single.materialRef, isNull);
    });

    test('貼り付けた文の資料には、ページを付けない', () {
      final j = _oral();
      (j['checks'] as List).single['materialRef'] = {'materialId': 'mat2', 'title': '衛生の手引き', 'page': null, 'lineNo': 1};
      expect(s(j).checks.single.materialRef?.label, '資料「衛生の手引き」');
    });

    test('口頭の記録が資料と食い違っても、資料と同じ文のノートの行には印を付けない', () {
      final st = s(_oral());
      expect(st.openChecksFor(line(st, _mat)), isEmpty);
      expect(st.openChecksFor(line(st, _salt)), isEmpty);
      expect(st.checksAt('mat1', 60).single.id, 'c1');
      expect(st.checksAt('mat1', 59), isEmpty);
      expect(st.openChecksIn('mat1'), hasLength(1));
      expect(st.openChecksIn('mat2'), isEmpty);
    });

    test('直接書いた行が資料と食い違ったら、書いた行に印を付ける', () {
      final st = s(_edited());
      expect(st.openChecksFor(line(st, _half)).single.id, 'c1');
      expect(st.openChecksFor(line(st, _salt)), isEmpty);
    });

    test('資料と同じ内容の記録は、同じ文のノートの行の裏付けにしない', () {
      final st = s(_state(
        utterances: [_said('u1', '田中さん', '2026-11-03', '味噌汁の塩は小さじ1')],
        patches: [_patch('p1', 'u1', '2026-11-03', _mat, status: 'discarded')],
        checks: [_check('c1', 'p1', 'u1', kind: 'same')],
      ));
      expect(st.sameChecksFor(line(st, _mat)), isEmpty);
      expect(st.checksAt('mat1', 60).single.kind, Kind.same);
    });

    test('「資料のまま」の確定は、資料と同じ文のノートの行の確認にしない', () {
      final st = s(_kept());
      expect(st.confirmationFor(line(st, _mat)), isNull);
    });

    test('資料と違う内容に決まってノートに書いた行は、その確定の行', () {
      final st = s(_changed());
      expect(st.confirmationFor(line(st, _half))?.id, 'c1');
    });

    test('資料の行が相手なら、その資料の行に結び付いた確定を引く（資料のまま・違う内容のどちらも）', () {
      final kept = s(_saidAgain(_kept(), _half));
      expect(kept.confirmedRecordFor(kept.checks.last)?.id, 'c1');
      // ME4：資料と違う内容に決まった行をノートから消したあとでも引ける
      final changed = _saidAgain(_changed(), _two)
        ..['lines'] = [
          {'text': _salt, 'patchId': null},
        ];
      final st = s(changed);
      expect(st.confirmedRecordFor(st.checks.last)?.id, 'c1');
      // 別の行の確定は引かない
      final other = _saidAgain(_kept(), _half);
      (other['checks'] as List).last['materialRef'] = {..._ref, 'lineNo': 61};
      expect(s(other).confirmedRecordFor(s(other).checks.last), isNull);
    });
  });

  for (final size in const [_narrow, _wide]) {
    group('確認のページ（$size）', () {
      testWidgets('比較の見出しが資料の箇所になり、選択肢は「資料のまま」。選ぶと資料の行の文で確定する', (tester) async {
        final server = await _pump(tester, _oral(), (c) => _checkPage(c, size, 'c1'));
        final pair = tester.widget<ConflictPair>(find.byType(ConflictPair));
        expect(pair.leftLabel, _where);
        expect(pair.left, _mat);
        expect(pair.rightLabel, '田中さん（11/3）');
        expect(find.widgetWithText(MoonTextButton, '資料で前後を見る'), findsOneWidget);
        // 資料で前後を見る は比較のすぐ下
        expect(tester.getTopLeft(find.text('資料で前後を見る')).dy, greaterThan(tester.getBottomLeft(find.byType(ConflictPair)).dy));

        await _openForm(tester);
        expect(find.text('資料のまま'), findsOneWidget);
        expect(find.text('ノートのまま'), findsNothing);
        expect(find.text('書き換える前の内容'), findsNothing);
        final keep = find.text('資料のまま');
        await tester.ensureVisible(keep);
        await tester.tap(keep);
        await tester.pump();
        await _confirm(tester);
        expect(server.resolved, containsPair('text', _mat));
      });

      testWidgets('「資料で前後を見る」で資料の中を開き、その行まで送って薄い青の地を付ける。戻ると確認に戻る', (tester) async {
        await _pump(tester, _oral(), (c) => _checkPage(c, size, 'c1'));
        await tester.ensureVisible(find.text('資料で前後を見る'));
        await tester.tap(find.text('資料で前後を見る'));
        await tester.pumpAndSettle();

        final screen = find.byWidgetPredicate((w) => w is MaterialScreen && w.materialId == 'mat1' && w.lineNo == 60);
        expect(screen, findsOneWidget);
        final target = find.text('・味噌汁の塩は小さじ1');
        expect(tester.getRect(screen).contains(tester.getRect(target).center), isTrue);
        final box = find.ancestor(of: target, matching: find.byType(ColoredBox));
        expect(tester.widgetList<ColoredBox>(box).any((b) => b.color == _k.colors.found), isTrue);
        final other = find.ancestor(of: find.text('・決まり61'), matching: find.byType(ColoredBox));
        expect(tester.widgetList<ColoredBox>(other).any((b) => b.color == _k.colors.found), isFalse);

        await tester.tap(find.byWidgetPredicate((w) => w is MoonButton && w.semanticLabel == '戻る').last);
        await tester.pumpAndSettle();
        expect(find.byType(MaterialScreen), findsNothing);
        expect(find.byType(ConflictPair), findsOneWidget);
      });

      testWidgets('資料を消していても「資料で前後を見る」を出し、開くと「この資料は消されています」', (tester) async {
        final j = _oral();
        (j['checks'] as List).single['materialRef'] = {..._ref, 'materialId': 'gone'};
        await _pump(tester, j, (c) => _checkPage(c, size, 'c1'));
        await tester.ensureVisible(find.text('資料で前後を見る'));
        await tester.tap(find.text('資料で前後を見る'));
        await tester.pumpAndSettle();
        expect(find.text('この資料は消されています'), findsOneWidget);
      });

      testWidgets('「資料のまま」に確定した記録と食い違ったら、主のボタンは「記録を見せて、資料のままにする」', (tester) async {
        final server = await _pump(tester, _saidAgain(_kept(), _half), (c) => _checkPage(c, size, 'c2'),
            afterResolve: (body) => _resolvedWith(_saidAgain(_kept(), _half), body));
        expect(find.text('11/7 店長に確認：資料の通り'), findsOneWidget);
        expect(find.text('記録を見せて、ノートのままにする'), findsNothing);
        final keep = find.widgetWithText(MoonFilledButton, '記録を見せて、資料のままにする');
        await tester.ensureVisible(keep);
        await tester.tap(keep);
        await tester.pumpAndSettle();
        expect(server.resolved, containsPair('text', _mat));
        expect(server.resolved, containsPair('decidedBy', '店長'));
        expect(server.resolved, containsPair('decidedAt', '2026-11-07'));
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 10));
      });
    });
  }

  testWidgets('「資料のまま」に確定した記録と食い違ったら、聞いた結果の欄は「資料のまま」から始まる', (tester) async {
    final server = await _pump(tester, _saidAgain(_kept(), _half), (c) => _checkPage(c, _narrow, 'c2'));
    await _openForm(tester);
    await _confirm(tester);
    expect(server.resolved, containsPair('text', _mat));
  });

  group('資料と違う内容に確定した記録と食い違ったとき（ME4）', () {
    testWidgets('主のボタンは「記録を見せて、確定した内容にする」で、前に確定した内容で確定する', (tester) async {
      final server = await _pump(tester, _saidAgain(_changed(), _two), (c) => _checkPage(c, _narrow, 'c2'));
      expect(find.text('記録を見せて、資料のままにする'), findsNothing);
      final keep = find.widgetWithText(MoonFilledButton, '記録を見せて、確定した内容にする');
      await tester.ensureVisible(keep);
      await tester.tap(keep);
      await tester.pumpAndSettle();
      expect(server.resolved, containsPair('text', _half));
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('聞いた結果の欄は、前に確定した内容を入れた「別の内容に決まった」から始まる', (tester) async {
      final server = await _pump(tester, _saidAgain(_changed(), _two), (c) => _checkPage(c, _narrow, 'c2'));
      await _openForm(tester);
      final custom = find.descendant(of: find.byType(MoonTextInput), matching: find.byType(EditableText));
      expect(tester.widgetList<EditableText>(custom).any((e) => e.controller.text == _half), isTrue);
      await _confirm(tester);
      expect(server.resolved, containsPair('text', _half));
    });
  });

  for (final size in const [_narrow, _wide]) {
    testWidgets('確認リストの行は「資料「…」p.2：資料の行 ／ 言われた行」（$size）', (tester) async {
      final j = _saidAgain(_kept(), _half);
      await _pump(tester, j, (c) => CheckListScreen(c: c), size: size);
      // あとで確認（c2）と確認済み（c1）の両方
      expect(find.text('$_where：味噌汁の塩は小さじ1 ／ 味噌汁の塩は小さじ1/2'), findsNWidgets(2));
    });
  }

  testWidgets('ノートの行が相手の確認は、今まで通り「ノート」で、「資料で前後を見る」を出さない', (tester) async {
    final j = _oral();
    (j['checks'] as List).single
      ..['materialRef'] = null
      ..['conflictLine'] = _salt;
    await _pump(tester, j, (c) => _checkPage(c, _wide, 'c1'));
    expect(tester.widget<ConflictPair>(find.byType(ConflictPair)).leftLabel, 'ノート');
    expect(find.text('資料で前後を見る'), findsNothing);
    expect(find.text('塩 小さじ1 ／ 味噌汁の塩は小さじ1/2'), findsOneWidget);
    await _openForm(tester);
    expect(find.text('ノートのまま'), findsOneWidget);
    expect(find.text('資料のまま'), findsNothing);
  });

  testWidgets('広い画面で確認リストから資料を開くと、パンくずは「ノート / 確認リスト / 資料」。確認リストを押すと1枚戻る', (tester) async {
    await _pump(tester, _oral(), (c) => CheckListScreen(c: c, initialCheckId: 'c1'),
        settings: const RouteSettings(name: 'above-note:1'));
    await tester.ensureVisible(find.text('資料で前後を見る'));
    await tester.tap(find.text('資料で前後を見る'));
    await tester.pumpAndSettle();
    final bar = find.descendant(of: find.byType(MaterialScreen), matching: find.byType(TopBar));
    for (final crumb in ['キッチン', '確認リスト', '店舗マニュアル']) {
      expect(find.descendant(of: bar, matching: find.text(crumb)), findsOneWidget);
    }
    expect(find.descendant(of: bar, matching: find.text('資料')), findsNothing);
    await tester.tap(find.descendant(of: bar, matching: find.text('確認リスト')));
    await tester.pumpAndSettle();
    expect(find.byType(MaterialScreen), findsNothing);
    expect(find.byType(CheckListScreen), findsOneWidget);
  });

  group('資料の中の行の印', () {
    for (final size in const [_narrow, _wide]) {
      testWidgets('食い違っている行は黄の線と「／ 田中さん（11/3）：…」「食い違い」。押すと確認リストでその食い違いを開く（$size）',
          (tester) async {
        await _pump(tester, _oral(), (c) => MaterialScreen(c: c, materialId: 'mat1', lineNo: 60), size: size);
        expect(find.text('・味噌汁の塩は小さじ1'), findsOneWidget);
        expect(find.text('田中さん（11/3）：'), findsOneWidget);
        expect(find.text('食い違い'), findsOneWidget);
        expect(_bars(tester, '・味噌汁の塩は小さじ1'), contains(_k.colors.pending));
        expect(_bars(tester, '・決まり61'), isNot(contains(_k.colors.pending)));
        // 題名の下に、この資料のあとで確認の数
        expect(find.descendant(of: find.byType(PageTitle), matching: find.text('あとで確認 1 件')), findsOneWidget);

        await tester.tap(find.text('・味噌汁の塩は小さじ1'));
        await tester.pumpAndSettle();
        final opened = size == _narrow
            ? find.byWidgetPredicate((w) => w is CheckScreen && w.checkId == 'c1')
            : find.byWidgetPredicate((w) => w is CheckDetail && w.checkId == 'c1');
        expect(opened, findsOneWidget);
      });
    }

    testWidgets('「資料のまま」の確定は緑の線と「店長 11/7 に確認」。押すとその確認の記録を開く', (tester) async {
      await _pump(tester, _kept(), (c) => MaterialScreen(c: c, materialId: 'mat1', lineNo: 60));
      expect(_bars(tester, '・味噌汁の塩は小さじ1'), contains(_k.colors.added));
      final speaker = find.byWidgetPredicate((w) => w is Speaker && w.name == '店長' && w.after == 'に確認');
      expect(speaker, findsOneWidget);
      expect(find.textContaining('に決まった'), findsNothing);
      expect(find.text('食い違い'), findsNothing);
      expect(find.descendant(of: find.byType(PageTitle), matching: find.textContaining('あとで確認')), findsNothing);
      await tester.tap(speaker);
      await tester.pumpAndSettle();
      expect(find.byWidgetPredicate((w) => w is CheckDetail && w.checkId == 'c1'), findsOneWidget);
      expect(find.text('確認の記録'), findsWidgets);
    });

    testWidgets('資料と違う内容に決まった確定は、決まった内容を添える', (tester) async {
      await _pump(tester, _changed(), (c) => MaterialScreen(c: c, materialId: 'mat1', lineNo: 60));
      expect(find.byWidgetPredicate((w) => w is Speaker && w.name == '店長' && w.after == 'に確認'), findsOneWidget);
      expect(find.text('「味噌汁の塩は小さじ1/2」に決まった'), findsOneWidget);
    });

    testWidgets('本人が決めた確定は「が決定」', (tester) async {
      final j = _kept();
      ((j['checks'] as List).single['resolution'] as Map<String, dynamic>)['answeredBy'] = 'tencho';
      await _pump(tester, j, (c) => MaterialScreen(c: c, materialId: 'mat1', lineNo: 60));
      expect(find.byWidgetPredicate((w) => w is Speaker && w.name == '店長' && w.after == 'が決定'), findsOneWidget);
    });

    testWidgets('資料と同じ内容の記録は「田中さん 11/3 も同じ」', (tester) async {
      await _pump(
        tester,
        _state(
          utterances: [_said('u1', '田中さん', '2026-11-03', '味噌汁の塩は小さじ1')],
          patches: [_patch('p1', 'u1', '2026-11-03', _mat, status: 'discarded')],
          checks: [_check('c1', 'p1', 'u1', kind: 'same')],
        ),
        (c) => MaterialScreen(c: c, materialId: 'mat1', lineNo: 60),
      );
      expect(find.byWidgetPredicate((w) => w is Speaker && w.name == '田中さん'), findsOneWidget);
      expect(find.text('も同じ'), findsOneWidget);
    });

    testWidgets('確認リストで確定すると、開いている資料の中の印も変わる', (tester) async {
      final server = await _pump(tester, _oral(), (c) => MaterialScreen(c: c, materialId: 'mat1', lineNo: 60));
      expect(find.text('食い違い'), findsOneWidget);
      server.state = _kept();
      await server.controller.load();
      await tester.pumpAndSettle();
      expect(find.text('食い違い'), findsNothing);
      expect(find.byWidgetPredicate((w) => w is Speaker && w.name == '店長' && w.after == 'に確認'), findsOneWidget);
    });
  });

  for (final size in const [_narrow, _wide]) {
    testWidgets('資料の一覧で、資料ごとの「あとで確認 N 件」（$size）', (tester) async {
      await _pump(tester, _saidAgain(_oral(), _two), (c) => MaterialsScreen(c: c), size: size);
      final first = find.ancestor(of: find.text('店舗マニュアル'), matching: find.byType(PaperSheet));
      final second = find.ancestor(of: find.text('衛生の手引き'), matching: find.byType(PaperSheet));
      expect(find.descendant(of: first, matching: find.text('あとで確認 2 件')), findsOneWidget);
      expect(find.descendant(of: second, matching: find.textContaining('あとで確認')), findsNothing);
    });
  }

  group('ノートのページ', () {
    for (final size in const [_narrow, _wide]) {
      testWidgets('口頭の記録が資料と食い違っても、資料と同じ文のノートの行に印を付けない（$size）', (tester) async {
        await _pump(tester, _oral(), (c) => ManualScreen(api: c.api, manualId: 'm1'), size: size);
        expect(find.text('・味噌汁の塩は小さじ1'), findsOneWidget);
        expect(find.text('食い違い'), findsNothing);
        expect(find.text('田中さん（11/3）：'), findsNothing);
      });
    }

    testWidgets('直接書いた行が資料と食い違ったら、その行に「／ 資料「…」p.2：資料の行」「食い違い」', (tester) async {
      await _pump(tester, _edited(), (c) => ManualScreen(api: c.api, manualId: 'm1'));
      expect(find.text('$_where：'), findsOneWidget);
      expect(find.text('味噌汁の塩は小さじ1'), findsOneWidget);
      expect(find.text('食い違い'), findsOneWidget);
      expect(_bars(tester, '・味噌汁の塩は小さじ1/2'), contains(_k.colors.pending));
      expect(_bars(tester, '・塩 小さじ1'), isNot(contains(_k.colors.pending)));
    });

    testWidgets('直接書いた行が資料と食い違ったら「資料「…」p.2 の「…」と食い違っています」と知らせる', (tester) async {
      final server = await _pump(
        tester,
        _state(utterances: [], patches: [], checks: []),
        (c) => ManualScreen(api: c.api, manualId: 'm1'),
      );
      final written = _edited();
      final pending = _edited()..['checks'] = <Map<String, dynamic>>[];
      server.afterEdit = pending;
      server.afterCheck = written;
      await tester.tap(find.text('・塩 小さじ1'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText).first, _half);
      await tester.tap(find.widgetWithText(MoonFilledButton, '保存する'));
      await tester.pumpAndSettle();
      expect(find.text('$_where の「味噌汁の塩は小さじ1」と食い違っています。確認リストに入れました'), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
    });
  });

  group('入力ページの結果のカード', () {
    Future<void> pumpCard(WidgetTester tester, Map<String, dynamic> j, String utteranceId, {Size size = _wide}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: appTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: RecordResultCard(
              records: [(manualId: 'm1', utteranceId: utteranceId, state: ManualState.fromJson(j))],
              onReview: () {},
              onClose: () {},
            ),
          ),
        ),
      ));
    }

    for (final size in const [_narrow, _wide]) {
      testWidgets('資料と食い違ったら「資料と食い違っています」。比較の見出しは資料の箇所（$size）', (tester) async {
        await pumpCard(tester, _oral(), 'u1', size: size);
        expect(find.text('資料と食い違っています'), findsOneWidget);
        expect(tester.widget<ConflictPair>(find.byType(ConflictPair)).leftLabel, _where);
      });
    }

    testWidgets('「資料のまま」の確定と食い違ったら、誰の決定と食い違ったかと、その記録を出す', (tester) async {
      await pumpCard(tester, _saidAgain(_kept(), _half), 'u3');
      expect(find.text('店長に確認済みの決定と食い違っています'), findsOneWidget);
      expect(tester.widget<ConflictPair>(find.byType(ConflictPair)).leftLabel, _where);
      expect(find.text('11/7 店長に確認：資料の通り'), findsOneWidget);
      expect(find.text('11/7 に店長に確認して、「味噌汁の塩は小さじ1」に決まっています（資料の通り）。'), findsOneWidget);
    });

    testWidgets('資料と同じ内容なら「資料と同じ内容でした」と、資料の箇所つきの行', (tester) async {
      await pumpCard(
        tester,
        _state(
          utterances: [_said('u1', '田中さん', '2026-11-03', '味噌汁の塩は小さじ1')],
          patches: [_patch('p1', 'u1', '2026-11-03', _mat)],
          checks: [_check('c1', 'p1', 'u1', kind: 'same')],
        ),
        'u1',
      );
      expect(find.text('資料と同じ内容でした（記録として残しました）'), findsOneWidget);
      expect(find.text('$_where：味噌汁の塩は小さじ1'), findsOneWidget);
    });
  });

  group('書き込む前の確認', () {
    Future<void> pumpReview(WidgetTester tester, Map<String, dynamic> j) async {
      tester.view.physicalSize = _wide;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = _Server(j).controller;
      await tester.pumpWidget(MaterialApp(
        theme: appTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => MoonOutlinedButton(
              label: const Text('開く'),
              onTap: () => showReview(context, [(c: c, utteranceId: 'u1')]),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('開く'));
      await tester.pumpAndSettle();
    }

    testWidgets('資料と同じ内容なら「資料「…」p.2 の「…」と同じ内容です」', (tester) async {
      await pumpReview(
        tester,
        _state(
          utterances: [_said('u1', '田中さん', '2026-11-03', '味噌汁の塩は小さじ1')],
          patches: [_patch('p1', 'u1', '2026-11-03', _mat)],
          checks: [_check('c1', 'p1', 'u1', kind: 'same')],
        ),
      );
      expect(find.text('$_where の「味噌汁の塩は小さじ1」と同じ内容です。本文は変えずに、言われた記録として残します'), findsOneWidget);
    });

    testWidgets('資料と食い違ったら、比較の見出しは資料の箇所', (tester) async {
      await pumpReview(tester, _oral());
      expect(tester.widget<ConflictPair>(find.byType(ConflictPair)).leftLabel, _where);
    });
  });

  testWidgets('履歴の枝は「資料「…」p.2：資料の行 ／ 言われた行」', (tester) async {
    await _pump(tester, _oral(), (c) => HistoryScreen(c: c));
    expect(find.textContaining('$_where：味噌汁の塩は小さじ1 ／ 味噌汁の塩は小さじ1/2'), findsWidgets);
  });
}
