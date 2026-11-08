import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
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
import '../web/files.dart';
import '../web/screen.dart';
import 'check_list_screen.dart';
import 'common.dart';
import 'home_screen.dart';
import 'manual_screen.dart';
import 'new_manual_screen.dart';
import 'review_dialog.dart';

/// 合言葉をブラウザ（shared_preferences）に覚えておくときのキー
const passcodeKey = 'passcode';

/// リワインドを開いていた（待ち受けていた）かをブラウザ（shared_preferences）に覚えておくときのキー
const listeningKey = 'listening';

/// リワインドでためた未整理メモをブラウザ（shared_preferences）に覚えておくときのキー
const memosKey = 'memos';

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

/// 最近の記録・リワインドのストックに並べる数
const _recentCount = 5;

const _rewind = 0;
const _organize = 1;

/// サムネイルで見せる形式（HEIC は Safari 以外で描けないので名前だけにする）
const _previewable = {'image/png', 'image/jpeg', 'image/webp'};

Future<List<PickedFile>> _pickWithFilePicker() async => [
      for (final f in await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: _fileTypes.keys.toList()))
        (name: f.name, type: '', bytes: await f.xFile.readAsBytes()),
    ];

/// アプリを開いて最初の画面。「リワインド」で常時待ち受けから切り出して未整理メモにため、
/// 「整理・入力」でメモを手直しし、書く（音声入力つき）・ファイルを添えるで記録する。どのマニュアルかは選ばない（ADR 0005）
class InputScreen extends StatefulWidget {
  const InputScreen({
    super.key,
    required this.api,
    this.newRecorder = AudioRecorder.new,
    this.pickFiles = _pickWithFilePicker,
  });
  final Api api;

  /// 録音を始めるたびに作る（作るだけでマイクの用意が走るため）。テストではマイクの代わりを渡す
  final AudioRecorder Function() newRecorder;

  /// 「ファイルを添える」で選ぶ。テストではファイル選択の代わりを渡す
  final Future<List<PickedFile>> Function() pickFiles;

  @override
  State<InputScreen> createState() => _InputScreenState();
}

class _InputScreenState extends State<InputScreen> {
  late Future<List<ManualState>> _manuals = _load();
  final _text = TextEditingController();
  final _files = <Attachment>[];
  var _attachMenu = false;
  var _busy = false;

  /// 常時待ち受けはリワインドを開いている間だけ。ブラウザはマイクを操作のあとでないと開けないので、
  /// リワインドから開いたときは最初の操作で待ち受けを再開する
  bool get _wantListening => _tab == _rewind;
  CaptureRecorder? _listener;
  var _starting = false;

  /// 切り出しボタンを押してから、話し終わりを待って切り出すまで
  var _capturing = false;

  /// 裏で書き起こしている切り出しの数
  var _transcribing = 0;

  final _memos = <Memo>[];

  /// 入力欄に流し込んだメモ。差分を作れたら未整理メモから消す
  final _poured = <Memo>[];

  var _tab = _organize;

  /// 最初のタブは前回開いていたタブで決める。決まったら切り替えを作り直す
  var _tabRestored = false;

  /// 音声入力の録音。話し終わると null になり、確定の文面が届いてソケットが閉じるのを待つ
  Dictation? _dictation;
  WebSocketChannel? _dictationSocket;

  /// 音声入力を始めたときの入力欄。届いた文面はこの後ろに足す
  var _beforeDictation = '';

  late final void Function() _stopWatchingScreen;
  late final void Function() _stopWatchingDrops;

  @override
  void initState() {
    super.initState();
    // 画面に戻ったら、待ち受けのマイクが止められていないかを確かめる
    _stopWatchingScreen = onScreenShown(() => _listener?.checkAlive());
    _stopWatchingDrops = onFilesDropped(_addPicked);
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      final listening = p.getBool(listeningKey) == true;
      setState(() {
        _tab = listening ? _rewind : _organize;
        _tabRestored = true;
        _memos.addAll([for (final m in p.getStringList(memosKey) ?? []) Memo.fromJson(jsonDecode(m))]);
      });
    });
  }

  @override
  void dispose() {
    _text.dispose();
    _stopWatchingScreen();
    _stopWatchingDrops();
    if (_listener != null) keepScreenOn(false);
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

  /// 選んだ・撮った・貼り付けた・ドロップしたファイルを添える。受け付けない形式は除き、大きな画像は縮める
  Future<void> _addPicked(List<PickedFile> picked) async {
    if (_busy || picked.isEmpty) return;
    final added = <Attachment>[];
    for (final f in picked) {
      final mimeType = _fileTypes[f.name.split('.').last.toLowerCase()] ??
          (_fileTypes.containsValue(f.type) ? f.type : null);
      if (mimeType == null) continue;
      final small = await shrinkImage(f.bytes, mimeType);
      added.add(Attachment(name: f.name, mimeType: small.mimeType, bytes: small.bytes));
    }
    if (!mounted) return;
    if (added.length < picked.length) showError(context, '添えられるのは PDF と画像（PNG・JPEG・WebP・HEIC）です');
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

  /// リワインドに切り替えたら待ち受けを始め、整理・入力に切り替えたら止める
  Future<void> _selectTab(int tab) async {
    setState(() => _tab = tab);
    final on = tab == _rewind;
    unawaited(SharedPreferences.getInstance().then((p) => p.setBool(listeningKey, on)));
    if (on) {
      await _startListening();
    } else {
      final c = _listener;
      setState(() => _listener = null);
      keepScreenOn(false);
      await c?.stop();
    }
  }

  Future<void> _startListening() async {
    if (_listener != null || _starting) return;
    _starting = true;
    final c = await CaptureRecorder.start(widget.newRecorder(), onStopped: _onListenerStopped);
    _starting = false;
    // マイクを開いている間に整理・入力へ切り替えられたら閉じる
    if (!mounted || !_wantListening) {
      await c?.stop();
      return;
    }
    if (c == null) {
      showError(context, _noMic);
      return;
    }
    setState(() => _listener = c);
    keepScreenOn(true);
  }

  /// 画面が消えている間などにマイクが止まったら知らせる。ON は覚えたままにし、次の操作で再開する
  void _onListenerStopped() {
    final c = _listener;
    if (!mounted || c == null) return;
    setState(() => _listener = null);
    keepScreenOn(false);
    c.stop();
    showError(context, '待ち受けが止まっていました。画面のどこかを押すと再開します');
  }

  /// 言われた後に押す。話し終わりを待って直前の発話だけを切り出す。書き起こしは裏で行い、
  /// 待ち受けを止めず確認も出さないので、切り出し終われば続けて押せる
  Future<void> _capture() async {
    final c = _listener;
    if (c == null || _capturing) return;
    final at = DateTime.now();
    setState(() => _capturing = true);
    final wav = await c.capture();
    if (!mounted) return;
    setState(() => _capturing = false);
    if (wav == null) {
      showError(context, '声が入っていませんでした。言われた直後にもう一度押してください');
      return;
    }
    unawaited(_transcribe(wav, at));
  }

  /// 書き起こせたら未整理メモにためる。書き起こせなければ音声は残さず知らせる
  Future<void> _transcribe(Uint8List wav, DateTime at) async {
    setState(() => _transcribing++);
    try {
      final text = await widget.api.listen(wav);
      // 書き起こしは前後して返るので、切り出した順に並べ直す
      _memos
        ..add(Memo(at: at, text: text))
        ..sort((a, b) => a.at.compareTo(b.at));
      _saveMemos();
    } on ApiException catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _transcribing--);
    }
  }

  void _saveMemos() {
    final saved = [for (final m in _memos) jsonEncode(m.toJson())];
    unawaited(SharedPreferences.getInstance().then((p) => p.setStringList(memosKey, saved)));
  }

  /// メモを入力欄の後ろに足す。続けて入れると1つの指示にまとめられる
  void _pour(Memo m) => setState(() {
        _text.text = [_text.text.trimRight(), m.text].where((t) => t.isNotEmpty).join('\n');
        _poured.add(m);
      });

  void _deleteMemo(Memo m) {
    setState(() {
      _memos.remove(m);
      _poured.remove(m);
    });
    _saveMemos();
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
    final poured = [..._poured];
    // メモから書いたときは、言われた日を切り出した日にする（後日まとめて整理しても日付がずれない）
    final saidOn = poured.isEmpty
        ? today()
        : DateFormat('yyyy-MM-dd').format(poured.map((m) => m.at).reduce((a, b) => a.isBefore(b) ? a : b));
    await _send(manuals, text: _text.text.trim(), files: _files, today: saidOn, onSaved: () {
      _text.clear();
      _files.clear();
      _memos.removeWhere(poured.contains);
      _poured.clear();
      _saveMemos();
    });
  }

  /// 記録して、関係したマニュアルごとに差分の確認を出す。onSaved は記録できたとき、確認を出す前に呼ぶ
  Future<void> _send(List<ManualState> manuals,
      {required String text, required List<Attachment> files, required String today, VoidCallback? onSaved}) async {
    setState(() => _busy = true);
    try {
      var r = await widget.api.intake(text: text, files: files, today: today);
      if (r.results.isEmpty) {
        setState(() => _busy = false);
        final ids = await _pickManuals(manuals, r.text);
        if (ids == null) return;
        setState(() => _busy = true);
        // ファイルや録音はもう読み取ったので、読み取った文面だけを送り直す
        r = await widget.api.intake(text: r.text, manualIds: ids, today: today);
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

  /// 関係するマニュアルが見つからなかったときに、記録先を選んでもらう。1回の指示が複数にまたがることもあるので、いくつでも選べる
  Future<List<String>?> _pickManuals(List<ManualState> manuals, String text) {
    final k = context.tokens;
    final picked = <String>{};
    return showMoonModal<List<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setPicked) {
        void toggle(String id) => setPicked(() => picked.contains(id) ? picked.remove(id) : picked.add(id));
        return MoonModal(
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
                    onTap: () => toggle(m.id),
                    menuItemPadding: EdgeInsets.symmetric(horizontal: k.space.sm, vertical: k.space.md),
                    leading: MoonCheckbox(
                      value: picked.contains(m.id),
                      semanticLabel: m.title,
                      onChanged: (_) => toggle(m.id),
                    ),
                    label: Text(m.title, style: k.text.heading),
                  ),
                  const Rule(),
                ],
                SizedBox(height: k.space.lg),
                Row(children: [
                  MoonOutlinedButton(label: const Text('記録しない'), onTap: () => Navigator.pop(ctx)),
                  const Spacer(),
                  MoonFilledButton(
                    label: const Text('記録する'),
                    onTap: picked.isEmpty
                        ? null
                        : () => Navigator.pop(ctx, [for (final m in manuals) if (picked.contains(m.id)) m.id]),
                  ),
                ]),
              ]),
            ),
          ),
        );
      }),
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
        child: GridBackground(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TopBar(
            crumbs: const ['DiffNote（仮）'],
            trailing: MoonOutlinedButton(
              buttonSize: MoonButtonSize.sm,
              onTap: () => _push(HomeScreen(api: widget.api)),
              label: const Text('マニュアルを確認'),
            ),
          ),
          Expanded(child: FutureBuilder(future: _manuals, builder: (context, snap) => _body(snap))),
        ])),
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
    return Narrow(
      child: ListView(padding: EdgeInsets.fromLTRB(k.space.xl, k.space.xxl, k.space.xl, k.space.xxl), children: [
        PageTitle('言われたことを記録', meta: [Text('どのマニュアルのことかは選ばなくてかまいません', style: k.text.small)]),
        SizedBox(height: k.space.xl),
        if (manuals.isEmpty)
          _empty()
        else ...[
          Align(
            alignment: Alignment.centerLeft,
            child: MoonSegmentedControl(
              // 前回のタブを読み込めたら、そのタブで作り直す
              key: ValueKey(_tabRestored),
              initialIndex: _tab,
              // 切り出しの途中で待ち受けを止めない
              isDisabled: _capturing,
              onSegmentChanged: _selectTab,
              segments: const [Segment(label: Text('リワインド')), Segment(label: Text('整理・入力'))],
            ),
          ),
          SizedBox(height: k.space.lg),
          if (_tab == _rewind) ...[
            _listening(),
            SizedBox(height: k.space.xxl),
            ..._stock(),
          ] else ...[
            ..._unsorted(),
            _composer(manuals),
            SizedBox(height: k.space.xxl),
            ..._openChecks(manuals),
            SizedBox(height: k.space.xxl),
            ..._recent(manuals),
          ],
        ],
      ]),
    );
  }

  /// 常時待ち受け。待ち受け中は、何も送っていないことと音量をいつも見せる。白い面に載せる
  Widget _listening() {
    final k = context.tokens;
    final c = _listener;
    return PaperSheet(
      padding: EdgeInsets.all(k.space.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('常時待ち受け', style: k.text.heading),
        SizedBox(height: k.space.sm),
        if (c == null)
          Text('画面のどこかを押すと、待ち受けを再開します', style: k.text.small)
        else ...[
          Text('端末内で直前60秒を保持中（送信していません）', style: k.text.small),
          Text('押したときだけ、その発話を文字に起こすために送ります。音声は保存しません', style: k.text.small),
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
          SizedBox(height: k.space.xl),
          // 指導中に画面を見なくても押せるよう、幅いっぱいの大きなボタンにする
          MoonFilledButton(
            buttonSize: MoonButtonSize.xl,
            isFullWidth: true,
            onTap: _capturing ? null : _capture,
            leading: _capturing ? const ButtonLoader() : null,
            label: Text(_capturing ? '話し終わりを待っています…' : '直前の発話を残す'),
          ),
        ],
      ]),
    );
  }

  /// リワインドで直近にためたメモ。書き起こし中の数も出し、押せたかを確かめられるようにする
  List<Widget> _stock() {
    final k = context.tokens;
    return [
      Text('未整理メモ', style: k.text.title),
      SizedBox(height: k.space.sm),
      Wrap(spacing: k.space.sm, runSpacing: k.space.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text('${_memos.length} 件', style: k.text.small),
        if (_transcribing > 0) StatusTag('書き起こし中 $_transcribing 件', bg: k.colors.pendingBg, fg: k.colors.pending),
      ]),
      SizedBox(height: k.space.sm),
      if (_memos.isEmpty)
        Text('残したメモは、あとで「整理・入力」で発言者や言葉を補ってから記録します', style: k.text.small)
      else
        _memoNotes(_memos.reversed.take(_recentCount)),
    ];
  }

  /// 「整理・入力」に出す未整理メモ。押すと入力欄に入れる。無ければ何も出さない
  List<Widget> _unsorted() {
    if (_memos.isEmpty) return [];
    final k = context.tokens;
    return [
      Text('未整理メモ', style: k.text.title),
      SizedBox(height: k.space.xs),
      Text('押すと入力欄に入ります。続けて押すと1つにまとめられます', style: k.text.small),
      _memoNotes(_memos, organizing: true),
      SizedBox(height: k.space.xxl),
    ];
  }

  Widget _memoNotes(Iterable<Memo> memos, {bool organizing = false}) {
    final k = context.tokens;
    return Padding(
      padding: EdgeInsets.only(top: k.space.sm),
      child: Wrap(spacing: k.space.lg, runSpacing: k.space.xl, children: [
        for (final m in memos)
          SizedBox(
            width: k.stickyWidth,
            child: StickyNote(
              onTap: organizing && !_poured.contains(m) && !_busy && !_dictating ? () => _pour(m) : null,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(DateFormat('M/d HH:mm').format(m.at), style: k.text.small)),
                  if (organizing)
                    MoonButton.icon(
                      buttonSize: MoonButtonSize.xs,
                      semanticLabel: 'メモを消す',
                      icon: Icon(LucideIcons.x, color: k.colors.inkMuted),
                      onTap: _busy ? null : () => _deleteMemo(m),
                    ),
                ]),
                SizedBox(height: k.space.sm),
                Text(m.text, style: k.text.body),
                if (_poured.contains(m)) ...[
                  SizedBox(height: k.space.sm),
                  StatusTag('入力欄に入れました', bg: k.colors.shell, fg: k.colors.inkMuted),
                ],
              ]),
            ),
          ),
      ]),
    );
  }

  /// 書く欄。白い面に載せる
  Widget _composer(List<ManualState> manuals) {
    final k = context.tokens;
    return PaperSheet(
      padding: EdgeInsets.fromLTRB(k.space.lg, k.space.xl, k.space.lg, k.space.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Stack(children: [
          MoonTextArea(
            controller: _text,
            height: k.composerHeight,
            expands: true,
            readOnly: _dictating,
            textStyle: k.text.body,
            // 下の行に添付とマイクのボタンを置くので、文字がその下に潜らないよう空けておく
            textPadding: EdgeInsets.fromLTRB(k.space.lg, k.space.md, k.space.lg, k.space.xxl),
            hintText: '例: 田中さんから、塩は小さじ1/2でいいと言われた',
            onChanged: (v) => setState(() {
              // 消し切ったら、流し込んだメモはもう使っていない
              if (v.trim().isEmpty) _poured.clear();
            }),
          ),
          Positioned(left: k.space.sm, bottom: k.space.sm, child: _attach()),
          Positioned(right: k.space.sm, bottom: k.space.sm, child: _mic()),
        ]),
        if (_files.isNotEmpty) ...[
          SizedBox(height: k.space.sm),
          Wrap(
            spacing: k.space.sm,
            runSpacing: k.space.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [for (final f in _files) _attachment(f)],
          ),
        ],
        if (_dictation != null) ...[
          SizedBox(height: k.space.md),
          Align(
            alignment: Alignment.centerLeft,
            child: StatusTag('聞き取り中。話し終わると止まります', bg: k.colors.pendingBg, fg: k.colors.pending),
          ),
        ],
        SizedBox(height: k.space.lg),
        Align(
          alignment: Alignment.centerLeft,
          child: MoonFilledButton(
            onTap: _ready && !_busy && !_dictating ? () => _submit(manuals) : null,
            leading: _busy ? const ButtonLoader() : null,
            label: Text(_busy ? '差分を作成中…' : '差分を作る'),
          ),
        ),
      ]),
    );
  }

  /// Web でも端末の種類を返す。スマホではカメラを直接開くボタンを出す
  bool get _onPhone => const {TargetPlatform.android, TargetPlatform.iOS}.contains(defaultTargetPlatform);

  /// 添えたもの。画像はサムネイルで、ほかは名前で見せる
  Widget _attachment(Attachment f) {
    final k = context.tokens;
    final remove = MoonButton.icon(
      buttonSize: MoonButtonSize.xs,
      backgroundColor: k.colors.canvas,
      semanticLabel: '${f.name}を外す',
      icon: Icon(LucideIcons.x, color: k.colors.inkMuted),
      onTap: _busy ? null : () => setState(() => _files.remove(f)),
    );
    if (!_previewable.contains(f.mimeType)) {
      return MoonTag(
        tagSize: MoonTagSize.sm,
        backgroundColor: k.colors.shell,
        label: Text(f.name, style: k.text.small),
        trailing: remove,
      );
    }
    return Stack(children: [
      ClipRRect(
        borderRadius: k.radius.control,
        child: Image.memory(f.bytes, width: k.thumbnail, height: k.thumbnail, fit: BoxFit.cover, semanticLabel: f.name),
      ),
      Positioned(top: k.space.xs, right: k.space.xs, child: remove),
    ]);
  }

  /// 入力欄の中の＋。押すと添え方を選ぶメニューを開く
  Widget _attach() {
    final k = context.tokens;
    Future<void> choose(Future<List<PickedFile>> Function() pick) async {
      setState(() => _attachMenu = false);
      _addPicked(await pick());
    }

    return MoonDropdown(
      show: _attachMenu,
      dropdownAnchorPosition: MoonDropdownAnchorPosition.topLeft,
      backgroundColor: k.colors.canvas,
      borderColor: k.colors.rule,
      onTapOutside: () => setState(() => _attachMenu = false),
      // 既定では画面いっぱいまで広がるので、項目の幅に合わせる
      content: IntrinsicWidth(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        MoonMenuItem(
          borderRadius: k.radius.control,
          onTap: () => choose(widget.pickFiles),
          label: Text('ファイルを選ぶ', style: k.text.body),
          content: Text(_onPhone ? 'PDF・画像' : 'PDF・画像。貼り付けやドロップでも添えられます', style: k.text.small),
        ),
        if (_onPhone)
          MoonMenuItem(
            borderRadius: k.radius.control,
            onTap: () => choose(takePhoto),
            label: Text('写真を撮る', style: k.text.body),
          ),
      ])),
      child: MoonButton.icon(
        buttonSize: MoonButtonSize.sm,
        semanticLabel: 'ファイルを添える',
        backgroundColor: _attachMenu ? k.colors.shell : null,
        onTap: _busy ? null : () => setState(() => _attachMenu = !_attachMenu),
        icon: Icon(LucideIcons.plus, color: k.colors.inkMuted),
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
  List<Widget> _recent(List<ManualState> manuals) {
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
                width: k.stickyWidth,
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
