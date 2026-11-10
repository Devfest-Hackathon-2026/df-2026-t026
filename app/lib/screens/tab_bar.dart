import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:moon_design/moon_design.dart';

import '../manual_controller.dart';
import '../theme.dart';
import 'check_list_screen.dart';
import 'common.dart';
import 'history_screen.dart';
import 'manual_screen.dart';
import 'materials_screen.dart';
import 'sidebar.dart';

/// 後ろをぼかすか（UI ルールの例外。.claude/rules/flutter-ui.md）。重い端末向けに `--dart-define=TABBAR_BLUR=false` で切れる
const tabBarBlur = bool.fromEnvironment('TABBAR_BLUR', defaultValue: true);

/// ノートの中のタブ。資料は広い画面のノートのタブにだけある（下のタブバーには足さない。ADR 0019）
enum NoteTab { note, checks, history, materials }

/// 下のタブバーを出すか。サイドバーの出ない狭い画面で、キーボードが出ていないときだけ
bool showsNoteTabBar(BuildContext context) =>
    !showsSidebar(context) && MediaQuery.viewInsetsOf(context).bottom == 0;

/// 下のタブバーの裏に隠れないよう、スクロールの下の余白に足す（Scaffold の extendBody で、body の下の余白がタブバーの高さになる）
EdgeInsets belowTabBar(BuildContext context, EdgeInsets padding) =>
    padding.copyWith(bottom: padding.bottom + MediaQuery.paddingOf(context).bottom);

/// ノートの上に積んだ確認リスト・履歴の印。数はノートから何枚上か（履歴の上に開いた確認リストなら 2）
const _aboveNote = 'above-note:';

int _depth(BuildContext context) {
  final name = ModalRoute.of(context)?.settings.name;
  return name != null && name.startsWith(_aboveNote) ? int.parse(name.substring(_aboveNote.length)) : 0;
}

/// 確認リスト・履歴を、ノートかその上から開くときに付ける印。ノートの外から開くときは null
RouteSettings? aboveNote(BuildContext context, {bool fromNote = false}) {
  final d = fromNote ? 0 : _depth(context);
  return fromNote || d > 0 ? RouteSettings(name: '$_aboveNote${d + 1}') : null;
}

/// タブを替える。替えたことが分かれば十分なので、横から出てくる動きは付けない。
/// ノートの上に積んだ画面からは、ノートまで外して戻る（画面を積み重ねない）。
/// 確認リスト・履歴は入力ページなどノートの外からも開くので、そのときはノートに入れ替える。
/// utteranceId を渡すと、履歴ではその記録で作った版を選んで開く
void openNoteTab(BuildContext context, ManualController c,
    {required NoteTab from, required NoteTab to, String? utteranceId}) {
  if (from == to) return;
  final nav = Navigator.of(context);
  final d = from == NoteTab.note ? 0 : _depth(context);
  final outside = from != NoteTab.note && d == 0;
  if (to == NoteTab.note) {
    if (outside) {
      nav.pushReplacement(_instant(ManualScreen(api: c.api, manualId: c.manualId), null));
    } else {
      var n = d;
      nav.popUntil((_) => n-- == 0);
    }
    return;
  }
  final screen = switch (to) {
    NoteTab.checks => CheckListScreen(c: c),
    NoteTab.history => HistoryScreen(c: c, utteranceId: utteranceId),
    _ => MaterialsScreen(c: c),
  };
  if (from == NoteTab.note) {
    nav.push(_instant(screen, RouteSettings(name: '${_aboveNote}1')));
    return;
  }
  // ノートのすぐ上の1枚まで外し、それを入れ替える
  var n = d - 1;
  if (n > 0) nav.popUntil((_) => n-- == 0);
  nav.pushReplacement(_instant(screen, outside ? null : RouteSettings(name: '${_aboveNote}1')));
}

PageRouteBuilder<void> _instant(Widget screen, RouteSettings? settings) => PageRouteBuilder<void>(
      settings: settings,
      pageBuilder: (_, _, _) => screen,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
    );

/// 狭い画面の下に浮かせるタブバー（ノート / 確認リスト / 履歴）。後ろが透けるガラスにし、選んでいるタブの後ろにカプセルを敷く
class NoteTabBar extends StatefulWidget {
  const NoteTabBar({super.key, required this.c, required this.current});
  final ManualController c;
  final NoteTab current;

  @override
  State<NoteTabBar> createState() => _NoteTabBarState();
}

/// ノートごと（同じ ManualController を使う、ノート・確認リスト・履歴のひと続き）に、いちばん上の画面で見せているタブを覚える。
/// タブを替えると画面ごと入れ替わる（積む・外す）ので、出てきた画面のカプセルを前のタブの位置から動かすために使う。
/// ノートの外から開いたときは ManualController が新しいので覚えが無く、動かさずにその位置に出す
final _shown = Expando<NoteTab>('いちばん上の画面のタブ');

class _NoteTabBarState extends State<NoteTabBar> {
  late NoteTab _pill;

  /// カプセルを前のタブの位置に「置き直す」たびに増やす。AnimatedAlign を作り直して、動かさずにその位置から始めるため
  var _placed = 0;

  @override
  void initState() {
    super.initState();
    _showFrom(_shown[widget.c]);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 上に積んだ画面が外れて、この画面がいちばん上に戻ったとき（「ノート」タブ・戻るボタン）も、前のタブの位置から動かす
    if (ModalRoute.of(context)?.isCurrent ?? true) {
      final before = _shown[widget.c];
      if (before != null && before != widget.current) _showFrom(before);
    }
  }

  /// カプセルを before の位置に置き、次の枠で今のタブへ動かす。覚えを今のタブにする（読んでから書き換える）
  void _showFrom(NoteTab? before) {
    _pill = before ?? widget.current;
    _placed++;
    _shown[widget.c] = widget.current;
    if (_pill != widget.current) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _pill = widget.current);
      });
    }
  }

  @override
  void didUpdateWidget(NoteTabBar old) {
    super.didUpdateWidget(old);
    if (old.current != widget.current || old.c != widget.c) _showFrom(_shown[widget.c]);
  }

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    final open = widget.c.state?.openChecks.length ?? 0;
    const tabs = [NoteTab.note, NoteTab.checks, NoteTab.history];
    final bar = SizedBox(
      height: k.tabBarHeight,
      child: Stack(children: [
        // 選んでいるタブの後ろのカプセル。タブを替えると横に動く
        AnimatedAlign(
          key: ValueKey(_placed),
          duration: k.tabBarPillMove,
          curve: Curves.easeOutCubic,
          alignment: Alignment(-1 + 2 * tabs.indexOf(_pill) / (tabs.length - 1), 0),
          child: FractionallySizedBox(
            widthFactor: 1 / tabs.length,
            child: Padding(
              padding: EdgeInsets.all(k.space.xs),
              child: DecoratedBox(
                key: const ValueKey('tab-pill'),
                decoration: BoxDecoration(color: k.tabBarPill, borderRadius: k.radius.round),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
        Row(children: [
          _tab(context, NoteTab.note, LucideIcons.fileText, 'ノート'),
          _tab(context, NoteTab.checks, LucideIcons.listChecks, '確認リスト', count: open),
          _tab(context, NoteTab.history, LucideIcons.history, '履歴'),
        ]),
        // 縁の上側に、少し明るい線を足す（光が当たって見える。グラデーションは使わない）
        Positioned(
          top: k.hairline,
          left: k.space.xl,
          right: k.space.xl,
          child: Container(height: k.hairline, color: k.tabBarEdgeLight),
        ),
      ]),
    );
    final glass = DecoratedBox(
      decoration: BoxDecoration(
        // ぼかさないときは不透明の白い帯にする（少しでも透けると、後ろの文字がくっきり重なって読みにくい）
        color: tabBarBlur ? k.tabBarGlass : k.colors.canvas,
        borderRadius: k.radius.floating,
        border: Border.all(color: tabBarBlur ? k.tabBarEdge : k.colors.rule, width: k.hairline),
      ),
      child: bar,
    );
    return SafeArea(
      top: false,
      minimum: EdgeInsets.only(bottom: k.space.sm),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: k.space.lg),
        child: DecoratedBox(
          decoration: BoxDecoration(borderRadius: k.radius.floating, boxShadow: k.tabBarShadow),
          child: ClipRRect(
            borderRadius: k.radius.floating,
            child: tabBarBlur ? BackdropFilter(filter: _glassFilter(k), child: glass) : glass,
          ),
        ),
      ),
    );
  }

  /// 後ろをぼかし、色を少し鮮やかにする
  ImageFilter _glassFilter(AppTokens k) => ImageFilter.compose(
        outer: ColorFilter.matrix(_saturation(k.tabBarSaturation)),
        inner: ImageFilter.blur(sigmaX: k.tabBarBlur, sigmaY: k.tabBarBlur),
      );

  /// 鮮やかさを s 倍にする色の行列（明るさの重みは sRGB の輝度の係数）
  static List<double> _saturation(double s) {
    const r = 0.2126, g = 0.7152, b = 0.0722;
    final i = 1 - s;
    return [
      r * i + s, g * i, b * i, 0, 0, //
      r * i, g * i + s, b * i, 0, 0, //
      r * i, g * i, b * i + s, 0, 0, //
      0, 0, 0, 1, 0,
    ];
  }

  Widget _tab(BuildContext context, NoteTab tab, IconData icon, String label, {int count = 0}) {
    final k = context.tokens;
    final selected = tab == widget.current;
    // 選んでいる印は青のカプセルとアイコン。文字は紺のまま（青い文字を青いカプセルに載せると、小さな文字のコントラストが足りない）
    final iconColor = selected ? k.colors.action : k.colors.ink;
    return Expanded(
      // MoonButton がボタンとして読み上げるので、ここでは選ばれているかだけを足す
      child: Semantics(
        selected: selected,
        child: MoonButton(
          height: k.tabBarHeight,
          isFullWidth: true,
          borderRadius: k.radius.round,
          // 押すと少し縮む（Moon の既定）。地の色は付けず、選んでいる所はカプセルで見せる
          onTap: () => openNoteTab(context, widget.c, from: widget.current, to: tab),
          label: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, color: iconColor),
              if (count > 0) ...[
                SizedBox(width: k.space.xs),
                StatusTag('$count', bg: k.colors.pendingBg, fg: k.colors.pending),
              ],
            ]),
            SizedBox(height: k.space.xs),
            Text(label, style: k.text.label.copyWith(color: k.colors.ink)),
          ]),
        ),
      ),
    );
  }
}

/// 広い画面で上部バーのすぐ下に出すノートのタブ（ノート / 確認リスト / 履歴 / 資料）。
/// 狭い画面では下のタブバーを使うので出さない
class NoteTabRow extends StatefulWidget {
  const NoteTabRow({super.key, required this.c, required this.current});
  final ManualController c;
  final NoteTab current;

  @override
  State<NoteTabRow> createState() => _NoteTabRowState();
}

class _NoteTabRowState extends State<NoteTabRow> {
  /// 押すと MoonTabBar は押したタブを選んだままになる。ノートから開いた画面を外して戻ったとき
  /// 下のノートのタブが前のまま残らないよう、押すたびに作り直して今のタブに戻す
  var _reset = 0;

  void _open(int i) {
    openNoteTab(context, widget.c, from: widget.current, to: NoteTab.values[i]);
    if (mounted) setState(() => _reset++);
  }

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    return Container(
      decoration: BoxDecoration(
        color: k.colors.canvas,
        border: Border(bottom: BorderSide(color: k.colors.rule, width: k.hairline)),
      ),
      padding: EdgeInsets.symmetric(horizontal: k.space.md),
      alignment: Alignment.centerLeft,
      child: ListenableBuilder(
        listenable: widget.c,
        builder: (context, _) {
          final open = widget.c.state?.openChecks.length ?? 0;
          return MoonTabBar(
            key: ValueKey(_reset),
            initialIndex: NoteTab.values.indexOf(widget.current),
            onTabChanged: _open,
            tabs: [
              const MoonTab(label: Text('ノート')),
              MoonTab(
                label: const Text('確認リスト'),
                trailing: open > 0 ? StatusTag('$open', bg: k.colors.pendingBg, fg: k.colors.pending) : null,
              ),
              const MoonTab(label: Text('履歴')),
              const MoonTab(label: Text('資料')),
            ],
          );
        },
      ),
    );
  }
}
