import 'package:flutter/material.dart';
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
    required this.pressed,
    required this.added,
    required this.addedBg,
    required this.removed,
    required this.removedBg,
    required this.pending,
    required this.pendingBg,
    required this.qualified,
    required this.qualifiedBg,
    required this.stamp,
    required this.action,
    required this.grid,
    required this.sticky,
    required this.avatar,
    required this.graphTrunk,
    required this.graphBranch,
    required this.graphPending,
  });

  /// 画面の地。ホワイトボードのような明るい灰色。クリームやベージュにすると AI が作った画面の既定の色に見える
  final Color shell;

  /// 白い面（フレーム）・入力欄・モーダル
  final Color canvas;
  final Color ink;
  final Color inkMuted;
  final Color rule;
  final Color hover;

  /// 押している間の地。hover より濃くして、押したことがはっきり分かるようにする
  final Color pressed;

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

  /// 主ボタンと選択中の印。状態の色（特に条件付きの青緑）と紛れない青にする
  final Color action;

  /// 地の方眼の線
  final Color grid;

  /// 言われたことの付箋。本物の付箋と同じ黄色1色にする。誰が言ったかはアバターと名前で示す
  final Color sticky;

  /// 発言者アバターの地。色で人を区別せず、頭文字で示す
  final Color avatar;

  /// 履歴のグラフの線と点の枠。Miro のコネクタと図形の枠のように、白い面の上で軽く見える明るい色にする。
  /// 幹（反映した版）は反映済みの緑、あとで確認の枝は黄、ほかの枝は明るい灰色。差分の文字の色より明るいので、文字には使わない
  final Color graphTrunk;
  final Color graphBranch;
  final Color graphPending;
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

  /// 狭い画面の下に浮かせるタブバー（試作）
  final BorderRadius floating = const BorderRadius.all(Radius.circular(22));
}

class AppText {
  const AppText({
    required this.display,
    required this.title,
    required this.heading,
    required this.body,
    required this.small,
    required this.label,
    required this.input,
    required this.inputArea,
  });

  /// 内容の頭に置く題名
  final TextStyle display;
  final TextStyle title;
  final TextStyle heading;
  final TextStyle body;
  final TextStyle small;

  /// タグ・確認印・アバターなど、小さく太い文字
  final TextStyle label;

  /// 入力欄の文字。iPhone（WebKit）は 16px 未満の入力欄にフォーカスすると画面を拡大して戻さないので、16 以上にする（調査17）。
  /// 1行の欄（MoonTextInput）は行の高さを決めない（Moon の既定と同じ。決めると Web で文字が下に寄る）
  final TextStyle input;

  /// 複数行の入力欄（MoonTextArea）の文字。input と同じ大きさで、行の間は本文と同じにする
  final TextStyle inputArea;

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

  /// 広い画面で左に常に出すサイドバーの幅
  final double sidebarWidth = 240;

  /// サイドバーの項目の左に置く物（自分のアイコン・ペンのアイコン）の幅。アイコンの付いた項目どうしで文字の頭をそろえる（自分のアイコンの大きさ xs と同じ）
  final double sidebarLeading = 24;
  final double sidebarIcon = 20;

  /// 上部バーの中身の高さ（戻るボタンの高さ）。ボタンの無い画面でも揃え、画面を移っても高さが変わらないようにする
  final double barHeight = 40;

  /// 一覧の数値の列の幅
  final double numberColumn = 112;

  /// これより狭いと、左右に並べる選択肢を縦に積む
  final double stackBelow = 480;

  /// マニュアルの行頭で、変更の色線を置く幅
  final double gutter = 24;
  final double modalWidth = 600;

  /// マニュアルを貼り付ける欄の高さ
  final double editorHeight = 320;

  /// 入力ページで言われたことを書く欄の高さ（下の添付・マイクの行を含む）
  final double composerHeight = 160;

  /// 書く欄の下の、添付・マイクのボタンを置く行の高さ
  final double composerTools = 48;

  /// 入力ページの最近の記録に並べる付箋の幅
  final double stickyWidth = 220;

  /// 未整理メモを付箋のまま書き直す欄の高さ
  final double memoEditorHeight = 120;

  /// 入力ページで添えた画像のサムネイルの大きさ
  final double thumbnail = 64;

  /// リワインドの丸いボタンの直径。指導中に画面を見ずに親指で押せる大きさ
  final double rewindButton = 200;

  /// 確認印の傾き（ラジアン）。手で押した印に見せる
  final double stampTilt = -0.08;
  final double stampDiameter = 84;

  /// 履歴のグラフで、幹と枝を並べる1本分の幅と、版の点の直径
  final double graphLane = 24;
  final double graphDot = 14;

  /// 履歴のグラフの線の太さと、1件の行の高さ。行の高さをそろえて、幹と枝の形が一目で見えるようにする
  final double graphStroke = 2.5;
  final double graphRow = 40;

  /// 履歴のグラフで、まだ確認していない枝を今まで伸ばす点線の1つ分の長さ
  final double graphDash = 4;

  /// 狭い画面の履歴の1件の、いちばん低い高さ。指で押しやすい 44 より大きくし、文を2行まで出せるときは伸びる
  final double graphRowTouch = 52;

  /// 履歴の各行の右端の「›」の大きさ。押すと版の詳細が開くと分かるように付ける
  final double graphChevron = 18;

  /// 狭い画面の下に浮かせるタブバー（試作。スマホで重くないかを見る）。高さ・後ろをぼかす強さ・半透明の白・影
  final double tabBarHeight = 60;

  /// 後ろをぼかす強さ。強すぎると後ろの色や形が消えて白い板に見えるので、ぼやけて見える程度にとどめる
  final double tabBarBlur = 12;

  /// 後ろの色の鮮やかさ（1 でそのまま）。iPhone の Liquid Glass のように少し上げると、透けた色がガラス越しに見える
  final double tabBarSaturation = 1.6;

  /// ガラスの白。後ろが透けて見えるよう半分より薄くする（ぼかしを切ったときは、不透明の白い帯 canvas にする）
  final Color tabBarGlass = const Color(0x66FFFFFF);

  /// ガラスの縁。細い白の半透明と、上側に少し明るい線（光が当たって見える）
  final Color tabBarEdge = const Color(0x8CFFFFFF);
  final Color tabBarEdgeLight = const Color(0xE6FFFFFF);
  final List<BoxShadow> tabBarShadow = const [BoxShadow(color: Color(0x2417173D), blurRadius: 24, offset: Offset(0, 8))];

  /// 選んでいるタブの後ろに敷くカプセル（action の青を薄く）と、横に動く時間
  final Color tabBarPill = const Color(0x262459F5);
  final Duration tabBarPillMove = const Duration(milliseconds: 220);

  @override
  AppTokens copyWith() => this;

  @override
  AppTokens lerp(AppTokens? other, double t) => this;
}

extension AppTokensContext on BuildContext {
  AppTokens get tokens => Theme.of(this).extension<AppTokens>()!;
}

const _colors = AppColors(
  shell: Color(0xFFF2F2F4),
  canvas: Color(0xFFFFFFFF),
  ink: Color(0xFF17173D),
  inkMuted: Color(0xFF5D5D78),
  rule: Color(0xFFE0E0E8),
  hover: Color(0x0D17173D),
  pressed: Color(0x1A17173D),
  // 差分の色は、差分表示でなじみのある、はっきりした緑・赤・黄・青にする
  added: Color(0xFF1A7F37),
  addedBg: Color(0xFFDAFBE1),
  removed: Color(0xFFCF222E),
  removedBg: Color(0xFFFFEBE9),
  pending: Color(0xFF9A6700),
  pendingBg: Color(0xFFFFF8C5),
  qualified: Color(0xFF0E7A86),
  qualifiedBg: Color(0xFFDDF3F5),
  stamp: Color(0xFFDE3A2E),
  action: Color(0xFF2459F5),
  grid: Color(0xFFE4E4EA),
  sticky: Color(0xFFFFF6A6),
  avatar: Color(0xFFE0E0E8),
  graphTrunk: Color(0xFF2DA44E),
  graphBranch: Color(0xFFA9A9C2),
  graphPending: Color(0xFFFAC710),
);

ThemeData appTheme() {
  final c = _colors;
  // 書体は pubspec.yaml で同梱したものだけを使う
  final printed = TextStyle(fontFamily: 'BIZUDPGothic', color: c.ink);
  final printBold = printed.copyWith(fontWeight: FontWeight.w700);

  final text = AppText(
    display: printBold.copyWith(fontSize: 28, height: 1.35),
    title: printBold.copyWith(fontSize: 20, height: 1.4),
    heading: printBold.copyWith(fontSize: 16, height: 1.5),
    body: printed.copyWith(fontSize: 15, height: 1.7),
    small: printed.copyWith(fontSize: 13, height: 1.5, color: c.inkMuted),
    label: printBold.copyWith(fontSize: 12, height: 1.2),
    input: printed.copyWith(fontSize: 16),
    inputArea: printed.copyWith(fontSize: 16, height: 1.7),
  );

  final moonColors = MoonColors.light.copyWith(
    piccolo: c.action,
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

  // Moon の入力欄の既定の文字（sm・md は 14px）も入力欄の文字にそろえ、textStyle を付け忘れても 16 以上になるようにする
  final inputBase = MoonTextInputTheme(tokens: moonTokens);
  final inputSizes = inputBase.sizes;
  final textInputTheme = inputBase.copyWith(
    sizes: inputSizes.copyWith(
      sm: inputSizes.sm.copyWith(textStyle: text.input),
      md: inputSizes.md.copyWith(textStyle: text.input),
      lg: inputSizes.lg.copyWith(textStyle: text.input),
      xl: inputSizes.xl.copyWith(textStyle: text.input),
    ),
  );
  final areaBase = MoonTextAreaTheme(tokens: moonTokens);
  final textAreaTheme = areaBase.copyWith(properties: areaBase.properties.copyWith(textStyle: text.inputArea));

  return ThemeData(
    colorScheme: ColorScheme.light(
      primary: c.action,
      onPrimary: c.canvas,
      surface: c.canvas,
      onSurface: c.ink,
      error: c.removed,
      outline: c.rule,
    ),
    scaffoldBackgroundColor: c.shell,
    fontFamily: printed.fontFamily,
    extensions: [
      MoonTheme(tokens: moonTokens, textInputTheme: textInputTheme, textAreaTheme: textAreaTheme),
      AppTokens(colors: c, text: text),
    ],
  );
}
