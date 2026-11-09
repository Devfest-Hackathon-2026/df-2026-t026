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
import 'sidebar.dart';

/// 後ろをぼかすか（UI ルールの例外。.claude/rules/flutter-ui.md）。重い端末向けに `--dart-define=TABBAR_BLUR=false` で切れる
const tabBarBlur = bool.fromEnvironment('TABBAR_BLUR', defaultValue: true);

/// ノートの中のタブ
enum NoteTab { note, checks, history }

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
/// 確認リスト・履歴は入力ページなどノートの外からも開くので、そのときはノートに入れ替える
void openNoteTab(BuildContext context, ManualController c, {required NoteTab from, required NoteTab to}) {
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
  final screen = to == NoteTab.checks ? CheckListScreen(c: c) : HistoryScreen(c: c);
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

/// 狭い画面の下に浮かせるタブバー（ノート / 確認リスト / 履歴）
class NoteTabBar extends StatelessWidget {
  const NoteTabBar({super.key, required this.c, required this.current});
  final ManualController c;
  final NoteTab current;

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    final open = c.state?.openChecks.length ?? 0;
    final row = SizedBox(
      height: k.tabBarHeight,
      child: Row(children: [
        _tab(context, NoteTab.note, LucideIcons.fileText, 'ノート'),
        _tab(context, NoteTab.checks, LucideIcons.listChecks, '確認リスト', count: open),
        _tab(context, NoteTab.history, LucideIcons.history, '履歴'),
      ]),
    );
    final glass = DecoratedBox(
      decoration: BoxDecoration(
        color: tabBarBlur ? k.tabBarGlass : k.tabBarGlassSolid,
        borderRadius: k.radius.floating,
        border: Border.all(color: k.colors.rule, width: k.hairline),
      ),
      child: row,
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
            child: tabBarBlur
                ? BackdropFilter(filter: ImageFilter.blur(sigmaX: k.tabBarBlur, sigmaY: k.tabBarBlur), child: glass)
                : glass,
          ),
        ),
      ),
    );
  }

  Widget _tab(BuildContext context, NoteTab tab, IconData icon, String label, {int count = 0}) {
    final k = context.tokens;
    final selected = tab == current;
    final color = selected ? k.colors.action : k.colors.inkMuted;
    return Expanded(
      // MoonButton がボタンとして読み上げるので、ここでは選ばれているかだけを足す
      child: Semantics(
        selected: selected,
        child: MoonButton(
          height: k.tabBarHeight,
          isFullWidth: true,
          borderRadius: k.radius.floating,
          onTap: () => openNoteTab(context, c, from: current, to: tab),
          label: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, color: color),
              if (count > 0) ...[
                SizedBox(width: k.space.xs),
                StatusTag('$count', bg: k.colors.pendingBg, fg: k.colors.pending),
              ],
            ]),
            SizedBox(height: k.space.xs),
            Text(label, style: k.text.label.copyWith(color: color)),
          ]),
        ),
      ),
    );
  }
}
