import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:moon_design/moon_design.dart';

// 色・余白・角丸・書体のリテラルはこのファイルにだけ書く（.claude/rules/flutter-ui.md）

class AppColors {
  const AppColors({
    required this.paper,
    required this.sheet,
    required this.ink,
    required this.inkMuted,
    required this.rule,
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
  });

  /// 画面の地
  final Color paper;

  /// マニュアル本文・入力欄の紙
  final Color sheet;
  final Color ink;
  final Color inkMuted;
  final Color rule;

  /// 反映された差分（追記）
  final Color added;
  final Color addedBg;
  final Color removed;
  final Color removedBg;

  /// 確認待ち（付箋）
  final Color pending;
  final Color pendingBg;

  /// 条件付きの補足
  final Color qualified;
  final Color qualifiedBg;

  /// 確認印（朱肉）
  final Color stamp;

  /// 発言者ラベル（マスキングテープ）
  final Color tape;
}

class AppSpace {
  const AppSpace();
  final double xs = 4, sm = 8, md = 12, lg = 16, xl = 24, xxl = 40;
}

class AppRadius {
  const AppRadius();
  final BorderRadius control = const BorderRadius.all(Radius.circular(6));
  final BorderRadius surface = const BorderRadius.all(Radius.circular(10));
  final BorderRadius tape = const BorderRadius.all(Radius.circular(2));
}

class AppText {
  const AppText({
    required this.title,
    required this.heading,
    required this.body,
    required this.small,
    required this.label,
    required this.hand,
    required this.handLarge,
  });

  final TextStyle title;
  final TextStyle heading;
  final TextStyle body;
  final TextStyle small;

  /// 確認印・行頭の印など、小さく太い文字
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

  /// 本文の幅の上限。1行が長くなりすぎないようにする
  final double readableWidth = 720;

  /// これより狭い画面ではマニュアルと確認を1列に並べる
  final double wideLayout = 900;

  /// マニュアルの行頭で、差分の印（+）を置く幅
  final double gutter = 32;
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
  paper: Color(0xFFEDF0EE),
  sheet: Color(0xFFFAFBFA),
  ink: Color(0xFF1F2B33),
  inkMuted: Color(0xFF56636C),
  rule: Color(0xFFD3DAD6),
  added: Color(0xFF2B6A4B),
  addedBg: Color(0xFFE0EFE5),
  removed: Color(0xFF9E3A31),
  removedBg: Color(0xFFF6E3E0),
  pending: Color(0xFF6B4A00),
  pendingBg: Color(0xFFF7E8AE),
  qualified: Color(0xFF2C5378),
  qualifiedBg: Color(0xFFE2EAF3),
  stamp: Color(0xFFC0402C),
  tape: Color(0xFFE6E1D3),
);

ThemeData appTheme() {
  final c = _colors;
  final printed = GoogleFonts.bizUDPGothic(color: c.ink);
  final printBold = GoogleFonts.bizUDPGothic(color: c.ink, fontWeight: FontWeight.w700);
  final hand = GoogleFonts.kleeOne(color: c.ink, fontWeight: FontWeight.w600);

  final text = AppText(
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
    goku: c.paper,
    gohan: c.sheet,
    bulma: c.ink,
    trunks: c.inkMuted,
    goten: c.sheet,
    popo: c.ink,
    jiren: c.ink.withValues(alpha: 0.08),
    heles: c.ink.withValues(alpha: 0.04),
    zeno: c.ink.withValues(alpha: 0.45),
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
      onPrimary: c.sheet,
      surface: c.sheet,
      onSurface: c.ink,
      error: c.removed,
      outline: c.rule,
    ),
    scaffoldBackgroundColor: c.paper,
    fontFamily: printed.fontFamily,
    extensions: [MoonTheme(tokens: moonTokens), AppTokens(colors: c, text: text)],
  );
}
