import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/web_postbuild.dart';

const _weights = [100, 200, 300, 400, 500, 600];

/// build/web/assets/FontManifest.json と同じ形（lucide_icons_flutter 4.0.2・moon_design 1.1.0 のとき）
List<Object?> _manifest() => [
      {
        'family': 'MaterialIcons',
        'fonts': [
          {'asset': 'fonts/MaterialIcons-Regular.otf'},
        ],
      },
      {
        'family': 'BIZUDPGothic',
        'fonts': [
          {'asset': 'fonts/BIZUDPGothic-Regular.ttf'},
          {'weight': 700, 'asset': 'fonts/BIZUDPGothic-Bold.ttf'},
        ],
      },
      {
        'family': 'packages/moon_icons/MoonIcons',
        'fonts': [
          {'asset': 'packages/moon_icons/lib/fonts/MoonIcons.ttf'},
        ],
      },
      {
        'family': lucideFamily,
        'fonts': [
          {'asset': 'packages/lucide_icons_flutter/assets/lucide.ttf'},
        ],
      },
      for (final w in _weights)
        {
          'family': '$lucideFamily$w',
          'fonts': [
            {'weight': w, 'asset': 'packages/lucide_icons_flutter/assets/build_font/LucideVariable-w$w.ttf'},
          ],
        },
    ];

List<String> _families(List<Object?> manifest) => [for (final e in manifest) (e as Map)['family'] as String];

List<String> _assets(List<Object?> manifest) => [
      for (final e in manifest)
        for (final f in (e as Map)['fonts'] as List) (f as Map)['asset'] as String,
    ];

const _firstFrame = 'i.initEvent("flutter-first-frame",!0,!0)';

/// dart2js が出す MoonIcons の IconData（moon_design 1.1.0 の MoonErrorMessage が描く generic_info_16_light）
const _infoIcon = 'B.P8=new A.de(60745,"MoonIcons","moon_icons",!1)';

/// 絞ったフォントに無い字の IconData
const _otherIcon = 'B.P9=new A.de(60746,"MoonIcons","moon_icons",!1)';

const _originalMoonIcons = '元の MoonIcons';

/// ビルドの成果物を真似た build/web を作る
Directory _fakeWeb({String mainJs = _firstFrame}) {
  final web = Directory.systemTemp.createTempSync('web_postbuild_test');
  addTearDown(() => web.deleteSync(recursive: true));
  for (final asset in _assets(_manifest())) {
    File('${web.path}/assets/$asset').createSync(recursive: true);
  }
  File('${web.path}/assets/$moonIconsAsset').writeAsStringSync(_originalMoonIcons);
  File('${web.path}/assets/FontManifest.json').writeAsStringSync(jsonEncode(_manifest()));
  File('${web.path}/index.html').writeAsStringSync(File('web/index.html').readAsStringSync());
  File('${web.path}/main.dart.js').writeAsStringSync(mainJs);
  return web;
}

File _moonIcons(Directory web) => File('${web.path}/assets/$moonIconsAsset');

void main() {
  test('Lucide の太さ違いだけを外し、既定の Lucide・MoonIcons・本文の書体は残す', () {
    final r = dropUnusedFonts(_manifest());
    expect(_families(r.manifest), ['MaterialIcons', 'BIZUDPGothic', 'packages/moon_icons/MoonIcons', lucideFamily]);
    expect(r.dropped, [for (final w in _weights) 'packages/lucide_icons_flutter/assets/build_font/LucideVariable-w$w.ttf']);
  });

  test('Lucide の太さ違いが見つからなければ失敗にする（外したあと・family 名が変わったとき）', () {
    final manifest = _manifest()..removeWhere((e) => RegExp(r'Lucide\d+$').hasMatch((e as Map)['family'] as String));
    expect(() => dropUnusedFonts(manifest), throwsStateError);
  });

  test('既定の Lucide が見つからなければ失敗にする', () {
    final manifest = _manifest()..removeWhere((e) => (e as Map)['family'] == lucideFamily);
    expect(() => dropUnusedFonts(manifest), throwsStateError);
  });

  // 太さ違いのフォントを外してよいのは、アプリが LucideIcons（既定の太さ）しか使わないから。CI は Web をビルドしないので、ここで確かめる
  test('アプリが lucide_icons_flutter から読むのは lucide_icons.dart だけ', () {
    final imports = RegExp(r'''package:lucide_icons_flutter/[^'"]+''');
    final found = {
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')))
        ...imports.allMatches(f.readAsStringSync()).map((m) => m[0]),
    };
    expect(found, {'package:lucide_icons_flutter/lucide_icons.dart'});
  });

  test('web/index.html の API の URL を入れる所に URL を入れる', () {
    final html = withApiUrl(File('web/index.html').readAsStringSync(), 'https://api.example.com');
    expect(html, contains('<meta name="diffnote-api" content="https://api.example.com">'));
    expect(html, isNot(contains(apiUrlMarker)));
  });

  test('API の URL が http(s) でなければ失敗にする', () {
    final html = File('web/index.html').readAsStringSync();
    for (final url in ['', 'example.com', 'javascript:alert(1)']) {
      expect(() => withApiUrl(html, url), throwsArgumentError, reason: url);
    }
  });

  test('ビルドの成果物から使っていないフォントを消し、index.html に API の URL を入れる', () {
    final web = _fakeWeb();
    postBuild(web, apiUrl: 'https://api.example.com');

    final manifest = jsonDecode(File('${web.path}/assets/FontManifest.json').readAsStringSync()) as List<Object?>;
    expect(_families(manifest), isNot(contains('${lucideFamily}100')));
    for (final asset in _assets(_manifest())) {
      expect(File('${web.path}/assets/$asset').existsSync(), _assets(manifest).contains(asset), reason: asset);
    }
    expect(File('${web.path}/index.html').readAsStringSync(), contains('content="https://api.example.com"'));
  });

  test('API の URL を渡さなければ index.html は変えない', () {
    final web = _fakeWeb();
    postBuild(web);
    expect(File('${web.path}/index.html').readAsStringSync(), File('web/index.html').readAsStringSync());
  });

  test('main.dart.js に最初のフレームのイベントが無ければ、何も変えずに失敗にする', () {
    _expectFailsUnchanged(_fakeWeb(mainJs: _infoIcon));
  });

  test('main.dart.js が Lucide の太さ違いを使っていたら、何も変えずに失敗にする', () {
    _expectFailsUnchanged(
        _fakeWeb(mainJs: '$_firstFrame\n$_infoIcon\nB.x=new A.de(57808,"Lucide300","lucide_icons_flutter",!1)'));
  });

  test('消すはずのフォントが1つでも無ければ、何も変えずに失敗にする', () {
    final web = _fakeWeb(mainJs: '$_firstFrame;$_infoIcon');
    File('${web.path}/assets/packages/lucide_icons_flutter/assets/build_font/LucideVariable-w600.ttf').deleteSync();
    final before = File('${web.path}/assets/FontManifest.json').readAsStringSync();

    expect(() => postBuild(web, apiUrl: 'https://api.example.com'), throwsStateError);
    expect(File('${web.path}/assets/FontManifest.json').readAsStringSync(), before);
    expect(File('${web.path}/assets/packages/lucide_icons_flutter/assets/build_font/LucideVariable-w100.ttf').existsSync(), isTrue);
    expect(File('${web.path}/index.html').readAsStringSync(), File('web/index.html').readAsStringSync());
    expect(_moonIcons(web).readAsStringSync(), _originalMoonIcons);
  });

  test('main.dart.js の MoonIcons の字が絞ったフォントに全部あれば、差し替えてよい', () {
    expect(moonIconsSubsetBlocker('$_firstFrame;$_infoIcon'), isNull);
    expect(moonIconsSubsetBlocker('$_infoIcon;B.Q1=new A.de(60745,"MoonIcons","moon_icons",!0)'), isNull);
  });

  test('絞ったフォントに無い字を使っていれば、その字を挙げて差し替えない', () {
    expect(moonIconsSubsetBlocker('$_infoIcon;$_otherIcon'), contains('U+ED4A'));
  });

  test('main.dart.js の MoonIcons を拾い漏らしたかもしれなければ、差し替えない', () {
    for (final js in [
      _firstFrame, // 1つも拾えない
      'B.P8=new A.de(0xed49,"MoonIcons","moon_icons",!1)', // 番号の書き方が変わった
      'B.s="MoonIcons";B.P8=new A.de(60745,B.s,"moon_icons",!1)', // 文字列を1か所にまとめた
      '$_infoIcon;B.t=A.H("packages/moon_icons/MoonIcons")', // IconData の外で使う
    ]) {
      expect(moonIconsSubsetBlocker(js), contains('読み切れない'), reason: js);
    }
  });

  test('ビルドの MoonIcons.ttf を、マニフェストの family と道はそのままで、絞ったフォントに差し替える', () {
    final web = _fakeWeb(mainJs: '$_firstFrame;$_infoIcon');
    expect(postBuild(web).moonIconsKept, isNull);

    expect(_moonIcons(web).readAsBytesSync(), File(moonIconsSubset).readAsBytesSync());
    final manifest = jsonDecode(File('${web.path}/assets/FontManifest.json').readAsStringSync()) as List<Object?>;
    expect(_families(manifest), contains('packages/moon_icons/MoonIcons'));
    expect(_assets(manifest), contains(moonIconsAsset));
  });

  test('差し替えないときは、元の MoonIcons.ttf のまま残して理由を返す', () {
    for (final js in [_firstFrame, '$_firstFrame;$_infoIcon;$_otherIcon']) {
      final web = _fakeWeb(mainJs: js);
      expect(postBuild(web).moonIconsKept, isNotNull, reason: js);
      expect(_moonIcons(web).readAsStringSync(), _originalMoonIcons, reason: js);
    }
  });

  test('ビルドに MoonIcons.ttf が無ければ、作らずに理由を返す', () {
    final web = _fakeWeb(mainJs: '$_firstFrame;$_infoIcon');
    _moonIcons(web).deleteSync();
    expect(postBuild(web).moonIconsKept, contains(moonIconsAsset));
    expect(_moonIcons(web).existsSync(), isFalse);
  });

  // 絞ったフォントは moon_icons 1.1.0 から作った。版を上げると同じ番号で字の形が変わりうるので、作り直してからここを直す
  test('moon_icons は、絞ったフォントを作った版（1.1.0）のまま', () {
    final lock = File('pubspec.lock').readAsStringSync();
    final version = RegExp(r'^  moon_icons:\n(?:    .*\n)*?    version: "([^"]+)"', multiLine: true).firstMatch(lock)?[1];
    expect(version, '1.1.0');
  });
}

/// 失敗し、マニフェスト・フォント（MoonIcons を含む）・index.html のどれも変えていないこと
void _expectFailsUnchanged(Directory web) {
  final before = File('${web.path}/assets/FontManifest.json').readAsStringSync();
  expect(() => postBuild(web, apiUrl: 'https://api.example.com'), throwsStateError);
  expect(File('${web.path}/assets/FontManifest.json').readAsStringSync(), before);
  expect(_assets(_manifest()).every((a) => File('${web.path}/assets/$a').existsSync()), isTrue);
  expect(_moonIcons(web).readAsStringSync(), _originalMoonIcons);
  expect(File('${web.path}/index.html').readAsStringSync(), File('web/index.html').readAsStringSync());
}
