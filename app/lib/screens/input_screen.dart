import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:moon_design/moon_design.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../api.dart';
import '../audio/capture_recorder.dart';
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

/// 常時待ち受けを ON にしたかをブラウザ（shared_preferences）に覚えておくときのキー
const listeningKey = 'listening';

const _noMic = 'マイクを使えません。ブラウザの設定でマイクを許可してください';

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

/// アプリを開いて最初の画面。どのマニュアルかを選ばずに、常時待ち受けからの切り出し・書く（音声入力つき）・ファイルを添えるで記録する（ADR 0005）
class InputScreen extends StatefulWidget {
  const InputScreen({super.key, required this.api, this.newRecorder = AudioRecorder.new});
  final Api api;

  /// 録音を始めるたびに作る（作るだけでマイクの用意が走るため）。テストではマイクの代わりを渡す
  final AudioRecorder Function() newRecorder;

  @override
  State<InputScreen> createState() => _InputScreenState();
}

class _InputScreenState extends State<InputScreen> {
  late Future<List<ManualState>> _manuals = _load();
  final _text = TextEditingController();
  final _files = <Attachment>[];
  var _busy = false;

  /// 利用者が選んだ常時待ち受けの ON／OFF。ブラウザはマイクを操作のあとでないと開けないので、
  /// 前回 ON のまま開いたときは最初の操作で待ち受けを再開する
  var _wantListening = false;
  CaptureRecorder? _listener;
  var _starting = false;

  /// 切り出しボタンを押してから、差分の確認を出すまで
  var _capturing = false;

  /// 音声入力の録音。話し終わると null になり、確定の文面が届いてソケットが閉じるのを待つ
  Dictation? _dictation;
  WebSocketChannel? _dictationSocket;

  /// 音声入力を始めたときの入力欄。届いた文面はこの後ろに足す
  var _beforeDictation = '';

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (mounted && p.getBool(listeningKey) == true) setState(() => _wantListening = true);
    });
  }

  @override
  void dispose() {
    _text.dispose();
    _listener?.stop();
    _dictation?.stop();
    _dictationSocket?.sink.close();
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
      showError(context, 'ファイルは合わせて10MBまでです。減らしてから添えてください');
      return;
    }
    setState(() => _files.addAll(added));
  }

  Future<void> _setListening(bool on) async {
    setState(() => _wantListening = on);
    unawaited(SharedPreferences.getInstance().then((p) => p.setBool(listeningKey, on)));
    if (on) {
      await _startListening();
    } else {
      final c = _listener;
      setState(() => _listener = null);
      await c?.stop();
    }
  }

  Future<void> _startListening() async {
    if (_listener != null || _starting) return;
    _starting = true;
    final c = await CaptureRecorder.start(widget.newRecorder());
    _starting = false;
    // マイクを開いている間に OFF にされたら閉じる
    if (!mounted || !_wantListening) {
      await c?.stop();
      return;
    }
    if (c == null) {
      await _setListening(false);
      if (mounted) showError(context, _noMic);
      return;
    }
    setState(() => _listener = c);
  }

  /// 言われた後に押す。話し終わりを待って直前の発話だけを切り出し、そのまま記録する
  Future<void> _capture(List<ManualState> manuals) async {
    final c = _listener;
    if (c == null || _busy || _capturing) return;
    setState(() => _capturing = true);
    final wav = await c.capture();
    if (!mounted) return;
    if (wav == null) {
      setState(() => _capturing = false);
      showError(context, '声が入っていませんでした。言われた直後にもう一度押してください');
      return;
    }
    await _send(
      manuals,
      text: '',
      files: [Attachment(name: '切り出した発話', mimeType: 'audio/wav', bytes: wav)],
      onSaved: () => _capturing = false,
    );
    if (mounted) setState(() => _capturing = false);
  }

  /// テキスト欄の音声入力。話している途中から入力欄に文字を出し、話し終わったら自動で止める
  Future<void> _toggleDictation() async {
    if (_dictation != null) return _finishDictation();
    if (_dictationSocket != null) return;
    final socket = widget.api.dictation();
    final d = await Dictation.start(widget.newRecorder(), onPcm: socket.sink.add, onEnd: _finishDictation);
    if (!mounted || d == null) {
      unawaited(socket.sink.close());
      await d?.stop();
      if (mounted) showError(context, _noMic);
      return;
    }
    _beforeDictation = _text.text.trimRight();
    socket.stream.listen(
      _onDictation,
      onError: (_) {
        if (mounted) showError(context, '音声入力のサーバーにつながりません。少し待ってからもう一度押すか、文字で書いてください');
      },
      onDone: _onDictationClosed,
    );
    setState(() {
      _dictation = d;
      _dictationSocket = socket;
    });
  }

  void _onDictation(dynamic message) {
    if (!mounted) return;
    final m = jsonDecode(message as String) as Map<String, dynamic>;
    if (m['error'] case final String e) {
      showError(context, e);
      return;
    }
    final heard = m['text'] as String;
    setState(() => _text.text = [_beforeDictation, heard].where((t) => t.isNotEmpty).join('\n'));
    if (m['done'] == true && heard.isEmpty) showError(context, '聞き取れませんでした。もう一度話すか、文字で書いてください');
  }

  /// 録音を止め、確定の文面を待つ。声が聞こえなかったら何も送っていないので、待たずに閉じる
  void _finishDictation() {
    final d = _dictation;
    if (d == null) return;
    d.stop();
    setState(() => _dictation = null);
    if (d.heard) {
      _dictationSocket?.sink.add('end');
      return;
    }
    _dictationSocket?.sink.close();
    showError(context, '声が入っていませんでした。マイクを押してから話してください');
  }

  /// 確定の前に閉じられたとき（失敗・切断）も、録音を止めて元に戻す
  void _onDictationClosed() {
    _dictation?.stop();
    if (!mounted) return;
    setState(() {
      _dictation = null;
      _dictationSocket = null;
    });
  }

  bool get _dictating => _dictationSocket != null;

  Future<void> _submit(List<ManualState> manuals) async {
    if (!_ready || _busy || _dictating) return;
    await _send(manuals, text: _text.text.trim(), files: _files, onSaved: () {
      _text.clear();
      _files.clear();
    });
  }

  /// 記録して、関係したマニュアルごとに差分の確認を出す。onSaved は記録できたとき、確認を出す前に呼ぶ
  Future<void> _send(List<ManualState> manuals,
      {required String text, required List<Attachment> files, VoidCallback? onSaved}) async {
    setState(() => _busy = true);
    try {
      var r = await widget.api.intake(text: text, files: files, today: today());
      if (r.results.isEmpty) {
        setState(() => _busy = false);
        final id = await _pickManual(manuals, r.text);
        if (id == null) return;
        setState(() => _busy = true);
        // ファイルや録音はもう読み取ったので、読み取った文面だけを送り直す
        r = await widget.api.intake(text: r.text, manualIds: [id], today: today());
      }
      setState(() {
        onSaved?.call();
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
      body: Listener(
        onPointerDown: (_) {
          if (_wantListening && _listener == null) _startListening();
        },
        child: WithSidebar(
          api: widget.api,
          place: Place.input,
          child: GridBackground(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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
          ])),
        ),
      ),
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
      // 広い画面では、入力とあとで確認を左に、最近の付箋を右に並べ、書きながら前の記録を見られるようにする
      final wide = box.maxWidth >= k.wideLayout;
      final input = [
        _listening(manuals),
        SizedBox(height: k.space.lg),
        _composer(manuals, wide: wide),
        SizedBox(height: k.space.xxl),
        ..._openChecks(manuals),
      ];
      return Narrow(
        maxWidth: wide ? k.readableWidth + k.space.xxl + k.panelWidth : null,
        child: ListView(padding: EdgeInsets.fromLTRB(k.space.xl, k.space.xxl, k.space.xl, k.space.xxl), children: [
          PageTitle('言われたことを記録', meta: [Text('どのマニュアルのことかは選ばなくてかまいません', style: k.text.small)]),
          SizedBox(height: k.space.xl),
          if (manuals.isEmpty)
            _empty()
          else if (wide)
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: input)),
              SizedBox(width: k.space.xxl),
              SizedBox(
                width: k.panelWidth,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _recent(manuals, noteWidth: k.panelWidth)),
              ),
            ])
          else ...[
            ...input,
            SizedBox(height: k.space.xxl),
            ..._recent(manuals),
          ],
        ]),
      );
    });
  }

  /// 常時待ち受け。待ち受け中は、何も送っていないことと音量をいつも見せる。白い面に載せる
  Widget _listening(List<ManualState> manuals) {
    final k = context.tokens;
    final c = _listener;
    return PaperSheet(
      padding: EdgeInsets.all(k.space.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          MoonSwitch(
            value: _wantListening,
            semanticLabel: '常時待ち受け',
            onChanged: _capturing ? null : _setListening,
          ),
          SizedBox(width: k.space.sm),
          Text('常時待ち受け', style: k.text.heading),
        ]),
        SizedBox(height: k.space.sm),
        if (c == null)
          Text(
            _wantListening ? '画面のどこかを押すと、待ち受けを再開します' : 'ON にすると、言われた後に押すだけで直前の発話を記録できます',
            style: k.text.small,
          )
        else ...[
          Text('端末内で直前60秒を保持中（送信していません）', style: k.text.small),
          SizedBox(height: k.space.xs),
          ValueListenableBuilder(
            valueListenable: c.level,
            builder: (_, v, _) => MoonLinearProgress(
              value: v,
              semanticLabel: '音量',
              color: k.colors.ink,
              backgroundColor: k.colors.rule,
            ),
          ),
          SizedBox(height: k.space.md),
          Align(
            alignment: Alignment.centerLeft,
            child: MoonFilledButton(
              onTap: _busy || _capturing ? null : () => _capture(manuals),
              leading: _capturing ? const ButtonLoader() : null,
              label: Text(_capturing ? (_busy ? '差分を作成中…' : '話し終わりを待っています…') : '直前の発話を記録する'),
            ),
          ),
        ],
      ]),
    );
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
          Stack(children: [
            MoonTextArea(
              controller: _text,
              height: k.composerHeight,
              expands: true,
              readOnly: _dictating,
              textStyle: k.text.body,
              hintText: '例: 田中さんから、塩は小さじ1/2でいいと言われた',
              onChanged: (_) => setState(() {}),
            ),
            Positioned(right: k.space.sm, bottom: k.space.sm, child: _mic()),
          ]),
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
            MoonOutlinedButton(onTap: _busy ? null : _pickFiles, label: const Text('ファイルを添える')),
            if (_dictation != null) StatusTag('聞き取り中。話し終わると止まります', bg: k.colors.pendingBg, fg: k.colors.pending),
          ]),
          SizedBox(height: k.space.lg),
          Row(children: [
            MoonFilledButton(
              onTap: _ready && !_busy && !_dictating ? submit : null,
              leading: _busy && !_capturing ? const ButtonLoader() : null,
              label: Text(_busy && !_capturing ? '差分を作成中…' : '差分を作る'),
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

  /// 入力欄の中のマイク。聞き取り中は色で示し、確定の文面を待つ間は読み込み中にする
  Widget _mic() {
    final k = context.tokens;
    final listening = _dictation != null;
    return MoonButton.icon(
      buttonSize: MoonButtonSize.sm,
      semanticLabel: listening ? '音声入力を止める' : '音声入力',
      backgroundColor: listening ? k.colors.pendingBg : null,
      onTap: _busy || (_dictating && !listening) ? null : _toggleDictation,
      icon: _dictating && !listening
          ? MoonCircularLoader(color: k.colors.inkMuted, circularLoaderSize: MoonCircularLoaderSize.x2s)
          : Icon(LucideIcons.mic, color: listening ? k.colors.pending : k.colors.inkMuted),
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
