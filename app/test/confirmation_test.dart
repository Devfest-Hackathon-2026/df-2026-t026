import 'dart:convert';

import 'package:diff_note/api.dart';
import 'package:diff_note/models.dart';
import 'package:diff_note/screens/check_list_screen.dart';
import 'package:diff_note/screens/check_screen.dart';
import 'package:diff_note/screens/common.dart';
import 'package:diff_note/screens/manual_screen.dart';
import 'package:diff_note/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moon_design/moon_design.dart';

// #91 確認済みの行に補足が入っても、行の「〇〇に確認」を残す

const _kept = '- 大盛りは250gまで';
const _weekend = '- 大盛りは250gまで（土日は受けない）';

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

Map<String, dynamic> _check(String id, String patchId, String u, String kind,
        {String? conflictLine, Map<String, dynamic>? resolution}) =>
    {
      'id': id,
      'patchId': patchId,
      'utteranceId': u,
      'kind': kind,
      'conflictLine': conflictLine,
      'sameLine': null,
      'reason': '',
      'ask': kind == 'contradiction' ? {'candidates': [], 'question': 'どちらですか？'} : null,
      'resolution': resolution,
    };

/// 見本のキッチンマニュアルと同じ形：田中さんの「300gまで」を 11/5 に店長に確認して 250g のまま。
/// そのあと 11/10 に店長の「土日は受けない」が補足（qualification）として入った
Map<String, dynamic> _qualified({String qualifiedBy = '店長', String kind = 'qualification', bool fromEdit = false}) => {
      'owner': 'demo',      'me': 'demo',      'manual': {'id': 'm1', 'title': 'キッチンマニュアル', 'base': _kept, 'createdAt': '2026-11-01T00:00:00Z'},
      'lines': [
        {'text': _weekend, 'patchId': 'p2'},
      ],
      'utterances': [
        _said('u1', '田中さん', '2026-11-04', '大盛りは300gまで盛っていいよ'),
        _said('a1', '店長', '2026-11-05', '原価があるので、大盛りは250gまでのまま'),
        _said('u2', qualifiedBy, '2026-11-10', '土日は混むからご飯の大盛りは受けない', fromEdit: fromEdit),
      ],
      'patches': [
        _patch('p1', 'u1', '2026-11-04', _kept, '- 大盛りは300gまで', status: 'discarded'),
        _patch('p2', 'u2', '2026-11-10', _kept, _weekend),
      ],
      'checks': [
        _check('c1', 'p1', 'u1', 'contradiction', conflictLine: _kept, resolution: {
          'utteranceId': 'a1',
          'patchId': null,
          'decidedBy': '店長',
          'decidedAt': '2026-11-05',
          'text': _kept,
          'note': '原価があるので、大盛りは250gまでのまま',
        }),
        _check('c2', 'p2', 'u2', kind),
      ],
    };

/// 補足の入った行に、佐藤さんの「土日も大盛りを受けていい」が食い違って、まだ確認していない
Map<String, dynamic> _pendingAfterQualification() {
  final j = _qualified();
  (j['utterances'] as List).add(_said('u3', '佐藤さん', '2026-11-11', '土日も大盛りを受けていいよ'));
  (j['patches'] as List).add(_patch('p3', 'u3', '2026-11-11', _weekend, _kept, status: 'proposed'));
  (j['checks'] as List).add(_check('c3', 'p3', 'u3', 'contradiction', conflictLine: _weekend));
  return j;
}

ManualState _state(Map<String, dynamic> j) => ManualState.fromJson(j);

Check? _confirmationOfFirstLine(Map<String, dynamic> j) {
  final s = _state(j);
  return s.confirmationFor(s.lines.first);
}

http.Response _json(Object body) => http.Response.bytes(utf8.encode(jsonEncode(body)), 200);

Api _api(Map<String, dynamic> state) => Api(client: MockClient((_) async => _json(state)), baseUrl: 'http://api');

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// ノート本文の、その行に並ぶ印（行の文・発言者・確認）
Finder _marksOf(String line) => find.ancestor(
      of: find.byWidgetPredicate((w) => w is LineText && w.line == line),
      matching: find.byType(Wrap),
    ).first;

void main() {
  group('confirmationFor', () {
    test('確認した行に補足が入っても、もとの確認を引き継ぐ', () {
      expect(_confirmationOfFirstLine(_qualified())?.id, 'c1');
    });

    test('補足が続けて入っても、さかのぼってもとの確認を引き継ぐ', () {
      const holiday = '- 大盛りは250gまで（土日・祝日は受けない）';
      final j = _qualified();
      j['lines'] = [
        {'text': holiday, 'patchId': 'p3'},
      ];
      (j['utterances'] as List).add(_said('u3', '店長', '2026-11-12', '祝日も大盛りは受けない'));
      (j['patches'] as List).add(_patch('p3', 'u3', '2026-11-12', _weekend, holiday));
      (j['checks'] as List).add(_check('c3', 'p3', 'u3', 'qualification'));
      expect(_confirmationOfFirstLine(j)?.id, 'c1');
    });

    test('確認待ちの食い違いがある行も、もとの確認を引き継ぐ', () {
      expect(_confirmationOfFirstLine(_pendingAfterQualification())?.id, 'c1');
    });

    test('補足のあとに食い違いを確定した行は、その確定の記録を出す', () {
      const decided = '- 大盛りは250gまで（土日は200gまで）';
      final j = _pendingAfterQualification();
      j['lines'] = [
        {'text': decided, 'patchId': 'p4'},
      ];
      (j['utterances'] as List).add(_said('a3', '社員の山田さん', '2026-11-12', '土日は200gまでにして受ける'));
      (j['patches'] as List).last['status'] = 'discarded';
      (j['patches'] as List).add(_patch('p4', 'a3', '2026-11-12', _weekend, decided));
      (j['checks'] as List).last['resolution'] = {
        'utteranceId': 'a3',
        'patchId': 'p4',
        'decidedBy': '社員の山田さん',
        'decidedAt': '2026-11-12',
        'text': decided,
        'note': '土日は200gまでにして受ける',
      };
      expect(_confirmationOfFirstLine(j)?.id, 'c3');
    });

    test('追記として書き換わった行は、確認を引き継がない', () {
      expect(_confirmationOfFirstLine(_qualified(kind: 'addition')), isNull);
    });

    test('直接の編集で書き換えた行は、補足と判定されても確認を引き継がない', () {
      expect(_confirmationOfFirstLine(_qualified(qualifiedBy: '自分', fromEdit: true)), isNull);
    });
  });

  group('ノートの行', () {
    for (final size in const [Size(390, 844), Size(1440, 900)]) {
      testWidgets('補足が入った行に、補足を言った人と「11/5 店長に確認」が並び、押すと確認の記録を開く（$size）', (tester) async {
        _size(tester, size);
        await tester.pumpWidget(MaterialApp(theme: appTheme(), home: ManualScreen(api: _api(_qualified()), manualId: 'm1')));
        await tester.pumpAndSettle();

        final marks = _marksOf(_weekend);
        expect(find.descendant(of: marks, matching: find.byType(Speaker)), findsNWidgets(2));
        expect(find.descendant(of: marks, matching: find.text('11/10')), findsOneWidget);
        final confirmed = find.descendant(of: marks, matching: find.widgetWithText(Speaker, 'に確認'));
        expect(find.descendant(of: confirmed, matching: find.text('11/5')), findsOneWidget);
        expect(find.descendant(of: confirmed, matching: find.text('店長')), findsOneWidget);

        await tester.tap(find.descendant(of: confirmed, matching: find.text('に確認')));
        await tester.pump();
        // 書き換えの欄（行を押すと出る入力欄）は開かない
        expect(find.descendant(of: find.byType(ManualScreen), matching: find.byType(MoonTextInput)), findsNothing);
        await tester.pumpAndSettle();
        final big = tester.widgetList<ConfirmStamp>(find.byType(ConfirmStamp)).where((s) => !s.compact);
        expect(big, isNotEmpty);
        expect(find.byType(size.width < 900 ? CheckScreen : CheckListScreen), findsOneWidget);
      });
    }

    testWidgets('確認待ちの食い違いがある行には、「食い違い」と、もとの「11/5 店長に確認」の両方を出す', (tester) async {
      _size(tester, const Size(390, 844));
      await tester.pumpWidget(
          MaterialApp(theme: appTheme(), home: ManualScreen(api: _api(_pendingAfterQualification()), manualId: 'm1')));
      await tester.pumpAndSettle();

      final marks = _marksOf(_weekend);
      expect(find.descendant(of: marks, matching: find.text('食い違い')), findsOneWidget);
      final confirmed = find.descendant(of: marks, matching: find.widgetWithText(Speaker, 'に確認'));
      expect(find.descendant(of: confirmed, matching: find.text('11/5')), findsOneWidget);

      // 「に確認」を押すと、確認リストでなく、その確認の記録が開く
      await tester.tap(find.descendant(of: confirmed, matching: find.text('に確認')));
      await tester.pumpAndSettle();
      final big = tester.widgetList<ConfirmStamp>(find.byType(ConfirmStamp)).where((s) => !s.compact);
      expect(big, isNotEmpty);
      expect(find.byType(CheckScreen), findsOneWidget);
    });
  });
}
