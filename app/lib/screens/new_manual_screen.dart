import 'package:flutter/material.dart';
import 'package:moon_design/moon_design.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import '../web/files.dart';
import 'attach.dart';
import 'common.dart';
import 'manual_screen.dart';
import 'sidebar.dart';

/// ノートを作る。今あるマニュアルやメモを貼り付けるか、PDF・画像から読み取るか、白紙から始める。以後の変更は差分として積む
class NewManualScreen extends StatefulWidget {
  const NewManualScreen({super.key, required this.api, this.pickFiles = pickWithFilePicker});
  final Api api;

  /// 「ファイルを選ぶ」で選ぶ。テストではファイル選択の代わりを渡す
  final Future<List<PickedFile>> Function() pickFiles;

  @override
  State<NewManualScreen> createState() => _NewManualScreenState();
}

class _NewManualScreenState extends State<NewManualScreen> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  var _busy = false;
  var _formatting = false;
  var _reading = false;

  bool get _ready => _title.text.trim().isNotEmpty;
  bool get _blank => _body.text.trim().isEmpty;

  /// ドロップと貼り付けは、本文の欄にしたときだけ読み取る
  final _bodyKey = GlobalKey();
  final _bodyFocus = FocusNode();
  late final void Function() _stopWatchingDrops;

  @override
  void initState() {
    super.initState();
    _stopWatchingDrops = onFilesDropped((files, at) {
      final box = _bodyKey.currentContext?.findRenderObject() as RenderBox?;
      final onBody = at == null
          ? _bodyFocus.hasFocus
          : box != null && (box.localToGlobal(Offset.zero) & box.size).contains(at);
      if (onBody) _read(files);
    });
  }

  @override
  void dispose() {
    _stopWatchingDrops();
    _title.dispose();
    _body.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  /// 選んだ・撮った・貼り付けた・ドロップしたファイルを読み取り、本文を置き換える（ADR 0012）
  Future<void> _read(List<PickedFile> picked) async {
    if (_reading || _formatting || _busy || picked.isEmpty) return;
    final (:files, :rejected) = await toAttachments(picked);
    if (!mounted) return;
    if (rejected) showError(context, '読み取れるのは PDF と画像（PNG・JPEG・WebP・HEIC）です');
    if (files.isEmpty) return;
    if (files.fold(0, (n, f) => n + f.bytes.length) > maxAttachmentBytes) {
      showError(context, 'ファイルは合わせて10MBまでです。減らしてから選んでください');
      return;
    }
    setState(() => _reading = true);
    try {
      final r = await widget.api.readNote(files);
      if (!mounted) return;
      setState(() {
        _body.text = r.text;
        if (_title.text.trim().isEmpty) _title.text = r.title;
      });
    } on ApiException catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  Future<void> _format() async {
    final sent = _body.text;
    setState(() => _formatting = true);
    try {
      final text = await widget.api.format(sent.trim());
      if (!mounted) return;
      // 待っている間に本文を直していたら、古い本文への案なので出さない
      if (_body.text != sent) return;
      if (text == sent.trim()) {
        showToast(context, '整える所はありませんでした');
        return;
      }
      setState(() => _formatting = false);
      // 受け入れるまで本文は変えない（ADR 0011）
      final ok = await _showAsNote(
        heading: 'AI が整えた案',
        note: '本文はまだ変わっていません。よければこの形にしてください',
        text: text,
        actions: (ctx) => [
          MoonTextButton(onTap: () => Navigator.pop(ctx, false), label: const Text('やめる')),
          const Spacer(),
          MoonFilledButton(onTap: () => Navigator.pop(ctx, true), label: const Text('この形にする')),
        ],
      );
      if (ok == true && mounted) setState(() => _body.text = text);
    } on ApiException catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted && _formatting) setState(() => _formatting = false);
    }
  }

  /// 本文を、ノートと同じ見た目（見出し・箇条書き）でモーダルに見せる。差分の印は付けない
  Future<bool?> _showAsNote({
    required String heading,
    String? note,
    required String text,
    required List<Widget> Function(BuildContext ctx) actions,
  }) {
    final k = context.tokens;
    return showMoonModal<bool>(
      context: context,
      builder: (ctx) => MoonModal(
        backgroundColor: k.colors.canvas,
        child: ConstrainedBox(
          // 長いノートは中だけを送る
          constraints: BoxConstraints(maxWidth: k.modalWidth, maxHeight: MediaQuery.sizeOf(ctx).height - k.space.xxl * 2),
          child: Padding(
            padding: EdgeInsets.all(k.space.xl),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(heading, style: k.text.title),
              if (note != null) ...[
                SizedBox(height: k.space.xs),
                Text(note, style: k.text.small),
              ],
              SizedBox(height: k.space.md),
              const Rule(),
              Flexible(
                child: SingleChildScrollView(
                  padding: EdgeInsets.symmetric(vertical: k.space.md),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    for (final l in text.split('\n'))
                      Padding(padding: EdgeInsets.symmetric(vertical: k.space.xs), child: LineText(l)),
                  ]),
                ),
              ),
              const Rule(),
              SizedBox(height: k.space.lg),
              Row(children: actions(ctx)),
            ]),
          ),
        ),
      ),
    );
  }

  void _preview() => _showAsNote(
        heading: 'ノートの形で見る',
        text: _body.text.trim(),
        actions: (ctx) => [MoonOutlinedButton(onTap: () => Navigator.pop(ctx), label: const Text('閉じる'))],
      );

  Future<void> _create() async {
    setState(() => _busy = true);
    try {
      final s = await widget.api.createManual(_title.text.trim(), _body.text.trim());
      // 作ったらそのまま開き、すぐ書き始められるようにする
      if (mounted) {
        Navigator.pushReplacement(
            context, MaterialPageRoute(builder: (_) => ManualScreen(api: widget.api, manualId: s.id)));
      }
    } on ApiException catch (e) {
      if (mounted) showError(context, e);
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    return Scaffold(
      body: WithSidebar(api: widget.api, place: Place.manuals, child: GridBackground(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const TopBar(crumbs: ['DiffNote（仮）', 'ノートを作る']),
        Expanded(
          child: Narrow(
            child: ListView(padding: EdgeInsets.fromLTRB(k.space.xl, k.space.xxl, k.space.xl, k.space.xxl), children: [
              PageTitle('ノートを作る', meta: [Text('以後の変更は、このノートへの差分として積み上げます', style: k.text.small)]),
              SizedBox(height: k.space.xl),
              Text('何のノート？', style: k.text.heading),
              SizedBox(height: k.space.sm),
              MoonTextInput(
                controller: _title,
                hintText: '例: キッチンマニュアル / 自分用メモ / コーディング規約',
                onChanged: (_) => setState(() {}),
              ),
              SizedBox(height: k.space.xl),
              Text('最初の本文', style: k.text.heading),
              SizedBox(height: k.space.xs),
              Text('今あるマニュアルやメモは、そのまま貼り付けるか、「ファイルから読み取る」で PDF や写真から読み取ってください（欄へのドロップや貼り付けでも読み取れます）。マークダウン（「## 見出し」「- 項目」「**太字**」など）は1行ずつ整えて表示します。\n'
                  '平文のままなら「マークダウンに整える」で、AI が見出しと箇条書きに整えた案を出します。\n'
                  '無ければ空のままで、白紙から書き始められます。', style: k.text.small),
              SizedBox(height: k.space.sm),
              // expands を付けると moon_design 1.1.0 は文字を欄の縦の真ん中に置く。高さだけ決めて、文字・カーソル・例文を左上から始める
              MoonTextArea(
                key: _bodyKey,
                focusNode: _bodyFocus,
                controller: _body,
                height: k.editorHeight,
                textStyle: k.text.inputArea,
                onChanged: (_) => setState(() {}),
              ),
              SizedBox(height: k.space.sm),
              Wrap(spacing: k.space.sm, runSpacing: k.space.sm, children: [
                MoonOutlinedButton(
                  onTap: !_reading && !_formatting && !_busy ? () async => _read(await widget.pickFiles()) : null,
                  leading: _reading ? const _OutlinedLoader() : null,
                  label: Text(_reading ? '読み取っています…' : 'ファイルから読み取る'),
                ),
                MoonOutlinedButton(
                  onTap: !_blank && !_formatting && !_reading ? _format : null,
                  leading: _formatting ? const _OutlinedLoader() : null,
                  label: Text(_formatting ? '整えています…' : 'マークダウンに整える'),
                ),
                MoonOutlinedButton(onTap: !_blank ? _preview : null, label: const Text('ノートの形で見る')),
              ]),
              SizedBox(height: k.space.xl),
              Align(
                alignment: Alignment.centerLeft,
                child: MoonFilledButton(
                  onTap: _ready && !_busy && !_reading ? _create : null,
                  leading: _busy ? const ButtonLoader() : null,
                  label: Text(_busy ? '作っています…' : (_blank ? '白紙から始める' : 'この内容で作る')),
                ),
              ),
            ]),
          ),
        ),
      ]))),
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
