import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:moon_design/moon_design.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import 'common.dart';
import 'manual_screen.dart';
import 'profile_screen.dart';
import 'sidebar.dart';

/// 自分のノートで、共有した相手が答えた・行を直したこと（ADR 0020）。サイドバーの自分から開く。
/// 開いたら見たことにし、前に見たときより後の通知に「新しい」を付ける
class NoticesScreen extends StatefulWidget {
  const NoticesScreen({super.key, required this.api});
  final Api api;

  @override
  State<NoticesScreen> createState() => _NoticesScreenState();
}

class _NoticesScreenState extends State<NoticesScreen> {
  late Future<(Me, ({String? seenAt, List<Notice> items}))> _data = _load();

  // 見たことにすると changes が増えるので、changes では読み直さない（読み直すたびに見たことになり、新しいの印が消える）
  Future<(Me, ({String? seenAt, List<Notice> items}))> _load() async {
    final (me, notices) = await (widget.api.me(), widget.api.notices()).wait;
    // 見たことにできなくても、通知は見せる。次に開いたときにまた新しいと出るだけ
    widget.api.seeNotices().catchError((Object _) {});
    return (me, notices);
  }

  void _reload() => setState(() {
        _data = _load();
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: WithSidebar(
        api: widget.api,
        place: Place.notices,
        child: GridBackground(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const TopBar(crumbs: ['通知']),
          Expanded(
            child: FutureBuilder(
              future: _data,
              builder: (context, snap) {
                if (snap.hasError) return LoadFailed(message: snap.error.toString(), onRetry: _reload);
                if (!snap.hasData) return const Loading();
                final (me, notices) = snap.data!;
                return _body(me, notices.seenAt, notices.items);
              },
            ),
          ),
        ])),
      ),
    );
  }

  Widget _body(Me me, String? seenAt, List<Notice> items) {
    final k = context.tokens;
    return Narrow(
      maxWidth: k.pageWidth,
      child: ListView(padding: EdgeInsets.fromLTRB(k.space.xl, k.space.xxl, k.space.xl, k.space.xxl), children: [
        const PageTitle('通知'),
        SizedBox(height: k.space.lg),
        Row(children: [
          Avatar(me.name, image: me.icon?.bytes),
          SizedBox(width: k.space.sm),
          Flexible(child: Text(me.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: k.text.body)),
          SizedBox(width: k.space.md),
          MoonOutlinedButton(
            buttonSize: MoonButtonSize.sm,
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ProfileScreen(api: widget.api))),
            label: const Text('名前とアイコンを変える'),
          ),
        ]),
        SizedBox(height: k.space.xl),
        if (items.isEmpty)
          Text('ノートを共有した人が確認に答えたり、行を直したりすると、ここに出ます', style: k.text.small)
        else
          // 罫線が方眼とぶつからないよう、白い面に載せる
          PaperSheet(
            padding: EdgeInsets.symmetric(horizontal: k.space.sm),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final (i, n) in items.indexed) ...[
                if (i > 0) const Rule(),
                _notice(n, fresh: seenAt == null || n.at.compareTo(seenAt) > 0),
              ],
            ]),
          ),
      ]),
    );
  }

  /// 誰が何をした → 何が変わったか → どのノートでいつ。押すとそのノートを開く
  Widget _notice(Notice n, {required bool fresh}) {
    final k = context.tokens;
    final what = n.kind == 'answer'
        ? '「${plain(n.line ?? '')}」→「${plain(n.text)}」${n.note == null || n.note!.isEmpty || n.note == n.text ? '' : '（${n.note}）'}'
        : editSummary(n.op ?? '', n.line, n.text);
    return MoonMenuItem(
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ManualScreen(api: widget.api, manualId: n.manualId))),
      menuItemPadding: EdgeInsets.symmetric(horizontal: k.space.sm, vertical: k.space.md),
      menuItemCrossAxisAlignment: CrossAxisAlignment.start,
      leading: SpeakerFace(n.by.name),
      label: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: k.space.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('${n.by.name}が${n.kind == 'answer' ? '確認に答えました' : '行を直しました'}', style: k.text.heading),
          if (fresh) StatusTag('新しい', bg: k.colors.found, fg: k.colors.action),
        ]),
        SizedBox(height: k.space.xs),
        Text(what, maxLines: 2, overflow: TextOverflow.ellipsis, style: k.text.body),
        SizedBox(height: k.space.xs),
        Text('${n.title}　${DateFormat('M/d H:mm').format(DateTime.parse(n.at).toLocal())}', style: k.text.small),
      ]),
      trailing: Icon(LucideIcons.chevronRight, color: k.colors.inkMuted),
    );
  }
}
