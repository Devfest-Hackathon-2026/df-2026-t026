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

/// ビルドの成果物を真似た build/web を作る
Directory _fakeWeb() {
  final web = Directory.systemTemp.createTempSync('web_postbuild_test');
  addTearDown(() => web.deleteSync(recursive: true));
  for (final asset in _assets(_manifest())) {
    File('${web.path}/assets/$asset').createSync(recursive: true);
  }
  File('${web.path}/assets/FontManifest.json').writeAsStringSync(jsonEncode(_manifest()));
  File('${web.path}/index.html').writeAsStringSync(File('web/index.html').readAsStringSync());
  File('${web.path}/main.dart.js').writeAsStringSync('i.initEvent("flutter-first-frame",!0,!0)');
  return web;
}

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
    final web = _fakeWeb();
    File('${web.path}/main.dart.js').writeAsStringSync('');
    final before = File('${web.path}/assets/FontManifest.json').readAsStringSync();

    expect(() => postBuild(web, apiUrl: 'https://api.example.com'), throwsStateError);
    expect(File('${web.path}/assets/FontManifest.json').readAsStringSync(), before);
    expect(_assets(_manifest()).every((a) => File('${web.path}/assets/$a').existsSync()), isTrue);
  });
}
