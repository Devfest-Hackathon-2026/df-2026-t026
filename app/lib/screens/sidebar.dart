import 'package:flutter/material.dart';
import 'package:moon_design/moon_design.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import 'common.dart';
import 'home_screen.dart';
import 'manual_screen.dart';

/// サイドバーで、いまいる画面
enum Place { input, manuals }

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

  // 読めないとき（合言葉を入れる前など）はマニュアルを並べないだけにする。FutureBuilder が受け取る前に失敗しても漏れないよう、ここで受ける
  Future<List<ManualSummary>> _load() => widget.api.listManuals().catchError((Object _) => const <ManualSummary>[]);

  void _reload() => setState(() {
        _manuals = _load();
      });

  /// 行き来するたびに画面が積み重ならないよう、最初の画面（入力ページ）まで戻してから開く
  void _go(Widget? screen) {
    final nav = Navigator.of(context);
    nav.popUntil((r) => r.isFirst);
    if (screen != null) nav.push(MaterialPageRoute(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    return Container(
      color: k.colors.canvas,
      child: FutureBuilder(
        future: _manuals,
        builder: (context, snap) => ListView(
          padding: EdgeInsets.symmetric(horizontal: k.space.sm, vertical: k.space.lg),
          children: [
            _item('言われたことを記録', selected: widget.place == Place.input, onTap: () => _go(null)),
            SizedBox(height: k.space.lg),
            _item('マニュアル', selected: widget.place == Place.manuals, onTap: () => _go(HomeScreen(api: widget.api))),
            for (final m in snap.data ?? const <ManualSummary>[])
              _item(
                m.title,
                nested: true,
                selected: widget.manualId == m.id,
                open: m.openCount,
                onTap: () => _go(ManualScreen(api: widget.api, manualId: m.id)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _item(String label, {required bool selected, required VoidCallback onTap, bool nested = false, int open = 0}) {
    final k = context.tokens;
    return MoonMenuItem(
      onTap: onTap,
      backgroundColor: selected ? k.colors.shell : null,
      borderRadius: k.radius.control,
      menuItemPadding: EdgeInsets.fromLTRB(nested ? k.space.lg : k.space.sm, k.space.sm, k.space.sm, k.space.sm),
      label: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: (nested ? k.text.body : k.text.heading).copyWith(fontWeight: selected ? FontWeight.w700 : null),
      ),
      trailing: open > 0 ? StatusTag('$open', bg: k.colors.pendingBg, fg: k.colors.pending) : null,
    );
  }
}
