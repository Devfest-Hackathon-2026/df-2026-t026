import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:diff_note/api.dart';
import 'package:diff_note/screens/check_list_screen.dart';
import 'package:diff_note/screens/common.dart';
import 'package:diff_note/screens/help_screen.dart';
import 'package:diff_note/screens/open_checks_screen.dart';
import 'package:diff_note/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// 調査18 の A5・実装22: 「あとで確認」の画面と使い方のページを守るテスト

http.Response _json(Object body) => http.Response.bytes(utf8.encode(jsonEncode(body)), 200);

/// 食い違いを open 件かかえたノート
Map<String, dynamic> _state(String id, String title, int open) => {
      'owner': 'demo',      'me': 'demo',      'manual': {'id': id, 'title': title, 'base': '- 塩 小さじ1', 'createdAt': '2026-11-01T00:00:00Z'},
      'lines': [
        {'text': '- 塩 小さじ1', 'patchId': null},
      ],
      'utterances': [
        for (var i = 0; i < open; i++)
          {'id': '$id-u$i', 'text': '塩は$i', 'speaker': '田中さん', 'saidAt': '2026-11-03', 'fromEdit': false, 'createdAt': '2026-11-03T10:00:00Z'},
      ],
      'patches': [
        for (var i = 0; i < open; i++)
          {'id': '$id-p$i', 'utteranceId': '$id-u$i', 'op': 'replace', 'line': '- 塩 小さじ1', 'text': '- 塩 $i', 'summary': '', 'status': 'pending', 'createdAt': '2026-11-03T10:00:00Z', 'appliedAt': null},
      ],
      'checks': [
        for (var i = 0; i < open; i++)
          {
            'id': '$id-c$i',
            'patchId': '$id-p$i',
            'utteranceId': '$id-u$i',
            'kind': 'contradiction',
            'conflictLine': '- 塩 小さじ1',
            'sameLine': null,
            'reason': '量が違う',
            'ask': {'candidates': [], 'question': 'どちらですか？'},
            'resolution': null,
          },
      ],
    };

/// notes の (id, 題名, あとで確認の数) を返す API。fail が true の間は一覧が 500 になる
Api _api(List<(String, String, int)> notes, {bool Function()? fail}) => Api(
      client: MockClient((req) async {
        final path = req.url.path;
        if (fail?.call() ?? false) return http.Response('<html>500</html>', 500);
        if (path == '/me') return _json({'id': 'kanade', 'name': 'かなで', 'icon': null});
        if (path == '/manuals') {
          return _json([for (final (id, title, open) in notes) {'id': id, 'title': title, 'utteranceCount': open, 'openCount': open}]);
        }
        for (final (id, title, open) in notes) {
          if (path == '/manuals/$id') return _json(_state(id, title, open));
        }
        return _json([]);
      }),
      baseUrl: 'http://api',
    );

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _pumpChecks(WidgetTester tester, Api api, {Size size = const Size(390, 844)}) async {
  _size(tester, size);
  await tester.pumpWidget(MaterialApp(theme: appTheme(), home: OpenChecksScreen(api: api)));
  await tester.pumpAndSettle();
}

/// help_screen.dart に書いてある画像の名前（shot: '…'）。節を足したら自動で確かめの対象になる
List<String> _shots() => [
      for (final m in RegExp(r"shot: '(\w+)'").allMatches(File('lib/screens/help_screen.dart').readAsStringSync())) m.group(1)!,
    ];

void main() {
  group('「あとで確認」の画面', () {
    testWidgets('共有されたノートの確認は「聞かれていること」に分け、持ち主の名前を添える。自分のノートは「自分が聞くこと」', (tester) async {
      final api = Api(
        client: MockClient((req) async => switch (req.url.path) {
              '/manuals' => _json([
                  {'id': 'm1', 'title': 'キッチン', 'utteranceCount': 1, 'openCount': 1},
                ]),
              '/shared' => _json([
                  {'id': 'm2', 'title': '閉店作業メモ', 'sharedBy': {'id': 'newbie', 'name': '新人'}, 'sharedAt': '2026-11-08T00:00:00Z', 'openCount': 2},
                ]),
              '/manuals/m1' => _json(_state('m1', 'キッチン', 1)),
              '/manuals/m2' => _json({
                  ..._state('m2', '閉店作業メモ', 2),
                  'owner': 'newbie',
                  'sharedBy': {'id': 'newbie', 'name': '新人'},
                }),
              _ => _json([]),
            }),
        baseUrl: 'http://api',
      );
      await _pumpChecks(tester, api, size: const Size(1440, 900));
      // サイドバーにも同じ題名が出るので、一覧の中で探す
      Rect at(String text) => tester.getRect(find.descendant(of: find.byType(OpenChecksList), matching: find.text(text)));
      expect(
        [at('自分が聞くこと').top < at('キッチン').top, at('キッチン').top < at('聞かれていること').top, at('聞かれていること').top < at('閉店作業メモ').top],
        [true, true, true],
      );
      expect(find.descendant(of: find.byType(OpenChecksList), matching: find.text('新人')), findsOneWidget);
      expect(find.text('あとで確認 2 件'), findsOneWidget);
    });

    testWidgets('共有されたノートの確認が無ければ、小見出しは出さない', (tester) async {
      await _pumpChecks(tester, _api([('m1', 'キッチン', 1)]));
      expect(find.text('自分が聞くこと'), findsNothing);
      expect(find.text('聞かれていること'), findsNothing);
    });

    for (final size in const [Size(390, 844), Size(1440, 900)]) {
      testWidgets('あとで確認が無ければ「食い違いは、いまはありません」。合計の札も出さない（$size）', (tester) async {
        await _pumpChecks(tester, _api([('m1', 'キッチン', 0), ('m2', 'ホール', 0)]), size: size);
        expect(find.descendant(of: find.byType(PageTitle), matching: find.text('あとで確認')), findsOneWidget);
        expect(find.text('食い違いは、いまはありません'), findsOneWidget);
        expect(find.textContaining('全部で'), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('件数：全部のノートの合計と、ノートごとの件数。あとで確認の無いノートは並べない', (tester) async {
      await _pumpChecks(tester, _api([('m1', 'キッチン', 1), ('m2', 'ホール', 2), ('m3', '洗い場', 0)]));
      expect(find.text('全部で 3 件'), findsOneWidget);
      final list = find.byType(OpenChecksList);
      expect(find.descendant(of: list, matching: find.text('あとで確認 1 件')), findsOneWidget);
      expect(find.descendant(of: list, matching: find.text('あとで確認 2 件')), findsOneWidget);
      expect(find.descendant(of: list, matching: find.text('洗い場')), findsNothing);
    });

    testWidgets('ノートを押すと、そのノートの確認リストを開く', (tester) async {
      await _pumpChecks(tester, _api([('m1', 'キッチン', 1), ('m2', 'ホール', 2)]));
      await tester.tap(find.descendant(of: find.byType(OpenChecksList), matching: find.text('ホール')));
      await tester.pumpAndSettle();
      expect(find.byType(CheckListScreen), findsOneWidget);
      expect(find.text('あとで確認（2）'), findsOneWidget);
    });

    testWidgets('読み込みに失敗したら「読み込めませんでした」を出し、「もう一度読み込む」で読み直せる', (tester) async {
      var failing = true;
      await _pumpChecks(tester, _api([('m1', 'キッチン', 1)], fail: () => failing));
      expect(find.byType(LoadFailed), findsOneWidget);
      expect(find.text('読み込めませんでした：エラーが起きました（500）'), findsOneWidget);

      failing = false;
      await tester.tap(find.text('もう一度読み込む'));
      await tester.pumpAndSettle();
      expect(find.byType(LoadFailed), findsNothing);
      expect(find.text('全部で 1 件'), findsOneWidget);
    });
  });

  group('使い方のページ', () {
    test('載せている画像が全部 assets にあり、PNG として読める（PC・スマホの両方）', () async {
      final shots = _shots();
      expect(shots, isNotEmpty);
      // pubspec.yaml の assets に入っていなければ rootBundle で読めない
      TestWidgetsFlutterBinding.ensureInitialized();
      for (final w in ['wide', 'narrow']) {
        for (final s in shots) {
          final data = await rootBundle.load('assets/help/$w/$s.png');
          final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
          final frame = await codec.getNextFrame();
          expect(frame.image.width, greaterThan(0), reason: '$w/$s.png');
        }
      }
    });

    test('assets/help に、ページで使っていない画像が残っていない', () {
      final shots = _shots().toSet();
      for (final w in ['wide', 'narrow']) {
        final files = Directory('assets/help/$w').listSync().map((f) => f.uri.pathSegments.last).where((n) => n.endsWith('.png'));
        expect(files.map((n) => n.replaceAll('.png', '')).toSet(), shots, reason: w);
      }
    });

    for (final (size, width) in const [(Size(390, 844), 'narrow'), (Size(1440, 900), 'wide')]) {
      testWidgets('$width の幅で崩れずに出て、その幅で撮った画像を使う', (tester) async {
        _size(tester, size);
        await tester.pumpWidget(MaterialApp(theme: appTheme(), home: const HelpScreen()));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.descendant(of: find.byType(PageTitle), matching: find.text('使い方')), findsOneWidget);
        expect(find.textContaining('暫定'), findsNothing);

        // 下までスクロールして、全部の画像がその幅のものを指し、はみ出しが無いことを見る
        final seen = <String>{};
        for (var i = 0; i < 40; i++) {
          for (final img in tester.widgetList<Image>(find.byType(Image))) {
            final name = (img.image as AssetImage).assetName;
            expect(name, startsWith('assets/help/$width/'));
            seen.add(name);
          }
          await tester.drag(find.byType(ListView), const Offset(0, -600));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        expect(seen, {for (final s in _shots()) 'assets/help/$width/$s.png'});
      });
    }
  });
}
