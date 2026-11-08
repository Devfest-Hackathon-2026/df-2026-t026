import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:diff_note/api.dart';
import 'package:diff_note/screens/input_screen.dart';
import 'package:diff_note/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:moon_design/moon_design.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

/// 一覧と各マニュアルを返し、POST /utterances は onIntake に、POST /transcribe は onTranscribe に任せる
MockClient _client(Future<http.Response> Function(Map<String, dynamic> body) onIntake,
    {void Function(http.Request)? onOther, Future<http.Response> Function(Map<String, dynamic> body)? onTranscribe}) {
  return MockClient((req) async {
    if (req.method == 'POST' && req.url.path == '/utterances') return onIntake(jsonDecode(req.body));
    if (req.method == 'POST' && req.url.path == '/transcribe') return onTranscribe!(jsonDecode(req.body));
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

/// マイクの代わり。test が流した PCM をそのまま渡す
class _FakeMic implements AudioRecorder {
  _FakeMic(this.pcm);
  final StreamController<Uint8List> pcm;

  @override
  Future<bool> hasPermission({bool request = true}) async => true;

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async => pcm.stream;

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 16kHz・16bit の PCM。声は一定の大きさの音、無音は 0
Uint8List _pcm(int ms, {required bool voice}) {
  final d = ByteData(16 * ms * 2);
  for (var i = 0; i < 16 * ms; i++) {
    d.setInt16(i * 2, voice ? 3000 : 0, Endian.little);
  }
  return d.buffer.asUint8List();
}

Future<void> _pumpInput(WidgetTester tester, http.Client client, {StreamController<Uint8List>? mic}) async {
  tester.view.physicalSize = const Size(1200, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final api = Api(client: client, baseUrl: 'http://api');
  await tester.pumpWidget(MaterialApp(
    theme: appTheme(),
    home: mic == null ? InputScreen(api: api) : InputScreen(api: api, newRecorder: () => _FakeMic(mic)),
  ));
  await tester.pumpAndSettle();
}

/// トーストが消えるまで進める（タイマーを残したまま終えない）
Future<void> _waitToast(WidgetTester tester) => tester.pumpAndSettle(const Duration(seconds: 10));

Future<void> _record(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(MoonTextArea), text);
  await tester.pump();
  await tester.tap(find.widgetWithText(MoonFilledButton, '差分を作る'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('あとで確認の件数と、全マニュアルの最近の記録を新しい順に出す', (tester) async {
    await _pumpInput(tester, _client((_) async => _json({})));

    expect(find.text('言われたことを記録'), findsOneWidget);
    expect(find.text('あとで確認 1 件'), findsOneWidget);
    final newer = tester.getTopLeft(find.text('お冷やはすぐ出す')).dy;
    final older = tester.getTopLeft(find.text('塩は小さじ1/2')).dy;
    expect(newer, lessThan(older));
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

  testWidgets('常時待ち受けを ON にすると、送っていないことの案内と音量を出し、選んだことを覚える', (tester) async {
    await _pumpInput(tester, _client((_) async => _json({})), mic: StreamController());
    expect(find.text('端末内で直前60秒を保持中（送信していません）'), findsNothing);

    await tester.tap(find.byType(MoonSwitch));
    await tester.pumpAndSettle();

    expect(find.text('端末内で直前60秒を保持中（送信していません）'), findsOneWidget);
    expect(find.byType(MoonLinearProgress), findsOneWidget);
    expect((await SharedPreferences.getInstance()).getBool(listeningKey), isTrue);
  });

  testWidgets('切り出すと、話し終わりを待って押した時刻の発話だけを送り、差分の確認を出す', (tester) async {
    final mic = StreamController<Uint8List>();
    Map<String, dynamic>? sent;
    await _pumpInput(
      tester,
      _client((body) async {
        sent = body;
        return _json({
          'text': '塩は小さじ1/2',
          'results': [
            {'manualId': 'm1', 'utteranceId': 'u1', 'state': _state('m1')},
          ],
        }, 201);
      }),
      mic: mic,
    );
    await tester.tap(find.byType(MoonSwitch));
    await tester.pumpAndSettle();

    // 前の発話のあとに長い無音をはさみ、話している途中で押す
    mic
      ..add(_pcm(500, voice: true))
      ..add(_pcm(2000, voice: false))
      ..add(_pcm(1000, voice: true));
    await tester.pump();
    await tester.tap(find.widgetWithText(MoonFilledButton, '直前の発話を記録する'));
    await tester.pump();
    expect(find.text('話し終わりを待っています…'), findsOneWidget);
    expect(sent, isNull);

    mic.add(_pcm(1200, voice: false));
    await tester.pumpAndSettle();

    final file = (sent!['files'] as List).single;
    expect(file['mimeType'], 'audio/wav');
    // 1秒の発話に前後300msの余白を足した長さ（16kHz・16bit）だけを切り出す
    expect(base64Decode(file['data']).length, 44 + 1600 * 16 * 2);
    expect(find.text('差分の確認'), findsOneWidget);
  });

  testWidgets('声が入っていなければ、切り出しても送らずに知らせる', (tester) async {
    final mic = StreamController<Uint8List>();
    var sent = false;
    await _pumpInput(tester, _client((_) async => (sent = true, _json({})).$2), mic: mic);
    await tester.tap(find.byType(MoonSwitch));
    await tester.pumpAndSettle();

    mic.add(_pcm(3000, voice: false));
    await tester.pump();
    await tester.tap(find.widgetWithText(MoonFilledButton, '直前の発話を記録する'));
    await tester.pump(const Duration(milliseconds: 500));

    expect(sent, isFalse);
    expect(find.text('声が入っていませんでした。言われた直後にもう一度押してください'), findsOneWidget);
    await _waitToast(tester);
  });

  testWidgets('テキスト欄の音声入力は、書き起こした文面を入力欄に足す', (tester) async {
    final mic = StreamController<Uint8List>();
    Map<String, dynamic>? sent;
    await _pumpInput(
      tester,
      _client((_) async => _json({}), onTranscribe: (body) async {
        sent = body;
        return _json({'text': '塩は小さじ1/2でいい'});
      }),
      mic: mic,
    );
    await tester.enterText(find.byType(MoonTextArea), '田中さんから');
    await tester.tap(find.widgetWithText(MoonOutlinedButton, '音声入力'));
    await tester.pump();
    mic.add(_pcm(1000, voice: true));
    await tester.pump();
    expect(find.text('録音中 あと59秒'), findsOneWidget);

    await tester.tap(find.widgetWithText(MoonOutlinedButton, '音声入力を止める'));
    await tester.pumpAndSettle();

    expect(base64Decode(sent!['data']).length, 44 + 1000 * 16 * 2);
    expect(tester.widget<MoonTextArea>(find.byType(MoonTextArea)).controller!.text, '田中さんから\n塩は小さじ1/2でいい');
  });

  testWidgets('音声入力は60秒で止めて書き起こす', (tester) async {
    final mic = StreamController<Uint8List>();
    Map<String, dynamic>? sent;
    await _pumpInput(
      tester,
      _client((_) async => _json({}), onTranscribe: (body) async {
        sent = body;
        return _json({'text': '長い説明'});
      }),
      mic: mic,
    );
    await tester.tap(find.widgetWithText(MoonOutlinedButton, '音声入力'));
    await tester.pump();
    mic.add(_pcm(61000, voice: true));
    await tester.pumpAndSettle();

    expect(base64Decode(sent!['data']).length, 44 + 60000 * 16 * 2);
    expect(find.widgetWithText(MoonOutlinedButton, '音声入力'), findsOneWidget);
  });
}
