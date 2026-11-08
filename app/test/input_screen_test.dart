import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:diff_note/api.dart';
import 'package:diff_note/screens/common.dart';
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
import 'package:web_socket_channel/web_socket_channel.dart';

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

/// 16kHz・16bit の PCM。声は一定の大きさの音、無音は 0。level を渡すとその大きさの音にする
Uint8List _pcm(int ms, {bool voice = false, int? level}) {
  final d = ByteData(16 * ms * 2);
  for (var i = 0; i < 16 * ms; i++) {
    d.setInt16(i * 2, level ?? (voice ? 3000 : 0), Endian.little);
  }
  return d.buffer.asUint8List();
}

/// 音声入力のサーバーの代わり。アプリが送ったものを残し、test から文面を返す
class _FakeSocket implements WebSocketChannel {
  final sent = <Object?>[];
  final _replies = StreamController<dynamic>();

  void reply(Map<String, dynamic> m) => _replies.add(jsonEncode(m));
  Future<void> close() => _replies.close();

  /// 送られた PCM の合計の大きさ
  int get pcmBytes => sent.whereType<Uint8List>().fold(0, (n, b) => n + b.length);

  @override
  Stream<dynamic> get stream => _replies.stream;

  @override
  late final WebSocketSink sink = _FakeSink(sent, onClose: close);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSink implements WebSocketSink {
  _FakeSink(this.sent, {required this.onClose});
  final List<Object?> sent;

  /// 本物と同じく、アプリが閉じたらサーバーからの流れも終える
  final Future<void> Function() onClose;

  @override
  void add(dynamic data) => sent.add(data);

  @override
  Future<void> close([int? closeCode, String? closeReason]) => onClose();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pumpInput(WidgetTester tester, http.Client client,
    {StreamController<Uint8List>? mic, _FakeSocket? socket}) async {
  tester.view.physicalSize = const Size(1200, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final api = Api(client: client, baseUrl: 'http://api', connect: (_) => socket!);
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

  testWidgets('差分の確認で書き起こしを直すと、直した文面を送って差分を作り直す', (tester) async {
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

    await tester.tap(find.widgetWithText(MoonTextButton, '書き起こしを直す'));
    await tester.pump();
    await tester.enterText(find.widgetWithText(MoonTextInput, '塩は小さじ1/2'), '塩は大さじ1/2');
    await tester.tap(find.widgetWithText(MoonFilledButton, '直して差分を作り直す'));
    await tester.pumpAndSettle();

    // 発言者と日付は変えていないので送らず、読み直した結果に任せる
    expect(editBody, {'text': '塩は大さじ1/2'});
    expect(find.text('直して差分を作り直す'), findsNothing);
  });

  testWidgets('差分の確認で、これまでの発言者を押すと発言者に入る', (tester) async {
    final kitchen = _state('m1');
    (kitchen['utterances'] as List).insert(0, {..._utterance('u0', 'お玉は洗って戻す', '2026-11-01T10:00:00Z'), 'speaker': '佐藤さん'});
    Map<String, dynamic>? editBody;
    await _pumpInput(
      tester,
      _client(
        (body) async => _json({
          'text': body['text'],
          'results': [
            {'manualId': 'm1', 'utteranceId': 'u1', 'state': kitchen},
          ],
        }, 201),
        onOther: (req) {
          if (req.method == 'PATCH') editBody = jsonDecode(req.body);
        },
      ),
    );
    await _record(tester, '塩は小さじ1/2');

    await tester.tap(find.widgetWithText(MoonChip, '佐藤さん'));
    await tester.pump();
    await tester.tap(find.byIcon(LucideIcons.x));
    await tester.pumpAndSettle();

    expect(editBody, containsPair('speaker', '佐藤さん'));
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

  testWidgets('騒音が続く所でも、騒音を声とみなさずに発話だけを切り出す', (tester) async {
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

    // 換気扇の音（RMS 1500）の中で1秒話す
    mic
      ..add(_pcm(3000, level: 1500))
      ..add(_pcm(1000, level: 8000))
      ..add(_pcm(1200, level: 1500));
    await tester.pump();
    await tester.tap(find.widgetWithText(MoonFilledButton, '直前の発話を記録する'));
    await tester.pumpAndSettle();

    final file = (sent!['files'] as List).single;
    // 1秒の発話に前後300msの余白を足した長さだけで、騒音の部分は切り出さない
    expect(base64Decode(file['data']).length, 44 + 1600 * 16 * 2);
  });

  testWidgets('待ち受けのマイクが止まったら知らせ、再開のしかたを出す', (tester) async {
    final mic = StreamController<Uint8List>();
    await _pumpInput(tester, _client((_) async => _json({})), mic: mic);
    await tester.tap(find.byType(MoonSwitch));
    await tester.pumpAndSettle();

    await mic.close();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('待ち受けが止まっていました。画面のどこかを押すと再開します'), findsOneWidget);
    expect(find.text('画面のどこかを押すと、待ち受けを再開します'), findsOneWidget);
    await _waitToast(tester);
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

  testWidgets('音声入力は、話している途中から入力欄に文字を出し、話し終わると止めて確定の文面にする', (tester) async {
    final mic = StreamController<Uint8List>();
    final socket = _FakeSocket();
    await _pumpInput(tester, _client((_) async => _json({})), mic: mic, socket: socket);
    await tester.enterText(find.byType(MoonTextArea), '田中さんから');
    await tester.tap(find.byIcon(LucideIcons.mic));
    await tester.pump();

    mic.add(_pcm(500, voice: true));
    await tester.pump();
    expect(socket.pcmBytes, 500 * 16 * 2);
    expect(find.text('聞き取り中。話し終わると止まります'), findsOneWidget);
    socket.reply({'text': '塩は'});
    await tester.pump();
    expect(_typed(tester), '田中さんから\n塩は');

    mic.add(_pcm(1600, voice: false));
    await tester.pump();
    expect(socket.sent.last, 'end');
    expect(find.text('聞き取り中。話し終わると止まります'), findsNothing);

    socket.reply({'text': '塩は小さじ1/2でいい', 'done': true});
    await socket.close();
    await tester.pumpAndSettle();
    expect(_typed(tester), '田中さんから\n塩は小さじ1/2でいい');
    expect(find.byIcon(LucideIcons.mic), findsOneWidget);
  });

  testWidgets('音声入力は、話し出さないまま8秒たったら、無音を送らずに止めて知らせる', (tester) async {
    final mic = StreamController<Uint8List>();
    final socket = _FakeSocket();
    await _pumpInput(tester, _client((_) async => _json({})), mic: mic, socket: socket);
    await tester.tap(find.byIcon(LucideIcons.mic));
    await tester.pump();

    mic.add(_pcm(7000, voice: false));
    await tester.pump();
    expect(find.text('聞き取り中。話し終わると止まります'), findsOneWidget);
    mic.add(_pcm(1100, voice: false));
    await tester.pump(const Duration(milliseconds: 500));

    // Speech-to-Text は無音を「はい。」などと書き起こすことがあるので、無音は送らない
    expect(socket.sent, isEmpty);
    expect(find.text('声が入っていませんでした。マイクを押してから話してください'), findsOneWidget);
    expect(find.text('聞き取り中。話し終わると止まります'), findsNothing);
    await _waitToast(tester);
  });

  testWidgets('音声入力は、声が聞こえる前の無音を送らず、話し始めの直前0.5秒からを送る', (tester) async {
    final mic = StreamController<Uint8List>();
    final socket = _FakeSocket();
    await _pumpInput(tester, _client((_) async => _json({})), mic: mic, socket: socket);
    await tester.tap(find.byIcon(LucideIcons.mic));
    await tester.pump();

    for (var i = 0; i < 30; i++) {
      mic.add(_pcm(100, voice: false));
    }
    await tester.pump();
    expect(socket.sent, isEmpty);
    mic.add(_pcm(300, voice: true));
    await tester.pump();
    expect(socket.pcmBytes, (500 + 300) * 16 * 2);
    await socket.close();
    await tester.pumpAndSettle();
  });

  testWidgets('音声入力は60秒で止める', (tester) async {
    final mic = StreamController<Uint8List>();
    final socket = _FakeSocket();
    await _pumpInput(tester, _client((_) async => _json({})), mic: mic, socket: socket);
    await tester.tap(find.byIcon(LucideIcons.mic));
    await tester.pump();

    mic.add(_pcm(61000, voice: true));
    await tester.pump();
    expect(socket.pcmBytes, 60000 * 16 * 2);
    expect(socket.sent.last, 'end');
    await socket.close();
    await tester.pumpAndSettle();
  });
}

String _typed(WidgetTester tester) => tester.widget<MoonTextArea>(find.byType(MoonTextArea)).controller!.text;
