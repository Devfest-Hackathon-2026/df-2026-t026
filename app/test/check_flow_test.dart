import 'dart:convert';

import 'package:diff_note/api.dart';
import 'package:diff_note/screens/manual_screen.dart';
import 'package:diff_note/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moon_design/moon_design.dart';

Map<String, dynamic> _state({required bool resolved}) => {
      'manual': {'id': 'm1', 'title': 'キッチン', 'base': '', 'createdAt': '2026-11-01T00:00:00Z'},
      'lines': [
        {'text': '## 味噌汁', 'patchId': null},
        {'text': resolved ? '- 塩 小さじ1/2' : '- 塩 小さじ1', 'patchId': resolved ? 'p2' : null},
      ],
      'utterances': [
        {'id': 'u1', 'text': '田中さんから塩は小さじ1/2でいいと言われた', 'speaker': '田中さん', 'saidAt': '2026-11-03'},
        if (resolved) {'id': 'u2', 'text': '1/2で統一', 'speaker': '店長', 'saidAt': '2026-11-07'},
      ],
      'patches': [
        {
          'id': 'p1',
          'utteranceId': 'u1',
          'op': 'replace',
          'line': '- 塩 小さじ1',
          'text': '- 塩 小さじ1/2',
          'summary': '塩: 小さじ1 → 小さじ1/2',
          'status': resolved ? 'discarded' : 'proposed',
        },
        if (resolved)
          {
            'id': 'p2',
            'utteranceId': 'u2',
            'op': 'replace',
            'line': '- 塩 小さじ1',
            'text': '- 塩 小さじ1/2',
            'summary': '確認：1/2で統一',
            'status': 'applied',
          },
      ],
      'checks': [
        {
          'id': 'c1',
          'patchId': 'p1',
          'utteranceId': 'u1',
          'kind': 'contradiction',
          'conflictLine': '- 塩 小さじ1',
          'reason': 'マニュアルと両立しません',
          'ask': {
            'candidates': [
              {'who': '店長', 'why': 'お店のやり方を決める立場なので'},
            ],
            'question': '「塩 小さじ1」と教わっていたのですが、どちらに合わせればよいですか？',
          },
          'resolution': resolved
              ? {
                  'utteranceId': 'u2',
                  'patchId': 'p2',
                  'decidedBy': '店長',
                  'decidedAt': '2026-11-07',
                  'text': '- 塩 小さじ1/2',
                  'note': '1/2で統一',
                }
              : null,
        },
      ],
    };

void main() {
  testWidgets('矛盾を確認して確定すると、確認の記録として見せられる', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    Map<String, dynamic>? resolveBody;
    final client = MockClient((req) async {
      final resolved = resolveBody != null || req.url.path.endsWith('/resolve');
      if (req.url.path.endsWith('/resolve')) resolveBody = jsonDecode(req.body);
      return http.Response.bytes(utf8.encode(jsonEncode(_state(resolved: resolved))), 200);
    });
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(),
      home: ManualScreen(api: Api(client: client, baseUrl: 'http://api'), manualId: 'm1'),
    ));
    await tester.pumpAndSettle();

    // 確認待ちがあれば、パネルは確認待ちを開いた状態で出る
    expect(find.text('塩 小さじ1 ／ 塩 小さじ1/2'), findsOneWidget);
    await tester.tap(find.text('塩 小さじ1 ／ 塩 小さじ1/2'));
    await tester.pumpAndSettle();

    expect(find.text('確認が必要です'), findsOneWidget);
    expect(find.text('お店のやり方を決める立場なので'), findsOneWidget);
    expect(find.textContaining('どちらに合わせればよいですか'), findsOneWidget);

    final note = find.widgetWithText(MoonTextInput, '例: 1/2で統一');
    await tester.ensureVisible(note);
    await tester.enterText(note, '1/2で統一');
    final confirm = find.widgetWithText(MoonFilledButton, '確定する');
    await tester.ensureVisible(confirm);
    await tester.tap(confirm);
    await tester.pumpAndSettle();

    expect(resolveBody, containsPair('decidedBy', '店長'));
    expect(resolveBody, containsPair('text', '- 塩 小さじ1/2'));
    expect(resolveBody, containsPair('note', '1/2で統一'));
    expect(find.text('11/7 店長に確認：1/2で統一'), findsOneWidget);
    expect(find.text('確定した内容：塩 小さじ1/2'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10)); // 確定のトーストが消えるのを待つ
  });

  // 狭い画面ではタブ1段に切り替わり、確認画面の選択肢は縦に積む。はみ出すとテストが失敗する
  testWidgets('狭い画面でも、確認待ちのタブから確認画面を開いて確定できる', (tester) async {
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    Map<String, dynamic>? resolveBody;
    final client = MockClient((req) async {
      final resolved = resolveBody != null || req.url.path.endsWith('/resolve');
      if (req.url.path.endsWith('/resolve')) resolveBody = jsonDecode(req.body);
      return http.Response.bytes(utf8.encode(jsonEncode(_state(resolved: resolved))), 200);
    });
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(),
      home: ManualScreen(api: Api(client: client, baseUrl: 'http://api'), manualId: 'm1'),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('確認待ち 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('塩 小さじ1 ／ 塩 小さじ1/2'));
    await tester.pumpAndSettle();
    expect(find.text('確認が必要です'), findsOneWidget);

    final confirm = find.widgetWithText(MoonFilledButton, '確定する');
    await tester.ensureVisible(confirm);
    await tester.pumpAndSettle();
    await tester.tap(confirm);
    await tester.pumpAndSettle();

    expect(resolveBody, containsPair('text', '- 塩 小さじ1/2'));
    expect(find.text('11/7 店長に確認：1/2で統一'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10)); // 確定のトーストが消えるのを待つ
  });
}
