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

  @override
  void initState() {
    super.initState();
    widget.api.store.ensureLoaded();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _reload() {
    widget.api.store.load();
    setState(() {});
  }

  /// line は押した行の番号。題名を押したときは省き、ノートの頭から見せる
  Future<void> _open(String id, String query, {int line = 0}) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ManualScreen(api: widget.api, manualId: id, found: (line: line, query: query))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    return Scaffold(
      body: WithSidebar(
        api: widget.api,
        place: Place.search,
        child: GridBackground(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const TopBar(crumbs: ['ノートを探す']),
          Expanded(
            child: Narrow(
              maxWidth: k.pageWidth,
              child: ListView(padding: EdgeInsets.fromLTRB(k.space.xl, k.space.xxl, k.space.xl, k.space.xxl), children: [
                const PageTitle('ノートを探す'),
                SizedBox(height: k.space.xl),
                MoonTextInput(
                  controller: _query,
                  autofocus: true,
                  leading: Icon(LucideIcons.search, color: k.colors.inkMuted),
                  onChanged: (_) => setState(() {}),
                ),
                SizedBox(height: k.space.xl),
                ListenableBuilder(listenable: widget.api.store, builder: (context, _) => _results()),
              ]),
            ),
          ),
        ])),
      ),
    );
  }

  Widget _results() {
    final store = widget.api.store;
    final notes = store.notes;
    if (notes == null) {
      return store.error == null ? const Loading() : LoadFailed(message: store.error.toString(), onRetry: _reload);
    }
    final q = _query.text.trim();
    if (q.isEmpty) return const SizedBox.shrink();
    final k = context.tokens;
    final hits = <(ManualState, List<(int, String)>)>[];
    for (final s in notes) {
      // マークダウンの印（「## 」「- 」など）では当てない
      final lines = [
        for (final (i, l) in s.lines.indexed)
          if (!isRule(l.text) && _has(plain(l.text), q)) (i, plain(l.text)),
      ];
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
              onTap: () => _open(s.id, q),
              menuItemPadding: EdgeInsets.symmetric(horizontal: k.space.sm, vertical: k.space.md),
              label: _marked(s.title, q, k.text.heading),
              trailing: Icon(LucideIcons.chevronRight, color: k.colors.inkMuted),
            ),
            for (final (i, l) in lines) ...[
              const Rule(),
              MoonMenuItem(
                onTap: () => _open(s.id, q, line: i),
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
