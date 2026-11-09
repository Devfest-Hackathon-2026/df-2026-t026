import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:diff_note/api.dart';
import 'package:diff_note/screens/common.dart';
import 'package:diff_note/screens/manual_screen.dart';
import 'package:diff_note/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moon_design/moon_design.dart';

// 発言者の丸に、名前から決まったイラストの顔を出す（実装24）

/// 画面に出ている発言者の顔の画像（assets/avatars/…）
List<String> _faces(WidgetTester tester, {String? of}) => [
      for (final a in tester.widgetList<MoonAvatar>(
          of == null ? find.byType(MoonAvatar) : find.descendant(of: find.widgetWithText(Speaker, of), matching: find.byType(MoonAvatar))))
        if (a.backgroundImage case final AssetImage img) img.assetName,
    ];

/// 田中さんの「塩は小さじ1/2」をノートに書き込んだ（ノートの行と付箋の両方に田中さんが出る）
Map<String, dynamic> _state() => {
      'owner': 'demo',      'me': 'demo',      'manual': {'id': 'm1', 'title': 'キッチン', 'base': '- 塩 小さじ1', 'createdAt': '2026-11-01T00:00:00Z'},
      'lines': [
        {'text': '- 塩 小さじ1/2', 'patchId': 'p1'},
      ],
      'utterances': [
        {'id': 'u1', 'text': '塩は小さじ1/2', 'speaker': '田中さん', 'saidAt': '2026-11-03', 'fromEdit': false, 'createdAt': '2026-11-03T00:00:00Z'},
      ],
      'patches': [
        {'id': 'p1', 'utteranceId': 'u1', 'op': 'replace', 'line': '- 塩 小さじ1', 'text': '- 塩 小さじ1/2', 'summary': '', 'status': 'applied', 'createdAt': '2026-11-03T00:00:00Z', 'appliedAt': '2026-11-03T00:00:00Z'},
      ],
      'checks': [
        {'id': 'c1', 'patchId': 'p1', 'utteranceId': 'u1', 'kind': 'addition', 'conflictLine': null, 'sameLine': null, 'reason': '', 'ask': null, 'resolution': null},
      ],
    };

void main() {
  group('名前から顔を選ぶ', () {
    test('同じ名前はいつも同じ顔。決まった計算なので、番号も毎回同じ（Web でも同じになるよう 32bit で計算）', () {
      // 値を固定しておく（計算を変えると、見本の画面の顔が入れ替わってしまう）
      expect({
        for (final n in ['田中さん', '店長', '佐藤さん', '鈴木さん', '山田課長', '高橋さん', '鈴木先輩']) n: SpeakerFace.faceOf(n),
      }, {'田中さん': 2, '店長': 5, '佐藤さん': 4, '鈴木さん': 0, '山田課長': 5, '高橋さん': 2, '鈴木先輩': 6});
      for (var i = 0; i < 3; i++) {
        expect(SpeakerFace.faceOf('田中さん'), 2);
      }
      expect(SpeakerFace.assetOf('田中さん'), 'assets/avatars/peep-3.png');
    });

    test('見本のノートの4人（キッチン）・使い方の例の4人は、それぞれ違う顔', () {
      for (final group in [
        ['田中さん', '店長', '佐藤さん', '鈴木さん'],
        ['山田課長', '高橋さん', '鈴木先輩', '佐藤さん'],
      ]) {
        expect({for (final n in group) SpeakerFace.faceOf(n)}, hasLength(group.length), reason: '$group');
      }
    });

    test('違う名前はだいたい違う顔：いろいろな名前で 8枚がまんべんなく使われ、番号は 0〜7 に収まる', () {
      final counts = List.filled(SpeakerFace.faces, 0);
      const family = ['佐藤', '鈴木', '高橋', '田中', '伊藤', '渡辺', '山本', '中村', '小林', '加藤', '吉田', '山田', '佐々木', '山口', '松本'];
      const suffix = ['さん', '先輩', '店長', '課長', 'くん', 'リーダー'];
      for (final f in family) {
        for (final s in suffix) {
          final i = SpeakerFace.faceOf('$f$s');
          expect(i, inInclusiveRange(0, SpeakerFace.faces - 1));
          counts[i]++;
        }
      }
      // 90人を 8枚に分けて、どの顔も 5人以上（偏りすぎていない）
      expect(counts.every((c) => c >= 5), isTrue, reason: '$counts');
    });

    test('顔の画像が全部 assets にあり、PNG として読める。README に出どころとライセンスがある', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      for (var i = 1; i <= SpeakerFace.faces; i++) {
        final data = await rootBundle.load('assets/avatars/peep-$i.png');
        final frame = await (await ui.instantiateImageCodec(data.buffer.asUint8List())).getNextFrame();
        expect(frame.image.width, greaterThan(0), reason: 'peep-$i.png');
      }
      final pngs = Directory('assets/avatars').listSync().where((f) => f.path.endsWith('.png'));
      expect(pngs, hasLength(SpeakerFace.faces));
      final readme = File('assets/avatars/README.md').readAsStringSync();
      expect(readme, contains('Open Peeps'));
      expect(readme, contains('CC0'));
    });
  });

  group('発言者の丸', () {
    Future<void> pump(WidgetTester tester, Widget w) =>
        tester.pumpWidget(MaterialApp(theme: appTheme(), home: Scaffold(body: Center(child: w))));

    testWidgets('名前があれば顔。読み上げは今までどおり名前', (tester) async {
      final semantics = tester.ensureSemantics();
      await pump(tester, const Speaker(name: '田中さん', day: '2026-11-07'));
      expect(_faces(tester), ['assets/avatars/peep-3.png']);
      expect(find.bySemanticsLabel('田中さん'), findsWidgets);
      // 頭文字の「田」は出さない
      expect(find.text('田'), findsNothing);
      semantics.dispose();
    });

    testWidgets('名前が無いとき・「自分」のときは、今までどおり頭文字の丸', (tester) async {
      await pump(tester, const Column(mainAxisSize: MainAxisSize.min, children: [
        Speaker(name: null, day: '2026-11-07'),
        Speaker(name: '自分', day: '2026-11-07'),
      ]));
      expect(_faces(tester), isEmpty);
      expect(find.text('?'), findsOneWidget);
      expect(find.text('自'), findsOneWidget);
    });

    testWidgets('ログインする人のアイコン（Avatar）は変えない（頭文字のまま）', (tester) async {
      await pump(tester, const Avatar('かなで'));
      expect(_faces(tester), isEmpty);
      expect(find.text('か'), findsOneWidget);
    });

    for (final size in const [Size(390, 844), Size(1440, 900)]) {
      testWidgets('ノートの画面では、ノートの行と付箋で同じ人は同じ顔（$size）', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final api = Api(
            client: MockClient((_) async => http.Response.bytes(utf8.encode(jsonEncode(_state())), 200)),
            baseUrl: 'http://api');
        await tester.pumpWidget(MaterialApp(theme: appTheme(), home: ManualScreen(api: api, manualId: 'm1')));
        await tester.pumpAndSettle();
        if (size.width < 900) {
          // 狭い画面は本文と発言をタブで切り替える。本文の行の顔を見てから、発言のタブの付箋の顔を見る
          expect(_faces(tester, of: '田中さん'), ['assets/avatars/peep-3.png']);
          await tester.tap(find.text('発言 1'));
          await tester.pumpAndSettle();
          expect(_faces(tester, of: '田中さん'), ['assets/avatars/peep-3.png']);
        } else {
          final faces = _faces(tester, of: '田中さん');
          expect(faces.length, greaterThanOrEqualTo(2), reason: '行と付箋の両方');
          expect(faces.toSet(), {'assets/avatars/peep-3.png'});
        }
      });
    }
  });
}
