import 'package:flutter/material.dart';
import 'package:moon_design/moon_design.dart';

import '../api.dart';
import '../history.dart';
import '../theme.dart';
import 'common.dart';
import 'manual_screen.dart';
import 'sidebar.dart';

/// ノートを作る。今あるマニュアルやメモを貼り付けるか、白紙から始める。以後の変更は差分として積む
class NewManualScreen extends StatefulWidget {
  const NewManualScreen({super.key, required this.api});
  final Api api;

  @override
  State<NewManualScreen> createState() => _NewManualScreenState();
}

class _NewManualScreenState extends State<NewManualScreen> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  var _busy = false;
  var _formatting = false;
  /// AI が整えた本文の案。受け入れるまで本文は変えない（ADR 0011）
  String? _suggestion;

  bool get _ready => _title.text.trim().isNotEmpty;
  bool get _blank => _body.text.trim().isEmpty;

  Future<void> _format() async {
    final sent = _body.text;
    setState(() {
      _formatting = true;
      _suggestion = null;
    });
    try {
      final text = await widget.api.format(sent.trim());
      if (!mounted) return;
      // 待っている間に本文を直していたら、古い本文への案なので出さない
      if (_body.text != sent) return;
      if (text == sent.trim()) {
        showToast(context, '整える所はありませんでした');
      } else {
        setState(() => _suggestion = text);
      }
    } on ApiException catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _formatting = false);
    }
  }

  void _accept() => setState(() {
        _body.text = _suggestion!;
        _suggestion = null;
      });

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
              Text('今あるマニュアルやメモは、そのまま貼り付けてください。マークダウン（「## 見出し」「- 項目」「**太字**」など）は1行ずつ整えて表示します。\n'
                  '平文のままなら「マークダウンに整える」で、AI が見出しと箇条書きに整えた案を出します。\n'
                  '無ければ空のままで、白紙から書き始められます。', style: k.text.small),
              SizedBox(height: k.space.sm),
              // expands を付けると moon_design 1.1.0 は文字を欄の縦の真ん中に置く。高さだけ決めて、文字・カーソル・例文を左上から始める
              MoonTextArea(
                controller: _body,
                height: k.editorHeight,
                textStyle: k.text.inputArea,
                // 手で直したら、案は前の本文に対するものになるので閉じる
                onChanged: (_) => setState(() => _suggestion = null),
              ),
              SizedBox(height: k.space.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: MoonOutlinedButton(
                  onTap: !_blank && !_formatting ? _format : null,
                  leading: _formatting
                      ? SizedBox.square(
                          dimension: k.space.lg,
                          child: MoonCircularLoader(color: k.colors.inkMuted, circularLoaderSize: MoonCircularLoaderSize.x2s),
                        )
                      : null,
                  label: Text(_formatting ? '整えています…' : 'マークダウンに整える'),
                ),
              ),
              if (_suggestion case final s?) ...[
                SizedBox(height: k.space.lg),
                Text('AI が整えた案', style: k.text.heading),
                SizedBox(height: k.space.xs),
                Text('本文はまだ変わっていません。違いを見て、よければこの形にしてください', style: k.text.small),
                SizedBox(height: k.space.sm),
                _SuggestionDiff(lineDiff(_body.text.trim().split('\n'), s.split('\n'))),
                SizedBox(height: k.space.sm),
                Row(children: [
                  MoonFilledButton(onTap: _accept, label: const Text('この形にする')),
                  SizedBox(width: k.space.sm),
                  MoonTextButton(onTap: () => setState(() => _suggestion = null), label: const Text('やめる')),
                ]),
              ],
              SizedBox(height: k.space.xl),
              Align(
                alignment: Alignment.centerLeft,
                child: MoonFilledButton(
                  onTap: _ready && !_busy ? _create : null,
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

/// 今の本文と整えた案の違いを、増えた行（緑）・消えた行（赤）で見せる
class _SuggestionDiff extends StatelessWidget {
  const _SuggestionDiff(this.lines);
  final List<DiffLine> lines;

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    final c = k.colors;
    return Container(
      decoration: BoxDecoration(
        color: c.canvas,
        border: Border.all(color: c.rule, width: k.hairline),
        borderRadius: k.radius.surface,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final l in lines)
          Builder(builder: (_) {
            final (mark, bg, fg) = switch (l.change) {
              LineChange.added => ('+', c.addedBg, c.added),
              // U+2212 は同梱フォントに無いので ASCII にする
              LineChange.removed => ('-', c.removedBg, c.removed),
              LineChange.kept => (' ', null, c.ink),
            };
            return Container(
              color: bg,
              padding: EdgeInsets.symmetric(horizontal: k.space.md, vertical: k.space.xs),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: k.space.lg, child: Text(mark, style: k.text.body.copyWith(color: fg))),
                Expanded(child: LineText(l.text, color: fg, compact: true)),
              ]),
            );
          }),
      ]),
    );
  }
}
