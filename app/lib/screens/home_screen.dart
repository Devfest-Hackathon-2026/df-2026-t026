import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:moon_design/moon_design.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import 'common.dart';
import 'manual_screen.dart';
import 'new_manual_screen.dart';
import 'sidebar.dart';

/// マニュアルの一覧。入力ページの上部バー「マニュアルを確認」から開く
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.api});
  final Api api;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late Future<List<ManualSummary>> _manuals = widget.api.listManuals();

  void _reload() => setState(() {
        _manuals = widget.api.listManuals();
      });

  Future<void> _open(String id) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => ManualScreen(api: widget.api, manualId: id)));
    _reload();
  }

  Future<void> _create() async {
    final id = await Navigator.push<String>(
        context, MaterialPageRoute(builder: (_) => NewManualScreen(api: widget.api)));
    if (id != null) await _open(id);
  }

  Widget _createButton() => MoonFilledButton(
        label: const Text('マニュアルを登録'),
        onTap: _create,
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: WithSidebar(api: widget.api, place: Place.manuals, child: GridBackground(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const TopBar(crumbs: ['DiffNote（仮）', 'マニュアル']),
        Expanded(child: FutureBuilder(future: _manuals, builder: (context, snap) => _body(snap))),
      ]))),
    );
  }

  Widget _body(AsyncSnapshot<List<ManualSummary>> snap) {
    if (snap.hasError) return LoadFailed(message: snap.error.toString(), onRetry: _reload);
    if (!snap.hasData) return const Loading();
    final manuals = snap.data!;

    final k = context.tokens;
    return Narrow(
      maxWidth: k.pageWidth,
      child: ListView(padding: EdgeInsets.fromLTRB(k.space.xl, k.space.xxl, k.space.xl, k.space.xxl), children: [
        PageTitle(
          'マニュアル',
          meta: [Text('教わったことを、言った人と日付つきでマニュアルに積み上げる', style: k.text.small)],
          trailing: manuals.isEmpty ? null : _createButton(),
        ),
        SizedBox(height: k.space.xl),
        if (manuals.isEmpty)
          _empty()
        else
          for (final m in manuals) ...[
            _sheet(m),
            SizedBox(height: k.space.md),
          ],
      ]),
    );
  }

  /// マニュアル1冊を、白い面1枚として見せる
  Widget _sheet(ManualSummary m) {
    final k = context.tokens;
    final c = k.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => _open(m.id),
        child: PaperSheet(
          padding: EdgeInsets.fromLTRB(k.space.xl, k.space.lg, k.space.lg, k.space.lg),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(m.title, style: k.text.title),
                SizedBox(height: k.space.xs),
                Wrap(spacing: k.space.md, runSpacing: k.space.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text('記録 ${m.utteranceCount} 件', style: k.text.small),
                  if (m.openCount > 0) StatusTag('あとで確認 ${m.openCount} 件', bg: c.pendingBg, fg: c.pending),
                ]),
              ]),
            ),
            SizedBox(width: k.space.md),
            Icon(LucideIcons.chevronRight, color: c.inkMuted),
          ]),
        ),
      ),
    );
  }

  /// 最初の1冊を登録するまでの案内
  Widget _empty() {
    final k = context.tokens;
    return PaperSheet(
      padding: EdgeInsets.all(k.space.xxl),
      child: Column(children: [
        Text('まだマニュアルがありません', style: k.text.heading),
        SizedBox(height: k.space.sm),
        Text(
          '今あるマニュアルを貼り付けて登録すると、\n口頭で教わったことをそこに積み上げていけます。',
          style: k.text.small,
          textAlign: TextAlign.center,
        ),
        SizedBox(height: k.space.xl),
        _createButton(),
      ]),
    );
  }
}
