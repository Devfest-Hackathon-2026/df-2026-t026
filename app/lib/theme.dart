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
    required this.accent,
    required this.accentSoft,
    required this.glass,
    required this.tape,
    required this.shellGrad,
    required this.tiles,
    required this.stickies,
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

  /// あとで確認（食い違い）
  final Color pending;
  final Color pendingBg;

  /// 条件付きの補足
  final Color qualified;
  final Color qualifiedBg;

  /// 確認印（朱肉）
  final Color stamp;

  /// ポップの主役色。主ボタンと選択中の印にだけ使う
  final Color accent;
  final Color accentSoft;

  /// リキッドガラス風の面（半透明の白）
  final Color glass;

  /// 付箋や紙を留めるマスキングテープ
  final Color tape;

  /// 外枠の地に敷く、パステルのグラデーション（左上から右下）
  final List<Color> shellGrad;

  /// 一覧のタイルを順に塗るパステル
  final List<Color> tiles;

  /// 言われたことの付箋を順に塗る色
  final List<Color> stickies;

  /// 発言者アバターの地。状態の色（緑・黄・赤・青）と紛れない色だけにする
  final List<Color> avatars;
}

class AppSpace {
  const AppSpace();
  final double xs = 4, sm = 8, md = 12, lg = 16, xl = 24, xxl = 40;
}

class AppRadius {
  const AppRadius();

  /// 操作するもの（ボタン・タグ・入力欄）はピル型
  final BorderRadius control = const BorderRadius.all(Radius.circular(999));

  /// 面（カード・モーダル・文書）
  final BorderRadius surface = const BorderRadius.all(Radius.circular(20));

  /// 一覧のタイルなど、大きめの面
  final BorderRadius tile = const BorderRadius.all(Radius.circular(24));
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

  /// 確認印の傾き（ラジアン）。手で押した印に見せる
  final double stampTilt = -0.08;
  final double stampDiameter = 84;

  /// 付箋の傾き（ラジアン）。貼った感を出すため、少しだけ傾ける
  final double stickyTilt = 0.012;

  /// ガラス面のぼかし量
  final double glassBlur = 14;

  @override
  AppTokens copyWith() => this;

  @override
  AppTokens lerp(AppTokens? other, double t) => this;
}

extension AppTokensContext on BuildContext {
  AppTokens get tokens => Theme.of(this).extension<AppTokens>()!;
}

const _colors = AppColors(
  shell: Color(0xFFFFF6EC),
  canvas: Color(0xFFFFFFFF),
  ink: Color(0xFF33302B),
  inkMuted: Color(0xFF837D73),
  rule: Color(0xFFEFE9E0),
  hover: Color(0x0D33302B),
  added: Color(0xFF1E9E62),
  addedBg: Color(0xFFDFF7E8),
  removed: Color(0xFFE5484D),
  removedBg: Color(0xFFFFE3E1),
  pending: Color(0xFFC77400),
  pendingBg: Color(0xFFFFEFC4),
  qualified: Color(0xFF1E88C7),
  qualifiedBg: Color(0xFFDFF2FF),
  stamp: Color(0xFFE03E2D),
  accent: Color(0xFFFF6B4A),
  accentSoft: Color(0xFFFFE3D9),
  glass: Color(0x9EFFFFFF),
  tape: Color(0xC2FFD166),
  shellGrad: [
    Color(0xFFFFF1DE),
    Color(0xFFE9F8EE),
    Color(0xFFE3F0FF),
  ],
  tiles: [
    Color(0xFFFFE8D6),
    Color(0xFFDFF5E1),
    Color(0xFFFFF3B8),
    Color(0xFFDCEEFF),
    Color(0xFFFFDFEC),
    Color(0xFFE9E4FF),
  ],
  stickies: [
    Color(0xFFFFF1A8),
    Color(0xFFFFD6E7),
    Color(0xFFCDEBFF),
    Color(0xFFD8F5C3),
    Color(0xFFFFE1B8),
  ],
  avatars: [
    Color(0xFFFFD9C0),
    Color(0xFFFFC7D9),
    Color(0xFFBDE0FE),
    Color(0xFFD9F99D),
    Color(0xFFFDE68A),
    Color(0xFFDDD6FE),
  ],
);

ThemeData appTheme() {
  final c = _colors;
  final printed = GoogleFonts.bizUDPGothic(color: c.ink);
  // 見出しは丸ゴシックでポップに。本文は読みやすい印字のまま
  final round = GoogleFonts.mPlusRounded1c(color: c.ink, fontWeight: FontWeight.w700);
  final roundHeavy = GoogleFonts.mPlusRounded1c(color: c.ink, fontWeight: FontWeight.w800);
  final hand = GoogleFonts.kleeOne(color: c.ink, fontWeight: FontWeight.w600);

  final text = AppText(
    display: roundHeavy.copyWith(fontSize: 32, height: 1.3),
    title: roundHeavy.copyWith(fontSize: 22, height: 1.35),
    heading: round.copyWith(fontSize: 17, height: 1.45),
    body: printed.copyWith(fontSize: 15, height: 1.7),
    small: printed.copyWith(fontSize: 13, height: 1.5, color: c.inkMuted),
    label: round.copyWith(fontSize: 12, height: 1.2),
    hand: hand.copyWith(fontSize: 16, height: 1.6),
    handLarge: hand.copyWith(fontSize: 20, height: 1.5),
  );

  final moonColors = MoonColors.light.copyWith(
    piccolo: c.accent,
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
      heading: MoonTypography.typography.heading.apply(fontFamily: round.fontFamily, color: c.ink),
    ),
  );

  return ThemeData(
    colorScheme: ColorScheme.light(
      primary: c.accent,
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
