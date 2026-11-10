import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:moon_design/moon_design.dart';

import '../api.dart';
import '../manual_controller.dart';
import '../models.dart';
import '../theme.dart';
import 'check_list_screen.dart';
import 'common.dart';
import 'sidebar.dart';

/// 「あとで確認」がある各ノートの並び。確認リストはノートごとなので、件数とともに1冊ずつ並べる。
/// 入力ページの「あとで確認」の節と、サイドバーから開く「あとで確認」の画面の両方で使う
class OpenChecksList extends StatelessWidget {
  const OpenChecksList({super.key, required this.manuals, required this.onOpen});
  final List<ManualState> manuals;

  /// そのノートの確認リストを開く
  final void Function(ManualState) onOpen;

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    final open = manuals.where((s) => s.openChecks.isNotEmpty).toList();
    if (open.isEmpty) return Text('食い違いは、いまはありません', style: k.text.small);
    // 自分が人に聞くことと、共有した人から答えを待たれていること（ADR 0017）を分ける。共有されたノートが無ければ今までどおり1つ
    final mine = open.where((s) => s.sharedBy == null).toList();
    final asked = open.where((s) => s.sharedBy != null).toList();
    if (asked.isEmpty) return _sheet(context, mine);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (mine.isNotEmpty) ...[
        Text('自分が聞くこと', style: k.text.heading),
        SizedBox(height: k.space.sm),
        _sheet(context, mine),
        SizedBox(height: k.space.lg),
      ],
      Text('聞かれていること', style: k.text.heading),
      SizedBox(height: k.space.sm),
      _sheet(context, asked),
    ]);
  }

  /// 罫線が方眼とぶつからないよう、白い面に載せる。共有されたノートは件数の左に持ち主の名前を添える
  Widget _sheet(BuildContext context, List<ManualState> notes) {
    final k = context.tokens;
    return PaperSheet(
      padding: EdgeInsets.symmetric(horizontal: k.space.sm),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final (i, s) in notes.indexed) ...[
          if (i > 0) const Rule(),
          MoonMenuItem(
            onTap: () => onOpen(s),
            menuItemPadding: EdgeInsets.symmetric(horizontal: k.space.sm, vertical: k.space.md),
            label: Text(s.title, style: k.text.heading),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (s.sharedBy case final owner?) ...[
                Text(owner.name, style: k.text.small),
                SizedBox(width: k.space.sm),
              ],
              StatusTag('あとで確認 ${s.openChecks.length} 件', bg: k.colors.pendingBg, fg: k.colors.pending),
              SizedBox(width: k.space.sm),
              Icon(LucideIcons.chevronRight, color: k.colors.inkMuted),
            ]),
          ),
        ],
      ]),
    );
  }
}

/// 全部のノートの「あとで確認」をまとめた画面。サイドバーの「あとで確認」から開く
class OpenChecksScreen extends StatefulWidget {
  const OpenChecksScreen({super.key, required this.api});
  final Api api;

  @override
  State<OpenChecksScreen> createState() => _OpenChecksScreenState();
}

class _OpenChecksScreenState extends State<OpenChecksScreen> {
  late Future<List<ManualState>> _manuals = _load();

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

  /// 自分のノートと、共有されたノート（共有された人も記録・確定できる。ADR 0016）
  Future<List<ManualState>> _load() async {
    // 失敗を ParallelWaitError で包まず、画面にそのまま出せる ApiException で受ける
    final ids = await Future.wait([
      widget.api.listManuals().then((l) => [for (final m in l) m.id]),
      widget.api.listShared().then((l) => [for (final m in l) m.id]),
    ]);
    return Future.wait([for (final id in ids.expand((x) => x)) widget.api.getManual(id)]);
  }

  void _reload() => setState(() {
        _manuals = _load();
      });

  // 入力ページと同じく「ノートの外から開いた」確認リストにする（ノートの上に積んだ印は付けない）
  Future<void> _open(ManualState s) async {
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => CheckListScreen(c: ManualController(widget.api, s.id, s))));
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: WithSidebar(
        api: widget.api,
        place: Place.checks,
        child: GridBackground(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const TopBar(crumbs: ['あとで確認']),
          Expanded(child: FutureBuilder(future: _manuals, builder: (context, snap) => _body(snap))),
        ])),
      ),
    );
  }

  Widget _body(AsyncSnapshot<List<ManualState>> snap) {
    if (snap.hasError) return LoadFailed(message: snap.error.toString(), onRetry: _reload);
    if (!snap.hasData) return const Loading();
    final k = context.tokens;
    final open = snap.data!.fold(0, (n, s) => n + s.openChecks.length);
    return Narrow(
      maxWidth: k.pageWidth,
      child: ListView(padding: EdgeInsets.fromLTRB(k.space.xl, k.space.xxl, k.space.xl, k.space.xxl), children: [
        PageTitle('あとで確認', meta: [
          Text('ノートと食い違っていて、あとで人に聞くこと', style: k.text.small),
          if (open > 0) StatusTag('全部で $open 件', bg: k.colors.pendingBg, fg: k.colors.pending),
        ]),
        SizedBox(height: k.space.xl),
        OpenChecksList(manuals: snap.data!, onOpen: _open),
      ]),
    );
  }
}
