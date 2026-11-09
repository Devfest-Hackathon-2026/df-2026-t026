import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:moon_design/moon_design.dart';

import '../models.dart';
import '../theme.dart';
import 'help_screen.dart';
import 'sidebar.dart';

/// YYYY-MM-DD → 11/3
String fmtDay(String ymd) {
  final p = ymd.split('-');
  return p.length == 3 ? '${int.parse(p[1])}/${int.parse(p[2])}' : ymd;
}

// ノートは1行を1まとまりとするマークダウン。表やコードブロックのように複数行にまたがる書き方は読まない（ADR 0009）
final _heading = RegExp(r'^(#{1,6})[ \t]+(.*)');
final _rule = RegExp(r'^ {0,3}([-*_])(\s*\1){2,}\s*$');
final _block = RegExp(r'^([ \t]*)([-*+][ \t]+|\d+[.)][ \t]+|>[ \t]?)?(.*)');
final _md = md.Document(extensionSet: md.ExtensionSet.gitHubFlavored, encodeHtml: false);

/// 見出しの行か（「# 」〜「###### 」）
bool isHeading(String line) => _heading.hasMatch(line);

/// 区切り線の行か（「---」など）
bool isRule(String line) => _rule.hasMatch(line);

/// 行頭と行の中のマークダウンの印を外した、文の中に出す形。パッチは複数行のこともあるので1行ずつ外す
String plain(String text) => text.split('\n').map((line) {
      final body = _heading.firstMatch(line)?[2] ?? _block.firstMatch(line)![3]!;
      return _md.parseInline(body).map((n) => n.textContent).join();
    }).join('\n');

(Color, Color) kindColors(BuildContext context, Kind k) {
  final c = context.tokens.colors;
  return switch (k) {
    // 本文を変えないので、差分や状態の色を付けない
    Kind.same => (c.rule, c.inkMuted),
    Kind.addition => (c.addedBg, c.added),
    Kind.qualification => (c.qualifiedBg, c.qualified),
    Kind.contradiction => (c.pendingBg, c.pending),
  };
}

/// 状態を表す小さなラベル
class StatusTag extends StatelessWidget {
  const StatusTag(this.label, {super.key, required this.bg, required this.fg, this.onTap});
  final String label;
  final Color bg;
  final Color fg;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => MoonTag(
        tagSize: MoonTagSize.xs,
        backgroundColor: bg,
        borderRadius: context.tokens.radius.round,
        onTap: onTap,
        label: Text(label, style: context.tokens.text.label.copyWith(color: fg)),
      );
}

/// 言われたことを貼る付箋。ホワイトボードの付箋のように、傾けずに置き、下側にだけ影を付ける
class StickyNote extends StatelessWidget {
  const StickyNote({super.key, required this.child, this.onTap});
  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    final c = k.colors;
    final note = Container(
      padding: EdgeInsets.fromLTRB(k.space.lg, k.space.lg, k.space.lg, k.space.md),
      decoration: BoxDecoration(
        color: c.sticky,
        borderRadius: k.radius.paper,
        boxShadow: [
          BoxShadow(color: c.ink.withValues(alpha: 0.16), blurRadius: k.space.sm, offset: Offset(0, k.space.xs)),
        ],
      ),
      child: child,
    );
    if (onTap == null) return note;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: onTap, child: note),
    );
  }
}

class KindTag extends StatelessWidget {
  const KindTag(this.kind, {super.key});
  final Kind kind;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = kindColors(context, kind);
    return StatusTag(kind.label, bg: bg, fg: fg);
  }
}

/// 上部バー。戻るボタンと、いまの場所を示すパンくず
class TopBar extends StatelessWidget {
  const TopBar({super.key, required this.crumbs, this.trailing, this.leading, this.help = true});

  /// 画面の積み重ねと同じ順。最後がいまの画面
  final List<String> crumbs;
  final Widget? trailing;

  /// 戻る先の無い画面（入力ページ）の左に置くボタン。狭い画面のメニュー（三本線）に使う
  final Widget? leading;

  /// 右端に使い方への（?）を出すか。使い方のページ自身では出さない
  final bool help;

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    final canPop = Navigator.canPop(context);
    return Container(
      decoration: BoxDecoration(
        color: k.colors.canvas,
        border: Border(bottom: BorderSide(color: k.colors.rule, width: k.hairline)),
      ),
      padding: EdgeInsets.symmetric(horizontal: k.space.md, vertical: k.space.sm),
      child: SafeArea(
        bottom: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: k.barHeight),
          child: Row(children: [
            if (canPop) ...[
              MoonButton.icon(
                semanticLabel: '戻る',
                icon: Icon(LucideIcons.arrowLeft, color: k.colors.ink),
                onTap: () => Navigator.maybePop(context),
              ),
              SizedBox(width: k.space.xs),
            ] else if (leading != null) ...[
              leading!,
              SizedBox(width: k.space.xs),
            ] else
              SizedBox(width: k.space.sm),
            Expanded(
              // スマホ（サイドバーの出ない幅）では、パンくずを出さず、いまの画面の名前だけにする。前の画面へは戻る矢印で戻る
              child: showsSidebar(context)
                  ? Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
                      for (var i = 0; i < crumbs.length; i++) ...[
                        if (i > 0) Text(' / ', style: k.text.small),
                        _crumb(context, i),
                      ],
                    ])
                  : Text(crumbs.last, maxLines: 1, overflow: TextOverflow.ellipsis, style: k.text.heading),
            ),
            ?trailing,
            if (help) ...[
              SizedBox(width: k.space.xs),
              MoonButton.icon(
                semanticLabel: '使い方を見る',
                icon: Icon(LucideIcons.circleQuestionMark, color: k.colors.ink),
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HelpScreen())),
              ),
            ],
          ]),
        ),
      ),
    );
  }

  Widget _crumb(BuildContext context, int i) {
    final k = context.tokens;
    final last = i == crumbs.length - 1;
    final text = Text(
      crumbs[i],
      overflow: TextOverflow.ellipsis,
      style: last ? k.text.heading : k.text.body.copyWith(color: k.colors.inkMuted),
    );
    if (last) return text;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () {
          var n = crumbs.length - 1 - i;
          Navigator.popUntil(context, (_) => n-- == 0);
        },
        child: text,
      ),
    );
  }
}

/// 内容の頭に置く題名と、その下のメタ情報
class PageTitle extends StatelessWidget {
  const PageTitle(this.title, {super.key, this.meta = const [], this.trailing});
  final String title;

  /// 1つずつ別の要素として並べる（・でつながない）
  final List<Widget> meta;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: Text(title, style: k.text.display)),
        if (trailing != null) ...[SizedBox(width: k.space.lg), trailing!],
      ]),
      if (meta.isNotEmpty) ...[
        SizedBox(height: k.space.sm),
        Wrap(spacing: k.space.lg, runSpacing: k.space.xs, crossAxisAlignment: WrapCrossAlignment.center, children: meta),
      ],
    ]);
  }
}

/// ノートの1行をマークダウンとして描く
class LineText extends StatelessWidget {
  const LineText(this.line, {super.key, this.color, this.compact = false, this.mark});
  final String line;

  /// 地を付けて見せる言葉（ノートを探して開いたとき）。英字の大文字・小文字は区別しない
  final String? mark;

  /// 差分の増減など、文字の色を変えるとき
  final Color? color;

  /// 差分の一覧など、見出しを本文に近い大きさで出すとき
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    final t = k.text;
    final head = _heading.firstMatch(line);
    if (head != null) {
      final level = head[1]!.length;
      final style = compact || level > 2 ? t.heading : (level == 1 ? t.display : t.title);
      return _inline(k, head[2]!, style.copyWith(color: color));
    }
    if (isRule(line)) return Container(height: k.hairline, color: k.colors.rule);
    final m = _block.firstMatch(line)!;
    final mark = m[2]?.trim() ?? '';
    final quote = mark == '>';
    final text = _inline(
      k,
      m[3]!,
      (quote ? t.body.copyWith(color: k.colors.inkMuted) : t.body).copyWith(color: color),
      prefix: switch (mark) { '' || '>' => '', '-' || '*' || '+' => '・', _ => '$mark ' },
    );
    final level = m[1]!.replaceAll('\t', '  ').length ~/ 2 + (quote ? 1 : 0);
    return level == 0 ? text : Padding(padding: EdgeInsets.only(left: k.space.lg * level), child: text);
  }

  Widget _inline(AppTokens k, String text, TextStyle style, {String prefix = ''}) =>
      Text.rich(TextSpan(style: style, children: [TextSpan(text: prefix), ..._spans(k, _md.parseInline(text), style)]));

  List<InlineSpan> _spans(AppTokens k, List<md.Node> nodes, TextStyle s) => [
        for (final n in nodes)
          if (n is md.Element && n.children != null)
            TextSpan(children: _spans(k, n.children!, _style(k, n.tag, s)))
          else
            ..._marked(k, n.textContent, s),
      ];

  // 太字などの印をまたいだ所には付けない（印ごとに分かれた文字の中だけで探す）
  List<TextSpan> _marked(AppTokens k, String text, TextStyle s) {
    final q = mark?.toLowerCase() ?? '';
    if (q.isEmpty) return [TextSpan(text: text, style: s)];
    final lower = text.toLowerCase();
    final spans = <TextSpan>[];
    var at = 0;
    for (var i = lower.indexOf(q); i >= 0; i = lower.indexOf(q, at)) {
      spans
        ..add(TextSpan(text: text.substring(at, i), style: s))
        ..add(TextSpan(text: text.substring(i, i + q.length), style: s.copyWith(backgroundColor: k.colors.found)));
      at = i + q.length;
    }
    return spans..add(TextSpan(text: text.substring(at), style: s));
  }

  // リンクは押せるようにしない。行を押すと編集が開くので、押し分けられない（ADR 0009）
  TextStyle _style(AppTokens k, String tag, TextStyle s) => switch (tag) {
        'strong' => s.copyWith(fontWeight: FontWeight.w700),
        'em' => s.copyWith(fontStyle: FontStyle.italic),
        'del' => s.copyWith(decoration: TextDecoration.lineThrough),
        'code' => s.copyWith(backgroundColor: k.colors.shell),
        'a' => s.copyWith(color: k.colors.action, decoration: TextDecoration.underline),
        _ => s,
      };
}

/// 名前の頭文字のアバター。image があれば、その画像を出す
class Avatar extends StatelessWidget {
  const Avatar(this.name, {super.key, this.image, this.large = false});
  final String? name;
  final Uint8List? image;

  /// 名前とアイコンのページで大きく出す
  final bool large;

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    final n = name == null || name!.isEmpty ? '?' : name!;
    return MoonAvatar(
      avatarSize: large ? MoonAvatarSize.x2l : MoonAvatarSize.xs,
      borderRadius: k.radius.round,
      backgroundColor: k.colors.avatar,
      backgroundImage: image == null ? null : MemoryImage(image!),
      content: image == null ? Text(n.characters.first, style: large ? k.text.display : k.text.label) : null,
    );
  }
}

/// 発言者の丸。名前から決まったイラストの顔（Open Peeps、assets/avatars/）を出す。同じ名前はいつも同じ顔。
/// 発言者は名前の文字だけで持っているので、顔は保存せずに毎回名前から選ぶ。
/// 名前が無いときと「自分」は、ログインする人のアイコン（Avatar）と同じ頭文字の丸のまま
class SpeakerFace extends StatelessWidget {
  const SpeakerFace(this.name, {super.key});
  final String? name;

  /// 顔の枚数（assets/avatars/peep-1.png〜）
  static const faces = 8;

  /// 名前から顔の番号（0〜faces-1）を選ぶ。String.hashCode は実行のたびに変わりうるので使わず、
  /// 文字コードから毎回同じになる計算（FNV-1a 32bit）にする。Web では数が 2^53 を超えると狂うので、
  /// 掛け算を分けて 32bit に収める。見本の名前（店長・田中さん・佐藤さん・鈴木さん など）どうしで顔がかぶらないよう、
  /// 上の桁を混ぜてから 8 で割る
  static int faceOf(String name) {
    var h = 0x811c9dc5;
    for (final c in name.codeUnits) {
      h = (h ^ c) & 0xffffffff;
      // h * 16777619（0x01000193 = 2^24 + 0x193）を 32bit で
      h = ((h * 0x193) + ((h << 24) & 0xffffffff)) & 0xffffffff;
    }
    return ((h ^ (h >> 13)) & 0xffffffff) % faces;
  }

  static String assetOf(String name) => 'assets/avatars/peep-${faceOf(name) + 1}.png';

  @override
  Widget build(BuildContext context) {
    final n = name;
    if (n == null || n.trim().isEmpty || n == '自分') return Avatar(n);
    final k = context.tokens;
    // 読み上げは今までどおり名前（顔の絵は読ませない）
    return Semantics(
      label: n,
      excludeSemantics: true,
      child: MoonAvatar(
        avatarSize: MoonAvatarSize.xs,
        borderRadius: k.radius.round,
        backgroundColor: k.colors.avatar,
        backgroundImage: AssetImage(assetOf(n)),
      ),
    );
  }
}

/// 誰が・いつ言ったか
class Speaker extends StatelessWidget {
  const Speaker({super.key, required this.name, required this.day, this.after, this.onTap});
  final String? name;
  final String day;

  /// 日付の後ろに添える言葉（例：「に確認」）。添えた言葉も含めてひとまとまりで押せる
  final String? after;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    final row = Row(mainAxisSize: MainAxisSize.min, children: [
      SpeakerFace(name),
      SizedBox(width: k.space.sm),
      Text(name ?? '発言者未入力', style: k.text.small.copyWith(color: k.colors.ink)),
      SizedBox(width: k.space.sm),
      Text(fmtDay(day), style: k.text.small),
      if (after != null) ...[SizedBox(width: k.space.sm), Text(after!, style: k.text.small)],
    ]);
    if (onTap == null) return row;
    // アイコンと名前の間のすき間を押しても、下の行（押すと書き換えの欄が開く）でなく、こちらが受ける
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: row),
    );
  }
}

/// 確認して確定したことの印。日付印（上に「確認」、帯に日付、下に確認した相手）の形
class ConfirmStamp extends StatelessWidget {
  const ConfirmStamp({super.key, required this.who, required this.day, this.compact = false, this.onTap});
  final String who;
  final String day;

  /// マニュアルの行に添える小さい形（1行）
  final bool compact;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    final ink = k.text.label.copyWith(color: k.colors.stamp);
    final line = BorderSide(color: k.colors.stamp, width: k.hairline);
    final Widget stamp;
    if (compact) {
      stamp = Container(
        padding: EdgeInsets.symmetric(horizontal: k.space.sm, vertical: k.space.xs),
        decoration: BoxDecoration(border: Border.fromBorderSide(line), borderRadius: k.radius.control),
        child: Text('${fmtDay(day)} $whoに確認', style: ink),
      );
    } else {
      stamp = Container(
        width: k.stampDiameter,
        height: k.stampDiameter,
        decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: k.colors.stamp.withValues(alpha: 0.06),
            border: Border.fromBorderSide(line.copyWith(width: k.hairline * 2))),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text('確認', style: ink),
          Container(
            margin: EdgeInsets.symmetric(vertical: k.space.xs),
            padding: EdgeInsets.symmetric(horizontal: k.space.sm),
            decoration: BoxDecoration(border: Border(top: line, bottom: line)),
            child: Text(fmtDay(day), style: ink),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: k.space.md),
            child: FittedBox(fit: BoxFit.scaleDown, child: Text(who, style: ink)),
          ),
        ]),
      );
    }
    final tilted = Transform.rotate(angle: k.stampTilt, child: stamp);
    if (onTap == null) return tilted;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: onTap, child: tilted),
    );
  }
}

/// パッチを赤緑の行差分で見せる
class PatchDiff extends StatelessWidget {
  const PatchDiff({super.key, required this.op, required this.line, required this.text});
  final String op;
  final String? line;
  final String text;

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    final c = k.colors;
    return Container(
      decoration: BoxDecoration(
        color: c.canvas,
        border: Border.all(color: c.rule, width: k.hairline),
        borderRadius: k.radius.surface,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (line != null)
          op == 'replace' ? _row(k, '−', line!, c.removedBg, c.removed) : _row(k, ' ', line!, null, c.inkMuted),
        for (final l in text.split('\n')) _row(k, '+', l, c.addedBg, c.added),
      ]),
    );
  }

  Widget _row(AppTokens k, String mark, String text, Color? bg, Color fg) => Container(
        color: bg,
        padding: EdgeInsets.symmetric(horizontal: k.space.md, vertical: k.space.xs),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: k.space.lg, child: Text(mark, style: k.text.body.copyWith(color: fg))),
          Expanded(child: LineText(text, color: fg, compact: true)),
        ]),
      );
}

/// 衝突を左右に並べて見せる。「マニュアル：塩 小さじ1 ／ 田中さん（11/3）：小さじ1/2」
/// どちらが正しいかはアプリが決めないので、左右は同じ色。未解決であることだけを中央の黄の帯で示す。
class ConflictPair extends StatelessWidget {
  const ConflictPair({
    super.key,
    required this.leftLabel,
    required this.left,
    required this.rightLabel,
    required this.right,
    this.settled = false,
  });
  final String leftLabel;
  final String left;
  final String rightLabel;
  final String right;

  /// 確認して確定済み。あとで確認の黄をやめる
  final bool settled;

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    final c = k.colors;
    Widget side(String label, String text, TextStyle style) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(
              color: c.shell,
              padding: EdgeInsets.symmetric(horizontal: k.space.lg, vertical: k.space.sm),
              child: Text(label, style: k.text.small),
            ),
            Padding(
              padding: EdgeInsets.all(k.space.lg),
              child: Text(plain(text), style: style),
            ),
          ]),
        );
    return Container(
      decoration: BoxDecoration(
        color: c.canvas,
        border: Border.all(color: c.rule, width: k.hairline),
        borderRadius: k.radius.surface,
      ),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          side(leftLabel, left, k.text.title),
          Container(
            width: k.space.xl + k.space.sm,
            color: settled ? c.shell : c.pendingBg,
            alignment: Alignment.center,
            child: Text('／', style: k.text.heading.copyWith(color: settled ? c.inkMuted : c.pending)),
          ),
          side(rightLabel, right, k.text.title),
        ]),
      ),
    );
  }
}

/// マニュアル本文や入力欄を載せる白い面。ホワイトボードのフレームのように、影を付けずに方眼の上に置く
class PaperSheet extends StatelessWidget {
  const PaperSheet({super.key, required this.child, required this.padding});
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    return Container(
      padding: padding,
      decoration: BoxDecoration(color: k.colors.canvas, borderRadius: k.radius.paper),
      child: child,
    );
  }
}

/// 画面の地。ホワイトボードのような方眼を敷く
class GridBackground extends StatelessWidget {
  const GridBackground({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    return CustomPaint(
      painter: _GridPainter(color: k.colors.grid, step: k.space.xl, width: k.hairline),
      child: child,
    );
  }
}

class _GridPainter extends CustomPainter {
  _GridPainter({required this.color, required this.step, required this.width});
  final Color color;
  final double step;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = color
      ..strokeWidth = width;
    for (var x = 0.0; x <= size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
    }
    for (var y = 0.0; y <= size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) => old.color != color || old.step != step || old.width != width;
}

/// 罫線
class Rule extends StatelessWidget {
  const Rule({super.key});

  @override
  Widget build(BuildContext context) => Container(height: context.tokens.hairline, color: context.tokens.colors.rule);
}

/// 幅を抑えて中央に置く
class Narrow extends StatelessWidget {
  const Narrow({super.key, required this.child, this.maxWidth});
  final Widget child;

  /// 省略時は本文の幅（readableWidth）
  final double? maxWidth;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth ?? context.tokens.readableWidth),
          child: child,
        ),
      );
}

class Loading extends StatelessWidget {
  const Loading({super.key});

  @override
  Widget build(BuildContext context) => Center(child: MoonCircularLoader(color: context.tokens.colors.ink));
}

/// 読み込みに失敗したときの表示。再読み込みの操作を必ず付ける
class LoadFailed extends StatelessWidget {
  const LoadFailed({super.key, required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    return Center(
      child: Padding(
        padding: EdgeInsets.all(k.space.xl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(LucideIcons.cloudOff, color: k.colors.inkMuted),
          SizedBox(height: k.space.md),
          Text('読み込めませんでした：$message', style: k.text.body, textAlign: TextAlign.center),
          SizedBox(height: k.space.lg),
          MoonOutlinedButton(
            label: const Text('もう一度読み込む'),
            onTap: onRetry,
          ),
        ]),
      ),
    );
  }
}

/// 送信中はボタンの中に出す読み込み中の印
class ButtonLoader extends StatelessWidget {
  const ButtonLoader({super.key});

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: context.tokens.space.lg,
        child: MoonCircularLoader(
          color: context.tokens.colors.canvas,
          circularLoaderSize: MoonCircularLoaderSize.x2s,
        ),
      );
}

/// action は知らせの右に置く操作。押す間を残すため、付けたときは長めに出す
void showToast(BuildContext context, String message,
    {bool error = false, ({String label, VoidCallback onTap})? action}) {
  final k = context.tokens;
  MoonToast.show(
    context,
    backgroundColor: k.colors.ink,
    toastShadows: const [],
    displayDuration: action == null ? null : const Duration(seconds: 6),
    leading: Icon(error ? LucideIcons.circleAlert : LucideIcons.check, color: k.colors.canvas),
    label: Text(message, style: k.text.body.copyWith(color: k.colors.canvas)),
    trailing: action == null
        ? null
        : MoonTextButton(
            onTap: () {
              MoonToast.clearToastQueue();
              action.onTap();
            },
            label: Text(action.label, style: k.text.label.copyWith(color: k.colors.canvas)),
          ),
  );
}

void showError(BuildContext context, Object e) => showToast(context, e.toString(), error: true);
