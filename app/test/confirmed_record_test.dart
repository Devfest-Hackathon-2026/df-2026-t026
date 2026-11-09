import 'dart:convert';

import 'package:diff_note/api.dart';
import 'package:diff_note/manual_controller.dart';
import 'package:diff_note/models.dart';
import 'package:diff_note/screens/check_list_screen.dart';
import 'package:diff_note/screens/check_screen.dart';
import 'package:diff_note/screens/common.dart';
import 'package:diff_note/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moon_design/moon_design.dart';

// 確定した記録を、次に食い違うことを言われたときの証拠として確認の画面に出す

const _half = '- 塩 小さじ1/2';
const _one = '- 塩 小さじ1';
const _record = '11/7 店長に確認：1/2で統一';
const _showText = '11/7 に店長に確認して、「塩 小さじ1/2」に決まっています（1/2で統一）。';

Map<String, dynamic> _said(String id, String speaker, String day, String text, {bool fromEdit = false}) =>
    {'id': id, 'text': text, 'speaker': speaker, 'saidAt': day, 'fromEdit': fromEdit, 'createdAt': '${day}T10:00:00Z'};

Map<String, dynamic> _patch(String id, String u, String day, String line, String text, {String status = 'applied'}) => {
      'id': id,
      'utteranceId': u,
      'op': 'replace',
      'line': line,
      'text': text,
      'summary': '',
      'status': status,
      'createdAt': '${day}T10:00:00Z',
      'appliedAt': status == 'applied' ? '${day}T10:00:00Z' : null,
    };

Map<String, dynamic> _check(String id, String patchId, String u, String conflictLine,
        {Map<String, dynamic>? resolution}) =>
    {
      'id': id,
      'patchId': patchId,
      'utteranceId': u,
      'kind': 'contradiction',
      'conflictLine': conflictLine,
      'sameLine': null,
      'reason': '両立しません',
      'ask': {
        'candidates': [
          {'who': '店長', 'why': 'お店のやり方を決める立場なので'},
        ],
        'question': 'どちらに合わせればよいですか？',
      },
      'resolution': resolution,
    };

/// 田中さんの「小さじ1/2」を 11/7 に店長に確認して 1/2 に決めた。そのあと 11/10 に佐藤さんが「小さじ1」と言った
Map<String, dynamic> _confirmed() => {
      'manual': {'id': 'm1', 'title': 'キッチン', 'base': _one, 'createdAt': '2026-11-01T00:00:00Z'},
      'lines': [
        {'text': _half, 'patchId': 'p2'},
      ],
      'utterances': [
        _said('u1', '田中さん', '2026-11-03', '塩は小さじ1/2でいい'),
        _said('a1', '店長', '2026-11-07', '1/2で統一'),
        _said('u3', '佐藤さん', '2026-11-10', '塩は小さじ1だよ'),
      ],
      'patches': [
        _patch('p1', 'u1', '2026-11-03', _one, _half, status: 'discarded'),
        _patch('p2', 'a1', '2026-11-07', _one, _half),
        _patch('p3', 'u3', '2026-11-10', _half, _one, status: 'proposed'),
      ],
      'checks': [
        _check('c1', 'p1', 'u1', _one, resolution: {
          'utteranceId': 'a1',
          'patchId': 'p2',
          'decidedBy': '店長',
          'decidedAt': '2026-11-07',
          'text': _half,
          'note': '1/2で統一',
        }),
        _check('c2', 'p3', 'u3', _half),
      ],
    };

/// 確定した「小さじ1/2」を、共有された佐藤店長が「小さじ1」に書き換えた（#86）。相手の行はもうノートに無い
Map<String, dynamic> _rewritten() {
  final j = _confirmed();
  j['lines'] = [
    {'text': _one, 'patchId': 'p3'},
  ];
  final said = (j['utterances'] as List).last as Map<String, dynamic>;
  said.addAll({'speaker': '佐藤店長', 'text': _one, 'fromEdit': true, 'editedBy': 'sato'});
  (j['patches'] as List).last.addAll({'status': 'applied', 'appliedAt': '2026-11-10T10:00:00Z'});
  return j;
}

/// まだ誰にも確認していない食い違い。田中さんの「小さじ1/2」がノートの「小さじ1」と食い違う
Map<String, dynamic> _unconfirmed() => {
      'manual': {'id': 'm1', 'title': 'キッチン', 'base': _one, 'createdAt': '2026-11-01T00:00:00Z'},
      'lines': [
        {'text': _one, 'patchId': null},
      ],
      'utterances': [
        _said('u1', '田中さん', '2026-11-03', '塩は小さじ1/2でいい'),
      ],
      'patches': [
        _patch('p1', 'u1', '2026-11-03', _one, _half, status: 'proposed'),
      ],
      'checks': [
        _check('c1', 'p1', 'u1', _one),
      ],
    };

class _Server {
  _Server(this.state);
  final Map<String, dynamic> state;
  Map<String, dynamic>? resolved;

  late final api = Api(
    client: MockClient((req) async {
      if (req.url.path.endsWith('/resolve')) resolved = jsonDecode(req.body);
      return http.Response.bytes(utf8.encode(jsonEncode(state)), 200);
    }),
    baseUrl: 'http://api',
  );
}

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<_Server> _pumpCheck(WidgetTester tester, Map<String, dynamic> state, String checkId,
    {Size size = const Size(390, 844)}) async {
  _size(tester, size);
  final server = _Server(state);
  final c = ManualController(server.api, 'm1', ManualState.fromJson(state));
  await tester.pumpWidget(MaterialApp(
    theme: appTheme(),
    home: size.width < 900 ? CheckScreen(c: c, checkId: checkId) : CheckListScreen(c: c, initialCheckId: checkId),
  ));
  await tester.pumpAndSettle();
  return server;
}

Iterable<ConfirmStamp> _bigStamps(WidgetTester tester) =>
    tester.widgetList<ConfirmStamp>(find.byType(ConfirmStamp)).where((s) => !s.compact);

/// 聞いた結果の欄を開き、選択肢を選ばずに「確認済みにする」を押す
Future<void> _confirmAsIs(WidgetTester tester) async {
  final start = find.widgetWithText(MoonOutlinedButton, '聞いた結果を記録する');
  await tester.ensureVisible(start);
  await tester.tap(start);
  await tester.pumpAndSettle();
  final confirm = find.widgetWithText(MoonFilledButton, '確認済みにする');
  await tester.ensureVisible(confirm);
  await tester.pumpAndSettle();
  await tester.tap(confirm);
  await tester.pumpAndSettle();
  await tester.pump(const Duration(seconds: 10)); // 確定のトーストが消えるのを待つ
}

void main() {
  group('confirmedRecordFor', () {
    Check? recordOf(Map<String, dynamic> j, String checkId) {
      final s = ManualState.fromJson(j);
      return s.confirmedRecordFor(s.checks.firstWhere((c) => c.id == checkId));
    }

    test('相手の行に確認の印があれば、その確認', () => expect(recordOf(_confirmed(), 'c2')?.id, 'c1'));
    test('相手の行がもう無くても、同じ内容に確定した確認', () => expect(recordOf(_rewritten(), 'c2')?.id, 'c1'));
    test('確定済みでない相手なら null', () => expect(recordOf(_unconfirmed(), 'c1'), isNull));
    test('確認済みの食い違いには出さない', () => expect(recordOf(_confirmed(), 'c1'), isNull));
  });

  testWidgets('確定済みと食い違った確認では、確定の記録と見せる文を出し、最初の選択は「ノートのまま」', (tester) async {
    final server = await _pumpCheck(tester, _confirmed(), 'c2');

    expect(find.text(_record), findsOneWidget);
    expect(find.text('確定した内容：塩 小さじ1/2'), findsOneWidget);
    expect(_bigStamps(tester), hasLength(1));
    expect(find.text('記録を見せる'), findsOneWidget);
    expect(find.text(_showText), findsOneWidget);
    // 比較のすぐ下に記録、そのあと見せる文、そのあと「誰に確認する？」
    final compare = tester.getBottomLeft(find.byType(ConflictPair)).dy;
    final record = tester.getTopLeft(find.text(_record)).dy;
    final show = tester.getTopLeft(find.text(_showText)).dy;
    final ask = tester.getTopLeft(find.text('誰に確認する？')).dy;
    expect(compare < record && record < show && show < ask, isTrue);
    // 「誰に確認する？」の中身はそのまま
    expect(find.text('お店のやり方を決める立場なので'), findsOneWidget);
    expect(find.text('どちらに合わせればよいですか？'), findsOneWidget);

    // 見せる文はコピーできる
    String? copied;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'];
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final copy = find.byWidgetPredicate((w) => w is MoonButton && w.semanticLabel == '記録を見せる文をコピーする');
    await tester.ensureVisible(copy);
    await tester.tap(copy);
    await tester.pump();
    expect(copied, _showText);
    await tester.pump(const Duration(seconds: 10)); // コピーのトーストが消えるのを待つ

    await _confirmAsIs(tester);
    expect(find.text('ノートのまま'), findsOneWidget);
    expect(server.resolved, containsPair('text', _half));
  });

  for (final size in const [Size(390, 844), Size(1440, 900)]) {
    testWidgets('確定の記録を押すと、その確認の記録が開く（$size）', (tester) async {
      await _pumpCheck(tester, _confirmed(), 'c2', size: size);
      expect(find.text('あとで確認すること'), findsOneWidget);

      await tester.ensureVisible(find.text(_record));
      await tester.tap(find.text(_record));
      await tester.pumpAndSettle();

      expect(find.text('あとで確認すること'), findsNothing);
      expect(find.text('確認の記録'), findsWidgets);
      final top = size.width < 900
          ? find.byWidgetPredicate((w) => w is CheckScreen && w.checkId == 'c1')
          : find.byWidgetPredicate((w) => w is CheckDetail && w.checkId == 'c1');
      expect(top, findsOneWidget);
    });
  }

  testWidgets('相手の行が書き換えられて無いときも記録を出し、最初の選択は「書き換える前の内容」', (tester) async {
    final server = await _pumpCheck(tester, _rewritten(), 'c2');

    expect(find.text(_record), findsOneWidget);
    expect(_bigStamps(tester), hasLength(1));
    expect(find.text(_showText), findsOneWidget);

    await _confirmAsIs(tester);
    expect(find.text('書き換える前の内容'), findsOneWidget);
    expect(find.text('ノートのまま'), findsNothing);
    expect(server.resolved, containsPair('text', _half));
  });

  testWidgets('確定済みでない食い違いでは、記録も見せる文も出さず、最初の選択は言った人の側', (tester) async {
    final server = await _pumpCheck(tester, _unconfirmed(), 'c1');

    expect(find.byType(ConfirmStamp), findsNothing);
    expect(find.text('記録を見せる'), findsNothing);
    expect(find.byWidgetPredicate((w) => w is MoonButton && w.semanticLabel == '記録を見せる文をコピーする'), findsNothing);

    await _confirmAsIs(tester);
    expect(find.text('田中さんの言う通り'), findsOneWidget);
    expect(server.resolved, containsPair('text', _half));
  });
}
