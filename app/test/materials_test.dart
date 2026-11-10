import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:diff_note/api.dart';
import 'package:diff_note/manual_controller.dart';
import 'package:diff_note/models.dart';
import 'package:diff_note/screens/common.dart';
import 'package:diff_note/screens/manual_screen.dart';
import 'package:diff_note/screens/material_screen.dart';
import 'package:diff_note/screens/materials_screen.dart';
import 'package:diff_note/screens/tab_bar.dart';
import 'package:diff_note/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moon_design/moon_design.dart';

import 'home.dart';

// 資料の一覧・足す・中を見る・消す（ADR 0019 と、その設計書の §6・§10）。
// API は設計書 §6 の形に合わせた偽（MockClient）

http.Response _json(Object? body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

const _narrow = Size(390, 844);
const _wide = Size(1440, 900);

/// 店舗マニュアル（PDF 2ページ、かなでが足した）と、衛生の手引き（貼り付けた文、足した人が無い前からある資料）。
/// 日付はどの時差でも同じ日になる時刻にする
List<Map<String, dynamic>> _defaultMaterials() => [
      {
        'id': 'mat1',
        'title': '店舗マニュアル',
        'pageCount': 2,
        'tokens': 120,
        'createdAt': '2026-11-10T10:00:00.000Z',
        'addedBy': {'id': 'kanade', 'name': 'かなで'},
        'lines': [
          {'page': 1, 'text': '## 開店前'},
          {'page': 1, 'text': '- 冷蔵庫の温度を記録する'},
          {'page': 2, 'text': '- 味噌汁の塩は小さじ1'},
        ],
      },
      {
        'id': 'mat2',
        'title': '衛生の手引き',
        'pageCount': null,
        'tokens': 40,
        'createdAt': '2026-11-09T10:00:00.000Z',
        'lines': [
          {'page': null, 'text': '- 手を洗う'},
        ],
      },
    ];

Map<String, dynamic> _summary(Map<String, dynamic> m) => {
      for (final k in const ['id', 'title', 'pageCount', 'tokens', 'createdAt']) k: m[k],
      if (m['addedBy'] != null) 'addedBy': m['addedBy'],
      'lineCount': (m['lines'] as List).length,
    };

/// キッチン（m1）のノートと、その資料。shared ならキッチンは佐藤店長から共有されたもの
class _Server {
  _Server({this.shared = false, List<Map<String, dynamic>>? materials}) : materials = materials ?? _defaultMaterials();
  final bool shared;
  final List<Map<String, dynamic>> materials;

  /// 送られた POST の本文と、DELETE のパス
  final posts = <Map<String, dynamic>>[];
  final deletes = <String>[];

  /// 差し替えると、一覧・足す・消すの返し方を変えられる（待たせる・失敗させる）
  Future<http.Response> Function()? onList;
  Future<http.Response> Function()? onGetMaterial;
  Future<http.Response> Function(Map<String, dynamic> body)? onPost;
  Future<http.Response> Function()? onDelete;

  Map<String, dynamic> get state => {
        'manual': {'id': 'm1', 'title': 'キッチン', 'base': '- 塩 小さじ1', 'createdAt': '2026-11-01T00:00:00Z'},
        'lines': [
          {'text': '- 塩 小さじ1', 'patchId': null},
        ],
        'utterances': [],
        'patches': [],
        'checks': [],
        'owner': shared ? 'sato' : 'kanade',
        'me': 'kanade',
        'sharedBy': shared ? {'id': 'sato', 'name': '佐藤店長'} : null,
      };

  /// 偽の API が足したときに返す一覧の1件。ファイルなら AI が読み取ったことにして3ページ、題名が空なら AI の題名
  Map<String, dynamic> _added(Map<String, dynamic> body) {
    final files = body['files'] as List;
    final title = body['title'] as String;
    return {
      'id': 'new${materials.length}',
      'title': title.isNotEmpty ? title : '読み取った資料',
      'pageCount': files.isEmpty ? null : 3,
      'tokens': 10,
      'createdAt': '2026-11-10T11:00:00.000Z',
      'addedBy': {'id': 'kanade', 'name': 'かなで'},
      'lines': [
        for (final l in (body['text'] as String).split('\n')) {'page': null, 'text': l},
      ],
    };
  }

  late final client = MockClient((req) async {
    final path = req.url.path;
    if (path == '/home') return _json(homeJson([state], me: {'id': 'kanade', 'name': 'かなで', 'icon': null}));
    if (path == '/manuals/m1/materials') {
      if (req.method == 'POST') {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        posts.add(body);
        if (onPost case final f?) return f(body);
        final m = _added(body);
        materials.add(m);
        return _json(_summary(m), 201);
      }
      if (onList case final f?) return f();
      return _json([for (final m in materials) _summary(m)]);
    }
    if (path.startsWith('/manuals/m1/materials/')) {
      final id = path.split('/').last;
      if (req.method == 'DELETE') {
        deletes.add(path);
        if (onDelete case final f?) return f();
        materials.removeWhere((m) => m['id'] == id);
        return http.Response('', 204);
      }
      if (onGetMaterial case final f?) return f();
      final m = materials.where((m) => m['id'] == id).firstOrNull;
      return m == null ? _json({'error': '資料が見つかりません'}, 404) : _json({..._summary(m), 'lines': m['lines']});
    }
    if (path == '/manuals/m1') return _json(state);
    return _json([]);
  });

  late final api = Api(client: client, baseUrl: 'http://api');

  ManualController get controller => ManualController(api, 'm1', ManualState.fromJson(state));
}

/// 最初の画面（入力ページの代わり）。ここから開くので、開いた画面には戻る矢印が出る
class _First extends StatelessWidget {
  const _First(this.open);
  final Widget Function() open;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: MoonFilledButton(
            label: const Text('開く'),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => open())),
          ),
        ),
      );
}

/// 既定では資料の一覧を開く。from で開く画面を変えられる
Future<_Server> _pump(
  WidgetTester tester, {
  bool shared = false,
  Size size = _wide,
  List<Map<String, dynamic>>? materials,
  Future<List<PickedFile>> Function()? pick,
  Widget Function(_Server)? from,
}) async {
  final server = _Server(shared: shared, materials: materials);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: appTheme(),
    home: _First(() =>
        from?.call(server) ?? MaterialsScreen(c: server.controller, pickFiles: pick ?? () async => <PickedFile>[])),
  ));
  await tester.tap(find.widgetWithText(MoonFilledButton, '開く'));
  await tester.pumpAndSettle();
  return server;
}

final _k = appTheme().extension<AppTokens>()!;

Finder _inTopBar(Finder f) => find.descendant(of: find.byType(TopBar), matching: f);
Finder _inModal(Finder f) => find.descendant(of: find.byType(MoonModal), matching: f);
Finder _more() => find.byWidgetPredicate((w) => w is MoonButton && w.semanticLabel == 'その他');
Finder _addButton() => find.widgetWithText(MoonFilledButton, '資料を足す');
Finder _pasteButton() => find.widgetWithText(MoonFilledButton, 'この文を資料にする');
Finder _fileButton() => find.widgetWithText(MoonOutlinedButton, 'ファイルから読み取る');

/// 資料を足すモーダルの題名の欄と本文の欄
Finder _titleField() => _inModal(find.byType(EditableText)).first;
Finder _bodyField() => _inModal(find.byType(EditableText)).last;

/// 知らせ（MoonToast）が消えるのを待つ。MoonToast はタイマーをアプリ全体で1つ持つので、残すと次のテストの知らせが出ない
Future<void> _waitToast(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

Future<void> _openAdd(WidgetTester tester) async {
  await tester.tap(_addButton());
  await tester.pumpAndSettle();
  expect(_inModal(find.text('資料を足す')), findsOneWidget);
}

Future<void> _fillPaste(WidgetTester tester, {String title = '仕込みの手順', String text = '- 米を研ぐ\n- 30分つける'}) async {
  await tester.enterText(_titleField(), title);
  await tester.enterText(_bodyField(), text);
  await tester.pump();
}

PickedFile _pdf([int size = 3]) => (name: 'manual.pdf', type: '', bytes: Uint8List(size));

void main() {
  for (final size in const [_narrow, _wide]) {
    for (final shared in const [false, true]) {
      testWidgets('ノートのページの上部バーに「資料」が出て、押すと資料の一覧を積む（$size・${shared ? '共有された' : '自分の'}ノート）',
          (tester) async {
        await _pump(tester, size: size, shared: shared, from: (s) => ManualScreen(api: s.api, manualId: 'm1'));
        final button = _inTopBar(find.widgetWithText(MoonOutlinedButton, '資料'));
        expect(button, findsOneWidget);
        // 広い画面では「履歴」の左、狭い画面では「共有」の左
        final next = _inTopBar(find.widgetWithText(MoonOutlinedButton, size == _wide ? '履歴' : '共有'));
        expect(tester.getRect(button).right, lessThan(tester.getRect(next).left));

        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(find.byType(MaterialsScreen), findsOneWidget);
        // 資料は下のタブバーに無いので、出さずに戻る矢印で戻る
        expect(find.byType(NoteTabBar), findsNothing);
        expect(find.text('店舗マニュアル'), findsOneWidget);

        await tester.tap(find.bySemanticsLabel('戻る'));
        await tester.pumpAndSettle();
        expect(find.byType(ManualScreen), findsOneWidget);
      });
    }

    testWidgets('一覧：題名・ページ数（貼り付けた文ならそう出す）・誰がいつ足したか（前からある資料は日だけ）。題名の右に「資料を足す」（$size）', (tester) async {
      await _pump(tester, size: size);
      expect(find.text('2 冊'), findsOneWidget);
      expect(find.text('店舗マニュアル'), findsOneWidget);
      expect(find.text('2ページ'), findsOneWidget);
      expect(find.text('かなで が 11/10 に足した'), findsOneWidget);
      expect(find.text('衛生の手引き'), findsOneWidget);
      expect(find.text('貼り付けた文'), findsOneWidget);
      expect(find.text('11/9 に足した'), findsOneWidget);
      expect(_addButton(), findsOneWidget);
      // 題名と同じ行
      expect(tester.getRect(_addButton()).top, lessThan(tester.getRect(find.text('店舗マニュアル')).top));
      expect(tester.getRect(_addButton()).left,
          greaterThan(tester.getRect(find.descendant(of: find.byType(PageTitle), matching: find.text('資料'))).right));
    });

    testWidgets('共有された人にも「資料を足す」と、資料の中の「…」→「資料を消す」が出て、消せる（$size）', (tester) async {
      final server = await _pump(tester, size: size, shared: true);
      expect(find.text('店舗マニュアル'), findsOneWidget);
      expect(_addButton(), findsOneWidget);
      await _openAdd(tester);
      await tester.tap(find.widgetWithText(MoonTextButton, 'やめる'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('店舗マニュアル'));
      await tester.pumpAndSettle();
      expect(find.byType(MaterialScreen), findsOneWidget);
      expect(find.text('・冷蔵庫の温度を記録する'), findsOneWidget);
      await tester.tap(_more());
      await tester.pumpAndSettle();
      await tester.tap(find.text('資料を消す'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MoonFilledButton, '消す'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('資料を消しました'), findsOneWidget);
      await _waitToast(tester);
      expect(server.deletes, ['/manuals/m1/materials/mat1']);
      expect(find.byType(MaterialsScreen), findsOneWidget);
      expect(find.text('店舗マニュアル'), findsNothing);
    });

    testWidgets('資料の中：ページの変わり目に罫線と「p.2」。行はノートと同じ見た目（$size）', (tester) async {
      await _pump(tester, size: size);
      await tester.tap(find.text('店舗マニュアル'));
      await tester.pumpAndSettle();
      expect(find.byType(MaterialScreen), findsOneWidget);
      // 題名と、ページ数・足した日
      expect(find.descendant(of: find.byType(PageTitle), matching: find.text('店舗マニュアル')), findsOneWidget);
      expect(find.text('2ページ'), findsOneWidget);
      expect(find.text('かなで が 11/10 に足した'), findsOneWidget);
      expect(find.text('開店前'), findsOneWidget);
      expect(find.text('p.1'), findsOneWidget);
      expect(find.text('p.2'), findsOneWidget);
      final rule = find.descendant(of: find.byType(MaterialScreen), matching: find.byType(Rule));
      expect(rule, findsOneWidget);
      // p.1 の行 → 罫線 → p.2 → p.2 の行
      final fridge = tester.getRect(find.text('・冷蔵庫の温度を記録する'));
      expect(tester.getRect(rule).top, greaterThan(fridge.bottom));
      expect(tester.getRect(find.text('p.2')).top, greaterThan(tester.getRect(rule).bottom));
      expect(tester.getRect(find.text('・味噌汁の塩は小さじ1')).top, greaterThan(tester.getRect(find.text('p.2')).bottom));
      // 押しても編集の欄は開かない（資料は書き換えない）
      await tester.tap(find.text('・冷蔵庫の温度を記録する'));
      await tester.pumpAndSettle();
      expect(find.byType(EditableText), findsNothing);
      if (size == _wide) {
        // パンくずは ノート / 資料 / 資料の題名
        expect(_inTopBar(find.text('キッチン')), findsOneWidget);
        expect(_inTopBar(find.text('資料')), findsOneWidget);
        expect(_inTopBar(find.text('店舗マニュアル')), findsOneWidget);
      }
    });

    testWidgets('「…」→「資料を消す」→「消す」で DELETE を送り、一覧へ戻って「資料を消しました」。一覧から消える（$size）', (tester) async {
      final server = await _pump(tester, size: size);
      await tester.tap(find.text('店舗マニュアル'));
      await tester.pumpAndSettle();
      await tester.tap(_more());
      await tester.pumpAndSettle();
      await tester.tap(find.text('資料を消す'));
      await tester.pumpAndSettle();
      expect(find.text('この資料を消しますか？'), findsOneWidget);
      expect(
        find.text('「店舗マニュアル」を消します。これからの照らし合わせには使いません。この資料と食い違った確認は、確認リストに残ります。元に戻せません。'),
        findsOneWidget,
      );
      final delete = find.widgetWithText(MoonFilledButton, '消す');
      expect(tester.widget<MoonFilledButton>(delete).backgroundColor, _k.colors.removed);

      await tester.tap(delete);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('資料を消しました'), findsOneWidget);
      await _waitToast(tester);

      expect(server.deletes, ['/manuals/m1/materials/mat1']);
      expect(find.byType(MaterialScreen), findsNothing);
      expect(find.byType(MaterialsScreen), findsOneWidget);
      expect(find.text('店舗マニュアル'), findsNothing);
      expect(find.text('衛生の手引き'), findsOneWidget);
      expect(find.text('1 冊'), findsOneWidget);
    });

    testWidgets('貼り付けた文で足す：題名と本文を送り、閉じて知らせ、一覧を読み直す（$size）', (tester) async {
      final server = await _pump(tester, size: size);
      await _openAdd(tester);
      // 題名と本文がそろうまで押せない
      expect(tester.widget<MoonFilledButton>(_pasteButton()).onTap, isNull);
      await tester.enterText(_titleField(), '仕込みの手順');
      await tester.pump();
      expect(tester.widget<MoonFilledButton>(_pasteButton()).onTap, isNull);
      await tester.enterText(_bodyField(), '- 米を研ぐ\n- 30分つける');
      await tester.pump();
      expect(tester.widget<MoonFilledButton>(_pasteButton()).onTap, isNotNull);

      await tester.tap(_pasteButton());
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(server.posts, [
        {'title': '仕込みの手順', 'text': '- 米を研ぐ\n- 30分つける', 'files': []},
      ]);
      expect(find.byType(MoonModal), findsNothing);
      // 貼り付けた文にはページを付けない
      expect(find.text('資料「仕込みの手順」を足しました'), findsOneWidget);
      await _waitToast(tester);
      expect(find.text('仕込みの手順'), findsOneWidget);
      expect(find.text('3 冊'), findsOneWidget);
    });

    testWidgets('ファイルから読み取る：選んだらすぐ送り、読み取り中はほかのボタンも押せない。足したらページ数を添えて知らせる（$size）', (tester) async {
      var picks = 0;
      final server = await _pump(tester, size: size, pick: () async {
        picks++;
        return [_pdf()];
      });
      final reply = Completer<http.Response>();
      server.onPost = (body) => reply.future;
      await _openAdd(tester);
      await tester.enterText(_titleField(), '店舗マニュアル（秋）');
      await tester.pump();

      await tester.tap(_fileButton());
      await tester.pump();
      expect(picks, 1);
      expect(server.posts, [
        {
          'title': '店舗マニュアル（秋）',
          'text': '',
          'files': [
            {'mimeType': 'application/pdf', 'data': base64Encode(Uint8List(3))},
          ],
        },
      ]);
      final reading = find.widgetWithText(MoonOutlinedButton, '読み取っています…');
      expect(reading, findsOneWidget);
      expect(tester.widget<MoonOutlinedButton>(reading).onTap, isNull);
      expect(tester.widget<MoonTextButton>(find.widgetWithText(MoonTextButton, 'やめる')).onTap, isNull);
      expect(tester.widget<MoonFilledButton>(_pasteButton()).onTap, isNull);
      // 読み取っている間は、外を押しても閉じない
      await tester.tapAt(const Offset(5, 5));
      await tester.pump(const Duration(milliseconds: 500));
      expect(_inModal(find.text('資料を足す')), findsOneWidget);

      reply.complete(_json({
        'id': 'new',
        'title': '店舗マニュアル（秋）',
        'pageCount': 3,
        'lineCount': 20,
        'tokens': 900,
        'createdAt': '2026-11-10T11:00:00.000Z',
      }, 201));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(MoonModal), findsNothing);
      expect(find.text('資料「店舗マニュアル（秋）」を足しました（3ページ）'), findsOneWidget);
      await _waitToast(tester);
    });

    testWidgets('上限を超えたときは、サーバーの文言をそのまま知らせ、モーダルは閉じない（$size）', (tester) async {
      final server = await _pump(tester, size: size);
      const limit = '資料は全部のノートで合わせて100000トークンまでです（いま約95000トークン）。使わない資料を消してから足してください';
      server.onPost = (_) async => _json({'error': limit}, 400);
      await _openAdd(tester);
      await _fillPaste(tester);
      await tester.tap(_pasteButton());
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(limit), findsOneWidget);
      // 入れたものは残り、もう一度押せる
      expect(_inModal(find.text('資料を足す')), findsOneWidget);
      expect(find.text('仕込みの手順'), findsOneWidget);
      expect(tester.widget<MoonFilledButton>(_pasteButton()).onTap, isNotNull);
      await _waitToast(tester);
      expect(find.text('仕込みの手順'), findsOneWidget);
    });
  }

  for (final shared in const [false, true]) {
    testWidgets('資料が無いとき、何ができるかと「資料を足す」を出す（${shared ? '共有された' : '自分の'}ノート）', (tester) async {
      await _pump(tester, materials: [], shared: shared);
      expect(find.text('まだ資料はありません'), findsOneWidget);
      expect(find.text('店のマニュアルや授業の資料を足すと、言われたことと食い違っていないかも確かめます'), findsOneWidget);
      expect(_addButton(), findsOneWidget);
      expect(find.textContaining('冊'), findsNothing);
      await _openAdd(tester);
    });
  }

  testWidgets('一覧の読み込み中と、読み込めなかったとき（もう一度読み込める）', (tester) async {
    final server = _Server();
    final first = Completer<http.Response>();
    server.onList = () => first.future;
    tester.view.physicalSize = _wide;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: appTheme(), home: MaterialsScreen(c: server.controller)));
    await tester.pump();
    expect(find.byType(Loading), findsOneWidget);

    first.complete(_json({'error': 'サーバーでエラーが起きました'}, 500));
    await tester.pumpAndSettle();
    expect(find.text('読み込めませんでした：サーバーでエラーが起きました'), findsOneWidget);

    server.onList = null;
    await tester.tap(find.text('もう一度読み込む'));
    await tester.pumpAndSettle();
    expect(find.text('店舗マニュアル'), findsOneWidget);
  });

  testWidgets('貼り付けて足している間は「足しています…」で、外を押しても閉じない', (tester) async {
    final server = await _pump(tester);
    final reply = Completer<http.Response>();
    server.onPost = (_) => reply.future;
    await _openAdd(tester);
    await _fillPaste(tester);
    await tester.tap(_pasteButton());
    await tester.pump();
    final adding = find.widgetWithText(MoonFilledButton, '足しています…');
    expect(adding, findsOneWidget);
    expect(tester.widget<MoonFilledButton>(adding).onTap, isNull);
    expect(tester.widget<MoonOutlinedButton>(_fileButton()).onTap, isNull);
    await tester.tapAt(const Offset(5, 5));
    await tester.pump(const Duration(milliseconds: 500));
    expect(_inModal(find.text('資料を足す')), findsOneWidget);

    reply.complete(_json({'error': 'エラーが起きました'}, 500));
    await tester.pump();
    await _waitToast(tester);
  });

  testWidgets('足していないときは「やめる」でも外を押しても閉じ、何も送らない', (tester) async {
    final server = await _pump(tester);
    await _openAdd(tester);
    await tester.tap(find.widgetWithText(MoonTextButton, 'やめる'));
    await tester.pumpAndSettle();
    expect(find.byType(MoonModal), findsNothing);

    await _openAdd(tester);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.byType(MoonModal), findsNothing);
    expect(server.posts, isEmpty);
  });

  testWidgets('ファイルの読み取りで1冊の上限を超えたら、その文言を知らせてモーダルは開いたまま', (tester) async {
    final server = await _pump(tester, pick: () async => [_pdf()]);
    const limit = '資料が大きすぎます（約42000トークン。1冊30000トークンまで）。ページを分けて足してください';
    server.onPost = (_) async => _json({'error': limit}, 400);
    await _openAdd(tester);
    await tester.tap(_fileButton());
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text(limit), findsOneWidget);
    expect(_inModal(find.text('資料を足す')), findsOneWidget);
    expect(tester.widget<MoonOutlinedButton>(_fileButton()).onTap, isNotNull);
    await _waitToast(tester);
  });

  testWidgets('合わせて10MBを超えるファイルは、送らずに知らせる', (tester) async {
    final server = await _pump(tester, pick: () async => [_pdf(10 * 1024 * 1024 + 1)]);
    await _openAdd(tester);
    await tester.tap(_fileButton());
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('ファイルは合わせて10MBまでです。減らしてから選んでください'), findsOneWidget);
    expect(server.posts, isEmpty);
    expect(_inModal(find.text('資料を足す')), findsOneWidget);
    await _waitToast(tester);
  });

  testWidgets('ファイルを選ばずに閉じたら、何も送らない', (tester) async {
    final server = await _pump(tester);
    await _openAdd(tester);
    await tester.tap(_fileButton());
    await tester.pumpAndSettle();
    expect(server.posts, isEmpty);
    expect(tester.widget<MoonOutlinedButton>(_fileButton()).onTap, isNotNull);
  });

  testWidgets('貼り付けた文の資料には、ページの印を出さない', (tester) async {
    await _pump(tester);
    await tester.tap(find.text('衛生の手引き'));
    await tester.pumpAndSettle();
    expect(find.text('・手を洗う'), findsOneWidget);
    expect(find.text('貼り付けた文'), findsOneWidget);
    // 足した人が無い前からある資料は、日だけ
    expect(find.text('11/9 に足した'), findsOneWidget);
    expect(find.textContaining('p.'), findsNothing);
    expect(find.descendant(of: find.byType(MaterialScreen), matching: find.byType(Rule)), findsNothing);
  });

  testWidgets('資料を消す確かめで「やめる」なら何も送らず、資料の中のまま', (tester) async {
    final server = await _pump(tester);
    await tester.tap(find.text('店舗マニュアル'));
    await tester.pumpAndSettle();
    await tester.tap(_more());
    await tester.pumpAndSettle();
    await tester.tap(find.text('資料を消す'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MoonOutlinedButton, 'やめる'));
    await tester.pumpAndSettle();
    expect(server.deletes, isEmpty);
    expect(find.text('この資料を消しますか？'), findsNothing);
    expect(find.byType(MaterialScreen), findsOneWidget);
  });

  testWidgets('消している間は「消しています…」で両方押せない。失敗したら知らせて、資料の中のまま', (tester) async {
    final server = await _pump(tester);
    final reply = Completer<http.Response>();
    server.onDelete = () => reply.future;
    await tester.tap(find.text('店舗マニュアル'));
    await tester.pumpAndSettle();
    await tester.tap(_more());
    await tester.pumpAndSettle();
    await tester.tap(find.text('資料を消す'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MoonFilledButton, '消す'));
    await tester.pump();
    expect(tester.widget<MoonFilledButton>(find.widgetWithText(MoonFilledButton, '消しています…')).onTap, isNull);
    expect(tester.widget<MoonOutlinedButton>(find.widgetWithText(MoonOutlinedButton, 'やめる')).onTap, isNull);

    reply.complete(http.Response('<html>500</html>', 500));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('エラーが起きました（500）'), findsOneWidget);
    await _waitToast(tester);
    expect(find.text('この資料を消しますか？'), findsNothing);
    expect(find.byType(MaterialScreen), findsOneWidget);
    expect(find.text('・冷蔵庫の温度を記録する'), findsOneWidget);
  });

  testWidgets('消された資料を開くと「この資料は消されています」。読み直しは出さない', (tester) async {
    await _pump(tester, from: (s) => MaterialScreen(c: s.controller, materialId: 'gone'));
    expect(find.text('この資料は消されています'), findsOneWidget);
    expect(find.text('もう一度読み込む'), findsNothing);
    expect(_more(), findsNothing);
  });

  testWidgets('資料の中を読み込めなかったときは、もう一度読み込める', (tester) async {
    final server = await _pump(tester, from: (s) {
      s.onGetMaterial = () async => _json({'error': 'サーバーでエラーが起きました'}, 500);
      return MaterialScreen(c: s.controller, materialId: 'mat1');
    });
    expect(find.text('読み込めませんでした：サーバーでエラーが起きました'), findsOneWidget);
    server.onGetMaterial = null;
    await tester.tap(find.text('もう一度読み込む'));
    await tester.pumpAndSettle();
    expect(find.text('・冷蔵庫の温度を記録する'), findsOneWidget);
    expect(_more(), findsOneWidget);
  });

  for (final size in const [_narrow, _wide]) {
    testWidgets('行の番号を渡して開くと、その行まで送り、薄い青の地を付ける（$size）', (tester) async {
      final long = {
        'id': 'long',
        'title': '長い規約',
        'pageCount': 4,
        'tokens': 3000,
        'createdAt': '2026-11-10T10:00:00.000Z',
        'lines': [
          for (var i = 1; i <= 120; i++) {'page': (i - 1) ~/ 30 + 1, 'text': '- 決まり$i'},
        ],
      };
      await _pump(tester, size: size, materials: [long], from: (s) => MaterialScreen(c: s.controller, materialId: 'long', lineNo: 80));
      final target = find.text('・決まり80');
      final screen = tester.getRect(find.byType(MaterialScreen));
      expect(screen.contains(tester.getRect(target).center), isTrue);
      final box = find.ancestor(of: target, matching: find.byType(ColoredBox));
      expect(tester.widgetList<ColoredBox>(box).any((b) => b.color == _k.colors.found), isTrue);
      // ほかの行には付けない
      final other = find.ancestor(of: find.text('・決まり79'), matching: find.byType(ColoredBox));
      expect(tester.widgetList<ColoredBox>(other).any((b) => b.color == _k.colors.found), isFalse);
    });
  }

  testWidgets('行の番号を渡さなければ、頭から見せる', (tester) async {
    final long = {
      'id': 'long',
      'title': '長い規約',
      'pageCount': 1,
      'tokens': 3000,
      'createdAt': '2026-11-10T10:00:00.000Z',
      'lines': [
        for (var i = 1; i <= 120; i++) {'page': 1, 'text': '- 決まり$i'},
      ],
    };
    await _pump(tester, size: _narrow, materials: [long], from: (s) => MaterialScreen(c: s.controller, materialId: 'long'));
    expect(find.descendant(of: find.byType(PageTitle), matching: find.text('長い規約')).hitTestable(), findsOneWidget);
    expect(find.text('・決まり80').hitTestable(), findsNothing);
  });
}
