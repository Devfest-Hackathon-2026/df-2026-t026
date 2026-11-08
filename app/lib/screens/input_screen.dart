import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:moon_design/moon_design.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../manual_controller.dart';
import '../models.dart';
import '../theme.dart';
import 'check_list_screen.dart';
import 'common.dart';
import 'home_screen.dart';
import 'manual_screen.dart';
import 'new_manual_screen.dart';
import 'review_dialog.dart';
import 'sidebar.dart';

/// 合言葉をブラウザ（shared_preferences）に覚えておくときのキー
const passcodeKey = 'passcode';

/// 添えられるファイルの拡張子と形式。バックエンドが受け付ける形式と揃える
const _fileTypes = {
  'pdf': 'application/pdf',
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'webp': 'image/webp',
  'heic': 'image/heic',
};

/// バックエンドの上限（base64 で 15MB）に収まる元の大きさ
const _maxAttachmentBytes = 10 * 1024 * 1024;

/// 最近の記録に並べる数
const _recentCount = 5;

/// アプリを開いて最初の画面。どのマニュアルかを選ばずに、書く・ファイルを添える・録音するで記録する（ADR 0005）
class InputScreen extends StatefulWidget {
  const InputScreen({super.key, required this.api});
  final Api api;

  @override
  State<InputScreen> createState() => _InputScreenState();
}

class _InputScreenState extends State<InputScreen> {
  late Future<List<ManualState>> _manuals = _load();
  final _text = TextEditingController();
  final _files = <Attachment>[];
  var _busy = false;

  /// 使うときに作る。作るだけでマイクの用意が走るため
  AudioRecorder? _recorder;
  var _recording = false;

  @override
  void dispose() {
    _text.dispose();
    _recorder?.dispose();
    super.dispose();
  }

  Future<List<ManualState>> _load() async {
    final list = await widget.api.listManuals();
    return Future.wait([for (final m in list) widget.api.getManual(m.id)]);
  }

  void _reload() => setState(() {
        _manuals = _load();
      });

  Future<void> _enter(String passcode) async {
    widget.api.passcode = passcode;
    _reload();
    try {
      await _manuals;
    } catch (_) {
      return; // 違っていれば FutureBuilder がもう一度合言葉を聞く
    }
    // 次に開いたときにまた聞かなくて済むよう、ブラウザに覚えておく
    await (await SharedPreferences.getInstance()).setString(passcodeKey, passcode);
  }

  bool get _ready => _text.text.trim().isNotEmpty || _files.isNotEmpty;

  Future<void> _pickFiles() async {
    final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: _fileTypes.keys.toList());
    final added = [
      for (final f in picked)
        if (_fileTypes[f.extension?.toLowerCase()] case final mimeType?)
          Attachment(name: f.name, mimeType: mimeType, bytes: await f.xFile.readAsBytes()),
    ];
    _addFiles(added);
  }

  void _addFiles(List<Attachment> added) {
    if (!mounted || added.isEmpty) return;
    final total = [..._files, ...added].fold(0, (n, f) => n + f.bytes.length);
    if (total > _maxAttachmentBytes) {
      showError(context, 'ファイルと録音は合わせて10MBまでです。減らしてから添えてください');
      return;
    }
    setState(() => _files.addAll(added));
  }

  Future<void> _toggleRecording() async {
    final rec = _recorder ??= AudioRecorder();
    if (_recording) {
      // Web では録音を blob の URL で返すので、そこから中身を読む
      final url = await rec.stop();
      setState(() => _recording = false);
      if (url == null) return;
      final n = _files.where((f) => f.mimeType == 'audio/wav').length + 1;
      _addFiles([Attachment(name: '録音 $n', mimeType: 'audio/wav', bytes: await http.readBytes(Uri.parse(url)))]);
      return;
    }
    if (!await rec.hasPermission()) {
      if (mounted) showError(context, 'マイクを使えません。ブラウザの設定でマイクを許可してください');
      return;
    }
    // Gemini が読める WAV にする。話し声なので 16kHz・モノラルで足りる。path は Web では使われない
    await rec.start(const RecordConfig(encoder: AudioEncoder.wav, sampleRate: 16000, numChannels: 1), path: '');
    setState(() => _recording = true);
  }

  Future<void> _submit(List<ManualState> manuals) async {
    if (!_ready || _busy || _recording) return;
    setState(() => _busy = true);
    try {
      var r = await widget.api.intake(text: _text.text.trim(), files: _files, today: today());
      if (r.results.isEmpty) {
        setState(() => _busy = false);
        final id = await _pickManual(manuals, r.text);
        if (id == null) return;
        setState(() => _busy = true);
        // ファイルや録音はもう読み取ったので、読み取った文面だけを送り直す
        r = await widget.api.intake(text: r.text, manualIds: [id], today: today());
      }
      _text.clear();
      setState(() {
        _files.clear();
        _busy = false;
      });
      for (final x in r.results) {
        if (!mounted) return;
        await showReview(context, ManualController(widget.api, x.manualId, x.state), x.utteranceId);
      }
    } on ApiException catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _reload();
      }
    }
  }

  /// 関係するマニュアルが見つからなかったときに、記録先を選んでもらう
  Future<String?> _pickManual(List<ManualState> manuals, String text) {
    final k = context.tokens;
    return showMoonModal<String>(
      context: context,
      builder: (ctx) => MoonModal(
        backgroundColor: k.colors.canvas,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: k.modalWidth),
          child: Padding(
            padding: EdgeInsets.all(k.space.xl),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('どのマニュアルに記録しますか？', style: k.text.title),
              SizedBox(height: k.space.xs),
              Text('関係するマニュアルが見つかりませんでした。記録するマニュアルを選んでください', style: k.text.small),
              SizedBox(height: k.space.md),
              Text('「$text」', style: k.text.body),
              SizedBox(height: k.space.lg),
              const Rule(),
              for (final m in manuals) ...[
                MoonMenuItem(
                  onTap: () => Navigator.pop(ctx, m.id),
                  menuItemPadding: EdgeInsets.symmetric(horizontal: k.space.sm, vertical: k.space.md),
                  label: Text(m.title, style: k.text.heading),
                  trailing: Icon(LucideIcons.chevronRight, color: k.colors.inkMuted),
                ),
                const Rule(),
              ],
              SizedBox(height: k.space.lg),
              Align(
                alignment: Alignment.centerLeft,
                child: MoonOutlinedButton(label: const Text('記録しない'), onTap: () => Navigator.pop(ctx)),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _push(Widget screen) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: WithSidebar(api: widget.api, place: Place.input, child: GridBackground(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TopBar(
          crumbs: const ['DiffNote（仮）'],
          // サイドバーが出ている幅では、そこからマニュアルへ移れるので出さない
          trailing: showsSidebar(context)
              ? null
              : MoonOutlinedButton(
                  buttonSize: MoonButtonSize.sm,
                  onTap: () => _push(HomeScreen(api: widget.api)),
                  label: const Text('マニュアルを確認'),
                ),
        ),
        Expanded(child: FutureBuilder(future: _manuals, builder: (context, snap) => _body(snap))),
      ]))),
    );
  }

  Widget _body(AsyncSnapshot<List<ManualState>> snap) {
    if (snap.error case ApiException(status: 401, :final message)) {
      return _PasscodeForm(message: message, onSubmit: _enter);
    }
    if (snap.hasError) return LoadFailed(message: snap.error.toString(), onRetry: _reload);
    if (!snap.hasData) return const Loading();
    final manuals = snap.data!;

    final k = context.tokens;
    return LayoutBuilder(builder: (context, box) {
      // 広い画面では、書く欄とあとで確認を左に、最近の付箋を右に並べ、書きながら前の記録を見られるようにする
      final wide = box.maxWidth >= k.wideLayout;
      return Narrow(
        maxWidth: wide ? k.readableWidth + k.space.xxl + k.panelWidth : null,
        child: ListView(padding: EdgeInsets.fromLTRB(k.space.xl, k.space.xxl, k.space.xl, k.space.xxl), children: [
          PageTitle('言われたことを記録', meta: [Text('どのマニュアルのことかは選ばなくてかまいません', style: k.text.small)]),
          SizedBox(height: k.space.xl),
          if (manuals.isEmpty)
            _empty()
          else if (wide)
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  _composer(manuals, wide: true),
                  SizedBox(height: k.space.xxl),
                  ..._openChecks(manuals),
                ]),
              ),
              SizedBox(width: k.space.xxl),
              SizedBox(
                width: k.panelWidth,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _recent(manuals, noteWidth: k.panelWidth)),
              ),
            ])
          else ...[
            _composer(manuals),
            SizedBox(height: k.space.xxl),
            ..._openChecks(manuals),
            SizedBox(height: k.space.xxl),
            ..._recent(manuals),
          ],
        ]),
      );
    });
  }

  /// 書く欄。白い面に載せる。Ctrl/⌘+Enter でも送れる（Slack やレビューのコメントを貼って、そのまま送る使い方のため）
  Widget _composer(List<ManualState> manuals, {bool wide = false}) {
    final k = context.tokens;
    void submit() => _submit(manuals);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): submit,
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): submit,
      },
      child: PaperSheet(
        padding: EdgeInsets.fromLTRB(k.space.lg, k.space.xl, k.space.lg, k.space.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          MoonTextArea(
            controller: _text,
            height: k.composerHeight,
            expands: true,
            textStyle: k.text.body,
            hintText: '例: 田中さんから、塩は小さじ1/2でいいと言われた',
            onChanged: (_) => setState(() {}),
          ),
          if (_files.isNotEmpty) ...[
            SizedBox(height: k.space.sm),
            Wrap(spacing: k.space.sm, runSpacing: k.space.xs, children: [
              for (final f in _files)
                MoonTag(
                  tagSize: MoonTagSize.sm,
                  backgroundColor: k.colors.shell,
                  label: Text(f.name, style: k.text.small),
                  trailing: MoonButton.icon(
                    buttonSize: MoonButtonSize.xs,
                    semanticLabel: '${f.name}を外す',
                    icon: Icon(LucideIcons.x, color: k.colors.inkMuted),
                    onTap: _busy ? null : () => setState(() => _files.remove(f)),
                  ),
                ),
            ]),
          ],
          SizedBox(height: k.space.md),
          Wrap(spacing: k.space.sm, runSpacing: k.space.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
            MoonOutlinedButton(onTap: _busy || _recording ? null : _pickFiles, label: const Text('ファイルを添える')),
            MoonOutlinedButton(
              onTap: _busy ? null : _toggleRecording,
              label: Text(_recording ? '録音を止める' : '録音する'),
            ),
            if (_recording) StatusTag('録音中', bg: k.colors.pendingBg, fg: k.colors.pending),
          ]),
          SizedBox(height: k.space.lg),
          Row(children: [
            MoonFilledButton(
              onTap: _ready && !_busy && !_recording ? submit : null,
              leading: _busy ? const ButtonLoader() : null,
              label: Text(_busy ? '差分を作成中…' : '差分を作る'),
            ),
            if (wide) ...[
              SizedBox(width: k.space.md),
              Text('Ctrl / ⌘ + Enter でも送れます', style: k.text.small),
            ],
          ]),
        ]),
      ),
    );
  }

  /// 「あとで確認」への導線。確認リストはマニュアルごとなので、件数とともに1冊ずつ並べる
  List<Widget> _openChecks(List<ManualState> manuals) {
    final k = context.tokens;
    final open = manuals.where((s) => s.openChecks.isNotEmpty).toList();
    return [
      Text('あとで確認', style: k.text.title),
      SizedBox(height: k.space.sm),
      if (open.isEmpty)
        Text('マニュアルと食い違う指示は、いまはありません', style: k.text.small)
      else
        // 罫線が方眼とぶつからないよう、白い面に載せる
        PaperSheet(
          padding: EdgeInsets.symmetric(horizontal: k.space.sm),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final (i, s) in open.indexed) ...[
              if (i > 0) const Rule(),
              MoonMenuItem(
                onTap: () => _push(CheckListScreen(c: ManualController(widget.api, s.id, s))),
                menuItemPadding: EdgeInsets.symmetric(horizontal: k.space.sm, vertical: k.space.md),
                label: Text(s.title, style: k.text.heading),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  StatusTag('あとで確認 ${s.openChecks.length} 件', bg: k.colors.pendingBg, fg: k.colors.pending),
                  SizedBox(width: k.space.sm),
                  Icon(LucideIcons.chevronRight, color: k.colors.inkMuted),
                ]),
              ),
            ],
          ]),
        ),
    ];
  }

  /// 全マニュアルの記録を新しい順に、言われたことの付箋で並べる。押すとそのマニュアルを開く
  /// noteWidth は付箋1枚の幅。広い画面の右の列では、列の幅いっぱいに縦に積む
  List<Widget> _recent(List<ManualState> manuals, {double? noteWidth}) {
    final k = context.tokens;
    final recent = [
      for (final s in manuals)
        for (final u in s.utterances) (manual: s, u: u),
    ]..sort((a, b) => b.u.createdAt.compareTo(a.u.createdAt));
    return [
      Text('最近の記録', style: k.text.title),
      SizedBox(height: k.space.sm),
      if (recent.isEmpty)
        Text('記録すると、ここに新しい順に並びます', style: k.text.small)
      else
        Padding(
          padding: EdgeInsets.only(top: k.space.sm),
          child: Wrap(spacing: k.space.lg, runSpacing: k.space.xl, children: [
            for (final (:manual, :u) in recent.take(_recentCount))
              SizedBox(
                width: noteWidth ?? k.stickyWidth,
                child: StickyNote(
                  onTap: () => _push(ManualScreen(api: widget.api, manualId: manual.id)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Speaker(name: u.speaker, day: u.saidAt),
                    SizedBox(height: k.space.sm),
                    Text(u.text, style: k.text.body),
                    SizedBox(height: k.space.sm),
                    Text(manual.title, style: k.text.small),
                  ]),
                ),
              ),
          ]),
        ),
    ];
  }

  /// 記録先が無いうちは入力欄を出さず、最初の1冊の登録へ誘う
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
        MoonFilledButton(label: const Text('マニュアルを登録'), onTap: () => _push(NewManualScreen(api: widget.api))),
      ]),
    );
  }
}

class _PasscodeForm extends StatefulWidget {
  const _PasscodeForm({required this.message, required this.onSubmit});
  final String message;
  final ValueChanged<String> onSubmit;

  @override
  State<_PasscodeForm> createState() => _PasscodeFormState();
}

class _PasscodeFormState extends State<_PasscodeForm> {
  final _passcode = TextEditingController();

  @override
  void dispose() {
    _passcode.dispose();
    super.dispose();
  }

  void _submit() {
    final v = _passcode.text.trim();
    if (v.isNotEmpty) widget.onSubmit(v);
  }

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    return Narrow(
      child: SingleChildScrollView(
        padding: EdgeInsets.symmetric(horizontal: k.space.xl, vertical: k.space.xxl),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(widget.message, style: k.text.heading),
          SizedBox(height: k.space.xs),
          Text('合言葉は、このアプリを紹介した人に聞いてください', style: k.text.small),
          SizedBox(height: k.space.lg),
          MoonTextInput(
            controller: _passcode,
            autofocus: true,
            obscureText: true,
            hintText: '合言葉',
            onSubmitted: (_) => _submit(),
          ),
          SizedBox(height: k.space.md),
          Align(
            alignment: Alignment.centerLeft,
            child: MoonFilledButton(label: const Text('入る'), onTap: _submit),
          ),
        ]),
      ),
    );
  }
}
