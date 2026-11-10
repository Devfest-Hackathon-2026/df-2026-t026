import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:moon_design/moon_design.dart';

import '../api.dart';
import '../manual_controller.dart';
import '../models.dart';
import '../theme.dart';
import 'attach.dart';
import 'common.dart';
import 'material_screen.dart';
import 'sidebar.dart';
import 'tab_bar.dart';

/// 資料の題名の下に並べるもの：ページ数（貼り付けた文ならそう出す）と、誰がいつ足したか、
/// この資料と食い違った「あとで確認」の数（open）。一覧と資料の中でそろえる
List<Widget> materialMeta(BuildContext context, MaterialSummary m, {int open = 0}) {
  final k = context.tokens;
  final day = fmtDay(DateFormat('yyyy-MM-dd').format(DateTime.parse(m.createdAt).toLocal()));
  return [
    Text(m.pageCount == null ? '貼り付けた文' : '${m.pageCount}ページ', style: k.text.small),
    // 前からある資料には足した人が無い
    Text(m.addedBy == null ? '$day に足した' : '${m.addedBy!.name} が $day に足した', style: k.text.small),
    if (open > 0) StatusTag('あとで確認 $open 件', bg: k.colors.pendingBg, fg: k.colors.pending),
  ];
}

/// ノートに付けた資料（書き換えない原本）の一覧（ADR 0019）。ノートのページの上部バー「資料」から開く。
/// 共有された人も、持ち主と同じく足す・消すができる（ADR 0016 の共同編集に合わせる）
class MaterialsScreen extends StatefulWidget {
  const MaterialsScreen({super.key, required this.c, this.pickFiles = pickWithFilePicker});
  final ManualController c;

  /// 「ファイルから読み取る」で選ぶ。テストではファイル選択の代わりを渡す
  final Future<List<PickedFile>> Function() pickFiles;

  @override
  State<MaterialsScreen> createState() => _MaterialsScreenState();
}

class _MaterialsScreenState extends State<MaterialsScreen> {
  ManualController get c => widget.c;

  /// 資料は store に持たず、足したあとと、資料の中（そこで消せる）から戻ったときにだけ読み直す（ADR 0020）
  late Future<List<MaterialSummary>> _materials = c.api.listMaterials(c.manualId);

  void _reload() => setState(() {
        _materials = c.api.listMaterials(c.manualId);
      });

  Future<void> _add() async {
    final added = await showMoonModal<MaterialSummary>(
      context: context,
      builder: (_) => _AddDialog(api: c.api, manualId: c.manualId, pickFiles: widget.pickFiles),
    );
    if (added == null || !mounted) return;
    _reload();
    showToast(context, '資料「${added.title}」を足しました${added.pageCount == null ? '' : '（${added.pageCount}ページ）'}');
  }

  Future<void> _open(MaterialSummary m) async {
    await Navigator.push(
      context,
      MaterialPageRoute(settings: aboveNote(context), builder: (_) => MaterialScreen(c: c, materialId: m.id)),
    );
    if (mounted) _reload();
  }

  Widget _addButton() => MoonFilledButton(label: const Text('資料を足す'), onTap: _add);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: WithSidebar(api: c.api, manualId: c.manualId, child: GridBackground(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TopBar(crumbs: [c.state!.title, '資料']),
        // 確認リストで確定すると「あとで確認」の数が変わるので、ノートの状態も聞く
        Expanded(
          child: FutureBuilder(
            future: _materials,
            builder: (context, snap) => ListenableBuilder(listenable: c, builder: (context, _) => _body(snap)),
          ),
        ),
      ]))),
    );
  }

  Widget _body(AsyncSnapshot<List<MaterialSummary>> snap) {
    if (snap.hasError) return LoadFailed(message: snap.error.toString(), onRetry: _reload);
    if (!snap.hasData) return const Loading();
    final k = context.tokens;
    final materials = snap.data!;
    return Narrow(
      maxWidth: k.pageWidth,
      child: ListView(padding: EdgeInsets.fromLTRB(k.space.xl, k.space.xxl, k.space.xl, k.space.xxl), children: [
        PageTitle(
          '資料',
          meta: [if (materials.isNotEmpty) Text('${materials.length} 冊', style: k.text.small)],
          trailing: materials.isNotEmpty ? _addButton() : null,
        ),
        SizedBox(height: k.space.xl),
        if (materials.isEmpty)
          _empty()
        else
          for (final m in materials) ...[
            _sheet(m),
            SizedBox(height: k.space.md),
          ],
      ]),
    );
  }

  /// 資料1冊を、白い面1枚として見せる
  Widget _sheet(MaterialSummary m) {
    final k = context.tokens;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => _open(m),
        child: PaperSheet(
          padding: EdgeInsets.fromLTRB(k.space.xl, k.space.lg, k.space.lg, k.space.lg),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(m.title, style: k.text.heading),
                SizedBox(height: k.space.xs),
                Wrap(
                  spacing: k.space.md,
                  runSpacing: k.space.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: materialMeta(context, m, open: c.state!.openChecksIn(m.id).length),
                ),
              ]),
            ),
            SizedBox(width: k.space.md),
            Icon(LucideIcons.chevronRight, color: k.colors.inkMuted),
          ]),
        ),
      ),
    );
  }

  Widget _empty() {
    final k = context.tokens;
    return PaperSheet(
      padding: EdgeInsets.all(k.space.xxl),
      child: Column(children: [
        Text('まだ資料はありません', style: k.text.heading),
        SizedBox(height: k.space.sm),
        Text('店のマニュアルや授業の資料を足すと、言われたことと食い違っていないかも確かめます',
            style: k.text.small, textAlign: TextAlign.center),
        SizedBox(height: k.space.xl),
        _addButton(),
      ]),
    );
  }
}

/// 「資料を足す」のモーダル。文を貼り付けるか、ファイルを選んで読み取らせる。足せたら一覧の1件を返して閉じる。
/// 失敗したら知らせて、入れた題名と本文を残したまま開いておく
class _AddDialog extends StatefulWidget {
  const _AddDialog({required this.api, required this.manualId, required this.pickFiles});
  final Api api;
  final String manualId;
  final Future<List<PickedFile>> Function() pickFiles;

  @override
  State<_AddDialog> createState() => _AddDialogState();
}

class _AddDialogState extends State<_AddDialog> {
  final _title = TextEditingController();
  final _text = TextEditingController();
  var _reading = false;
  var _adding = false;

  bool get _busy => _reading || _adding;
  bool get _ready => _title.text.trim().isNotEmpty && _text.text.trim().isNotEmpty;

  @override
  void dispose() {
    _title.dispose();
    _text.dispose();
    super.dispose();
  }

  Future<void> _readFiles() async {
    final picked = await widget.pickFiles();
    if (!mounted || picked.isEmpty) return;
    final (:files, :rejected) = await toAttachments(picked);
    if (!mounted) return;
    if (rejected) showError(context, '読み取れるのは PDF と画像（PNG・JPEG・WebP・HEIC）です');
    if (files.isEmpty) return;
    if (files.fold(0, (n, f) => n + f.bytes.length) > maxAttachmentBytes) {
      showError(context, 'ファイルは合わせて10MBまでです。減らしてから選んでください');
      return;
    }
    setState(() => _reading = true);
    await _send(() => widget.api.addMaterial(widget.manualId, title: _title.text.trim(), files: files));
  }

  Future<void> _addText() async {
    setState(() => _adding = true);
    await _send(() => widget.api.addMaterial(widget.manualId, title: _title.text.trim(), text: _text.text.trim()));
  }

  Future<void> _send(Future<MaterialSummary> Function() add) async {
    try {
      final m = await add();
      if (mounted) Navigator.pop(context, m);
    } on ApiException catch (e) {
      if (!mounted) return;
      // 上限を超えたときなどの文言はサーバーが返す
      showError(context, e);
      setState(() {
        _reading = false;
        _adding = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    // 読み取りは長くかかるので、足している間は外を押しても閉じない
    return PopScope(
      canPop: !_busy,
      child: Padding(
        padding: EdgeInsets.all(k.space.lg),
        child: MoonModal(
          backgroundColor: k.colors.canvas,
          // Moon の入力欄は Material の祖先を要求する
          child: Material(
            type: MaterialType.transparency,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: k.modalWidth,
                maxHeight: MediaQuery.sizeOf(context).height - k.space.xxl * 2,
              ),
              child: SingleChildScrollView(
                padding: EdgeInsets.all(k.space.xl),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text('資料を足す', style: k.text.title),
                  SizedBox(height: k.space.lg),
                  Text('題名', style: k.text.small),
                  SizedBox(height: k.space.xs),
                  MoonTextInput(
                    controller: _title,
                    enabled: !_busy,
                    hintText: '例: 店舗マニュアル',
                    onChanged: (_) => setState(() {}),
                  ),
                  SizedBox(height: k.space.lg),
                  Text('本文', style: k.text.small),
                  SizedBox(height: k.space.xs),
                  MoonTextArea(
                    controller: _text,
                    enabled: !_busy,
                    height: k.composerHeight,
                    textStyle: k.text.inputArea,
                    hintText: '資料の文を貼り付ける',
                    onChanged: (_) => setState(() {}),
                  ),
                  SizedBox(height: k.space.lg),
                  // 狭い画面では、右の2つが次の行に回る
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    spacing: k.space.sm,
                    runSpacing: k.space.sm,
                    children: [
                      MoonOutlinedButton(
                        onTap: _busy ? null : _readFiles,
                        leading: _reading ? const _OutlinedLoader() : null,
                        label: Text(_reading ? '読み取っています…' : 'ファイルから読み取る'),
                      ),
                      Wrap(spacing: k.space.sm, runSpacing: k.space.sm, children: [
                        MoonTextButton(onTap: _busy ? null : () => Navigator.pop(context), label: const Text('やめる')),
                        MoonFilledButton(
                          onTap: _busy || !_ready ? null : _addText,
                          leading: _adding ? const ButtonLoader() : null,
                          label: Text(_adding ? '足しています…' : 'この文を資料にする'),
                        ),
                      ]),
                    ],
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 枠のボタンの読み込み中の印
class _OutlinedLoader extends StatelessWidget {
  const _OutlinedLoader();

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    return SizedBox.square(
      dimension: k.space.lg,
      child: MoonCircularLoader(color: k.colors.inkMuted, circularLoaderSize: MoonCircularLoaderSize.x2s),
    );
  }
}
