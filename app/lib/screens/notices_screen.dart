import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:moon_design/moon_design.dart';

import '../api.dart';
import '../models.dart';
import '../note_store.dart';
import '../theme.dart';
import 'common.dart';
import 'manual_screen.dart';
import 'profile_screen.dart';
import 'sidebar.dart';

/// 自分のノートで、共有した相手が答えた・行を直したこと（ADR 0020）。サイドバーの自分から開く。
/// 通知は store にあるものをすぐ出し、裏で1本読み直す（ノートを開くときと同じ形。ADR 0021）。
/// 読み直してから見たことにし、開いた時点で前に見たときより後の通知に「新しい」を付ける
class NoticesScreen extends StatefulWidget {
  const NoticesScreen({super.key, required this.api});
  final Api api;

  @override
  State<NoticesScreen> createState() => _NoticesScreenState();
}

class _NoticesScreenState extends State<NoticesScreen> {
  NoteStore get _store => widget.api.store;

  /// 開いた時点の、通知を最後に見た時刻。見たことにしたあとも、開いている間は「新しい」の印をこれで付ける
  String? _seenAt;

  /// _seenAt を控えたか。見たことが無ければ _seenAt は null なので、別に持つ
  var _opened = false;

  @override
  void initState() {
    super.initState();
    _capture();
    _load();
  }

  /// 開いた時点の見た時刻を控える。store にまだ通知が無ければ、読めたときに控える
  void _capture() {
    final n = _store.notices;
    if (n == null || _opened) return;
    _seenAt = n.seenAt;
    _opened = true;
  }

  /// 裏で読み直し、そのあとで見たことにする。アプリを前面に開いたままだと戻ってきたときの読み直しが無いので、
  /// ここで読まないと届いていた通知が出ない。先に見たことにすると、読み直しで届いた通知が手元の見た時刻より後になり、
  /// サイドバーの数がまた出る
  void _load() {
    _store.load().then((_) {
      if (!mounted) return;
      setState(_capture);
      // 読み直せなかったら見たことにしない。最後に読めたあとに届いた通知を、出さないまま見たことにしてしまう。
      // 見たことにできなくても、通知は見せる。次に開いたときにまた新しいと出るだけ
      if (_opened && _store.error == null) widget.api.seeNotices().catchError((Object _) {});
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: WithSidebar(
        api: widget.api,
        place: Place.notices,
        child: GridBackground(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const TopBar(crumbs: ['通知']),
          Expanded(
            child: ListenableBuilder(
              listenable: _store,
              builder: (context, _) {
                final (me, notices) = (_store.me, _store.notices);
                if (!_opened || me == null || notices == null) {
                  return _store.error == null
                      ? const Loading()
                      : LoadFailed(message: _store.error.toString(), onRetry: () => setState(_load));
                }
                return _body(me, notices.items);
              },
            ),
          ),
        ])),
      ),
    );
  }

  Widget _body(Me me, List<Notice> items) {
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
                _notice(n, fresh: _seenAt == null || n.at.compareTo(_seenAt!) > 0),
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
          Text('${n.by.name}が${n.kind == 'answer' ? '回答しました' : 'ノートを編集しました'}', style: k.text.heading),
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
