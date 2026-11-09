import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:moon_design/moon_design.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import 'common.dart';
import 'manual_screen.dart';
import 'sidebar.dart';

/// 全部のノート（共有されたノートも）の題名と本文から探す画面。サイドバーの「ノートを探す」から開く。
/// ノートは何冊もないので、全部を読んで手元で探す（「あとで確認」の画面と同じ）
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.api});
  final Api api;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _query = TextEditingController();
  late Future<List<ManualState>> _manuals = _load();

  @override
  void initState() {
    super.initState();
    widget.api.changes.addListener(_reload);
  }

  @override
  void dispose() {
    widget.api.changes.removeListener(_reload);
    _query.dispose();
    super.dispose();
  }

  Future<List<ManualState>> _load() async {
    final (own, shared) = await (widget.api.listManuals(), widget.api.listShared()).wait;
    return Future.wait([for (final id in [...own.map((m) => m.id), ...shared.map((m) => m.id)]) widget.api.getManual(id)]);
  }

  void _reload() => setState(() {
        _manuals = _load();
      });

  Future<void> _open(String id) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => ManualScreen(api: widget.api, manualId: id)));
  }

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    return Scaffold(
      body: WithSidebar(
        api: widget.api,
        place: Place.search,
        child: GridBackground(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const TopBar(crumbs: ['DiffNote（仮）', 'ノートを探す']),
          Expanded(
            child: Narrow(
              maxWidth: k.pageWidth,
              child: ListView(padding: EdgeInsets.fromLTRB(k.space.xl, k.space.xxl, k.space.xl, k.space.xxl), children: [
                const PageTitle('ノートを探す'),
                SizedBox(height: k.space.xl),
                MoonTextInput(
                  controller: _query,
                  autofocus: true,
                  hintText: '探す言葉',
                  leading: Icon(LucideIcons.search, color: k.colors.inkMuted),
                  onChanged: (_) => setState(() {}),
                ),
                SizedBox(height: k.space.xl),
                FutureBuilder(future: _manuals, builder: (context, snap) => _results(snap)),
              ]),
            ),
          ),
        ])),
      ),
    );
  }

  Widget _results(AsyncSnapshot<List<ManualState>> snap) {
    if (snap.hasError) return LoadFailed(message: snap.error.toString(), onRetry: _reload);
    if (!snap.hasData) return const Loading();
    final q = _query.text.trim();
    if (q.isEmpty) return const SizedBox.shrink();
    final k = context.tokens;
    final hits = <(ManualState, List<String>)>[];
    for (final s in snap.data!) {
      // マークダウンの印（「## 」「- 」など）では当てない
      final lines = [
        for (final l in s.lines)
          if (!isRule(l.text)) plain(l.text),
      ].where((t) => _has(t, q)).toList();
      if (lines.isNotEmpty || _has(s.title, q)) hits.add((s, lines));
    }
    if (hits.isEmpty) return Text('「$q」が書かれたノートはありません', style: k.text.small);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final (s, lines) in hits) ...[
        // 罫線が方眼とぶつからないよう、白い面に載せる
        PaperSheet(
          padding: EdgeInsets.symmetric(horizontal: k.space.sm),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            MoonMenuItem(
              onTap: () => _open(s.id),
              menuItemPadding: EdgeInsets.symmetric(horizontal: k.space.sm, vertical: k.space.md),
              label: _marked(s.title, q, k.text.heading),
              trailing: Icon(LucideIcons.chevronRight, color: k.colors.inkMuted),
            ),
            for (final l in lines) ...[
              const Rule(),
              MoonMenuItem(
                onTap: () => _open(s.id),
                menuItemPadding: EdgeInsets.symmetric(horizontal: k.space.sm, vertical: k.space.sm),
                label: _marked(l, q, k.text.body),
              ),
            ],
          ]),
        ),
        SizedBox(height: k.space.md),
      ],
    ]);
  }

  // 英字の大文字・小文字は区別しない
  bool _has(String text, String q) => text.toLowerCase().contains(q.toLowerCase());

  /// 当たった所を太字にした文
  Widget _marked(String text, String q, TextStyle style) {
    final lower = text.toLowerCase();
    final needle = q.toLowerCase();
    final spans = <TextSpan>[];
    var at = 0;
    for (var i = lower.indexOf(needle); i >= 0; i = lower.indexOf(needle, at)) {
      spans
        ..add(TextSpan(text: text.substring(at, i)))
        ..add(TextSpan(text: text.substring(i, i + needle.length), style: const TextStyle(fontWeight: FontWeight.w700)));
      at = i + needle.length;
    }
    spans.add(TextSpan(text: text.substring(at)));
    return Text.rich(TextSpan(style: style, children: spans));
  }
}
