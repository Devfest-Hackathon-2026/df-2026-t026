import 'dart:convert';

import 'package:diff_note/api.dart';
import 'package:diff_note/history.dart';
import 'package:diff_note/models.dart';
import 'package:diff_note/screens/manual_screen.dart';
import 'package:diff_note/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moon_design/moon_design.dart';

Map<String, dynamic> _u(String id, String text, String speaker, String at, {bool fromEdit = false}) =>
    {'id': id, 'text': text, 'speaker': speaker, 'saidAt': at.substring(0, 10), 'fromEdit': fromEdit, 'createdAt': at};

Map<String, dynamic> _p(String id, String uid, String op, String? line, String text, String status, String at,
        {String? appliedAt}) =>
    {
      'id': id,
      'utteranceId': uid,
      'op': op,
      'line': line,
      'text': text,
      'summary': '',
      'status': status,
      'createdAt': at,
      'appliedAt': status == 'applied' ? (appliedAt ?? at) : null,
    };

Map<String, dynamic> _check(String id, String patchId, String uid, String conflictLine, {String? answeredBy}) => {
      'id': id,
      'patchId': patchId,
      'utteranceId': uid,
      'kind': 'contradiction',
      'conflictLine': conflictLine,
      'sameLine': null,
      'reason': '量が違う',
      'ask': {'candidates': [], 'question': 'どちらですか？'},
      'resolution': answeredBy == null
          ? null
          : {
              'utteranceId': answeredBy,
              'patchId': null,
              'decidedBy': '店長',
              'decidedAt': '2026-11-07',
              'text': '- 塩 小さじ1/2',
              'note': '1/2で統一',
            },
    };

/// 田中さんの「塩は1/2」がノートと食い違い、店長に確認して1/2に決めた。その後の佐藤さんの指示はまだ確認していない
Map<String, dynamic> _kitchen() => {
      'manual': {'id': 'm1', 'title': 'キッチン', 'base': '## 味噌汁\n- 塩 小さじ1\n- 味噌 大さじ2', 'createdAt': '2026-11-01T00:00:00Z'},
      'lines': [
        {'text': '## 味噌汁', 'patchId': null},
        {'text': '- 塩 小さじ1/2', 'patchId': 'p3'},
        {'text': '- 味噌 大さじ2', 'patchId': null},
        {'text': '- だしは煮干し', 'patchId': 'p2'},
      ],
      'utterances': [
        _u('u1', '塩は小さじ1/2でいい', '田中さん', '2026-11-03T10:00:00Z'),
        _u('u2', '- だしは煮干し', '自分', '2026-11-04T10:00:00Z', fromEdit: true),
        _u('u3', '1/2で統一', '店長', '2026-11-07T10:00:00Z'),
        _u('u4', 'だしは昆布でとって', '佐藤さん', '2026-11-08T10:00:00Z'),
      ],
      'patches': [
        _p('p1', 'u1', 'replace', '- 塩 小さじ1', '- 塩 小さじ1/2', 'discarded', '2026-11-03T10:00:00Z'),
        _p('p2', 'u2', 'insert', '- 味噌 大さじ2', '- だしは煮干し', 'applied', '2026-11-04T10:00:00Z'),
        _p('p3', 'u3', 'replace', '- 塩 小さじ1', '- 塩 小さじ1/2', 'applied', '2026-11-07T10:00:00Z'),
        _p('p4', 'u4', 'replace', '- だしは煮干し', '- だしは昆布', 'proposed', '2026-11-08T10:00:00Z'),
      ],
      'checks': [
        _check('c1', 'p1', 'u1', '- 塩 小さじ1', answeredBy: 'u3'),
        _check('c2', 'p4', 'u4', '- だしは煮干し'),
      ],
    };

List<String> _texts(Commit c, LineChange change) => [for (final l in c.diff) if (l.change == change) l.text];

void main() {
  group('buildHistory', () {
    test('反映した順に版を積み、食い違った記録は記録した時点の版から分かれて、確定した版に合流する', () {
      final s = ManualState.fromJson(_kitchen());
      final h = buildHistory(s);
      final rows = {for (final r in h.rows) r.commit.id: r};

      expect(h.rows.map((r) => r.commit.id), ['p4', 'p3', 'p2', 'p1', 'root']);
      expect(h.lanes, 3);
      // 幹
      expect([for (final r in h.rows) if (!r.commit.onBranch) r.lane], [0, 0, 0]);
      expect((rows['root']!.up, rows['root']!.down), (true, false));
      expect((rows['p3']!.up, rows['p3']!.down), (false, true));
      expect(rows['p1']!.through, {0});
      // 田中さんの枝：作った版から分かれ、店長に確認した版に合流する
      expect(rows['root']!.forks, {1});
      expect((rows['p1']!.lane, rows['p1']!.up, rows['p1']!.down), (1, true, true));
      expect(rows['p2']!.through, {1});
      expect(rows['p3']!.merges, {1});
      // 佐藤さんの枝：確認した版から分かれ、まだ合流していない
      expect(rows['p3']!.forks, {2});
      expect((rows['p4']!.lane, rows['p4']!.up, rows['p4']!.down), (2, false, true));
      // 枝の線を、その記録の状態の色で描けるよう、行ごとにレーンを使う記録を持つ
      expect(rows['p2']!.branches.map((l, c) => MapEntry(l, c.id)), {1: 'p1'});
      expect(rows['p3']!.branches.map((l, c) => MapEntry(l, c.id)), {1: 'p1', 2: 'p4'});
      expect(rows['root']!.branches.map((l, c) => MapEntry(l, c.id)), {1: 'p1'});
      expect(rows['p4']!.through, isEmpty);

      expect(_texts(rows['root']!.commit, LineChange.added), ['## 味噌汁', '- 塩 小さじ1', '- 味噌 大さじ2']);
      expect(_texts(rows['p3']!.commit, LineChange.removed), ['- 塩 小さじ1']);
      expect(_texts(rows['p3']!.commit, LineChange.added), ['- 塩 小さじ1/2']);
      expect(rows['p3']!.commit.check?.id, 'c1');
      expect(_texts(rows['p4']!.commit, LineChange.removed), ['- だしは煮干し']);
      expect(_texts(rows['p4']!.commit, LineChange.added), ['- だしは昆布']);
      // いちばん新しい版は、バックエンドが組み立てたノートと同じになる
      expect(
        [for (final l in rows['p3']!.commit.diff) if (l.change != LineChange.removed) l.text],
        s.lines.map((l) => l.text),
      );
    });

    test('確定で続けて当てたパッチは1つの版にし、ノートのままと確定した記録もパッチなしの版として残す', () {
      final s = ManualState.fromJson({
        'manual': {'id': 'm1', 'title': 'メモ', 'base': '- 塩 小さじ1', 'createdAt': '2026-11-01T00:00:00Z'},
        'lines': [
          {'text': '- 塩 小さじ1/2', 'patchId': 'p3'},
        ],
        'utterances': [
          _u('u1', '- 塩 小さじ2', '自分', '2026-11-02T10:00:00Z', fromEdit: true),
          _u('u2', '1/2で統一', '店長', '2026-11-03T10:00:00Z'),
          _u('u3', '塩は少々でいい', '田中さん', '2026-11-04T10:00:00Z'),
          _u('u4', 'ノートのままでいい', '店長', '2026-11-05T10:00:00Z'),
        ],
        'patches': [
          _p('p1', 'u1', 'insert', null, '- 塩 小さじ2', 'applied', '2026-11-02T10:00:00Z'),
          _p('p2', 'u2', 'delete', '- 塩 小さじ2', '', 'applied', '2026-11-03T10:00:00.000Z'),
          _p('p3', 'u2', 'replace', '- 塩 小さじ1', '- 塩 小さじ1/2', 'applied', '2026-11-03T10:00:00.001Z'),
          _p('p4', 'u3', 'replace', '- 塩 小さじ1/2', '- 塩 少々', 'discarded', '2026-11-04T10:00:00Z'),
        ],
        'checks': [
          _check('c1', 'p1', 'u1', '- 塩 小さじ1', answeredBy: 'u2'),
          _check('c2', 'p4', 'u3', '- 塩 小さじ1/2', answeredBy: 'u4'),
        ],
      });
      final h = buildHistory(s);
      final rows = {for (final r in h.rows) r.commit.id: r};

      expect(h.rows.map((r) => r.commit.id), ['u4', 'p4', 'p2', 'p1', 'root']);
      expect(_texts(rows['p2']!.commit, LineChange.removed), ['- 塩 小さじ1', '- 塩 小さじ2']);
      expect(_texts(rows['p2']!.commit, LineChange.added), ['- 塩 小さじ1/2']);
      expect(rows['u4']!.commit.diff.map((l) => l.change), [LineChange.kept]);
      expect(rows['u4']!.commit.check?.id, 'c2');
      expect(rows['u4']!.merges, {1});
      expect(rows['p2']!.forks, {1});
    });
  });

  group('履歴の画面', () {
    Future<void> pump(WidgetTester tester, double width) async {
      tester.view.physicalSize = Size(width, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final client = MockClient((_) async => http.Response.bytes(utf8.encode(jsonEncode(_kitchen())), 200));
      await tester.pumpWidget(MaterialApp(
        theme: appTheme(),
        home: ManualScreen(api: Api(client: client, baseUrl: 'http://api'), manualId: 'm1'),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MoonOutlinedButton, '履歴'));
      await tester.pumpAndSettle();
    }

    testWidgets('狭い画面：版と枝を新しい順に並べ、押すとその版のノートを増減の印つきで見せる', (tester) async {
      await pump(tester, 390);

      expect(find.text('版 3'), findsOneWidget);
      // 行は「誰が・いつ」と本文を1つの文にしている
      expect(find.textContaining('ノートを作った'), findsOneWidget);
      expect(find.textContaining('だしは昆布でとって'), findsOneWidget);
      expect(find.text('あとで確認'), findsOneWidget);
      expect(find.text('確認済み'), findsOneWidget);
      // 1件を同じ高さの1行に詰め、行の間で線を途切れさせずに幹と枝の形を見せる
      final graph = find.byWidgetPredicate((w) => w is CustomPaint && '${w.painter.runtimeType}' == '_GraphPainter');
      expect(graph, findsNWidgets(5));
      expect({for (final e in graph.evaluate()) e.size!.height}, hasLength(1));

      await tester.tap(find.textContaining('1/2で統一'));
      await tester.pumpAndSettle();

      expect(find.text('この版のノート'), findsOneWidget);
      expect(find.text('・塩 小さじ1'), findsOneWidget);
      expect(find.text('・塩 小さじ1/2'), findsOneWidget);
      expect(find.text('-1 行'), findsOneWidget);
      expect(find.text('+1 行'), findsOneWidget);
    });

    testWidgets('広い画面：右にいちばん新しい記録の差分を出し、左で選んだ版に切り替える', (tester) async {
      await pump(tester, 1000);

      expect(find.text('ノートに入れていない差分'), findsOneWidget);
      expect(find.text('・だしは昆布'), findsOneWidget);
      expect(find.text('確認リストで開く'), findsOneWidget);

      await tester.tap(find.textContaining('ノートを作った'));
      await tester.pumpAndSettle();

      expect(find.text('この版のノート'), findsOneWidget);
      // 行の中では「行」を外し、詳細では付ける
      expect(find.text('+3'), findsOneWidget);
      expect(find.text('+3 行'), findsOneWidget);
    });
  });
}
