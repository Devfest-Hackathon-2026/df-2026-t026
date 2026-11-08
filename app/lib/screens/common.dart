import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:moon_design/moon_design.dart';

import '../models.dart';
import '../theme.dart';

/// YYYY-MM-DD → 11/3
String fmtDay(String ymd) {
  final p = ymd.split('-');
  return p.length == 3 ? '${int.parse(p[1])}/${int.parse(p[2])}' : ymd;
}

/// 「- 」「## 」を外した、人に見せる形
String plain(String line) => line.replaceFirst(RegExp(r'^(## |- )'), '');

(Color, Color) kindColors(BuildContext context, Kind k) {
  final c = context.tokens.colors;
  return switch (k) {
    Kind.addition => (c.addedBg, c.added),
    Kind.qualification => (c.qualifiedBg, c.qualified),
    Kind.contradiction => (c.pendingBg, c.pending),
  };
}

/// 状態を表す小さなラベル。白フチと影でステッカーらしく見せる
class StatusTag extends StatelessWidget {
  const StatusTag(this.label, {super.key, required this.bg, required this.fg, this.onTap, this.emoji});
  final String label;
  final Color bg;
  final Color fg;
  final VoidCallback? onTap;

  /// 状態の印の絵文字（📌・✅ など）。言葉の装飾には使わない
  final String? emoji;

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    final tag = Container(
      padding: EdgeInsets.symmetric(horizontal: k.space.sm, vertical: k.space.xs),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: k.radius.control,
        border: Border.all(color: k.colors.canvas, width: k.hairline * 2),
        boxShadow: [
          BoxShadow(color: k.colors.ink.withValues(alpha: 0.12), blurRadius: k.space.xs, offset: Offset(0, k.space.xs)),
        ],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (emoji != null) ...[
          Text(emoji!, style: k.text.label),
          SizedBox(width: k.space.xs),
        ],
        Text(label, style: k.text.label.copyWith(color: fg)),
      ]),
    );
    if (onTap == null) return tag;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: onTap, child: tag),
    );
  }
}

/// 画面の地。パステルのグラデーションを敷く
class PopBackground extends StatelessWidget {
  const PopBackground({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.tokens.colors;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: c.shellGrad, begin: Alignment.topLeft, end: Alignment.bottomRight),
      ),
      child: child,
    );
  }
}

/// リキッドガラス風のタブ。白いピルが滑って移動する
class GlassTabs extends StatelessWidget {
  const GlassTabs({super.key, required this.labels, required this.index, required this.onChanged, this.emojis = const []});
  final List<String> labels;

  /// タブの印の絵文字（labels と同じ並び。無いタブは null）
  final List<String?> emojis;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    return ClipRRect(
      borderRadius: k.radius.control,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: k.glassBlur, sigmaY: k.glassBlur),
        child: Container(
          padding: EdgeInsets.all(k.space.xs),
          decoration: BoxDecoration(
            color: k.colors.glass,
            borderRadius: k.radius.control,
            border: Border.all(color: k.colors.canvas, width: k.hairline),
          ),
          child: LayoutBuilder(builder: (context, box) {
            final w = box.maxWidth / labels.length;
            return Stack(children: [
              AnimatedPositioned(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                left: w * index,
                top: 0,
                bottom: 0,
                width: w,
                child: Container(
                  decoration: BoxDecoration(
                    color: k.colors.canvas,
                    borderRadius: k.radius.control,
                    boxShadow: [
                      BoxShadow(
                          color: k.colors.ink.withValues(alpha: 0.14),
                          blurRadius: k.space.sm,
                          offset: Offset(0, k.space.xs)),
                    ],
                  ),
                ),
              ),
              Row(children: [
                for (var i = 0; i < labels.length; i++)
                  Expanded(
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onChanged(i),
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: k.space.sm),
                          child: Row(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
                            if (i < emojis.length && emojis[i] != null) ...[
                              Text(emojis[i]!, style: k.text.heading),
                              SizedBox(width: k.space.xs),
                            ],
                            Text(
                              labels[i],
                              textAlign: TextAlign.center,
                              style: k.text.heading.copyWith(color: i == index ? k.colors.ink : k.colors.inkMuted),
                            ),
                          ]),
                        ),
                      ),
                    ),
                  ),
              ]),
            ]);
          }),
        ),
      ),
    );
  }
}

/// 言われたことを貼る付箋。色と傾きは seed（名前など）から決める
class StickyNote extends StatelessWidget {
  const StickyNote({super.key, required this.seed, required this.child, this.onTap});
  final int seed;
  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    final c = k.colors;
    final color = c.stickies[seed.abs() % c.stickies.length];
    final note = Transform.rotate(
      angle: (seed.isEven ? 1 : -1) * k.stickyTilt,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            padding: EdgeInsets.fromLTRB(k.space.lg, k.space.lg, k.space.lg, k.space.md),
            decoration: BoxDecoration(
              color: color,
              borderRadius: k.radius.surface,
              boxShadow: [
                BoxShadow(color: c.ink.withValues(alpha: 0.12), blurRadius: k.space.md, offset: Offset(0, k.space.xs)),
              ],
            ),
            child: child,
          ),
          // マスキングテープ
          Positioned(
            top: -k.space.sm,
            left: 0,
            right: 0,
            child: Center(
              child: Transform.rotate(
                angle: -k.stickyTilt * 2,
                child: Container(width: k.space.xxl + k.space.xl, height: k.space.md, color: c.tape),
              ),
            ),
          ),
        ],
      ),
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
    final emoji = switch (kind) {
      Kind.addition => '➕',
      Kind.qualification => '🔖',
      Kind.contradiction => '⚡',
    };
    return StatusTag(kind.label, bg: bg, fg: fg, emoji: emoji);
  }
}

/// 上部バー。戻るボタンと、いまの場所を示すパンくず
class TopBar extends StatelessWidget {
  const TopBar({super.key, required this.crumbs, this.trailing});

  /// 画面の積み重ねと同じ順。最後がいまの画面
  final List<String> crumbs;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    final canPop = Navigator.canPop(context);
    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: k.glassBlur, sigmaY: k.glassBlur),
        child: Container(
      decoration: BoxDecoration(
        color: k.colors.glass,
        border: Border(bottom: BorderSide(color: k.colors.canvas, width: k.hairline)),
      ),
      padding: EdgeInsets.symmetric(horizontal: k.space.md, vertical: k.space.sm),
      child: SafeArea(
        bottom: false,
        child: Row(children: [
          if (canPop) ...[
            MoonButton.icon(
              semanticLabel: '戻る',
              icon: Icon(LucideIcons.arrowLeft, color: k.colors.ink),
              onTap: () => Navigator.maybePop(context),
            ),
            SizedBox(width: k.space.xs),
          ] else
            SizedBox(width: k.space.sm),
          Expanded(
            child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
              for (var i = 0; i < crumbs.length; i++) ...[
                if (i > 0) Text(' / ', style: k.text.small),
                _crumb(context, i),
              ],
            ]),
          ),
          ?trailing,
        ]),
      ),
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
  const PageTitle(this.title, {super.key, this.meta = const [], this.trailing, this.emoji});
  final String title;

  /// 1つずつ別の要素として並べる（・でつながない）
  final List<Widget> meta;
  final Widget? trailing;

  /// 画面の印の絵文字。丸いバッジに入れて題名の横に置く
  final String? emoji;

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (emoji != null) ...[
        Container(
          padding: EdgeInsets.all(k.space.md),
          decoration: BoxDecoration(color: k.colors.accentSoft, borderRadius: k.radius.surface),
          child: Text(emoji!, style: k.text.title),
        ),
        SizedBox(width: k.space.lg),
      ],
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Text(title, style: k.text.display)),
            if (trailing != null) ...[SizedBox(width: k.space.lg), trailing!],
          ]),
          if (meta.isNotEmpty) ...[
            SizedBox(height: k.space.sm),
            Wrap(spacing: k.space.lg, runSpacing: k.space.xs, crossAxisAlignment: WrapCrossAlignment.center, children: meta),
          ],
        ]),
      ),
    ]);
  }
}

/// マニュアルの1行（## を見出し、- を箇条書きとして扱う）
class LineText extends StatelessWidget {
  const LineText(this.line, {super.key});
  final String line;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens.text;
    if (line.startsWith('## ')) return Text(line.substring(3), style: t.title);
    return Text(line.startsWith('- ') ? '・${line.substring(2)}' : line, style: t.body);
  }
}

/// 名前の頭文字のアバター。色は名前から決める
class Avatar extends StatelessWidget {
  const Avatar(this.name, {super.key});
  final String? name;

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    final n = name == null || name!.isEmpty ? '?' : name!;
    final colors = k.colors.avatars;
    return MoonAvatar(
      avatarSize: MoonAvatarSize.xs,
      borderRadius: k.radius.round,
      backgroundColor: colors[n.codeUnits.fold(0, (a, b) => a + b) % colors.length],
      content: Text(n.characters.first, style: k.text.label),
    );
  }
}

/// 誰が・いつ言ったか
class Speaker extends StatelessWidget {
  const Speaker({super.key, required this.name, required this.day, this.onTap});
  final String? name;
  final String day;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    final row = Row(mainAxisSize: MainAxisSize.min, children: [
      Avatar(name),
      SizedBox(width: k.space.sm),
      Text(name ?? '発言者未入力', style: k.text.small.copyWith(color: k.colors.ink)),
      SizedBox(width: k.space.sm),
      Text(fmtDay(day), style: k.text.small),
    ]);
    if (onTap == null) return row;
    return MouseRegion(cursor: SystemMouseCursors.click, child: GestureDetector(onTap: onTap, child: row));
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
          Expanded(child: Text(text.startsWith('- ') ? '・${text.substring(2)}' : plain(text), style: k.text.body.copyWith(color: fg))),
        ]),
      );
}

/// 衝突を左右に並べて見せる。「マニュアル：塩 小さじ1 ／ 田中さん（11/3）：小さじ1/2」
/// どちらが正しいかはアプリが決めないので、左右は同じ色。未解決であることだけを中央の黄の帯で示す。
/// マニュアル側は印字、言われた側は手書きの書体にして、文書と口頭の違いを見せる
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
    Widget side(String label, String text, TextStyle style, Color header) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(
              color: header,
              padding: EdgeInsets.symmetric(horizontal: k.space.lg, vertical: k.space.sm),
              child: Text(label, style: k.text.small.copyWith(color: k.colors.ink, fontWeight: FontWeight.w700)),
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
        borderRadius: k.radius.surface,
        boxShadow: [
          BoxShadow(color: c.ink.withValues(alpha: 0.08), blurRadius: k.space.lg, offset: Offset(0, k.space.xs)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          side(leftLabel, left, k.text.title, c.shell),
          Container(
            width: k.space.xl + k.space.sm,
            color: settled ? c.addedBg : c.pendingBg,
            alignment: Alignment.center,
            child: Container(
              padding: EdgeInsets.all(k.space.sm),
              decoration: BoxDecoration(color: c.canvas, shape: BoxShape.circle),
              child: Text(settled ? '✅' : '⚡', style: k.text.heading),
            ),
          ),
          side(rightLabel, right, k.text.handLarge, c.stickies.first),
        ]),
      ),
    );
  }
}

/// マニュアル本文を載せる白い紙。上の両端をテープで留めた形にする
class PaperSheet extends StatelessWidget {
  const PaperSheet({super.key, required this.child, required this.padding});
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    final c = k.colors;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          padding: padding,
          decoration: BoxDecoration(
            color: c.canvas,
            borderRadius: k.radius.surface,
            boxShadow: [
              BoxShadow(color: c.ink.withValues(alpha: 0.10), blurRadius: k.space.xl, offset: Offset(0, k.space.sm)),
            ],
          ),
          child: child,
        ),
        for (final side in [0, 1])
          Positioned(
            top: -k.space.sm,
            left: side == 0 ? k.space.xxl : null,
            right: side == 1 ? k.space.xxl : null,
            child: Transform.rotate(
              angle: (side == 0 ? -1 : 1) * k.stickyTilt * 3,
              child: Container(width: k.space.xxl + k.space.xl, height: k.space.md, color: c.tape),
            ),
          ),
      ],
    );
  }
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

void showToast(BuildContext context, String message, {bool error = false}) {
  final k = context.tokens;
  MoonToast.show(
    context,
    backgroundColor: k.colors.ink,
    toastShadows: const [],
    leading: Icon(error ? LucideIcons.circleAlert : LucideIcons.check, color: k.colors.canvas),
    label: Text(message, style: k.text.body.copyWith(color: k.colors.canvas)),
  );
}

void showError(BuildContext context, Object e) => showToast(context, e.toString(), error: true);
