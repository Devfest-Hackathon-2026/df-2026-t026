import 'dart:convert';

import 'package:diff_note/api.dart';
import 'package:diff_note/manual_controller.dart';
import 'package:diff_note/models.dart';
import 'package:diff_note/screens/check_list_screen.dart';
import 'package:diff_note/screens/check_screen.dart';
import 'package:diff_note/screens/common.dart';
import 'package:diff_note/screens/manual_screen.dart';
import 'package:diff_note/screens/tab_bar.dart';
import 'package:diff_note/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// 記録を見せて済ませた確定（#118）。決めたのは前の店長で、見せたのは記録した人。
// 行の印・証拠は元の確定を指し、見せたことは見せた人の行いとして出す

const _half = '- 塩 小さじ1/2';
const _one = '- 塩 小さじ1';
const _shownText = '11/7 店長に確認した記録（1/2で統一）を見せた';

Map<String, dynamic> _said(String id, String speaker, String at, String text, {Map<String, dynamic>? recordedBy}) => {
      'id': id,
      'text': text,
      'speaker': speaker,
      'saidAt': at.substring(0, 10),
      'fromEdit': false,
      'recordedBy': ?recordedBy,
      'createdAt': at,
    };

Map<String, dynamic> _patch(String id, String u, String at, String line, String text, {String status = 'applied'}) => {
      'id': id,
      'utteranceId': u,
      'op': 'replace',
      'line': line,
      'text': text,
      'summary': '',
      'status': status,
      'createdAt': at,
      'appliedAt': status == 'applied' ? at : null,
    };

Map<String, dynamic> _check(String id, String patchId, String u, String conflictLine, {Map<String, dynamic>? resolution}) => {
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

const _kanade = {'id': 'demo', 'name': 'かなで'};
const _decided = {'decidedBy': '店長', 'decidedAt': '2026-11-07', 'text': _half, 'note': '1/2で統一'};

/// 田中さんの「小さじ1/2」を 11/7 に店長に確認して 1/2 に決めた（c1）。11/10 に佐藤さんが「小さじ1」と言い、
/// かなでが店長に確認した記録を見せて済ませた（c2）。me は読んでいる人
Map<String, dynamic> _shown({String me = 'demo'}) => {
      'owner': 'demo',
      'me': me,
      if (me != 'demo') 'sharedBy': _kanade,
      'manual': {'id': 'm1', 'title': 'キッチン', 'base': _one, 'createdAt': '2026-11-01T00:00:00Z'},
      'lines': [
        {'text': _half, 'patchId': 'p2'},
      ],
      'utterances': [
        _said('u1', '田中さん', '2026-11-03T10:00:00Z', '塩は小さじ1/2でいい'),
        _said('a1', '店長', '2026-11-07T10:00:00Z', '1/2で統一'),
        _said('u3', '佐藤さん', '2026-11-10T10:00:00Z', '塩は小さじ1だよ'),
        _said('a2', 'かなで', '2026-11-10T11:00:00Z', _shownText, recordedBy: _kanade),
      ],
      'patches': [
        _patch('p1', 'u1', '2026-11-03T10:00:00Z', _one, _half, status: 'discarded'),
        _patch('p2', 'a1', '2026-11-07T10:00:00Z', _one, _half),
        _patch('p3', 'u3', '2026-11-10T10:00:00Z', _half, _one, status: 'discarded'),
      ],
      'checks': [
        _check('c1', 'p1', 'u1', _one, resolution: {..._decided, 'utteranceId': 'a1', 'patchId': 'p2'}),
        _check('c2', 'p3', 'u3', _half, resolution: {
          ..._decided,
          'utteranceId': 'a2',
          'patchId': null,
          'shown': {'by': _kanade, 'at': '2026-11-10'},
        }),
      ],
    };

/// そのあと 11/11 に鈴木さんがまた「小さじ1」と言った（c4、あとで確認）
Map<String, dynamic> _saidAgain(Map<String, dynamic> j) => j
  ..['utterances'].add(_said('u4', '鈴木さん', '2026-11-11T10:00:00Z', '塩は小さじ1'))
  ..['patches'].add(_patch('p4', 'u4', '2026-11-11T10:00:00Z', _half, _one, status: 'proposed'))
  ..['checks'].add(_check('c4', 'p4', 'u4', _half));

Api _api(Map<String, dynamic> state) =>
    Api(client: MockClient((_) async => http.Response.bytes(utf8.encode(jsonEncode(state)), 200)), baseUrl: 'http://api');

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _pump(WidgetTester tester, Widget home, {Size size = const Size(1440, 900)}) async {
  _size(tester, size);
  await tester.pumpWidget(MaterialApp(theme: appTheme(), home: home));
  await tester.pumpAndSettle();
}

/// ノート本文の、その行に並ぶ印
Finder _marksOf(String line) =>
    find.ancestor(of: find.byWidgetPredicate((w) => w is LineText && w.line == line), matching: find.byType(Wrap)).first;

void main() {
  group('ノートの状態（models.dart）', () {
    test('見せた人と日を読む。前からある確定には無い', () {
      final s = ManualState.fromJson(_shown());
      final shown = s.checks.last.resolution!.shown!;
      expect([shown.by.id, shown.by.name, shown.at], ['demo', 'かなで', '2026-11-10']);
      expect(s.checks.first.resolution!.shown, isNull);
      expect([s.checks.first.isDecision, s.checks.last.isDecision], [true, false]);
    });

    test('ノートの行の確認と、次に食い違ったときの証拠は、見せた確定でなく元の確定', () {
      final s = ManualState.fromJson(_saidAgain(_shown()));
      expect(s.confirmationFor(s.lines.single)?.id, 'c1');
      expect(s.confirmedRecordFor(s.checks.last)?.id, 'c1');
    });
  });

  for (final size in const [Size(390, 844), Size(1440, 900)]) {
    testWidgets('ノートの行の印は元の「店長 11/7 に確認」の1つで、押すと元の確定の記録が開く（$size）', (tester) async {
      await _pump(tester, ManualScreen(api: _api(_shown()), manualId: 'm1'), size: size);
      final marks = _marksOf(_half);
      final confirmed = find.descendant(of: marks, matching: find.byType(Speaker));
      expect(confirmed, findsOneWidget);
      final mark = tester.widget<Speaker>(confirmed);
      expect([mark.name, mark.day, mark.after], ['店長', '2026-11-07', 'に確認']);

      await tester.tap(find.descendant(of: marks, matching: find.text('に確認')));
      await tester.pumpAndSettle();
      final opened = size.width < 900
          ? find.byWidgetPredicate((w) => w is CheckScreen && w.checkId == 'c1')
          : find.byWidgetPredicate((w) => w is CheckDetail && w.checkId == 'c1');
      expect(opened, findsOneWidget);
    });
  }

  group('確認リストの確認済み', () {
    testWidgets('見せた確定は「11/10 自分が記録を見せた（11/7 店長に確認：1/2で統一）」。元の確定は今までどおり', (tester) async {
      final s = ManualState.fromJson(_shown());
      await _pump(tester, CheckListScreen(c: ManualController(_api(_shown()), 'm1', s), initialCheckId: 'c1'));
      expect(find.text('11/10 自分が記録を見せた（11/7 店長に確認：1/2で統一）'), findsOneWidget);
      // 店長の確認として出るのは元の確定の行だけ
      expect(find.byWidgetPredicate((w) => w is Speaker && w.name == '店長' && w.after == 'に確認'), findsOneWidget);
    });

    testWidgets('共有された人が見ると、見せた人は名前で出る', (tester) async {
      final j = _shown(me: 'sato');
      await _pump(tester, CheckListScreen(c: ManualController(_api(j), 'm1', ManualState.fromJson(j)), initialCheckId: 'c1'));
      expect(find.text('11/10 かなでが記録を見せた（11/7 店長に確認：1/2で統一）'), findsOneWidget);
    });

    testWidgets('見せた確定の記録を開くと、確認印と中身は元の確定のまま、上に「11/10 自分が記録を見せた」', (tester) async {
      final s = ManualState.fromJson(_shown());
      await _pump(tester, CheckScreen(c: ManualController(_api(_shown()), 'm1', s), checkId: 'c2'), size: const Size(390, 844));
      expect(find.text('11/10 自分が記録を見せた'), findsOneWidget);
      expect(find.text('11/7 店長に確認：1/2で統一'), findsOneWidget);
      final stamps = tester.widgetList<ConfirmStamp>(find.byType(ConfirmStamp)).where((x) => !x.compact);
      expect([for (final x in stamps) (x.who, x.day, x.decided)], [('店長', '2026-11-07', false)]);
    });
  });

  testWidgets('確定のときに残した答え（店長の確認の答え・見せた記録）は、記録した発言の付箋にも件数にも混ぜない', (tester) async {
    await _pump(tester, ManualScreen(api: _api(_shown()), manualId: 'm1'));
    final notes = find.byType(StickyNote);
    expect(find.descendant(of: notes, matching: find.text('塩は小さじ1/2でいい')), findsOneWidget);
    expect(find.descendant(of: notes, matching: find.text('塩は小さじ1だよ')), findsOneWidget);
    expect(find.descendant(of: notes, matching: find.text('1/2で統一')), findsNothing);
    expect(find.descendant(of: notes, matching: find.text(_shownText)), findsNothing);
    expect(find.text('記録した発言（2）'), findsOneWidget);
  });

  testWidgets('履歴では、見せた版は見せた人と「…記録（1/2で統一）を見せた」で、店長の確認にしない', (tester) async {
    await _pump(tester, ManualScreen(api: _api(_shown()), manualId: 'm1'), size: const Size(390, 844));
    await tester.tap(find.descendant(of: find.byType(NoteTabBar), matching: find.text('履歴')));
    await tester.pumpAndSettle();
    expect(find.textContaining('かなで  11/10  $_shownText'), findsOneWidget);
    // 「11/7 に確認」の版は元の確定の1つだけ
    expect(find.textContaining('店長  11/7 に確認'), findsOneWidget);
  });
}
