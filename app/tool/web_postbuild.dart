// Web のリリースビルドのあと、デプロイの前に走らせる（.github/workflows/deploy.yml。設計書 0020 の A2）。
//   dart run tool/web_postbuild.dart [API の URL]
// Flutter Web は FontManifest.json のフォントを最初の画面の前に全部取りに行くので、
// 依存のパッケージが宣言しているだけで使っていないフォントを外す。
// dart run で動くよう、Flutter に依存するものは import しない。
import 'dart:convert';
import 'dart:io';

/// アプリが使う Lucide（`LucideIcons`、既定の太さ）。残す
const lucideFamily = 'packages/lucide_icons_flutter/Lucide';

/// Lucide の太さ違い（Lucide100〜600）。アプリは使わない。
/// MoonIcons は外さない。MoonTextInput に errorText を渡すと MoonIcons の字を描く（review_dialog.dart）
final _lucideWeights = RegExp(r'^packages/lucide_icons_flutter/Lucide\d+$');

/// index.html の、API の URL を入れる所。空のままなら index.html は API を呼ばない
const apiUrlMarker = '<meta name="diffnote-api" content="">';

/// index.html が読み込み中の画面を消すのに待つイベント。main.dart.js が送る
const firstFrameEvent = 'flutter-first-frame';

/// FontManifest.json の中身から Lucide の太さ違いを外し、残す中身と消すフォント（assets/ からの道）を返す。
/// lucide_icons_flutter の更新で family 名が変わったら、何も外さずに通らないよう失敗にする
({List<Object?> manifest, List<String> dropped}) dropUnusedFonts(List<Object?> manifest) {
  final kept = <Object?>[];
  final dropped = <String>[];
  for (final entry in manifest) {
    final family = (entry as Map<String, Object?>)['family'];
    if (family is String && _lucideWeights.hasMatch(family)) {
      for (final font in entry['fonts'] as List<Object?>) {
        dropped.add((font as Map<String, Object?>)['asset'] as String);
      }
    } else {
      kept.add(entry);
    }
  }
  if (dropped.isEmpty) {
    throw StateError('FontManifest.json に Lucide の太さ違いが無い。外したあとか、lucide_icons_flutter の family 名が変わった');
  }
  if (!kept.any((e) => (e as Map<String, Object?>)['family'] == lucideFamily)) {
    throw StateError('FontManifest.json に $lucideFamily が無い。lucide_icons_flutter の family 名が変わった');
  }
  return (manifest: kept, dropped: dropped);
}

/// index.html に API の URL を入れる
String withApiUrl(String html, String apiUrl) {
  final uri = Uri.tryParse(apiUrl);
  if (uri == null || !(uri.isScheme('https') || uri.isScheme('http')) || uri.host.isEmpty) {
    throw ArgumentError.value(apiUrl, 'apiUrl', 'http(s) の URL ではない');
  }
  if (apiUrlMarker.allMatches(html).length != 1) {
    throw StateError('index.html に $apiUrlMarker が1つだけ無い');
  }
  final escaped = const HtmlEscape(HtmlEscapeMode.attribute).convert(apiUrl);
  return html.replaceFirst(apiUrlMarker, '<meta name="diffnote-api" content="$escaped">');
}

/// ビルドの成果物（build/web）を直し、消したフォントを返す。確かめ終えてから書き換えるので、失敗したときは何も変えない
List<String> postBuild(Directory web, {String? apiUrl}) {
  final manifestFile = File('${web.path}/assets/FontManifest.json');
  final indexFile = File('${web.path}/index.html');
  final fonts = dropUnusedFonts(jsonDecode(manifestFile.readAsStringSync()) as List<Object?>);
  // Flutter を上げてイベント名が変わると、読み込み中の画面が消えなくなる
  if (!File('${web.path}/main.dart.js').readAsStringSync().contains(firstFrameEvent)) {
    throw StateError('main.dart.js に $firstFrameEvent が無い。web/index.html の読み込み中の画面を直す');
  }
  final html = apiUrl == null ? null : withApiUrl(indexFile.readAsStringSync(), apiUrl);

  manifestFile.writeAsStringSync(jsonEncode(fonts.manifest));
  for (final asset in fonts.dropped) {
    File('${web.path}/assets/$asset').deleteSync();
  }
  if (html != null) indexFile.writeAsStringSync(html);
  return fonts.dropped;
}

void main(List<String> args) {
  if (args.length > 1) {
    stderr.writeln('使い方: dart run tool/web_postbuild.dart [API の URL]');
    exit(64);
  }
  final dropped = postBuild(Directory('build/web'), apiUrl: args.firstOrNull);
  stdout.writeln('外したフォント:\n  ${dropped.join('\n  ')}');
  stdout.writeln(args.isEmpty ? 'API の URL は入れていない' : 'index.html に API の URL を入れた');
}
