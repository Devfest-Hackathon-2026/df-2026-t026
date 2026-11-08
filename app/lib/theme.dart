import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:moon_design/moon_design.dart';

// 色・余白・角丸・書体のリテラルはこのファイルにだけ書く（.claude/rules/flutter-ui.md）

class AppColors {
  const AppColors({
    required this.shell,
    required this.canvas,
    required this.ink,
    required this.inkMuted,
    required this.rule,
    required this.hover,
    required this.added,
    required this.addedBg,
    required this.removed,
    required this.removedBg,
    required this.pending,
    required this.pendingBg,
    required this.qualified,
    required this.qualifiedBg,
    required this.stamp,
    required this.tape,
    required this.sticky,
    required this.avatar,
  });

  /// 画面の地。紙や付箋を置く机。クリームやベージュにすると AI が作った画面の既定の色に見える
  final Color shell;

  /// 紙・入力欄・モーダル
  final Color canvas;
  final Color ink;
  final Color inkMuted;
  final Color rule;
  final Color hover;

  /// 反映された差分（追記）
  final Color added;
  final Color addedBg;
  final Color removed;
  final Color removedBg;

  /// あとで確認（食い違い）
  final Color pending;
  final Color pendingBg;

  /// 条件付きの補足
  final Color qualified;
  final Color qualifiedBg;

  /// 確認印（朱肉）。画面で朱を使うのは確認印だけにして、印を目立たせる
  final Color stamp;

  /// 付箋や紙を留めるマスキングテープ
  final Color tape;

  /// 言われたことの付箋。本物の付箋と同じ黄色1色にする。誰が言ったかはアバターと名前で示す
  final Color sticky;

  /// 発言者アバターの地。色で人を区別せず、頭文字で示す
  final Color avatar;
}

class AppSpace {
  const AppSpace();
  final double xs = 4, sm = 8, md = 12, lg = 16, xl = 24, xxl = 40;
}

class AppRadius {
  const AppRadius();

  /// 操作するもの（ボタン・入力欄）
  final BorderRadius control = const BorderRadius.all(Radius.circular(6));

  /// 面（モーダル・比較の枠）
  final BorderRadius surface = const BorderRadius.all(Radius.circular(10));

  /// 紙と付箋。本物の紙に見せるため、ほとんど丸めない
  final BorderRadius paper = const BorderRadius.all(Radius.circular(2));

  /// アバターと状態のタグ
  final BorderRadius round = const BorderRadius.all(Radius.circular(999));
}

class AppText {
  const AppText({
    required this.display,
    required this.title,
    required this.heading,
    required this.body,
    required this.small,
    required this.label,
    required this.hand,
    required this.handLarge,
  });

  /// 内容の頭に置く題名
  final TextStyle display;
  final TextStyle title;
  final TextStyle heading;
  final TextStyle body;
  final TextStyle small;

  /// タグ・確認印・アバターなど、小さく太い文字
  final TextStyle label;

  /// 口頭で言われたこと（手書き）
  final TextStyle hand;
  final TextStyle handLarge;
}

@immutable
class AppTokens extends ThemeExtension<AppTokens> {
  const AppTokens({required this.colors, required this.text});

  final AppColors colors;
  final AppText text;
  final AppSpace space = const AppSpace();
  final AppRadius radius = const AppRadius();

  /// 罫線の太さ
  final double hairline = 1;

  /// 変更行の左余白の色線の太さ
  final double changeBar = 4;

  /// 本文の幅の上限。1行が長くなりすぎないようにする
  final double readableWidth = 720;

  /// 一覧ページの幅の上限
  final double pageWidth = 880;

  /// これより狭い画面では文書とパネルをタブで切り替える
  final double wideLayout = 900;
  final double panelWidth = 380;

  /// 一覧の数値の列の幅
  final double numberColumn = 112;

  /// これより狭いと、左右に並べる選択肢を縦に積む
  final double stackBelow = 480;

  /// マニュアルの行頭で、変更の色線を置く幅
  final double gutter = 24;
  final double modalWidth = 600;

  /// マニュアルを貼り付ける欄の高さ
  final double editorHeight = 320;

  /// 入力ページで言われたことを書く欄の高さ
  final double composerHeight = 160;

  /// 入力ページの最近の記録に並べる付箋の幅
  final double stickyWidth = 220;

  /// 確認印の傾き（ラジアン）。手で押した印に見せる
  final double stampTilt = -0.08;
  final double stampDiameter = 84;

  /// 付箋の傾き（ラジアン）。貼った感を出すため、少しだけ傾ける
  final double stickyTilt = 0.012;

  @override
  AppTokens copyWith() => this;

  @override
  AppTokens lerp(AppTokens? other, double t) => this;
}

extension AppTokensContext on BuildContext {
  AppTokens get tokens => Theme.of(this).extension<AppTokens>()!;
}

const _colors = AppColors(
  shell: Color(0xFFE8E9EB),
  canvas: Color(0xFFFFFFFF),
  ink: Color(0xFF1F2023),
  inkMuted: Color(0xFF5E6168),
  rule: Color(0xFFDADCE0),
  hover: Color(0x0D1F2023),
  // 差分の色は、差分表示でなじみのある、はっきりした緑・赤・黄・青にする
  added: Color(0xFF1A7F37),
  addedBg: Color(0xFFDAFBE1),
  removed: Color(0xFFCF222E),
  removedBg: Color(0xFFFFEBE9),
  pending: Color(0xFF9A6700),
  pendingBg: Color(0xFFFFF8C5),
  qualified: Color(0xFF0969DA),
  qualifiedBg: Color(0xFFDDF4FF),
  stamp: Color(0xFFDE3A2E),
  tape: Color(0xB3E2DCCB),
  sticky: Color(0xFFFFF07F),
  avatar: Color(0xFFDADCE0),
);

ThemeData appTheme() {
  final c = _colors;
  final printed = GoogleFonts.bizUDPGothic(color: c.ink);
  final printBold = printed.copyWith(fontWeight: FontWeight.w700);
  // 丸ゴシックは画面の題名だけ。どこにでも使うと全体がのっぺり柔らかくなる
  final round = GoogleFonts.mPlusRounded1c(color: c.ink, fontWeight: FontWeight.w800);
  final hand = GoogleFonts.kleeOne(color: c.ink, fontWeight: FontWeight.w600);

  final text = AppText(
    display: round.copyWith(fontSize: 30, height: 1.3),
    title: printBold.copyWith(fontSize: 20, height: 1.4),
    heading: printBold.copyWith(fontSize: 16, height: 1.5),
    body: printed.copyWith(fontSize: 15, height: 1.7),
    small: printed.copyWith(fontSize: 13, height: 1.5, color: c.inkMuted),
    label: printBold.copyWith(fontSize: 12, height: 1.2),
    hand: hand.copyWith(fontSize: 16, height: 1.6),
    handLarge: hand.copyWith(fontSize: 20, height: 1.5),
  );

  final moonColors = MoonColors.light.copyWith(
    piccolo: c.ink,
    hit: c.ink,
    beerus: c.rule,
    goku: c.canvas,
    gohan: c.shell,
    bulma: c.ink,
    trunks: c.inkMuted,
    goten: c.canvas,
    popo: c.ink,
    jiren: c.ink.withValues(alpha: 0.08),
    heles: c.hover,
    zeno: c.ink.withValues(alpha: 0.4),
    krillin: c.pending,
    krillin10: c.pendingBg,
    chichi: c.removed,
    chichi10: c.removedBg,
    roshi: c.added,
    roshi10: c.addedBg,
    whis: c.qualified,
    whis10: c.qualifiedBg,
    textPrimary: c.ink,
    textSecondary: c.inkMuted,
    iconPrimary: c.ink,
    iconSecondary: c.inkMuted,
  );
  const radius = AppRadius();
  final moonTokens = MoonTokens.light.copyWith(
    colors: moonColors,
    borders: MoonBorders.borders.copyWith(
      interactiveXs: radius.control,
      interactiveSm: radius.control,
      interactiveMd: radius.control,
      surfaceXs: radius.surface,
      surfaceSm: radius.surface,
      surfaceMd: radius.surface,
      surfaceLg: radius.surface,
    ),
    shadows: const MoonShadows(sm: [], md: [], lg: [], xl: []),
    typography: MoonTypography.typography.copyWith(
      body: MoonTypography.typography.body.apply(fontFamily: printed.fontFamily, color: c.ink),
      heading: MoonTypography.typography.heading.apply(fontFamily: printed.fontFamily, color: c.ink),
    ),
  );

  return ThemeData(
    colorScheme: ColorScheme.light(
      primary: c.ink,
      onPrimary: c.canvas,
      surface: c.canvas,
      onSurface: c.ink,
      error: c.removed,
      outline: c.rule,
    ),
    scaffoldBackgroundColor: c.shell,
    fontFamily: printed.fontFamily,
    extensions: [MoonTheme(tokens: moonTokens), AppTokens(colors: c, text: text)],
  );
}
