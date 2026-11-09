import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:moon_design/moon_design.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import 'common.dart';
import 'home_screen.dart';
import 'manual_screen.dart';
import 'new_manual_screen.dart';
import 'open_checks_screen.dart';
import 'profile_screen.dart';

/// サイドバーで、いまいる画面
enum Place { input, checks, manuals, profile }

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

class _Sidebar extends StatefulWidget {
  const _Sidebar({required this.api, this.place, this.manualId});
  final Api api;
  final Place? place;
  final String? manualId;

  @override
  State<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<_Sidebar> {
  late Future<List<ManualSummary>> _manuals = _load();

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

  void _reload() => setState(() {
        _manuals = _load();
      });

  /// 行き来するたびに画面が積み重ならないよう、最初の画面（入力ページ）まで戻してから開く。
  /// サイドバーが出ている（広い画面）ときだけ使うので、戻る動き・横から出る動きは付けない（違和感 #1）。
  /// pop だと上の画面の戻る動きが出るので、外すのは remove（動きなしで外れる）で行う
  void _go(Widget? screen) {
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
          // 上から：言われたことを記録 → あとで確認 → 「ノート」と＋ → 全部のノート → 自分（いちばん下に固定）。
          // ノートの並びの所だけスクロールする
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: EdgeInsets.fromLTRB(k.space.sm, k.space.lg, k.space.sm, 0),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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
              ]),
            ),
            SizedBox(height: k.space.lg),
            Padding(padding: EdgeInsets.symmetric(horizontal: k.space.sm), child: _notesHeading()),
            Expanded(
              child: ListView(
                padding: EdgeInsets.symmetric(horizontal: k.space.sm),
                children: [
                  for (final m in manuals)
                    _item(
                      m.title,
                      selected: widget.manualId == m.id,
                      open: m.openCount,
                      onTap: () => _go(ManualScreen(api: widget.api, manualId: m.id)),
                    ),
                ],
              ),
            ),
            Container(height: k.hairline, color: k.colors.rule),
            Padding(
              padding: EdgeInsets.all(k.space.sm),
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
          ]);
        },
      ),
    );
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
      trailing: open > 0 ? StatusTag('$open', bg: k.colors.pendingBg, fg: k.colors.pending) : null,
    );
  }
}
