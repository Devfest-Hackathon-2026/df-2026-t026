import 'dart:convert';

import 'package:diff_note/api.dart';
import 'package:diff_note/manual_controller.dart';
import 'package:diff_note/models.dart';
import 'package:diff_note/screens/common.dart';
import 'package:diff_note/screens/input_screen.dart';
import 'package:diff_note/screens/manual_screen.dart';
import 'package:diff_note/screens/review_dialog.dart';
import 'package:diff_note/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moon_design/moon_design.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'home.dart';

// 入力欄に1文字打つたびに画面全体を作り直さない（設計書 0021 の B2）。
// 打つ前後で、入力欄に関係しない部品が同じ物のままかで確かめる（時間には頼らない）

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

/// lines 行の本文に、直接編集で足した行（あとで確認つき）と、口頭の記録 said 件を持つノート
Map<String, dynamic> _note(String id, {int lines = 0, int edits = 0, int said = 0}) => {
      'owner': 'demo',
      'me': 'demo',
      'manual': {'id': id, 'title': 'ノート$id', 'base': '', 'createdAt': '2026-11-01T00:00:00Z'},
      'lines': [
        for (var i = 0; i < lines; i++) {'text': '- 項目$i', 'patchId': null},
        for (var i = 0; i < edits; i++) {'text': '- 足した行$i', 'patchId': '$id-p$i'},
      ],
      'utterances': [
        for (var i = 0; i < edits; i++)
          {'id': '$id-e$i', 'text': '- 足した行$i', 'speaker': '自分', 'saidAt': '2026-11-03', 'fromEdit': true, 'createdAt': '2026-11-03T11:00:00Z'},
        for (var i = 0; i < said; i++)
          {'id': '$id-u$i', 'text': '$id で言われたこと$i', 'speaker': '田中さん', 'saidAt': '2026-11-03', 'createdAt': '2026-11-03T10:00:${(i % 60).toString().padLeft(2, '0')}Z'},
      ],
      'patches': [
        for (var i = 0; i < edits; i++)
          {
            'id': '$id-p$i',
            'utteranceId': '$id-e$i',
            'op': 'insert',
            'line': null,
            'text': '- 足した行$i',
            'summary': '追記',
            'status': 'applied',
            'createdAt': '2026-11-03T11:00:00Z',
            'appliedAt': '2026-11-03T11:00:00Z',
          },
      ],
      'checks': [
        for (var i = 0; i < edits; i++)
          {
            'id': '$id-c$i',
            'patchId': '$id-p$i',
            'utteranceId': '$id-e$i',
            'kind': 'contradiction',
            'conflictLine': '- 項目$i',
            'reason': '食い違う',
            'resolution': null,
          },
      ],
    };

MockClient _client(List<Map<String, dynamic>> notes, {List<Map<String, dynamic>> memos = const []}) =>
    MockClient((req) async {
      if (req.url.path == '/home') return _json(homeJson(notes, memos: memos));
      final segs = req.url.pathSegments;
      if (segs.length == 2 && segs[0] == 'manuals') return _json(notes.firstWhere((n) => n['manual']['id'] == segs[1]));
      return _json([]);
    });

void _setSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// 画面にある部品（見えていないものも）を、上から順に
List<Widget> _widgets<T extends Widget>(WidgetTester tester) =>
    tester.widgetList<T>(find.byType(T, skipOffstage: false)).toList();

void _expectSameWidgets(List<Widget> before, List<Widget> after, String what) {
  expect(after, hasLength(before.length), reason: what);
  for (var i = 0; i < before.length; i++) {
    expect(identical(before[i], after[i]), isTrue, reason: '$what の $i 番目を作り直した');
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('長いノートの行の欄に打っても、ほかの行と記録した発言は作り直さず、右端のチェック（保存する）の押せる・押せないだけが変わる', (tester) async {
    _setSize(tester, const Size(1400, 900));
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(),
      home: ManualScreen(
        api: Api(client: _client([_note('m1', lines: 150, edits: 50, said: 30)]), baseUrl: 'http://api'),
        manualId: 'm1',
      ),
    ));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('・項目60'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('・項目60'));
    await tester.pumpAndSettle();
    MoonButton save() => tester.widget<MoonButton>(find.byWidgetPredicate((w) => w is MoonButton && w.semanticLabel == '保存する'));
    expect(save().onTap, isNotNull);

    final lines = _widgets<LineText>(tester);
    final notes = _widgets<StickyNote>(tester);
    final tags = _widgets<StatusTag>(tester);
    expect(lines.length, greaterThan(190));
    expect(notes, isNotEmpty);
    expect(tags, isNotEmpty);

    tester.testTextInput.enterText('- 項目60 を直す');
    await tester.pump();
    tester.testTextInput.enterText('  ');
    await tester.pump();
    expect(save().onTap, isNull);
    tester.testTextInput.enterText('- 項');
    await tester.pump();
    expect(save().onTap, isNotNull);

    _expectSameWidgets(lines, _widgets<LineText>(tester), '本文の行');
    _expectSameWidgets(notes, _widgets<StickyNote>(tester), '記録した発言の付箋');
    _expectSameWidgets(tags, _widgets<StatusTag>(tester), '状態の札');
  });

  testWidgets('入力ページの書く欄に打っても、付箋は作り直さず、消し切ったときだけ流し込んだメモの印を外す', (tester) async {
    _setSize(tester, const Size(1400, 1400));
    final notes = [_note('m1', lines: 3, said: 20), _note('m2', lines: 3, said: 20)];
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(),
      home: InputScreen(
        api: Api(
          client: _client(notes, memos: [
            {'id': 'a', 'at': '2026-11-03T05:00:00Z', 'text': '塩は小さじ1/2'},
            {'id': 'b', 'at': '2026-11-03T06:00:00Z', 'text': 'お冷やはすぐ出す'},
          ]),
          baseUrl: 'http://api',
        ),
      ),
    ));
    await tester.pumpAndSettle();
    MoonFilledButton submit() =>
        tester.widget<MoonFilledButton>(find.widgetWithText(MoonFilledButton, 'ノートと照らし合わせる'));
    expect(submit().onTap, isNull);

    await tester.tap(find.text('塩は小さじ1/2'));
    await tester.pumpAndSettle();
    expect(find.text('入力欄に入れました'), findsOneWidget);
    // 欄に打つ所を移す（枠の色が変わるので、ここまでは作り直してよい）
    await tester.showKeyboard(find.byType(MoonTextArea));
    await tester.pumpAndSettle();

    final stickies = _widgets<StickyNote>(tester);
    final speakers = _widgets<Speaker>(tester);
    expect(stickies.length, greaterThanOrEqualTo(7));
    expect(speakers, isNotEmpty);

    tester.testTextInput.enterText('塩は小さじ1/2 と田中さんから');
    await tester.pump();
    tester.testTextInput.enterText('塩は小さじ1/2 と田中さんから言われた');
    await tester.pump();
    expect(submit().onTap, isNotNull);
    expect(find.text('入力欄に入れました'), findsOneWidget);
    _expectSameWidgets(stickies, _widgets<StickyNote>(tester), '付箋');
    _expectSameWidgets(speakers, _widgets<Speaker>(tester), '最近の記録の発言者');

    // 消し切ったら、流し込んだメモはもう使っていない
    tester.testTextInput.enterText('');
    await tester.pump();
    expect(submit().onTap, isNull);
    expect(find.text('入力欄に入れました'), findsNothing);
  });

  testWidgets('書き込む前の確認の「誰が言った？」に打っても、言われたことと変わる行は作り直さず、発言者に関わる所だけ変わる',
      (tester) async {
    _setSize(tester, const Size(1440, 1400));
    final state = {
      'owner': 'demo',
      'me': 'demo',
      'manual': {'id': 'm1', 'title': 'キッチン', 'base': '', 'createdAt': '2026-11-01T00:00:00Z'},
      'lines': [
        {'text': '- 塩 小さじ1', 'patchId': null},
        {'text': '- 皿は白', 'patchId': null},
      ],
      'utterances': [
        {'id': 'u0', 'text': '前の記録', 'speaker': '佐藤店長', 'saidAt': '2026-11-02', 'createdAt': '2026-11-02T10:00:00Z'},
        {'id': 'u1', 'text': '塩は小さじ2、皿は白、油も足す', 'speaker': null, 'saidAt': '2026-11-03', 'createdAt': '2026-11-03T10:00:00Z'},
      ],
      'patches': [
        for (final (id, text) in [('p1', '- 塩 小さじ2'), ('p2', '- 皿は白'), ('p3', '- 油 大さじ1')])
          {
            'id': id,
            'utteranceId': 'u1',
            'op': 'insert',
            'line': null,
            'text': text,
            'summary': '$text を足す',
            'status': 'proposed',
            'createdAt': '2026-11-03T10:00:00Z',
            'appliedAt': null,
          },
      ],
      'checks': [
        {'id': 'c1', 'patchId': 'p1', 'utteranceId': 'u1', 'kind': 'contradiction', 'conflictLine': '- 塩 小さじ1', 'reason': '量が違う', 'resolution': null},
        {'id': 'c2', 'patchId': 'p2', 'utteranceId': 'u1', 'kind': 'same', 'sameLine': '- 皿は白', 'reason': '同じ', 'resolution': null},
        {'id': 'c3', 'patchId': 'p3', 'utteranceId': 'u1', 'kind': 'addition', 'reason': '新しい', 'resolution': null},
      ],
    };
    final c = ManualController(Api(client: _client([state]), baseUrl: 'http://api'), 'm1', ManualState.fromJson(state));
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(),
      home: Builder(
        builder: (context) =>
            MoonOutlinedButton(label: const Text('開く'), onTap: () => showReview(context, [(c: c, utteranceId: 'u1')])),
      ),
    ));
    await tester.tap(find.byType(MoonOutlinedButton));
    await tester.pumpAndSettle();
    final speaker = find.byType(EditableText).first;
    await tester.showKeyboard(speaker);
    await tester.pumpAndSettle();
    MoonButton button(String label) => tester.widget<MoonButton>(find.widgetWithText(MoonButton, label));
    expect(button('ノートに書き込む').onTap, isNull);
    expect(button('それでも書き込む').onTap, isNull);
    expect(find.text('反映する前に入れてください'), findsOneWidget);
    expect(find.text('発言者未入力（11/3）'), findsOneWidget);

    final said = _widgets<StickyNote>(tester);
    final diffs = _widgets<PatchDiff>(tester);
    final kinds = _widgets<KindTag>(tester);
    expect(said, hasLength(1));
    expect(diffs, hasLength(1));
    expect(kinds, hasLength(3));

    tester.testTextInput.enterText('佐藤');
    await tester.pump();
    // 打った言葉で候補を絞る
    expect(find.bySemanticsLabel('発言者を佐藤店長にする'), findsOneWidget);
    tester.testTextInput.enterText('田中さん');
    await tester.pump();
    expect(find.bySemanticsLabel('発言者を佐藤店長にする'), findsNothing);
    expect(button('ノートに書き込む').onTap, isNotNull);
    expect(button('それでも書き込む').onTap, isNotNull);
    expect(find.text('反映する前に入れてください'), findsNothing);
    expect(find.text('田中さん（11/3）'), findsOneWidget);

    _expectSameWidgets(said, _widgets<StickyNote>(tester), '言われたこと');
    _expectSameWidgets(diffs, _widgets<PatchDiff>(tester), '変わる行');
    _expectSameWidgets(kinds, _widgets<KindTag>(tester), '分類の札');

    // 消すと、また押せなくなる
    tester.testTextInput.enterText('');
    await tester.pump();
    expect(button('ノートに書き込む').onTap, isNull);
    expect(find.text('反映する前に入れてください'), findsOneWidget);
  });
}
