import 'dart:convert';

import 'package:diff_note/api.dart';
import 'package:diff_note/manual_controller.dart';
import 'package:diff_note/models.dart';
import 'package:diff_note/screens/check_list_screen.dart';
import 'package:diff_note/screens/common.dart';
import 'package:diff_note/screens/history_screen.dart';
import 'package:diff_note/screens/input_screen.dart';
import 'package:diff_note/screens/manual_screen.dart';
import 'package:diff_note/screens/materials_screen.dart';
import 'package:diff_note/screens/tab_bar.dart';
import 'package:diff_note/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moon_design/moon_design.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'home.dart';

/// 塩の量が食い違い、あとで確認が1件ある
Map<String, dynamic> _note() => {
      'owner': 'demo',      'me': 'demo',      'manual': {'id': 'm1', 'title': 'キッチン', 'base': '- 塩 小さじ1', 'createdAt': '2026-11-01T00:00:00Z'},
      'lines': [
        {'text': '- 塩 小さじ1', 'patchId': null},
      ],
      'utterances': [
        {'id': 'u1', 'text': '塩は小さじ1/2', 'speaker': '田中さん', 'saidAt': '2026-11-03', 'fromEdit': false, 'createdAt': '2026-11-03T10:00:00Z'},
      ],
      'patches': [
        {
          'id': 'p1',
          'utteranceId': 'u1',
          'op': 'replace',
          'line': '- 塩 小さじ1',
          'text': '- 塩 小さじ1/2',
          'summary': '',
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
          'sameLine': null,
          'reason': '量が違う',
          'ask': {'candidates': [], 'question': 'どちらですか？'},
          'resolution': null,
        },
      ],
    };

/// 塩の量の食い違いを店長に確認して 1/2 に決めた（行に「店長 11/7 に確認」が付く）
Map<String, dynamic> _confirmed() {
  final n = _note();
  n['lines'] = [
    {'text': '- 塩 小さじ1/2', 'patchId': 'p2'},
  ];
  (n['utterances'] as List).add(
      {'id': 'u2', 'text': '1/2で統一', 'speaker': '店長', 'saidAt': '2026-11-07', 'fromEdit': false, 'createdAt': '2026-11-07T10:00:00Z'});
  final p1 = (n['patches'] as List).first as Map<String, dynamic>;
  p1['status'] = 'discarded';
  (n['patches'] as List).add({
    'id': 'p2',
    'utteranceId': 'u2',
    'op': 'replace',
    'line': '- 塩 小さじ1',
    'text': '- 塩 小さじ1/2',
    'summary': '',
    'status': 'applied',
    'createdAt': '2026-11-07T10:00:00Z',
    'appliedAt': '2026-11-07T10:00:00Z',
  });
  ((n['checks'] as List).first as Map<String, dynamic>)['resolution'] = {
    'utteranceId': 'u2',
    'patchId': null,
    'decidedBy': '店長',
    'decidedAt': '2026-11-07',
    'text': '- 塩 小さじ1/2',
    'note': '1/2で統一',
  };
  return n;
}

Api _api([Map<String, dynamic> Function() data = _note]) => Api(
    client: MockClient((req) async => http.Response.bytes(
        utf8.encode(jsonEncode(req.url.path == '/home' ? homeJson([data()]) : data())), 200)),
    baseUrl: 'http://api');

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Finder _tab(String label) => find.ancestor(
    of: find.descendant(of: find.byType(NoteTabBar), matching: find.text(label)), matching: find.byType(MoonButton));

/// 確認リストの上に確認のページが開いていたら、戻って確認リストに出る（タブバーは確認リストにある）
Future<void> _backToList(WidgetTester tester) async {
  if (find.byType(CheckListScreen).evaluate().isEmpty) {
    await tester.tap(find.bySemanticsLabel('戻る'));
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets('狭い画面：下のタブバーでノート・確認リスト・履歴を、横から出てくる動きなしで行き来する', (tester) async {
    _size(tester, const Size(390, 844));
    await tester.pumpWidget(MaterialApp(theme: appTheme(), home: ManualScreen(api: _api(), manualId: 'm1')));
    await tester.pumpAndSettle();

    expect(find.byType(NoteTabBar), findsOneWidget);
    // 確認リストのタブに、あとで確認の件数を出す
    expect(find.descendant(of: find.byType(NoteTabBar), matching: find.text('1')), findsOneWidget);

    await tester.tap(_tab('確認リスト'));
    await tester.pump(); // 動きが無いので、1枚目の描画で切り替わっている
    expect(find.byType(CheckListScreen), findsOneWidget);
    expect(find.byType(ManualScreen, skipOffstage: true), findsNothing);

    await tester.tap(_tab('履歴'));
    await tester.pump();
    expect(find.byType(HistoryScreen), findsOneWidget);
    // 確認リストは履歴に入れ替わり、積み重ならない
    expect(find.byType(CheckListScreen, skipOffstage: false), findsNothing);

    await tester.tap(_tab('ノート'));
    await tester.pump();
    expect(find.byType(ManualScreen), findsOneWidget);
    expect(find.byType(HistoryScreen, skipOffstage: false), findsNothing);
  });

  // #120：幅 390 の iframe で、ノートから履歴と確認リストに入れなかった（疑い）。審査員と同じく入力ページのメニューから開く
  for (final size in const [Size(390, 844), Size(390, 600)]) {
    testWidgets('幅 390（$size）：入力ページのメニューから開いたノートでも、下のタブの確認リスト・履歴が画面の中にあり、押せる', (tester) async {
      _size(tester, size);
      SharedPreferences.setMockInitialValues({});
      final api = Api(
          client: MockClient((req) async => http.Response.bytes(
              utf8.encode(jsonEncode(switch (req.url.path) {
                '/home' => homeJson([_note()], me: {'id': 'demo', 'name': 'デモ', 'icon': null}),
                _ => _note(),
              })),
              200)),
          baseUrl: 'http://api');
      await tester.pumpWidget(MaterialApp(theme: appTheme(), home: InputScreen(api: api)));
      await tester.pumpAndSettle();
      await tester.tap(find.byWidgetPredicate((w) => w is MoonButton && w.semanticLabel == 'メニュー'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(MoonDrawer), matching: find.widgetWithText(MoonMenuItem, 'キッチン')));
      await tester.pumpAndSettle();
      expect(find.byType(ManualScreen), findsOneWidget);

      for (final label in ['確認リスト', '履歴']) {
        final tab = tester.getRect(_tab(label));
        expect(tab.top >= 0 && tab.bottom <= size.height, isTrue, reason: '$label のタブが画面の外にある');
      }
      await tester.tap(_tab('確認リスト'));
      await tester.pump();
      expect(find.byType(CheckListScreen), findsOneWidget);
      await tester.tap(_tab('履歴'));
      await tester.pump();
      expect(find.byType(HistoryScreen), findsOneWidget);
    });
  }

  testWidgets('後ろのぼかしは TABBAR_BLUR で切り替えられる（既定はぼかす）', (tester) async {
    _size(tester, const Size(390, 844));
    await tester.pumpWidget(MaterialApp(theme: appTheme(), home: ManualScreen(api: _api(), manualId: 'm1')));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(NoteTabBar), matching: find.byType(BackdropFilter)),
        tabBarBlur ? findsOneWidget : findsNothing);
  });

  testWidgets('広い画面（サイドバーが出る幅）では下のタブバーを出さず、上部バーの下のノートのタブに移る先を並べる。上部バーには共有と…だけ', (tester) async {
    _size(tester, const Size(1440, 900));
    await tester.pumpWidget(MaterialApp(theme: appTheme(), home: ManualScreen(api: _api(), manualId: 'm1')));
    await tester.pumpAndSettle();
    expect(find.byType(NoteTabBar), findsNothing);
    for (final label in ['ノート', '確認リスト', '履歴', '資料']) {
      expect(noteTab(label), findsOneWidget);
    }
    // あとで確認の件数は確認リストのタブのタグで出す
    expect(noteTab('1'), findsOneWidget);
    // 本文の下の「行を足す」も枠のボタンなので、上部バーの中だけを数える
    final inTopBar = find.descendant(of: find.byType(TopBar), matching: find.byType(MoonOutlinedButton));
    expect(inTopBar, findsOneWidget);
    expect(find.descendant(of: find.byType(TopBar), matching: find.widgetWithText(MoonOutlinedButton, '共有')), findsOneWidget);
    expect(find.bySemanticsLabel('その他'), findsOneWidget);
  });

  testWidgets('広い画面のノートのタブは、押すと画面を積まずに入れ替え、ノートに戻ると「ノート」が選ばれたままになる', (tester) async {
    _size(tester, const Size(1440, 900));
    await tester.pumpWidget(MaterialApp(theme: appTheme(), home: ManualScreen(api: _api(), manualId: 'm1')));
    await tester.pumpAndSettle();

    for (final (label, screen) in [('確認リスト', CheckListScreen), ('履歴', HistoryScreen), ('資料', MaterialsScreen)]) {
      await tester.tap(noteTab(label), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.byType(screen), findsOneWidget);
      // ノートの上に1枚だけ。ほかのタブの画面は外れている
      expect(find.byType(ManualScreen, skipOffstage: false), findsOneWidget);
      for (final other in [CheckListScreen, HistoryScreen, MaterialsScreen].where((t) => t != screen)) {
        expect(find.byType(other, skipOffstage: false), findsNothing);
      }
    }

    await tester.tap(noteTab('ノート'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.byType(ManualScreen), findsOneWidget);
    expect(find.byType(MaterialsScreen, skipOffstage: false), findsNothing);

    // 戻る矢印で戻ったあとも、下に残っていたノートのタブが前に押したタブのままにならず、もう一度押せる
    await tester.tap(noteTab('確認リスト'), warnIfMissed: false);
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('戻る'));
    await tester.pumpAndSettle();
    await tester.tap(noteTab('確認リスト'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.byType(CheckListScreen), findsOneWidget);
  });

  testWidgets('狭い画面では「ノート」は下のタブだけ（上のタブは「本文」）。上部バーに履歴・確認リストを出さない', (tester) async {
    _size(tester, const Size(390, 844));
    await tester.pumpWidget(MaterialApp(theme: appTheme(), home: ManualScreen(api: _api(), manualId: 'm1')));
    await tester.pumpAndSettle();
    expect(find.text('ノート'), findsOneWidget);
    expect(_tab('ノート'), findsOneWidget);
    expect(find.descendant(of: find.byType(MoonTabBar), matching: find.text('本文')), findsOneWidget);
    // 上部バーには、タブバーに無い「資料」と「共有」だけを出す（ADR 0013・0019）
    // 本文の下の「行を足す」も枠のボタンなので、上部バーの中だけを数える
    expect(find.descendant(of: find.byType(TopBar), matching: find.byType(MoonOutlinedButton)), findsNWidgets(2));
    expect(find.descendant(of: find.byType(TopBar), matching: find.widgetWithText(MoonOutlinedButton, '資料')), findsOneWidget);
    expect(find.descendant(of: find.byType(TopBar), matching: find.widgetWithText(MoonOutlinedButton, '共有')), findsOneWidget);
  });

  testWidgets('ノートの食い違っている行から開いた確認リストから、ノートのタブで1枚のノートに戻る', (tester) async {
    _size(tester, const Size(390, 844));
    await tester.pumpWidget(MaterialApp(theme: appTheme(), home: ManualScreen(api: _api(), manualId: 'm1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('・塩 小さじ1'));
    await tester.pumpAndSettle();
    await _backToList(tester);
    expect(find.byType(CheckListScreen), findsOneWidget);

    await tester.tap(_tab('ノート'));
    await tester.pumpAndSettle();
    expect(find.byType(ManualScreen, skipOffstage: false), findsOneWidget);
    expect(find.byType(CheckListScreen, skipOffstage: false), findsNothing);
  });

  testWidgets('行の「店長 11/7 に確認」から開いた確認リスト（その上に確認の記録）でも、ノートのタブで1枚のノートに戻る', (tester) async {
    _size(tester, const Size(390, 844));
    await tester.pumpWidget(MaterialApp(theme: appTheme(), home: ManualScreen(api: _api(_confirmed), manualId: 'm1')));
    await tester.pumpAndSettle();
    // 確認して決めた行には、誰に確認したかが発言者の形で出る。押すと確認の記録を開く
    await tester.tap(find.widgetWithText(Speaker, '店長').first);
    await tester.pumpAndSettle();
    await _backToList(tester);
    expect(find.byType(CheckListScreen), findsOneWidget);

    await tester.tap(_tab('ノート'));
    await tester.pumpAndSettle();
    expect(find.byType(ManualScreen, skipOffstage: false), findsOneWidget);
    expect(find.byType(CheckListScreen, skipOffstage: false), findsNothing);
  });

  testWidgets('履歴 → 版の詳細 → 確認リストを見る、と進んでも、ノートのタブで1枚のノートに戻る', (tester) async {
    _size(tester, const Size(390, 844));
    await tester.pumpWidget(MaterialApp(theme: appTheme(), home: ManualScreen(api: _api(), manualId: 'm1')));
    await tester.pumpAndSettle();
    await tester.tap(_tab('履歴'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('／').first);
    await tester.pumpAndSettle();
    final toList = find.widgetWithText(MoonOutlinedButton, '確認リストを見る');
    await tester.ensureVisible(toList);
    await tester.pumpAndSettle();
    await tester.tap(toList);
    await tester.pumpAndSettle();
    await _backToList(tester);
    expect(find.byType(CheckListScreen), findsOneWidget);

    await tester.tap(_tab('ノート'));
    await tester.pumpAndSettle();
    expect(find.byType(ManualScreen, skipOffstage: false), findsOneWidget);
    expect(find.byType(HistoryScreen, skipOffstage: false), findsNothing);
    expect(find.byType(CheckListScreen, skipOffstage: false), findsNothing);
  });

  testWidgets('ノートの外（入力ページなど）から開いた確認リストでは、ノートのタブでそのノートに入れ替える', (tester) async {
    _size(tester, const Size(390, 844));
    final api = _api();
    final c = ManualController(api, 'm1', ManualState.fromJson(_note()));
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: GestureDetector(
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CheckListScreen(c: c))),
              child: const Text('入力ページ'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('入力ページ'));
    await tester.pumpAndSettle();
    expect(find.byType(CheckListScreen), findsOneWidget);

    await tester.tap(_tab('ノート'));
    await tester.pumpAndSettle();
    expect(find.byType(ManualScreen), findsOneWidget);
    expect(find.byType(CheckListScreen, skipOffstage: false), findsNothing);
    // 入力ページへは戻れる（ノートを入力ページの上に開いている）
    expect(find.text('入力ページ', skipOffstage: false), findsOneWidget);
  });

  // #110：記録したあとの確認から開いた確認リストで、パンくずはノートの題名を出すのに ← は入力ページへ戻っていた
  group('確認リストのパンくずは、← の戻る先と合わせる', () {
    Finder inTopBar(String text) => find.descendant(of: find.byType(TopBar), matching: find.text(text));

    testWidgets('ノートの外（入力ページなど）から開いたときは、ノートの題名を出さず、← で開いた元へ戻る', (tester) async {
      _size(tester, const Size(1440, 900));
      final c = ManualController(_api(), 'm1', ManualState.fromJson(_note()));
      await tester.pumpWidget(MaterialApp(
        theme: appTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: GestureDetector(
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CheckListScreen(c: c))),
                child: const Text('入力ページ'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('入力ページ'));
      await tester.pumpAndSettle();
      expect(inTopBar('確認リスト'), findsOneWidget);
      expect(inTopBar('キッチン'), findsNothing);

      await tester.tap(find.bySemanticsLabel('戻る'));
      await tester.pumpAndSettle();
      expect(find.text('入力ページ'), findsOneWidget);
      expect(find.byType(CheckListScreen), findsNothing);
    });

    testWidgets('ノートから開いたときは、ノートの題名を出し、← でもパンくずでもノートへ戻る', (tester) async {
      _size(tester, const Size(1440, 900));
      Future<void> openList() async {
        await tester.tap(noteTab('確認リスト'), warnIfMissed: false);
        await tester.pumpAndSettle();
        expect(inTopBar('キッチン'), findsOneWidget);
        expect(inTopBar('確認リスト'), findsOneWidget);
      }

      await tester.pumpWidget(MaterialApp(theme: appTheme(), home: ManualScreen(api: _api(), manualId: 'm1')));
      await tester.pumpAndSettle();
      await openList();
      await tester.tap(find.bySemanticsLabel('戻る'));
      await tester.pumpAndSettle();
      expect(find.byType(ManualScreen), findsOneWidget);
      expect(find.byType(CheckListScreen), findsNothing);

      await openList();
      await tester.tap(inTopBar('キッチン'));
      await tester.pumpAndSettle();
      expect(find.byType(ManualScreen), findsOneWidget);
      expect(find.byType(CheckListScreen), findsNothing);
    });
  });

  testWidgets('キーボードが出ている間も、狭い画面では上部バーに履歴・確認リストを出さず、札から開いてもノートが2枚積まれない', (tester) async {
    _size(tester, const Size(390, 844));
    await tester.pumpWidget(MaterialApp(theme: appTheme(), home: ManualScreen(api: _api(), manualId: 'm1')));
    await tester.pumpAndSettle();

    // キーボードが出た状態（行を直接書き換えている間）
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    expect(find.byType(NoteTabBar), findsNothing);
    expect(find.widgetWithText(MoonOutlinedButton, '履歴'), findsNothing);
    expect(find.widgetWithText(MoonOutlinedButton, '確認リスト 1'), findsNothing);

    // 「あとで確認 1 件」の札から確認リストへ（キーボードが出ていても、タブと同じ移り方）
    await tester.tap(find.text('あとで確認 1 件'));
    await tester.pumpAndSettle();
    expect(find.byType(CheckListScreen), findsOneWidget);

    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    await tester.tap(_tab('ノート'));
    await tester.pumpAndSettle();
    expect(find.byType(ManualScreen, skipOffstage: false), findsOneWidget);
    expect(find.byType(CheckListScreen, skipOffstage: false), findsNothing);
  });

  for (final (label, screen) in [('確認リスト', CheckListScreen), ('履歴', HistoryScreen)]) {
    testWidgets('広い画面のノートのタブの「$label」で開いてから狭い幅に変えても、下のタブバーで1枚のノートに戻る', (tester) async {
      _size(tester, const Size(1440, 900));
      await tester.pumpWidget(MaterialApp(theme: appTheme(), home: ManualScreen(api: _api(), manualId: 'm1')));
      await tester.pumpAndSettle();
      await tester.tap(noteTab(label), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.byType(screen), findsOneWidget);

      // iPad を縦にする・ウィンドウを狭くする
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      expect(find.byType(NoteTabBar), findsOneWidget);

      await tester.tap(_tab('ノート'));
      await tester.pumpAndSettle();
      expect(find.byType(ManualScreen, skipOffstage: false), findsOneWidget);
      expect(find.byType(screen, skipOffstage: false), findsNothing);
    });
  }

  testWidgets('発言の付箋 → 記録の確認 → 確認リストを見る、と進んでも、ノートのタブで1枚のノートに戻る', (tester) async {
    _size(tester, const Size(390, 844));
    await tester.pumpWidget(MaterialApp(theme: appTheme(), home: ManualScreen(api: _api(), manualId: 'm1')));
    await tester.pumpAndSettle();
    // 狭い画面では、発言は上のタブ「発言」にある
    // MoonTab は MoonTabBar が中で部品に作り直すので、名前の文字を押す（押した所はタブの中なので、当たりの警告は出さない）
    await tester.tap(find.descendant(of: find.byType(MoonTabBar), matching: find.textContaining('発言')), warnIfMissed: false);
    await tester.pumpAndSettle();
    await tester.tap(find.text('塩は小さじ1/2'));
    await tester.pumpAndSettle();
    final toList = find.widgetWithText(MoonOutlinedButton, '確認リストを見る');
    await tester.ensureVisible(toList);
    await tester.pumpAndSettle();
    await tester.tap(toList);
    await tester.pumpAndSettle();
    expect(find.byType(CheckListScreen), findsOneWidget);

    await tester.tap(_tab('ノート'));
    await tester.pumpAndSettle();
    expect(find.byType(ManualScreen, skipOffstage: false), findsOneWidget);
    expect(find.byType(CheckListScreen, skipOffstage: false), findsNothing);
  });

  testWidgets('選んでいるタブの後ろにカプセルがあり、タブを替えると前のタブの位置から横に動く（ぼかしの有無によらない）', (tester) async {
    _size(tester, const Size(390, 844));
    await tester.pumpWidget(MaterialApp(theme: appTheme(), home: ManualScreen(api: _api(), manualId: 'm1')));
    await tester.pumpAndSettle();

    final pill = find.byKey(const ValueKey('tab-pill'));
    double centerOf(Finder f) => tester.getCenter(f).dx;
    expect(pill, findsOneWidget);
    expect((centerOf(pill) - centerOf(_tab('ノート'))).abs(), lessThan(1));

    await tester.tap(_tab('確認リスト'));
    await tester.pump(); // 新しい画面の1枚目：カプセルは前のタブ（ノート）の位置
    expect((centerOf(pill) - centerOf(_tab('ノート'))).abs(), lessThan(1));
    await tester.pump(); // 次の枠で動き始める
    await tester.pump(const Duration(milliseconds: 100)); // 動いている途中
    final mid = centerOf(pill);
    expect(mid, greaterThan(centerOf(_tab('ノート'))));
    expect(mid, lessThan(centerOf(_tab('確認リスト'))));
    await tester.pumpAndSettle();
    expect((centerOf(pill) - centerOf(_tab('確認リスト'))).abs(), lessThan(1));
  });

  testWidgets('ぼかしありでは、後ろをぼかして色を鮮やかにするガラスにする', (tester) async {
    _size(tester, const Size(390, 844));
    await tester.pumpWidget(MaterialApp(theme: appTheme(), home: ManualScreen(api: _api(), manualId: 'm1')));
    await tester.pumpAndSettle();
    final glass = find.descendant(of: find.byType(NoteTabBar), matching: find.byType(BackdropFilter));
    if (!tabBarBlur) {
      expect(glass, findsNothing);
      return;
    }
    // ぼかしだけでなく、色の行列（鮮やかさ）も重ねている
    expect(tester.widget<BackdropFilter>(glass).filter.toString(), contains('matrix'));
  });

  /// カプセルが from のタブの位置から to のタブの位置へ、途中を通って動くことを確かめる（タブを押す・戻るのあとに呼ぶ）
  Future<void> expectPillMoves(WidgetTester tester, String from, String to) async {
    final pill = find.byKey(const ValueKey('tab-pill'));
    double x(Finder f) => tester.getCenter(f).dx;
    await tester.pump(); // 出てきた画面の1枚目：カプセルは前のタブの位置
    expect((x(pill) - x(_tab(from))).abs(), lessThan(1), reason: '$from の位置から始まる');
    await tester.pump(); // 次の枠で動き始める
    await tester.pump(const Duration(milliseconds: 100));
    final mid = x(pill);
    final (lo, hi) = x(_tab(from)) < x(_tab(to)) ? (x(_tab(from)), x(_tab(to))) : (x(_tab(to)), x(_tab(from)));
    expect(mid, greaterThan(lo + 1), reason: '動いている途中');
    expect(mid, lessThan(hi - 1), reason: '動いている途中');
    await tester.pumpAndSettle();
    expect((x(pill) - x(_tab(to))).abs(), lessThan(1), reason: '$to の位置に着く');
  }

  for (final from in ['確認リスト', '履歴']) {
    testWidgets('$from から「ノート」に戻るときも、カプセルが$fromの位置からなめらかに動く', (tester) async {
      _size(tester, const Size(390, 844));
      await tester.pumpWidget(MaterialApp(theme: appTheme(), home: ManualScreen(api: _api(), manualId: 'm1')));
      await tester.pumpAndSettle();
      await tester.tap(_tab(from));
      await tester.pumpAndSettle();

      await tester.tap(_tab('ノート'));
      await expectPillMoves(tester, from, 'ノート');
    });
  }

  testWidgets('確認リスト → 履歴 → ノート、と替えても、いつも直前のタブの位置から動く', (tester) async {
    _size(tester, const Size(390, 844));
    await tester.pumpWidget(MaterialApp(theme: appTheme(), home: ManualScreen(api: _api(), manualId: 'm1')));
    await tester.pumpAndSettle();
    await tester.tap(_tab('確認リスト'));
    await expectPillMoves(tester, 'ノート', '確認リスト');
    await tester.tap(_tab('履歴'));
    await expectPillMoves(tester, '確認リスト', '履歴');
    await tester.tap(_tab('ノート'));
    await expectPillMoves(tester, '履歴', 'ノート');
  });

  testWidgets('戻るボタンでノートに戻ったときも、カプセルが前のタブの位置から動く', (tester) async {
    _size(tester, const Size(390, 844));
    await tester.pumpWidget(MaterialApp(theme: appTheme(), home: ManualScreen(api: _api(), manualId: 'm1')));
    await tester.pumpAndSettle();
    await tester.tap(_tab('履歴'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('戻る'));
    await expectPillMoves(tester, '履歴', 'ノート');
  });

  testWidgets('ノートの外から開いたときは、カプセルを動かさずにその位置に出す', (tester) async {
    _size(tester, const Size(390, 844));
    final pill = find.byKey(const ValueKey('tab-pill'));
    double x(Finder f) => tester.getCenter(f).dx;
    // 別のノートの流れで「確認リスト」を見たあとでも、外から開いた画面には影響しない
    final c = ManualController(_api(), 'm1', ManualState.fromJson(_note()));
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: GestureDetector(
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CheckListScreen(c: c))),
              child: const Text('入力ページ'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('入力ページ'));
    // MaterialPageRoute は1枚目を画面に出さない（Hero の下調べ）ので、2枚目から見る。前のタブの覚えが無いので、はじめから確認リストの位置で動かない
    await tester.pump();
    await tester.pump();
    expect((x(pill) - x(_tab('確認リスト'))).abs(), lessThan(1));
    await tester.pump(const Duration(milliseconds: 100));
    expect((x(pill) - x(_tab('確認リスト'))).abs(), lessThan(1));
    await tester.pumpAndSettle();
    expect((x(pill) - x(_tab('確認リスト'))).abs(), lessThan(1));

    // そこから「ノート」でノートに入れ替えると、新しいノートの画面になるので、カプセルは動かずにノートの位置に出る
    await tester.tap(_tab('ノート'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect((x(pill) - x(_tab('ノート'))).abs(), lessThan(1));
  });

  testWidgets('ノートを開いたばかりのときは、カプセルを動かさない', (tester) async {
    _size(tester, const Size(390, 844));
    await tester.pumpWidget(MaterialApp(theme: appTheme(), home: ManualScreen(api: _api(), manualId: 'm1')));
    final pill = find.byKey(const ValueKey('tab-pill'));
    await tester.pumpAndSettle();
    // 1枚目からずっと「ノート」の位置（動きが無いので、pumpAndSettle の間に位置は変わらない）
    expect((tester.getCenter(pill).dx - tester.getCenter(_tab('ノート')).dx).abs(), lessThan(1));
  });
}
