import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:moon_design/moon_design.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import 'common.dart';
import 'help_screen.dart';
import 'home_screen.dart';
import 'manual_screen.dart';
import 'new_manual_screen.dart';
import 'open_checks_screen.dart';
import 'profile_screen.dart';
import 'search_screen.dart';

/// サイドバーで、いまいる画面
enum Place { input, checks, search, manuals, profile }

/// サイドバーを出す幅か。サイドバーを出しても、中身が広い画面の並べ方（文書と右パネル、一覧と詳細）を保てる幅からにする
bool showsSidebar(BuildContext context) {
  final k = context.tokens;
  return MediaQuery.sizeOf(context).width >= k.wideLayout + k.sidebarWidth;
}

/// 広い画面では、左にサイドバーを常に出して画面のあいだを直接移れるようにする。狭い画面では child だけ（押して進んで戻る）
class WithSidebar extends StatelessWidget {
  const WithSidebar({super.key, required this.api, required this.child, this.place, this.manualId});
  final Api api;
  final Widget child;
  final Place? place;

  /// マニュアルの中（マニュアル画面・確認リスト）にいるときの、そのマニュアル
  final String? manualId;

  @override
  Widget build(BuildContext context) {
    if (!showsSidebar(context)) return child;
    final k = context.tokens;
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(width: k.sidebarWidth, child: _Sidebar(api: api, place: place, manualId: manualId)),
      Container(width: k.hairline, color: k.colors.rule),
      Expanded(child: child),
    ]);
  }
}

/// 狭い画面の入力ページで、上部バーの三本線から左に出すメニュー。中身は広い画面のサイドバーと同じ。
/// 影は付けず、右の罫線で本文と区切る。項目を押すと、先にメニューを閉じてから open で移る
class SidebarDrawer extends StatelessWidget {
  const SidebarDrawer({super.key, required this.api, required this.place, required this.open});
  final Api api;
  final Place place;

  /// 画面を開く（入力ページの push。戻ってきたら入力ページを読み直す）
  final Future<void> Function(Widget screen) open;

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    return MoonDrawer(
      width: math.min(MediaQuery.sizeOf(context).width * k.drawerWidthFactor, k.drawerMaxWidth),
      semanticLabel: 'メニュー',
      decoration: BoxDecoration(
        color: k.colors.canvas,
        border: Border(right: BorderSide(color: k.colors.rule, width: k.hairline)),
      ),
      child: SafeArea(right: false, child: _Sidebar(api: api, place: place, open: open)),
    );
  }
}

class _Sidebar extends StatefulWidget {
  const _Sidebar({required this.api, this.place, this.manualId, this.open});
  final Api api;
  final Place? place;
  final String? manualId;

  /// メニュー（狭い画面）のときだけ。画面の開き方を入力ページに任せ、ふつうの横から出る動きで開く
  final Future<void> Function(Widget screen)? open;

  @override
  State<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<_Sidebar> {
  late Future<List<ManualSummary>> _manuals = _load();
  late Future<List<SharedManual>> _shared = _loadShared();

  @override
  void initState() {
    super.initState();
    widget.api.changes.addListener(_reload);
  }

  @override
  void dispose() {
    widget.api.changes.removeListener(_reload);
    super.dispose();
  }

  // 読めないとき（ログインする前など）はマニュアルを並べないだけにする。FutureBuilder が受け取る前に失敗しても漏れないよう、ここで受ける
  Future<List<ManualSummary>> _load() => widget.api.listManuals().catchError((Object _) => const <ManualSummary>[]);

  Future<List<SharedManual>> _loadShared() =>
      widget.api.listShared().catchError((Object _) => const <SharedManual>[]);

  void _reload() => setState(() {
        _manuals = _load();
        _shared = _loadShared();
      });

  /// 行き来するたびに画面が積み重ならないよう、最初の画面（入力ページ）まで戻してから開く。
  /// 広い画面のサイドバーでは、戻る動き・横から出る動きは付けない（違和感 #1）。
  /// pop だと上の画面の戻る動きが出るので、外すのは remove（動きなしで外れる）で行う
  void _go(Widget? screen) {
    // メニュー（狭い画面）：先にメニューを閉じてから移る。閉じずに移ると、戻ったときにメニューが開いたまま残る
    if (widget.open case final open?) {
      Scaffold.of(context).closeDrawer();
      if (screen != null) open(screen);
      return;
    }
    final nav = Navigator.of(context);
    if (screen != null) {
      // 動きなしで開き、その下の、最初の画面より上の画面は動きなしで外す
      nav.pushAndRemoveUntil(
        PageRouteBuilder<void>(
          pageBuilder: (_, _, _) => screen,
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
        ),
        (r) => r.isFirst,
      );
      return;
    }
    // 最初の画面に戻るだけのとき：上の画面を1つずつ remove で外す
    for (;;) {
      // いちばん上の画面を見るだけ（true を返すので何も外さない）
      late Route<dynamic> top;
      nav.popUntil((r) {
        top = r;
        return true;
      });
      if (top.isFirst) break;
      nav.removeRoute(top);
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    return Container(
      color: k.colors.canvas,
      child: FutureBuilder(
        future: _manuals,
        builder: (context, snap) {
          final manuals = snap.data ?? const <ManualSummary>[];
          final open = manuals.fold(0, (n, m) => n + m.openCount);
          // 上から：アプリ名 → 言われたことを記録 → あとで確認 → ノートを探す → 「ノート」と＋ → 全部のノート → 自分と使い方（いちばん下に固定）。
          // ノートの並びの所だけスクロールする
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: EdgeInsets.fromLTRB(k.space.sm, k.space.lg, k.space.sm, 0),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                // アプリ名。サイドバーの中で一番太く大きい文字にする。押せない（最初の画面へは「言われたことを記録」で戻る）
                Padding(
                  padding: EdgeInsets.fromLTRB(k.space.sm, 0, k.space.sm, k.space.md),
                  child: Text('DiffNote', maxLines: 1, overflow: TextOverflow.ellipsis, style: k.text.title),
                ),
                // 新しく書き始める所なので、チャットの「新しいチャット」と同じペンと四角のアイコンを付け、いちばん上に置く（違和感 #4）
                _item(
                  '言われたことを記録',
                  icon: LucideIcons.squarePen,
                  selected: widget.place == Place.input,
                  strong: true,
                  onTap: () => _go(null),
                ),
                // 全部のノートのあとで確認をまとめた画面へ。アイコンはタブバーの「確認リスト」と同じ
                _item(
                  'あとで確認',
                  icon: LucideIcons.listChecks,
                  selected: widget.place == Place.checks,
                  open: open,
                  onTap: () => _go(OpenChecksScreen(api: widget.api)),
                ),
                _item(
                  'ノートを探す',
                  icon: LucideIcons.search,
                  selected: widget.place == Place.search,
                  onTap: () => _go(SearchScreen(api: widget.api)),
                ),
              ]),
            ),
            SizedBox(height: k.space.lg),
            Padding(padding: EdgeInsets.symmetric(horizontal: k.space.sm), child: _notesHeading()),
            Expanded(
              child: FutureBuilder(
                future: _shared,
                builder: (context, snap) {
                  final shared = snap.data ?? const <SharedManual>[];
                  return ListView(
                    padding: EdgeInsets.symmetric(horizontal: k.space.sm),
                    children: [
                      for (final m in manuals)
                        _item(
                          m.title,
                          selected: widget.manualId == m.id,
                          open: m.openCount,
                          onTap: () => _go(ManualScreen(api: widget.api, manualId: m.id)),
                        ),
                      // ほかの人から共有されたノート。確定は持ち主がするので、あとで確認の件数は付けない（ADR 0013）
                      if (shared.isNotEmpty) ...[
                        SizedBox(height: k.space.lg),
                        SizedBox(
                          height: k.sidebarRow,
                          child: Padding(
                            padding: EdgeInsets.only(left: k.space.sm),
                            child: Align(alignment: Alignment.centerLeft, child: Text('共有されたノート', style: k.text.small)),
                          ),
                        ),
                        for (final m in shared)
                          _item(
                            m.title,
                            owner: m.sharedBy.name,
                            selected: widget.manualId == m.id,
                            onTap: () => _go(ManualScreen(api: widget.api, manualId: m.id)),
                          ),
                      ],
                    ],
                  );
                },
              ),
            ),
            Container(height: k.hairline, color: k.colors.rule),
            Padding(
              padding: EdgeInsets.all(k.space.sm),
              // 自分の右に使い方（?）。上部バーには置かない
              child: Row(children: [
                Expanded(
                  child: MeBuilder(
                    api: widget.api,
                    builder: (context, me) => _item(
                      me.name,
                      leading: Avatar(me.name, image: me.icon?.bytes),
                      selected: widget.place == Place.profile,
                      onTap: () => _go(ProfileScreen(api: widget.api)),
                    ),
                  ),
                ),
                SizedBox(width: k.space.xs),
                MoonButton.icon(
                  semanticLabel: '使い方を見る',
                  icon: Icon(LucideIcons.circleQuestionMark, color: k.colors.ink),
                  onTap: _help,
                ),
              ]),
            ),
          ]);
        },
      ),
    );
  }

  /// 使い方を開く。今いる画面の上に積み、戻るとその画面に戻る（サイドバーのほかの項目のように積み直さない）。
  /// メニュー（狭い画面）では、先にメニューを閉じてから開く
  void _help() {
    if (widget.open case final open?) {
      Scaffold.of(context).closeDrawer();
      open(const HelpScreen());
      return;
    }
    Navigator.push(context, MaterialPageRoute(builder: (_) => const HelpScreen()));
  }

  /// ノートの並びの小見出し。押すとノート一覧へ。右の＋でノートを作る（メニューに「ノート」の項目は別に作らない）
  Widget _notesHeading() {
    final k = context.tokens;
    final selected = widget.place == Place.manuals;
    return MoonMenuItem(
      onTap: () => _go(HomeScreen(api: widget.api)),
      height: k.sidebarRow,
      backgroundColor: selected ? k.colors.shell : null,
      borderRadius: k.radius.control,
      menuItemPadding: EdgeInsets.only(left: k.space.sm),
      label: Text('ノート', style: k.text.small.copyWith(fontWeight: selected ? FontWeight.w700 : null)),
      trailing: MoonButton.icon(
        buttonSize: MoonButtonSize.sm,
        semanticLabel: 'ノートを作る',
        onTap: () => _go(NewManualScreen(api: widget.api)),
        icon: Icon(LucideIcons.plus, size: k.sidebarIcon, color: k.colors.inkMuted),
      ),
    );
  }

  /// サイドバーの1項目。アイコン（あれば）+ 文字で、高さはそろえる。選んでいる項目は薄い地色にする
  Widget _item(String label,
      {required bool selected,
      required VoidCallback onTap,
      int open = 0,
      String? owner,
      IconData? icon,
      Widget? leading,
      bool strong = false}) {
    final k = context.tokens;
    final lead = leading ??
        (icon == null ? null : SizedBox(width: k.sidebarLeading, child: Icon(icon, size: k.sidebarIcon, color: k.colors.ink)));
    return MoonMenuItem(
      onTap: onTap,
      height: k.sidebarRow,
      backgroundColor: selected ? k.colors.shell : null,
      borderRadius: k.radius.control,
      menuItemPadding: EdgeInsets.symmetric(horizontal: k.space.sm),
      leading: lead,
      label: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: k.text.body.copyWith(fontWeight: selected || strong ? FontWeight.w700 : null),
      ),
      trailing: open > 0
          ? StatusTag('$open', bg: k.colors.pendingBg, fg: k.colors.pending)
          : owner == null
              ? null
              : ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: k.sidebarWidth / 3),
                  child: Text(owner, maxLines: 1, overflow: TextOverflow.ellipsis, style: k.text.small),
                ),
    );
  }
}
