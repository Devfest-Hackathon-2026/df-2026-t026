import 'dart:convert';

import 'package:diff_note/api.dart';
import 'package:diff_note/screens/common.dart';
import 'package:diff_note/screens/input_screen.dart';
import 'package:diff_note/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:moon_design/moon_design.dart';

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

Map<String, dynamic> _utterance(String id, String text, String createdAt) =>
    {'id': id, 'text': text, 'speaker': '田中さん', 'saidAt': '2026-11-03', 'createdAt': createdAt};

/// m1 はキッチン（食い違いが1件）、m2 はホール
Map<String, dynamic> _state(String id) => switch (id) {
      'm1' => {
          'manual': {'id': 'm1', 'title': 'キッチン'},
          'lines': [
            {'text': '- 塩 小さじ1', 'patchId': null},
          ],
          'utterances': [_utterance('u1', '塩は小さじ1/2', '2026-11-03T10:00:00Z')],
          'patches': [
              {
                'id': 'p1',
                'utteranceId': 'u1',
                'op': 'replace',
                'line': '- 塩 小さじ1',
                'text': '- 塩 小さじ1/2',
                'summary': '塩: 小さじ1 → 小さじ1/2',
                'status': 'proposed',
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
                'ask': {'candidates': [], 'question': 'どちらに合わせればよいですか？'},
                'resolution': null,
              },
          ],
        },
      _ => {
          'manual': {'id': 'm2', 'title': 'ホール'},
          'lines': [
            {'text': '- レジは現金とカードのみ', 'patchId': null},
          ],
          'utterances': [_utterance('u2', 'お冷やはすぐ出す', '2026-11-04T10:00:00Z')],
          'patches': [],
          'checks': [],
        },
    };

/// 一覧と各マニュアルを返し、POST /utterances は onIntake に任せる
MockClient _client(Future<http.Response> Function(Map<String, dynamic> body) onIntake,
    {void Function(http.Request)? onOther}) {
  return MockClient((req) async {
    if (req.method == 'POST' && req.url.path == '/utterances') return onIntake(jsonDecode(req.body));
    onOther?.call(req);
    if (req.url.path == '/manuals') {
      return _json([
        {'id': 'm1', 'title': 'キッチン', 'utteranceCount': 1, 'openCount': 1},
        {'id': 'm2', 'title': 'ホール', 'utteranceCount': 1, 'openCount': 0},
      ]);
    }
    return _json(_state(req.url.pathSegments[1]));
  });
}

Future<void> _pumpInput(WidgetTester tester, http.Client client, {Size size = const Size(1200, 1400)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: appTheme(), home: InputScreen(api: Api(client: client, baseUrl: 'http://api'))));
  await tester.pumpAndSettle();
}

Future<void> _record(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(MoonTextArea), text);
  await tester.pump();
  await tester.tap(find.widgetWithText(MoonFilledButton, '差分を作る'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('あとで確認の件数と、全マニュアルの最近の記録を新しい順に出す', (tester) async {
    await _pumpInput(tester, _client((_) async => _json({})));

    // 広い画面ではサイドバーにも同じ名前が出るので、題名として出ているかを見る
    expect(find.descendant(of: find.byType(PageTitle), matching: find.text('言われたことを記録')), findsOneWidget);
    expect(find.text('あとで確認 1 件'), findsOneWidget);
    // 最近の記録は付箋を横にも並べるので、画面上の高さではなく並び順で比べる
    final texts = tester
        .widgetList<Text>(find.descendant(of: find.byType(StickyNote), matching: find.byType(Text)))
        .map((t) => t.data)
        .toList();
    expect(texts.indexOf('お冷やはすぐ出す'), lessThan(texts.indexOf('塩は小さじ1/2')));
  });

  testWidgets('マニュアルを選ばずに記録し、関係するマニュアルごとに差分の確認を順に出す', (tester) async {
    Map<String, dynamic>? sent;
    await _pumpInput(
      tester,
      _client((body) async {
        sent = body;
        return _json({
          'text': body['text'],
          'results': [
            {'manualId': 'm1', 'utteranceId': 'u1', 'state': _state('m1')},
            {'manualId': 'm2', 'utteranceId': 'u2', 'state': _state('m2')},
          ],
        }, 201);
      }),
    );
    await _record(tester, '田中さんから、レジ締めは店長がやると言われた');

    expect(sent, containsPair('text', '田中さんから、レジ締めは店長がやると言われた'));
    expect(sent!.containsKey('manualIds'), isFalse);
    expect(find.text('差分の確認'), findsOneWidget);
    // 記録しても確認へ急がせない
    expect(find.text('確認リストに入れました。聞けるときに確認して、決まったら記録します'), findsOneWidget);

    await tester.tap(find.byIcon(LucideIcons.x));
    await tester.pumpAndSettle();
    expect(find.text('差分の確認'), findsOneWidget);
    expect(find.text('マニュアルに関わる内容は見つかりませんでした。発言の記録だけ残しています。'), findsOneWidget);

    await tester.tap(find.byIcon(LucideIcons.x));
    await tester.pumpAndSettle();
    expect(find.text('差分の確認'), findsNothing);
    expect(tester.widget<MoonTextArea>(find.byType(MoonTextArea)).controller!.text, isEmpty);
  });

  testWidgets('関係するマニュアルが無ければ、選んだマニュアルに読み取った文面を記録する', (tester) async {
    final sent = <Map<String, dynamic>>[];
    await _pumpInput(
      tester,
      _client((body) async {
        sent.add(body);
        if (body['manualIds'] == null) return _json({'text': '傘は入口に置く', 'results': []});
        return _json({
          'text': body['text'],
          'results': [
            {'manualId': 'm2', 'utteranceId': 'u2', 'state': _state('m2')},
          ],
        }, 201);
      }),
    );
    await _record(tester, '傘は入口に置く');

    expect(find.text('どのマニュアルに記録しますか？'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(MoonModal), matching: find.text('ホール')));
    await tester.pumpAndSettle();

    expect(sent.last['manualIds'], ['m2']);
    expect(sent.last['text'], '傘は入口に置く');
    expect(sent.last['files'], isEmpty);
    expect(find.text('差分の確認'), findsOneWidget);
  });

  testWidgets('差分の確認を閉じるときに、発言者の修正を保存する', (tester) async {
    Map<String, dynamic>? editBody;
    await _pumpInput(
      tester,
      _client(
        (body) async => _json({
          'text': body['text'],
          'results': [
            {'manualId': 'm1', 'utteranceId': 'u1', 'state': _state('m1')},
          ],
        }, 201),
        onOther: (req) {
          if (req.method == 'PATCH') editBody = jsonDecode(req.body);
        },
      ),
    );
    await _record(tester, '塩は小さじ1/2');

    await tester.enterText(find.widgetWithText(MoonTextInput, '田中さん'), '田中さん（ホール）');
    await tester.tap(find.byIcon(LucideIcons.x));
    await tester.pumpAndSettle();

    expect(editBody, containsPair('speaker', '田中さん（ホール）'));
    expect(find.text('差分の確認'), findsNothing);
  });

  testWidgets('マニュアルが無いうちは、登録への案内を出す', (tester) async {
    await _pumpInput(tester, MockClient((_) async => _json([])));

    expect(find.text('まだマニュアルがありません'), findsOneWidget);
    expect(find.byType(MoonTextArea), findsNothing);
  });

  testWidgets('広い画面では、左のサイドバーからマニュアルへ直接移れ、あとで確認の件数も並ぶ', (tester) async {
    await _pumpInput(tester, _client((_) async => _json({})));

    // サイドバーと役割が重なるので、上部バーの「マニュアルを確認」は出さない
    expect(find.widgetWithText(MoonOutlinedButton, 'マニュアルを確認'), findsNothing);

    // ホールは「あとで確認」が無いので、入力ページの一覧には出ず、サイドバーにだけ並ぶ
    final hall = find.widgetWithText(MoonMenuItem, 'ホール');
    expect(hall, findsOneWidget);
    expect(find.descendant(of: find.widgetWithText(MoonMenuItem, 'キッチン').first, matching: find.text('1')), findsOneWidget);

    await tester.tap(hall);
    await tester.pumpAndSettle();
    expect(find.text('・レジは現金とカードのみ'), findsOneWidget);

    // サイドバーから移っても画面は積み重ならず、戻ると入力ページに出る
    await tester.tap(find.bySemanticsLabel('戻る'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(PageTitle), matching: find.text('言われたことを記録')), findsOneWidget);
  });

  testWidgets('Ctrl+Enter でも、ボタンを押さずに送れる', (tester) async {
    Map<String, dynamic>? sent;
    await _pumpInput(
      tester,
      _client((body) async {
        sent = body;
        return _json({'text': body['text'], 'results': []}, 201);
      }),
    );
    await tester.enterText(find.byType(MoonTextArea), 'UUID は使わないでと言われた');
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    await tester.pumpAndSettle();

    expect(sent, containsPair('text', 'UUID は使わないでと言われた'));
  });

  testWidgets('狭い画面ではサイドバーを出さず、上部バーの「マニュアルを確認」から一覧へ進む', (tester) async {
    await _pumpInput(tester, _client((_) async => _json({})), size: const Size(400, 900));

    expect(find.widgetWithText(MoonMenuItem, 'ホール'), findsNothing);
    await tester.tap(find.widgetWithText(MoonOutlinedButton, 'マニュアルを確認'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(PageTitle), matching: find.text('マニュアル')), findsOneWidget);
  });
}
