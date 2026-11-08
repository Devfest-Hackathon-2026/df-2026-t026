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

class KindTag extends StatelessWidget {
  const KindTag(this.kind, {super.key});
  final Kind kind;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = kindColors(context, kind);
    return MoonTag(
      tagSize: MoonTagSize.xs,
      backgroundColor: bg,
      borderRadius: context.tokens.radius.control,
      label: Text(kind.label, style: context.tokens.text.label.copyWith(color: fg)),
    );
  }
}

/// 戻るボタンと題名。AppBar の代わり
class PageHeader extends StatelessWidget {
  const PageHeader({super.key, required this.title, this.trailing, this.wide = false});
  final String title;
  final Widget? trailing;

  /// 本文が画面幅いっぱいのとき true。false なら本文（Narrow）と端を揃える
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    final canPop = Navigator.canPop(context);
    final row = Row(children: [
      if (canPop) ...[
        MoonButton.icon(
          semanticLabel: '戻る',
          icon: Icon(LucideIcons.arrowLeft, color: k.colors.ink),
          onTap: () => Navigator.maybePop(context),
        ),
        SizedBox(width: k.space.xs),
      ],
      Expanded(child: Text(title, style: k.text.title, overflow: TextOverflow.ellipsis)),
      ?trailing,
    ]);
    return Container(
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: k.colors.rule, width: k.hairline))),
      padding: EdgeInsets.symmetric(vertical: k.space.md),
      child: SafeArea(
        bottom: false,
        child: wide
            ? Padding(padding: EdgeInsets.symmetric(horizontal: k.space.sm), child: row)
            : Narrow(child: Padding(padding: EdgeInsets.symmetric(horizontal: k.space.xl), child: row)),
      ),
    );
  }
}

/// マニュアルの1行（## を見出し、- を箇条書きとして扱う）
class LineText extends StatelessWidget {
  const LineText(this.line, {super.key});
  final String line;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens.text;
    if (line.startsWith('## ')) return Text(line.substring(3), style: t.heading);
    return Text(line.startsWith('- ') ? '・${line.substring(2)}' : line, style: t.body);
  }
}

/// 口頭で言われたことの発言者と日付。マスキングテープのラベルに見立てる
class SpeakerTape extends StatelessWidget {
  const SpeakerTape({super.key, required this.speaker, required this.day, this.onTap});
  final String? speaker;
  final String day;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    return MoonTag(
      tagSize: MoonTagSize.xs,
      backgroundColor: k.colors.tape,
      borderRadius: k.radius.tape,
      onTap: onTap,
      label: Text('${speaker ?? '発言者未入力'} ${fmtDay(day)}', style: k.text.hand.copyWith(fontSize: k.text.small.fontSize)),
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
        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.fromBorderSide(line.copyWith(width: k.hairline * 2))),
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
        color: c.sheet,
        border: Border.all(color: c.rule, width: k.hairline),
        borderRadius: k.radius.control,
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

/// 衝突を並べて見せる。「マニュアル：塩 小さじ1 ／ 田中さん（11/3）：小さじ1/2」
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

  /// 確認して確定済み。確認待ち（付箋）の色をやめる
  final bool settled;

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    final c = k.colors;
    Widget side(String label, String text, TextStyle style) => Expanded(
          child: Padding(
            padding: EdgeInsets.all(k.space.lg),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: k.text.small),
              SizedBox(height: k.space.sm),
              Text(plain(text), style: style),
            ]),
          ),
        );
    return Container(
      decoration: BoxDecoration(
        color: c.sheet,
        border: Border.all(color: settled ? c.rule : c.pending, width: k.hairline),
        borderRadius: k.radius.surface,
      ),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          side(leftLabel, left, k.text.title),
          Container(
            width: k.space.xl + k.space.sm,
            color: settled ? c.paper : c.pendingBg,
            alignment: Alignment.center,
            child: Text('／', style: k.text.heading.copyWith(color: settled ? c.inkMuted : c.pending)),
          ),
          side(rightLabel, right, k.text.handLarge),
        ]),
      ),
    );
  }
}

/// 一覧の区切りの見出し
class SectionHeading extends StatelessWidget {
  const SectionHeading(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    return Padding(
      padding: EdgeInsets.fromLTRB(k.space.lg, k.space.xl, k.space.lg, k.space.sm),
      child: Text(text, style: k.text.heading),
    );
  }
}

/// 罫線
class Rule extends StatelessWidget {
  const Rule({super.key, this.indent = 0});
  final double indent;

  @override
  Widget build(BuildContext context) => Container(
        margin: EdgeInsetsDirectional.only(start: indent),
        height: context.tokens.hairline,
        color: context.tokens.colors.rule,
      );
}

/// 幅を抑えて中央に置く
class Narrow extends StatelessWidget {
  const Narrow({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(constraints: BoxConstraints(maxWidth: context.tokens.readableWidth), child: child),
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
            leading: const Icon(LucideIcons.refreshCw),
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
          color: context.tokens.colors.sheet,
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
    leading: Icon(error ? LucideIcons.circleAlert : LucideIcons.check, color: k.colors.sheet),
    label: Text(message, style: k.text.body.copyWith(color: k.colors.sheet)),
  );
}

void showError(BuildContext context, Object e) => showToast(context, e.toString(), error: true);
