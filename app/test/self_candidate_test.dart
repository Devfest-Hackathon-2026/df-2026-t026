import 'dart:convert';

import 'package:diff_note/api.dart';
import 'package:diff_note/manual_controller.dart';
import 'package:diff_note/models.dart';
import 'package:diff_note/screens/check_screen.dart';
import 'package:diff_note/screens/review_dialog.dart';
import 'package:diff_note/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moon_design/moon_design.dart';

// #125：記録を見せた答えは見せた人の名前（名前を決めていなければログイン ID）で残るので、
// 発言者・確認した相手の候補で、自分を「demo」のようにほかの人として並べない

Map<String, dynamic> _said(String id, String? speaker, String day, {Map<String, String>? by, bool fromEdit = false}) => {
      'id': id,
      'text': '$id の発言',
      'speaker': speaker,
      'saidAt': day,
      'fromEdit': fromEdit,
      'recordedBy': ?by,
      'createdAt': '${day}T10:00:00Z',
    };

/// demo のノート（名前を決めていないので名前も demo）。自分で直接書いた行、田中さん、店長の確認の答え、
/// 自分が記録を見せた答え（発言者 demo）があり、そのあと佐藤さんの「小さじ1」が食い違った。
/// 佐藤店長（sato）は、記録した人を残す前（ADR 0018）に行を直し、前に自分で答えた。
/// shared なら、佐藤店長として、かなで（demo）から共有されたノートを見ている
Map<String, dynamic> _state({bool shared = false}) {
  final me = shared ? const {'id': 'sato', 'name': '佐藤店長'} : const {'id': 'demo', 'name': 'demo'};
  return {
    'owner': 'demo',
    'me': me['id'],
    'sharedBy': shared ? {'id': 'demo', 'name': 'かなで'} : null,
    'manual': {'id': 'm1', 'title': 'キッチン', 'base': '- 塩 小さじ1/2', 'createdAt': '2026-11-01T00:00:00Z'},
    'lines': [
      {'text': '- 塩 小さじ1/2', 'patchId': null},
      {'text': '- だしは煮干し', 'patchId': 'p1'},
    ],
    'utterances': [
      _said('e1', '自分', '2026-11-01', fromEdit: true),
      {..._said('e2', '佐藤店長', '2026-11-02', fromEdit: true), 'editedBy': 'sato'},
      _said('u1', '田中さん', '2026-11-03'),
      _said('a1', '店長', '2026-11-07', by: const {'id': 'demo', 'name': 'demo'}),
      _said('a2', me['name'], '2026-11-09', by: me),
      _said('u3', '佐藤さん', '2026-11-10', by: me),
    ],
    'patches': [
      {'id': 'p1', 'utteranceId': 'e1', 'op': 'insert', 'line': '- 塩 小さじ1/2', 'text': '- だしは煮干し', 'summary': '', 'status': 'applied', 'createdAt': '2026-11-01T10:00:00Z', 'appliedAt': '2026-11-01T10:00:00Z'},
      {'id': 'p3', 'utteranceId': 'u3', 'op': 'replace', 'line': '- 塩 小さじ1/2', 'text': '- 塩 小さじ1', 'summary': '', 'status': 'proposed', 'createdAt': '2026-11-10T10:00:00Z', 'appliedAt': null},
    ],
    'checks': [
      {
        'id': 'c3',
        'patchId': 'p3',
        'utteranceId': 'u3',
        'kind': 'contradiction',
        'conflictLine': '- 塩 小さじ1/2',
        'sameLine': null,
        'reason': '量が違う',
        'ask': {'candidates': [], 'question': null},
        'resolution': null,
      },
    ],
  };
}

ManualController _controller(Map<String, dynamic> state, {List<Map<String, String>> shares = const []}) {
  final api = Api(
    client: MockClient((req) async =>
        http.Response.bytes(utf8.encode(jsonEncode(req.url.path.endsWith('/shares') ? shares : state)), 200)),
    baseUrl: 'http://api',
  );
  return ManualController(api, 'm1', ManualState.fromJson(state));
}

Future<void> _openReview(WidgetTester tester, ManualController c) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: appTheme(),
    home: Builder(
      builder: (context) => MoonOutlinedButton(
          label: const Text('開く'), onTap: () => showReview(context, [(c: c, utteranceId: 'u3')])),
    ),
  ));
  await tester.tap(find.byType(MoonOutlinedButton));
  await tester.pumpAndSettle();
}

List<String?> _names(ManualState s) => [for (final u in s.utterances) s.speakerCandidate(u)?.name];

void main() {
  test('自分のノートでは、自分の名前の発言者を「自分」にまとめ、共有されたノートでは自分を出さない', () {
    final own = ManualState.fromJson(_state());
    expect(_names(own), ['自分', '佐藤店長', '田中さん', '店長', '自分', '佐藤さん']);
    expect(own.speakerCandidate(own.utterance('a2'))?.id, 'demo');
    // 名前を決めた人の、見せた答え（発言者は記録した時点の名前）もまとめる
    final named = _state();
    (named['utterances'] as List)[4]
      ..['speaker'] = 'かなで'
      ..['recordedBy'] = {'id': 'demo', 'name': 'かなで'};
    expect(_names(ManualState.fromJson(named))[4], '自分');
    // 共有されたノートの「自分」は持ち主の直接の編集なので、そのまま。記録した人の無い自分の直接の編集も出さない
    expect(_names(ManualState.fromJson(_state(shared: true))), ['自分', null, '田中さん', '店長', null, '佐藤さん']);
  });

  testWidgets('「誰が言った？」に、自分の ID と「自分」を並べず「自分」1つにする。ID を打つと「自分（demo）」が出る', (tester) async {
    await _openReview(tester, _controller(_state()));
    expect(find.bySemanticsLabel('発言者を自分にする'), findsOneWidget);
    expect(find.bySemanticsLabel('発言者をdemoにする'), findsNothing);
    expect(find.bySemanticsLabel('発言者を店長にする'), findsOneWidget);
    expect(find.bySemanticsLabel('発言者を田中さんにする'), findsOneWidget);

    await tester.enterText(find.byType(EditableText).first, 'dem');
    await tester.pump();
    expect(find.text('自分（demo）'), findsOneWidget);
    await tester.tap(find.text('自分（demo）'));
    await tester.pump();
    expect(tester.widget<EditableText>(find.byType(EditableText).first).controller.text, '自分');
  });

  testWidgets('共有されたノートの「誰が言った？」には、自分の名前を出さず、持ち主と共有の相手と言ったことのある人を出す', (tester) async {
    await _openReview(
      tester,
      _controller(_state(shared: true), shares: const [
        {'id': 'sato', 'name': '佐藤店長'},
        {'id': 'haruto', 'name': 'はると'},
      ]),
    );
    expect(find.bySemanticsLabel('発言者を佐藤店長にする'), findsNothing);
    expect(find.bySemanticsLabel('発言者をかなでにする'), findsOneWidget);
    expect(find.bySemanticsLabel('発言者をはるとにする'), findsOneWidget);
    expect(find.bySemanticsLabel('発言者を店長にする'), findsOneWidget);
  });

  testWidgets('確認した相手の候補も、自分の ID でなく「自分」1つにする。ID を打つと「自分（demo）」が出る', (tester) async {
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: appTheme(), home: CheckScreen(c: _controller(_state()), checkId: 'c3')));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('確認した相手を自分にする'), findsOneWidget);
    expect(find.bySemanticsLabel('確認した相手をdemoにする'), findsNothing);
    expect(find.bySemanticsLabel('確認した相手を店長にする'), findsOneWidget);

    await tester.enterText(find.byType(EditableText).first, 'demo');
    await tester.pump();
    expect(find.text('自分（demo）'), findsOneWidget);
  });
}
