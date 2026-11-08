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
    required this.avatars,
  });

  /// 外枠（画面の地・右パネル）
  final Color shell;

  /// 文書面・入力欄・モーダル
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

  /// 確認待ち
  final Color pending;
  final Color pendingBg;

  /// 条件付きの補足
  final Color qualified;
  final Color qualifiedBg;

  /// 確認印（朱肉）
  final Color stamp;

  /// 発言者アバターの地。状態の色（緑・黄・赤・青）と紛れない色だけにする
  final List<Color> avatars;
}

class AppSpace {
  const AppSpace();
  final double xs = 4, sm = 8, md = 12, lg = 16, xl = 24, xxl = 40;
}

class AppRadius {
  const AppRadius();
  final BorderRadius control = const BorderRadius.all(Radius.circular(6));
  final BorderRadius surface = const BorderRadius.all(Radius.circular(10));
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
  final double changeBar = 3;

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

  /// 確認印の傾き（ラジアン）。手で押した印に見せる
  final double stampTilt = -0.08;
  final double stampDiameter = 80;

  @override
  AppTokens copyWith() => this;

  @override
  AppTokens lerp(AppTokens? other, double t) => this;
}

extension AppTokensContext on BuildContext {
  AppTokens get tokens => Theme.of(this).extension<AppTokens>()!;
}

const _colors = AppColors(
  shell: Color(0xFFF7F6F3),
  canvas: Color(0xFFFFFFFF),
  ink: Color(0xFF2F2D29),
  inkMuted: Color(0xFF6E6B65),
  rule: Color(0xFFE8E6E1),
  hover: Color(0x0D2F2D29),
  added: Color(0xFF3B7457),
  addedBg: Color(0xFFEAF3EC),
  removed: Color(0xFFB2443B),
  removedBg: Color(0xFFFCEBEA),
  pending: Color(0xFF8A6116),
  pendingBg: Color(0xFFFBF3DB),
  qualified: Color(0xFF2C6D94),
  qualifiedBg: Color(0xFFE7F2F8),
  stamp: Color(0xFFC8452F),
  avatars: [
    Color(0xFFEDEBE7),
    Color(0xFFF1E6DF),
    Color(0xFFFBE8D8),
    Color(0xFFEEE7F6),
    Color(0xFFF7E5EE),
  ],
);

ThemeData appTheme() {
  final c = _colors;
  final printed = GoogleFonts.bizUDPGothic(color: c.ink);
  final printBold = GoogleFonts.bizUDPGothic(color: c.ink, fontWeight: FontWeight.w700);
  final hand = GoogleFonts.kleeOne(color: c.ink, fontWeight: FontWeight.w600);

  final text = AppText(
    display: printBold.copyWith(fontSize: 28, height: 1.35),
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
    hit: c.added,
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
      heading: MoonTypography.typography.heading.apply(fontFamily: printBold.fontFamily, color: c.ink),
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
