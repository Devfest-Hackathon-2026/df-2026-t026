// Web のリリースビルドのあと、デプロイの前に走らせる（.github/workflows/deploy.yml。設計書 0021 の A2）。
//   dart run tool/web_postbuild.dart [API の URL]
// Flutter Web は FontManifest.json のフォントを最初の画面の前に全部取りに行くので、
// 依存のパッケージが宣言しているだけで使っていないフォントを外し、1字しか使わない MoonIcons は絞ったものに差し替える。
// dart run で動くよう、Flutter に依存するものは import しない。
import 'dart:convert';
import 'dart:io';

/// アプリが使う Lucide（`LucideIcons`、既定の太さ）。残す
const lucideFamily = 'packages/lucide_icons_flutter/Lucide';

/// Lucide の太さ違い（Lucide100〜600）。アプリは使わない。
/// MoonIcons は外さない。MoonTextInput に errorText を渡すと MoonIcons の字を描く（review_dialog.dart）
final _lucideWeights = RegExp(r'^packages/lucide_icons_flutter/Lucide\d+$');

/// main.dart.js の中で、Lucide の太さ違いの family を使っている所（IconData の fontFamily）
final _lucideWeightInJs = RegExp(r'''["']Lucide\d+["']''');

/// ビルドの MoonIcons（assets/ からの道）。マニフェストの family と道はそのままにし、中身だけ差し替える
const moonIconsAsset = 'packages/moon_icons/lib/fonts/MoonIcons.ttf';

/// 使う字だけに絞った MoonIcons（tool/moon_icons/README.md）
const moonIconsSubset = 'tool/moon_icons/MoonIcons.ttf';

/// 絞ったフォントに入っている字。作り直すときは pyftsubset の --unicodes と揃える
const moonIconsCodePoints = {0xED49};

/// main.dart.js の MoonIcons の IconData。dart2js は `new A.dg(60745,"MoonIcons","moon_icons",!1)` のように出す。
/// `A.dg` は IconData の縮めた名前で、ビルドごとに変わるので見ない
final _moonIconData = RegExp(r'\((\d+),"MoonIcons","moon_icons"');

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

/// main.dart.js が描く MoonIcons の字が、絞ったフォントに全部あるかを見る。差し替えてよければ null、だめなら理由を返す。
/// 無い字を描くと豆腐（□）になるので、拾い漏らしたかもしれないとき（MoonIcons の出てくる回数が IconData の数と合わない、
/// 1つも拾えない）も差し替えない
String? moonIconsSubsetBlocker(String mainJs) {
  final found = [for (final m in _moonIconData.allMatches(mainJs)) int.parse(m[1]!)];
  final mentions = 'MoonIcons'.allMatches(mainJs).length;
  if (found.isEmpty || found.length != mentions) {
    return 'main.dart.js の MoonIcons を読み切れない（IconData ${found.length} 個、MoonIcons の文字列 $mentions 回）';
  }
  final missing = found.toSet().difference(moonIconsCodePoints);
  if (missing.isNotEmpty) {
    final names = missing.map((c) => 'U+${c.toRadixString(16).toUpperCase()}').join(', ');
    return '絞ったフォントに無い字を使っている（$names）。tool/moon_icons/README.md の手順で作り直す';
  }
  return null;
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

/// ビルドの成果物（build/web）を直し、消したフォントと、MoonIcons を差し替えなかった理由（差し替えたら null）を返す。
/// 確かめ終えてから書き換えるので、失敗したときは何も変えない
({List<String> dropped, String? moonIconsKept}) postBuild(Directory web, {String? apiUrl}) {
  final manifestFile = File('${web.path}/assets/FontManifest.json');
  final indexFile = File('${web.path}/index.html');
  final moonIconsFile = File('${web.path}/assets/$moonIconsAsset');
  final fonts = dropUnusedFonts(jsonDecode(manifestFile.readAsStringSync()) as List<Object?>);
  final js = File('${web.path}/main.dart.js').readAsStringSync();
  // Flutter を上げてイベント名が変わると、読み込み中の画面が消えなくなる
  if (!js.contains(firstFrameEvent)) {
    throw StateError('main.dart.js に $firstFrameEvent が無い。web/index.html の読み込み中の画面を直す');
  }
  // アプリが太さ違いを使っているのに外すと、そのアイコンが豆腐になる
  if (_lucideWeightInJs.firstMatch(js) case final used?) {
    throw StateError('main.dart.js が Lucide の太さ違い ${used[0]} を使っている。外せない');
  }
  final missing = fonts.dropped.where((asset) => !File('${web.path}/assets/$asset').existsSync()).toList();
  if (missing.isNotEmpty) {
    throw StateError('消すはずのフォントが無い: ${missing.join(', ')}');
  }
  final html = apiUrl == null ? null : withApiUrl(indexFile.readAsStringSync(), apiUrl);
  final moonIconsKept = moonIconsFile.existsSync() ? moonIconsSubsetBlocker(js) : 'ビルドに $moonIconsAsset が無い';
  final subset = moonIconsKept == null ? File(moonIconsSubset).readAsBytesSync() : null;

  manifestFile.writeAsStringSync(jsonEncode(fonts.manifest));
  for (final asset in fonts.dropped) {
    File('${web.path}/assets/$asset').deleteSync();
  }
  if (subset != null) moonIconsFile.writeAsBytesSync(subset);
  if (html != null) indexFile.writeAsStringSync(html);
  return (dropped: fonts.dropped, moonIconsKept: moonIconsKept);
}

void main(List<String> args) {
  if (args.length > 1) {
    stderr.writeln('使い方: dart run tool/web_postbuild.dart [API の URL]');
    exit(64);
  }
  final r = postBuild(Directory('build/web'), apiUrl: args.firstOrNull);
  stdout.writeln('外したフォント:\n  ${r.dropped.join('\n  ')}');
  // 残したときもデプロイは止めない。元のフォントなら最初の表示が重いだけで、字は出る
  stdout.writeln(r.moonIconsKept == null
      ? 'MoonIcons.ttf を使う字だけに絞ったものに差し替えた'
      : 'MoonIcons.ttf は差し替えずに元のまま残した: ${r.moonIconsKept}');
  stdout.writeln(args.isEmpty ? 'API の URL は入れていない' : 'index.html に API の URL を入れた');
}
