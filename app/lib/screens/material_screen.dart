import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:moon_design/moon_design.dart';

import '../api.dart';
import '../manual_controller.dart';
import '../models.dart';
import '../theme.dart';
import 'common.dart';
import 'materials_screen.dart';
import 'sidebar.dart';

/// 資料1冊の中（ADR 0016）。書き起こした文を、ページの区切りつきで1行ずつ見せる。
/// 資料は書き換えないので、行を押しても編集の欄は開かない
class MaterialScreen extends StatefulWidget {
  const MaterialScreen({super.key, required this.c, required this.materialId, this.lineNo});
  final ManualController c;
  final String materialId;

  /// 開いたときに送る行の番号（1始まり、ページをまたいで通し）。その行に薄い青の地を付ける
  final int? lineNo;

  @override
  State<MaterialScreen> createState() => _MaterialScreenState();
}

class _MaterialScreenState extends State<MaterialScreen> {
  ManualController get c => widget.c;

  late Future<MaterialBody> _material = _load();

  /// 上部バーの「…」（その他）のメニューを開いているか
  var _more = false;

  /// 送る行。開いて最初に読めたときに1度だけ、その行まで送る
  final _lineKey = GlobalKey();
  late var _toLine = widget.lineNo != null;

  bool get _mine => c.state!.sharedBy == null;

  Future<MaterialBody> _load() => c.api.getMaterial(c.manualId, widget.materialId);

  void _reload() => setState(() {
        _material = _load();
      });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _material,
      builder: (context, snap) {
        final m = snap.data;
        return Scaffold(
          body: WithSidebar(api: c.api, manualId: c.manualId, child: GridBackground(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TopBar(
              crumbs: [c.state!.title, '資料', m?.title ?? ''],
              trailing: _mine && m != null ? _moreMenu(m) : null,
            ),
            Expanded(child: _body(snap)),
          ]))),
        );
      },
    );
  }

  Widget _body(AsyncSnapshot<MaterialBody> snap) {
    final k = context.tokens;
    // 消された資料を開いたとき。読み直しても戻らないので、読み直しは出さない
    if (snap.error case ApiException(status: 404)) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(k.space.xl),
          child: Text('この資料は消されています', style: k.text.body, textAlign: TextAlign.center),
        ),
      );
    }
    if (snap.hasError) return LoadFailed(message: snap.error.toString(), onRetry: _reload);
    if (!snap.hasData) return const Loading();
    final m = snap.data!;
    if (_toLine) {
      _toLine = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_lineKey.currentContext case final ctx?) Scrollable.ensureVisible(ctx, alignment: 0.3);
      });
    }
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(k.space.lg, k.space.xl, k.space.lg, k.space.xxl),
      child: Narrow(
        child: PaperSheet(
          padding: EdgeInsets.fromLTRB(k.space.lg, k.space.xxl, k.space.xl, k.space.xxl),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: EdgeInsets.only(left: k.gutter),
              child: PageTitle(m.title, meta: materialMeta(context, m)),
            ),
            SizedBox(height: k.space.xl),
            // ノートと同じく全行を並べる。送る行に GlobalKey を付けるため、ListView.builder にはしない
            for (final (i, l) in m.lines.indexed) ...[
              if (l.page case final page? when i == 0 || m.lines[i - 1].page != page) _pageMark(page, first: i == 0),
              _line(l.text, i + 1),
            ],
          ]),
        ),
      ),
    );
  }

  /// ページの変わり目。紙のどこに書いてあるかを見比べられるよう、罫線と「p.3」を出す
  Widget _pageMark(int page, {required bool first}) {
    final k = context.tokens;
    return Padding(
      padding: EdgeInsets.only(left: k.gutter, top: first ? 0 : k.space.lg, bottom: k.space.xs),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (!first) ...[const Rule(), SizedBox(height: k.space.sm)],
        Text('p.$page', style: k.text.small),
      ]),
    );
  }

  /// 1行。見た目はノートの行にそろえる
  Widget _line(String text, int lineNo) {
    final k = context.tokens;
    final row = Padding(
      padding: isHeading(text)
          ? EdgeInsets.fromLTRB(k.gutter, k.space.xl, 0, k.space.xs)
          : EdgeInsets.fromLTRB(k.gutter, k.space.xs, 0, k.space.xs),
      child: LineText(text),
    );
    if (lineNo != widget.lineNo) return row;
    return KeyedSubtree(key: _lineKey, child: ColoredBox(color: k.colors.found, child: row));
  }

  /// 上部バーの「…」（その他）。ノートのページの「…」と同じ形。持ち主だけに出す
  Widget _moreMenu(MaterialBody m) {
    final k = context.tokens;
    return MoonDropdown(
      show: _more,
      dropdownAnchorPosition: MoonDropdownAnchorPosition.bottomRight,
      backgroundColor: k.colors.canvas,
      borderColor: k.colors.rule,
      onTapOutside: () => setState(() => _more = false),
      // 既定では画面いっぱいまで広がるので、項目の幅に合わせる
      content: IntrinsicWidth(
        child: MoonMenuItem(
          borderRadius: k.radius.control,
          onTap: () {
            setState(() => _more = false);
            _confirmDelete(m);
          },
          // 危ない操作なので文字を消した行と同じ赤にする
          label: Text('資料を消す', style: k.text.body.copyWith(color: k.colors.removed)),
        ),
      ),
      child: MoonButton.icon(
        buttonSize: MoonButtonSize.sm,
        semanticLabel: 'その他',
        backgroundColor: _more ? k.colors.shell : null,
        onTap: () => setState(() => _more = !_more),
        icon: Icon(LucideIcons.ellipsis, color: k.colors.ink),
      ),
    );
  }

  /// 消す前に必ず確かめる（元に戻せない）。消せたら前の画面（資料の一覧）に戻る
  Future<void> _confirmDelete(MaterialBody m) async {
    final nav = Navigator.of(context);
    final deleted = await showMoonModal<bool>(
      context: context,
      // 消している間に外を押して閉じると、消えた資料の画面に取り残される。閉じるのは「やめる」だけ
      barrierDismissible: false,
      builder: (_) => _DeleteDialog(api: c.api, manualId: c.manualId, material: m),
    );
    if (deleted != true || !mounted) return;
    nav.pop();
    // この画面は外れるので、知らせは Navigator の上に出す
    showToast(nav.context, '資料を消しました');
  }
}

/// 「この資料を消しますか？」。消している間はボタンを押せなくし、二重に送らない。
/// 消せたら true で閉じる。失敗したら知らせて閉じ、資料はそのまま
class _DeleteDialog extends StatefulWidget {
  const _DeleteDialog({required this.api, required this.manualId, required this.material});
  final Api api;
  final String manualId;
  final MaterialSummary material;

  @override
  State<_DeleteDialog> createState() => _DeleteDialogState();
}

class _DeleteDialogState extends State<_DeleteDialog> {
  var _busy = false;

  Future<void> _delete() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.api.deleteMaterial(widget.manualId, widget.material.id);
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (!mounted) return;
      final nav = Navigator.of(context);
      nav.pop(false);
      showError(nav.context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    return Padding(
      padding: EdgeInsets.all(k.space.lg),
      child: MoonModal(
        backgroundColor: k.colors.canvas,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: k.modalWidth),
          child: Padding(
            padding: EdgeInsets.all(k.space.xl),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('この資料を消しますか？', style: k.text.title),
              SizedBox(height: k.space.md),
              Text(
                '「${widget.material.title}」を消します。これからの照らし合わせには使いません。'
                'この資料と食い違った確認は、確認リストに残ります。元に戻せません。',
                style: k.text.body,
              ),
              SizedBox(height: k.space.xl),
              Row(children: [
                // 危ない操作なので、消した行と同じ赤にする
                MoonFilledButton(
                  backgroundColor: k.colors.removed,
                  onTap: _busy ? null : _delete,
                  label: Text(_busy ? '消しています…' : '消す'),
                ),
                SizedBox(width: k.space.sm),
                MoonOutlinedButton(
                  onTap: _busy ? null : () => Navigator.pop(context, false),
                  label: const Text('やめる'),
                ),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}
