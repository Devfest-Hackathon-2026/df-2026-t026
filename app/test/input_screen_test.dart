import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:diff_note/api.dart';
import 'package:diff_note/models.dart';
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
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'input_font.dart';

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

Map<String, dynamic> _utterance(String id, String text, String createdAt) =>
    {'id': id, 'text': text, 'speaker': '田中さん', 'saidAt': '2026-11-03', 'createdAt': createdAt};

/// m1 はキッチン（食い違いが1件）、m2 はホール
Map<String, dynamic> _state(String id) => switch (id) {
      'm1' => {
          'manual': {'id': 'm1', 'title': 'キッチン', 'base': '- 塩 小さじ1', 'createdAt': '2026-11-01T00:00:00Z'},
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
                'createdAt': '2026-11-03T10:00:00Z',
                'appliedAt': null,
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
          'manual': {'id': 'm2', 'title': 'ホール', 'base': '- レジは現金とカードのみ', 'createdAt': '2026-11-01T00:00:00Z'},
          'lines': [
            {'text': '- レジは現金とカードのみ', 'patchId': null},
          ],
          'utterances': [_utterance('u2', 'お冷やはすぐ出す', '2026-11-04T10:00:00Z')],
          'patches': [],
          'checks': [],
        },
    };

/// 一覧と各マニュアルを返し、POST /utterances は onIntake、POST /listen は onListen に任せる
MockClient _client(Future<http.Response> Function(Map<String, dynamic> body) onIntake,
    {void Function(http.Request)? onOther, Future<http.Response> Function(Map<String, dynamic> body)? onListen}) {
  return MockClient((req) async {
    if (req.method == 'POST' && req.url.path == '/utterances') return onIntake(jsonDecode(req.body));
    if (req.method == 'POST' && req.url.path == '/listen') return onListen!(jsonDecode(req.body));
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
  _FakeMic(this.pcm, {this.allowed = true, this.onAsked});
  final StreamController<Uint8List> pcm;
  final bool allowed;
  final VoidCallback? onAsked;

  @override
  Future<bool> hasPermission({bool request = true}) async {
    onAsked?.call();
    return allowed;
  }

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
    {StreamController<Uint8List>? mic,
    bool micAllowed = true,
    VoidCallback? onMicAsked,
    _FakeSocket? socket,
    List<PickedFile> picked = const [],
    Size size = const Size(1200, 1400)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final api = Api(client: client, baseUrl: 'http://api', connect: (_) => socket!);
  await tester.pumpWidget(MaterialApp(
    theme: appTheme(),
    home: InputScreen(
      api: api,
      newRecorder: mic == null ? AudioRecorder.new : () => _FakeMic(mic, allowed: micAllowed, onAsked: onMicAsked),
      pickFiles: () async => picked,
    ),
  ));
  await tester.pumpAndSettle();
}

/// 題名の右のトグルでリワインドを ON にする。ON にすると常時待ち受けが始まる
Future<void> _startRewind(WidgetTester tester) async {
  await tester.tap(find.byType(MoonSwitch));
  await tester.pumpAndSettle();
}

/// 前の発話のあとに長い無音をはさみ、話している途中で押して、話し終わらせる
Future<void> _captureOnce(WidgetTester tester, StreamController<Uint8List> mic) async {
  mic
    ..add(_pcm(500, voice: true))
    ..add(_pcm(6000, voice: false))
    ..add(_pcm(1000, voice: true));
  await tester.pump();
  await tester.tap(find.widgetWithText(MoonFilledButton, 'いま言われたことをメモする'));
  await tester.pump();
  mic.add(_pcm(1200, voice: false));
  await tester.pump();
}

/// トーストが消えるまで進める（タイマーを残したまま終えない）
Future<void> _waitToast(WidgetTester tester) => tester.pumpAndSettle(const Duration(seconds: 10));

Future<void> _record(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(MoonTextArea), text);
  await tester.pump();
  await tester.tap(find.widgetWithText(MoonFilledButton, 'ノートと照らし合わせる'));
  await tester.pumpAndSettle();
}

/// 照らし合わせた後の知らせの「確かめる」から、書き込む前の確認を開く
Future<void> _review(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(MoonTextButton, '確かめる'));
  await tester.pumpAndSettle();
}

Map<String, dynamic> _patch(String id, String text) => {
      'id': id,
      'utteranceId': 'u2',
      'op': 'insert',
      'line': '- レジは現金とカードのみ',
      'text': text,
      'summary': '追記',
      'status': 'proposed',
      'createdAt': '2026-11-04T10:00:00Z',
      'appliedAt': null,
    };

Map<String, dynamic> _check(String id, String patchId, String kind) => {
      'id': id,
      'patchId': patchId,
      'utteranceId': 'u2',
      'kind': kind,
      'conflictLine': null,
      'sameLine': kind == 'same' ? '- レジは現金とカードのみ' : null,
      'reason': '理由',
      'ask': null,
      'resolution': null,
    };

/// ホールに、追加1行と同じ内容1行を記録した結果
Map<String, dynamic> _hallWithPatches({String? speaker = '田中さん'}) => {
      ..._state('m2'),
      'utterances': [
        {..._utterance('u2', 'お冷やはすぐ出す', '2026-11-04T10:00:00Z'), 'speaker': speaker},
      ],
      'patches': [_patch('p1', '- お冷やはすぐ出す'), _patch('p2', '- レジは現金とカードのみ')],
      'checks': [_check('c1', 'p1', 'addition'), _check('c2', 'p2', 'same')],
    };

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

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

  testWidgets('マニュアルを選ばずに記録し、関係するマニュアルの変わる行を1つの確認に並べる', (tester) async {
    Map<String, dynamic>? sent;
    final edited = <String, Map<String, dynamic>>{};
    await _pumpInput(
      tester,
      _client(
        (body) async {
          sent = body;
          return _json({
            'text': body['text'],
            'results': [
              {'manualId': 'm1', 'utteranceId': 'u1', 'state': _state('m1')},
              {'manualId': 'm2', 'utteranceId': 'u2', 'state': _state('m2')},
            ],
          }, 201);
        },
        onOther: (req) {
          if (req.method == 'PATCH') edited[req.url.pathSegments[1]] = jsonDecode(req.body);
        },
      ),
    );
    await _record(tester, '田中さんから、レジ締めは店長がやると言われた');

    expect(sent, containsPair('text', '田中さんから、レジ締めは店長がやると言われた'));
    expect(sent!.containsKey('manualIds'), isFalse);
    // 食い違いだけなので、確認は開かずに知らせる
    expect(find.text('ノートに書き込む前の確認'), findsNothing);
    expect(find.text('食い違いが1件あり、確認リストに入れました'), findsOneWidget);
    await _review(tester);
    expect(find.text('ノートに書き込む前の確認'), findsOneWidget);
    // どのノートの話かを題名で分け、上下に並べる
    final modal = find.byType(MoonModal);
    expect(find.descendant(of: modal, matching: find.text('キッチン')), findsOneWidget);
    expect(find.descendant(of: modal, matching: find.text('ホール')), findsOneWidget);
    // 記録しても確認へ急がせない
    expect(find.text('確認リストに入れました。聞けるときに確認して、決まったら記録します'), findsOneWidget);
    expect(find.text('ノートに関わる内容は見つかりませんでした。発言の記録だけ残しています。'), findsOneWidget);
    // 発言者は1回だけ入れる
    expect(find.descendant(of: modal, matching: find.byType(MoonTextInput)), findsOneWidget);

    await tester.enterText(find.widgetWithText(MoonTextInput, '田中さん'), '田中さん（ホール）');
    await tester.tap(find.byIcon(LucideIcons.x));
    await tester.pumpAndSettle();
    expect(find.text('ノートに書き込む前の確認'), findsNothing);
    // 直した発言者は、どのノートの記録にも入る
    expect(edited.keys, unorderedEquals(['m1', 'm2']));
    expect(edited['m1'], containsPair('speaker', '田中さん（ホール）'));
    expect(edited['m2'], containsPair('speaker', '田中さん（ホール）'));
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

    expect(find.text('どのノートに記録しますか？'), findsOneWidget);
    // 選ぶまでは記録できない。1回の指示が複数にまたがることもあるので、いくつでも選べる
    expect(tester.widget<MoonFilledButton>(find.widgetWithText(MoonFilledButton, '選んだノートと照らし合わせる')).onTap, isNull);
    await tester.tap(find.descendant(of: find.byType(MoonModal), matching: find.text('ホール')));
    await tester.tap(find.descendant(of: find.byType(MoonModal), matching: find.text('キッチン')));
    await tester.pump();
    await tester.tap(find.widgetWithText(MoonFilledButton, '選んだノートと照らし合わせる'));
    await tester.pumpAndSettle();

    expect(sent.last['manualIds'], ['m1', 'm2']);
    expect(sent.last['text'], '傘は入口に置く');
    expect(sent.last['files'], isEmpty);
    expect(find.text('ノートは変えずに、言われた記録として残しました'), findsOneWidget);
    await _waitToast(tester);
  });

  testWidgets('記録先を先に選ぶと、そのノートだけに記録し、選び直せば自動に戻る', (tester) async {
    final sent = <Map<String, dynamic>>[];
    await _pumpInput(
      tester,
      _client((body) async {
        sent.add(body);
        return _json({
          'text': body['text'],
          'results': [
            {'manualId': 'm2', 'utteranceId': 'u2', 'state': _state('m2')},
          ],
        }, 201);
      }),
    );
    expect(find.text('記録先：自動'), findsOneWidget);
    // 記録先を足しても、マイクは入力欄の右端に置いたまま（余白の分だけ内側）
    final mic = tester.getRect(find.widgetWithIcon(MoonButton, LucideIcons.mic));
    final area = tester.getRect(find.byType(MoonTextArea));
    expect(area.right - mic.right, lessThan(16));
    await tester.tap(find.widgetWithText(MoonTextButton, '記録先：自動'));
    await tester.pumpAndSettle();
    expect(find.text('どのノートに記録しますか？'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(MoonModal), matching: find.text('ホール')));
    await tester.pump();
    await tester.tap(find.widgetWithText(MoonFilledButton, '記録先を決める'));
    await tester.pumpAndSettle();
    expect(find.text('記録先：ホール'), findsOneWidget);

    await _record(tester, 'お冷やはすぐ出す');
    expect(sent.single['manualIds'], ['m2']);
    await _waitToast(tester);

    // 送った後も記録先は残る。外して決めれば自動に戻る
    await tester.tap(find.widgetWithText(MoonTextButton, '記録先：ホール'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(MoonModal), matching: find.text('ホール')));
    await tester.pump();
    await tester.tap(find.widgetWithText(MoonFilledButton, '記録先を決める'));
    await tester.pumpAndSettle();
    expect(find.text('記録先：自動'), findsOneWidget);
    await _record(tester, 'レジ締めは店長');
    expect(sent.last.containsKey('manualIds'), isFalse);
    await _waitToast(tester);
  });

  testWidgets('記録先を2冊選ぶと冊数で出し、狭い画面でもはみ出さない', (tester) async {
    await _pumpInput(tester, _client((_) async => _json({})), size: const Size(360, 800));
    await tester.tap(find.widgetWithText(MoonTextButton, '記録先：自動'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(MoonModal), matching: find.text('キッチン')));
    await tester.tap(find.descendant(of: find.byType(MoonModal), matching: find.text('ホール')));
    await tester.pump();
    await tester.tap(find.widgetWithText(MoonFilledButton, '記録先を決める'));
    await tester.pumpAndSettle();
    expect(find.text('記録先：2冊'), findsOneWidget);
    expect(tester.takeException(), isNull);
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
    await _review(tester);
    expectInputFontsAtLeast16(tester, count: 1); // 書き込む前の確認の、発言者

    await tester.enterText(find.widgetWithText(MoonTextInput, '田中さん'), '田中さん（ホール）');
    await tester.tap(find.byIcon(LucideIcons.x));
    await tester.pumpAndSettle();

    expect(editBody, containsPair('speaker', '田中さん（ホール）'));
    expect(find.text('ノートに書き込む前の確認'), findsNothing);
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
    await _review(tester);

    await tester.tap(find.widgetWithText(MoonTextButton, '言われたことを直す'));
    await tester.pump();
    expectInputFontsAtLeast16(tester, count: 2); // 発言者・言われたことを直す欄
    await tester.enterText(find.widgetWithText(MoonTextInput, '塩は小さじ1/2'), '塩は大さじ1/2');
    await tester.tap(find.widgetWithText(MoonFilledButton, '直して照らし合わせ直す'));
    await tester.pumpAndSettle();

    // 発言者と日付は変えていないので送らず、読み直した結果に任せる
    expect(editBody, {'text': '塩は大さじ1/2'});
    expect(find.text('直して照らし合わせ直す'), findsNothing);
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
    await _review(tester);

    await tester.tap(find.widgetWithText(MoonChip, '佐藤さん'));
    await tester.pump();
    await tester.tap(find.byIcon(LucideIcons.x));
    await tester.pumpAndSettle();

    expect(editBody, containsPair('speaker', '佐藤さん'));
  });

  testWidgets('マニュアルが無いうちは、登録への案内を出す', (tester) async {
    await _pumpInput(tester, MockClient((_) async => _json([])));

    expect(find.text('まだノートがありません'), findsOneWidget);
    expect(find.byType(MoonTextArea), findsNothing);
  });

  testWidgets('リワインドを ON にすると、サイドバーとトグルの位置はそのままで、書く欄の所に待ち受け、最近の記録の所に未整理メモを出し、OFF にすると止める', (tester) async {
    final mic = StreamController<Uint8List>();
    await _pumpInput(tester, _client((_) async => _json({})), mic: mic);
    expect(find.byType(MoonTextArea), findsOneWidget);
    expect(mic.hasListener, isFalse);
    final toggleAt = tester.getTopLeft(find.byType(MoonSwitch));

    await _startRewind(tester);

    expect(mic.hasListener, isTrue);
    expect(find.text('端末内で直前60秒を保持中（送信していません）'), findsOneWidget);
    expect(find.byType(MoonLinearProgress), findsOneWidget);
    expect(find.byType(MoonTextArea), findsNothing);
    expect(tester.getTopLeft(find.byType(MoonSwitch)), toggleAt);
    expect(find.descendant(of: find.byType(PageTitle), matching: find.text('言われたことを記録')), findsOneWidget);
    // サイドバーにだけある項目（ノートを作る＋）。リワインドにしてもサイドバーはそのまま
    expect(find.bySemanticsLabel('ノートを作る'), findsOneWidget);
    expect(find.text('最近の記録'), findsNothing);
    expect(find.text('いま言われたことをメモすると、ここにたまります'), findsOneWidget);

    await tester.tap(find.byType(MoonSwitch));
    await tester.pumpAndSettle();
    expect(mic.hasListener, isFalse);
    expect(find.byType(MoonTextArea), findsOneWidget);
    expect(find.text('最近の記録'), findsOneWidget);
  });

  testWidgets('切り出すと、押す前の会話を書き起こして未整理メモにため、確認は出さずに続けて押せる', (tester) async {
    final mic = StreamController<Uint8List>();
    final heard = <Completer<http.Response>>[];
    final sent = <Map<String, dynamic>>[];
    await _pumpInput(
      tester,
      _client((_) async => _json({}), onListen: (body) {
        sent.add(body);
        heard.add(Completer());
        return heard.last.future;
      }),
      mic: mic,
    );
    await _startRewind(tester);

    // 前の話・長い無音・言われたこと・返事の順に話してから押す
    mic
      ..add(_pcm(500, voice: true))
      ..add(_pcm(6000, voice: false))
      ..add(_pcm(1000, voice: true))
      ..add(_pcm(2000, voice: false))
      ..add(_pcm(400, voice: true));
    await tester.pump();
    await tester.tap(find.widgetWithText(MoonFilledButton, 'いま言われたことをメモする'));
    await tester.pump();
    expect(find.widgetWithText(MoonFilledButton, '話し終わるのを待っています…'), findsOneWidget);
    expect(sent, isEmpty);

    mic.add(_pcm(1200, voice: false));
    await tester.pump();
    // 言われたこと（1秒）と返事（0.4秒）に、それぞれ前後300msの余白を足し、間の無音を詰めてつなぐ（16kHz・16bit）
    expect(base64Decode(sent.single['data']).length, 44 + (1600 + 1000) * 16 * 2);
    expect(find.text('書き起こし中 1 件'), findsOneWidget);

    // 書き起こしを待たずに、もう一度切り出せる
    await _captureOnce(tester, mic);
    expect(sent, hasLength(2));
    expect(find.text('書き起こし中 2 件'), findsOneWidget);

    heard[1].complete(_json({'text': 'お冷やはすぐ出す'}));
    heard[0].complete(_json({'text': '塩は小さじ1/2'}));
    await tester.pumpAndSettle();
    expect(find.text('ノートに書き込む前の確認'), findsNothing);
    expect(find.textContaining('書き起こし中'), findsNothing);
    // 最近の記録にも同じ文面があるので、未整理メモの数で見る
    expect(find.bySemanticsLabel('メモを消す'), findsNWidgets(2));
    // 端末内には、切り出した順にためる
    final saved = (await SharedPreferences.getInstance()).getStringList(memosKey)!;
    expect([for (final m in saved) jsonDecode(m)['text']], ['塩は小さじ1/2', 'お冷やはすぐ出す']);
  });

  testWidgets('書き起こしを待つ間にリワインドを OFF にしても、届いたメモを未整理メモにためる', (tester) async {
    final mic = StreamController<Uint8List>();
    final heard = Completer<http.Response>();
    await _pumpInput(tester, _client((_) async => _json({}), onListen: (_) => heard.future), mic: mic);
    await _startRewind(tester);
    await _captureOnce(tester, mic);

    await tester.tap(find.byType(MoonSwitch));
    await tester.pumpAndSettle();
    heard.complete(_json({'text': '大皿は右の棚の下の段'}));
    await tester.pumpAndSettle();

    expect(find.byType(MoonTextArea), findsOneWidget);
    expect(find.text('大皿は右の棚の下の段'), findsOneWidget);
    expect((await SharedPreferences.getInstance()).getStringList(memosKey), hasLength(1));
  });

  testWidgets('書き起こせなければ、メモを作らずに知らせる', (tester) async {
    final mic = StreamController<Uint8List>();
    await _pumpInput(
      tester,
      _client((_) async => _json({}),
          onListen: (_) async => _json({'error': '聞き取れませんでした。言われた直後にもう一度押してください'}, 422)),
      mic: mic,
    );
    await _startRewind(tester);
    await _captureOnce(tester, mic);
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('聞き取れませんでした。言われた直後にもう一度押してください'), findsOneWidget);
    expect(find.bySemanticsLabel('メモを消す'), findsNothing);
    expect((await SharedPreferences.getInstance()).getStringList(memosKey), isNull);
    await _waitToast(tester);
  });

  testWidgets('前回リワインドを開いたまま閉じても、入力ページから始め、ためたメモを出す', (tester) async {
    SharedPreferences.setMockInitialValues({
      // 前の版が覚えていた「リワインドを開いていた」印
      'listening': true,
      memosKey: [jsonEncode(Memo(at: DateTime(2026, 11, 3, 14, 5), text: '塩は小さじ1/2').toJson())],
    });
    final mic = StreamController<Uint8List>();
    await _pumpInput(tester, _client((_) async => _json({})), mic: mic);

    expect(find.byType(MoonTextArea), findsOneWidget);
    expect(find.text('11/3 14:05'), findsOneWidget);
    expect(mic.hasListener, isFalse);
  });

  testWidgets('未整理メモを入力欄にまとめて入れ、切り出した日として記録したら、メモから消す', (tester) async {
    SharedPreferences.setMockInitialValues({
      memosKey: [
        jsonEncode(Memo(at: DateTime(2026, 11, 3, 14, 5), text: '塩は小さじ1/2').toJson()),
        jsonEncode(Memo(at: DateTime(2026, 11, 4, 9, 30), text: 'お冷やはすぐ出す').toJson()),
        jsonEncode(Memo(at: DateTime(2026, 11, 4, 9, 40), text: 'えーと').toJson()),
      ],
    });
    Map<String, dynamic>? sent;
    await _pumpInput(
      tester,
      _client((body) async {
        sent = body;
        return _json({
          'text': body['text'],
          'results': [
            {'manualId': 'm1', 'utteranceId': 'u1', 'state': _state('m1')},
          ],
        }, 201);
      }),
    );

    await tester.tap(find.text('お冷やはすぐ出す').first);
    await tester.pump();
    await tester.tap(find.text('塩は小さじ1/2').first);
    await tester.pump();
    expect(_typed(tester), 'お冷やはすぐ出す\n塩は小さじ1/2');
    expect(find.text('入力欄に入れました'), findsNWidgets(2));

    await tester.enterText(find.byType(MoonTextArea), '田中さんから、お冷やはすぐ出す。塩は小さじ1/2');
    await tester.tap(find.widgetWithText(MoonFilledButton, 'ノートと照らし合わせる'));
    await tester.pumpAndSettle();

    // 一番古いメモの日を、言われた日として送る
    expect(sent, containsPair('today', '2026-11-03'));
    await _waitToast(tester);
    final saved = (await SharedPreferences.getInstance()).getStringList(memosKey)!;
    expect([for (final m in saved) jsonDecode(m)['text']], ['えーと']);
    expect(find.text('入力欄に入れました'), findsNothing);
  });

  for (final size in const [Size(390, 844), Size(1200, 1400)]) {
    testWidgets('書く欄は、例文・カーソル・書いた文字がそろって左上から始まる（$size）', (tester) async {
      await _pumpInput(tester, _client((_) async => _json({})), size: size);

      final area = find.byType(MoonTextArea);
      final field = find.descendant(of: area, matching: find.byType(EditableText));
      final box = tester.getRect(area);
      final hint = tester.getRect(find.text('例: 田中さんから、塩は小さじ1/2でいいと言われた'));
      expectInputFontsAtLeast16(tester, count: 1); // 書く欄
      // 例文とカーソルは同じ高さ。余白（12）の分だけ下から始まる（前はカーソルだけ 40 下、expands では真ん中だった）
      expect((tester.getRect(field).top - hint.top).abs(), lessThanOrEqualTo(1));
      expect(hint.top - box.top, lessThanOrEqualTo(13));

      await tester.enterText(field, '田中さんから\n塩は小さじ1/2でいいと言われた');
      await tester.pumpAndSettle();
      expect(tester.getRect(field).top - box.top, lessThanOrEqualTo(13));
      // 添付とマイクのボタンは、文字の下の行に置く（文字がボタンの下に潜らない）
      for (final label in ['ファイルを添える', '声で入力する']) {
        expect(tester.getRect(find.bySemanticsLabel(label)).top, greaterThanOrEqualTo(box.bottom), reason: label);
      }
    });
  }

  testWidgets('未整理メモを書き直す欄も、文字が左上から始まる', (tester) async {
    SharedPreferences.setMockInitialValues({
      memosKey: [jsonEncode(Memo(at: DateTime(2026, 11, 3, 14, 5), text: '塩は小さじいち').toJson())],
    });
    await _pumpInput(tester, _client((_) async => _json({})), mic: StreamController());
    await _startRewind(tester);
    await tester.tap(find.text('塩は小さじいち'));
    await tester.pump();

    final area = find.widgetWithText(MoonTextArea, '塩は小さじいち');
    final field = find.descendant(of: area, matching: find.byType(EditableText));
    expect(tester.getRect(field).top - tester.getRect(area).top, lessThanOrEqualTo(17));
    expectInputFontsAtLeast16(tester, count: 1); // 未整理メモを書き直す欄
  });

  testWidgets('リワインドの間は、未整理メモを押すとその場で書き直して保存できる', (tester) async {
    SharedPreferences.setMockInitialValues({
      memosKey: [jsonEncode(Memo(at: DateTime(2026, 11, 3, 14, 5), text: '塩は小さじいち').toJson())],
    });
    await _pumpInput(tester, _client((_) async => _json({})), mic: StreamController());
    await _startRewind(tester);

    await tester.tap(find.text('塩は小さじいち'));
    await tester.pump();
    await tester.enterText(find.widgetWithText(MoonTextArea, '塩は小さじいち'), '塩は小さじ1');
    await tester.tap(find.widgetWithText(MoonOutlinedButton, '保存する'));
    await tester.pump();

    expect(find.text('保存する'), findsNothing);
    expect(find.text('塩は小さじ1'), findsOneWidget);
    final saved = (await SharedPreferences.getInstance()).getStringList(memosKey)!;
    expect(jsonDecode(saved.single), {'at': DateTime(2026, 11, 3, 14, 5).toIso8601String(), 'text': '塩は小さじ1'});
  });

  testWidgets('リワインドの間に、書き直した未整理メモ1件を切り出した日として記録し、メモから消す', (tester) async {
    SharedPreferences.setMockInitialValues({
      memosKey: [
        jsonEncode(Memo(at: DateTime(2026, 11, 3, 14, 5), text: '塩は小さじいち').toJson()),
        jsonEncode(Memo(at: DateTime(2026, 11, 4, 9, 30), text: 'お冷やはすぐ出す').toJson()),
      ],
    });
    Map<String, dynamic>? sent;
    final mic = StreamController<Uint8List>();
    await _pumpInput(
      tester,
      _client((body) async {
        sent = body;
        return _json({
          'text': body['text'],
          'results': [
            {'manualId': 'm1', 'utteranceId': 'u1', 'state': _state('m1')},
          ],
        }, 201);
      }),
      mic: mic,
    );
    await _startRewind(tester);

    await tester.tap(find.text('塩は小さじいち'));
    await tester.pump();
    await tester.enterText(find.widgetWithText(MoonTextArea, '塩は小さじいち'), '田中さんから、塩は小さじ1/2');
    await tester.tap(find.widgetWithText(MoonFilledButton, 'ノートと照らし合わせる'));
    await tester.pumpAndSettle();

    expect(sent, containsPair('text', '田中さんから、塩は小さじ1/2'));
    expect(sent, containsPair('today', '2026-11-03'));
    await _review(tester);
    expect(find.text('ノートに書き込む前の確認'), findsOneWidget);
    // 確認を出している間も待ち受けは止めない
    expect(mic.hasListener, isTrue);
    await tester.tap(find.byIcon(LucideIcons.x).last);
    await tester.pumpAndSettle();
    final saved = (await SharedPreferences.getInstance()).getStringList(memosKey)!;
    expect([for (final m in saved) jsonDecode(m)['text']], ['お冷やはすぐ出す']);
  });

  testWidgets('いらない未整理メモは消せる', (tester) async {
    SharedPreferences.setMockInitialValues({
      memosKey: [jsonEncode(Memo(at: DateTime(2026, 11, 3, 14, 5), text: 'えーと').toJson())],
    });
    await _pumpInput(tester, _client((_) async => _json({})));

    await tester.tap(find.bySemanticsLabel('メモを消す'));
    await tester.pump();

    expect(find.text('えーと'), findsNothing);
    expect((await SharedPreferences.getInstance()).getStringList(memosKey), isEmpty);
  });

  testWidgets('騒音が続く所でも、騒音を声とみなさずに発話だけを切り出す', (tester) async {
    final mic = StreamController<Uint8List>();
    Map<String, dynamic>? sent;
    await _pumpInput(
      tester,
      _client((_) async => _json({}), onListen: (body) async {
        sent = body;
        return _json({'text': '塩は小さじ1/2'});
      }),
      mic: mic,
    );
    await _startRewind(tester);

    // 換気扇の音（RMS 1500）の中で1秒話す
    mic
      ..add(_pcm(3000, level: 1500))
      ..add(_pcm(1000, level: 8000))
      ..add(_pcm(1200, level: 1500));
    await tester.pump();
    await tester.tap(find.widgetWithText(MoonFilledButton, 'いま言われたことをメモする'));
    await tester.pumpAndSettle();

    // 1秒の発話に前後300msの余白を足した長さだけで、騒音の部分は切り出さない
    expect(base64Decode(sent!['data']).length, 44 + 1600 * 16 * 2);
  });

  testWidgets('マイクを使えなければ、許可を求める案内を出し、同じボタンを押したときだけ開き直す', (tester) async {
    var asked = 0;
    await _pumpInput(tester, _client((_) async => _json({})),
        mic: StreamController(), micAllowed: false, onMicAsked: () => asked++);
    await _startRewind(tester);

    expect(asked, 1);
    expect(find.text('マイクを使えません。ブラウザの設定でマイクを許可してから、もう一度押してください'), findsOneWidget);
    expect(find.byType(MoonFilledButton), findsOneWidget);

    await tester.tap(find.textContaining('マイクを使えません'));
    await tester.pumpAndSettle();
    expect(asked, 1);

    await tester.tap(find.widgetWithText(MoonFilledButton, '待ち受けを始める'));
    await tester.pumpAndSettle();
    expect(asked, 2);
  });

  testWidgets('待ち受けのマイクが止まったら知らせ、同じボタンで再開できる', (tester) async {
    var asked = 0;
    final mic = StreamController<Uint8List>.broadcast();
    await _pumpInput(tester, _client((_) async => _json({})), mic: mic, onMicAsked: () => asked++);
    await _startRewind(tester);

    await mic.close();
    await tester.pump();
    expect(find.text('待ち受けが止まっていました。押すと再開します'), findsOneWidget);
    expect(find.byType(MoonFilledButton), findsOneWidget);

    await tester.tap(find.widgetWithText(MoonFilledButton, '待ち受けを始める'));
    await tester.pumpAndSettle();
    expect(asked, 2);
  });

  testWidgets('声が入っていなければ、切り出しても送らずに知らせる', (tester) async {
    final mic = StreamController<Uint8List>();
    var sent = false;
    await _pumpInput(tester, _client((_) async => _json({}), onListen: (_) async => (sent = true, _json({})).$2), mic: mic);
    await _startRewind(tester);

    mic.add(_pcm(3000, voice: false));
    await tester.pump();
    await tester.tap(find.widgetWithText(MoonFilledButton, 'いま言われたことをメモする'));
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

  testWidgets('広い画面では、左のサイドバーからマニュアルへ直接移れ、あとで確認の件数も並ぶ', (tester) async {
    await _pumpInput(tester, _client((_) async => _json({})));

    // サイドバーと役割が重なるので、上部バーの「ノートを見る」は出さない
    expect(find.widgetWithText(MoonOutlinedButton, 'ノートを見る'), findsNothing);

    // ホールは「あとで確認」が無いので、入力ページの一覧には出ず、サイドバーにだけ並ぶ
    final hall = find.widgetWithText(MoonMenuItem, 'ホール');
    expect(hall, findsOneWidget);
    // ノートがあっても、サイドバーの「ノート」の右の＋から新しいノートを作れる
    expect(find.bySemanticsLabel('ノートを作る'), findsOneWidget);
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
    await _waitToast(tester);
  });

  testWidgets('狭い画面ではサイドバーを出さず、上部バーの三本線から出るメニューの「ノート」から一覧へ進む', (tester) async {
    await _pumpInput(tester, _client((_) async => _json({})), size: const Size(400, 900));

    expect(find.widgetWithText(MoonMenuItem, 'ホール'), findsNothing);
    // 上部バーの「ノートを見る」はやめた（メニューから行ける）
    expect(find.widgetWithText(MoonOutlinedButton, 'ノートを見る'), findsNothing);
    await tester.tap(find.byWidgetPredicate((w) => w is MoonButton && w.semanticLabel == 'メニュー'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(MoonMenuItem, 'ホール'), findsOneWidget);
    await tester.tap(find.widgetWithText(MoonMenuItem, 'ノート'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(PageTitle), matching: find.text('ノート')), findsOneWidget);
  });

  testWidgets('画像はサムネイル、PDF は名前で添え、受け付けない形式は除いて知らせる', (tester) async {
    // 1×1 の PNG
    final png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=');
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
      picked: [
        (name: 'メモ.PNG', type: '', bytes: png),
        (name: '手順.pdf', type: 'application/pdf', bytes: Uint8List(8)),
        (name: 'メモ.txt', type: 'text/plain', bytes: Uint8List(8)),
      ],
    );
    await tester.tap(find.bySemanticsLabel('ファイルを添える'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ファイルを選ぶ'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.bySemanticsLabel('メモ.PNG'), findsOneWidget);
    expect(find.widgetWithText(MoonTag, '手順.pdf'), findsOneWidget);
    expect(find.text('メモ.txt'), findsNothing);
    expect(find.text('ファイルを選ぶ'), findsNothing);
    expect(find.text('添えられるのは PDF と画像（PNG・JPEG・WebP・HEIC）です'), findsOneWidget);
    await _waitToast(tester);

    await tester.tap(find.widgetWithText(MoonFilledButton, 'ノートと照らし合わせる'));
    await tester.pumpAndSettle();
    expect([for (final f in sent!['files']) f['mimeType']], ['image/png', 'application/pdf']);
    await _waitToast(tester);
  });

  testWidgets('発言者が分かっていれば、確認を開かずに追加は書き込み、同じ内容は記録だけ残して知らせる', (tester) async {
    final posted = <String>[];
    await _pumpInput(
      tester,
      _client(
        (body) async => _json({
          'text': body['text'],
          'results': [
            {'manualId': 'm2', 'utteranceId': 'u2', 'state': _hallWithPatches()},
          ],
        }, 201),
        onOther: (req) {
          if (req.method == 'POST') posted.add(req.url.path);
        },
      ),
    );
    await _record(tester, '田中さんから、お冷やはすぐ出すと言われた');

    expect(posted, ['/manuals/m2/patches/p1/apply', '/manuals/m2/patches/p2/discard']);
    expect(find.text('ノートに書き込む前の確認'), findsNothing);
    expect(find.text('ノートに1行書き込みました'), findsOneWidget);
    await _waitToast(tester);
  });

  testWidgets('スマホの幅でも、書き込む前の確認のボタンがはみ出さない', (tester) async {
    // 発言者が分からないと、照らし合わせた後にそのまま確認が開く
    final state = _hallWithPatches(speaker: null);
    await _pumpInput(
      tester,
      _client((body) async => _json({
            'text': body['text'],
            'results': [
              {'manualId': 'm2', 'utteranceId': 'u2', 'state': state},
            ],
          }, 201)),
      size: const Size(390, 844),
    );
    await _record(tester, '田中さんから、お冷やはすぐ出すと言われた');

    // はみ出すと描画のエラーになり、ここで落ちる
    expect(tester.takeException(), isNull);
    expect(find.widgetWithText(MoonFilledButton, 'ノートに書き込む'), findsOneWidget);
    expect(find.widgetWithText(MoonTextButton, '書き込む内容を直す'), findsOneWidget);
    expect(find.widgetWithText(MoonTextButton, 'それでも書き込む'), findsOneWidget);
  });
}

String _typed(WidgetTester tester) => tester.widget<MoonTextArea>(find.byType(MoonTextArea)).controller!.text;
