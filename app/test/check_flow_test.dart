import 'dart:convert';

import 'package:diff_note/api.dart';
import 'package:diff_note/screens/manual_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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
      home: ManualScreen(api: Api(client: client, baseUrl: 'http://api'), manualId: 'm1'),
    ));
    await tester.pumpAndSettle();

    expect(find.text('確認待ち（1）'), findsOneWidget);
    await tester.tap(find.text('塩 小さじ1 ／ 塩 小さじ1/2'));
    await tester.pumpAndSettle();

    expect(find.text('確認が必要です'), findsOneWidget);
    expect(find.text('お店のやり方を決める立場なので'), findsOneWidget);
    expect(find.textContaining('どちらに合わせればよいですか'), findsOneWidget);

    final note = find.widgetWithText(TextField, 'メモ（何と言われたか）');
    await tester.ensureVisible(note);
    await tester.enterText(note, '1/2で統一');
    await tester.ensureVisible(find.text('確定する'));
    await tester.tap(find.text('確定する'));
    await tester.pumpAndSettle();

    expect(resolveBody, containsPair('decidedBy', '店長'));
    expect(resolveBody, containsPair('text', '- 塩 小さじ1/2'));
    expect(resolveBody, containsPair('note', '1/2で統一'));
    expect(find.text('11/7 店長に確認：1/2で統一'), findsOneWidget);
    expect(find.text('確定した内容：塩 小さじ1/2'), findsOneWidget);
  });
}
