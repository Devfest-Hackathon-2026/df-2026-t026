import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
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
import 'attach.dart';
import 'check_list_screen.dart';
import 'common.dart';
import 'manual_screen.dart';
import 'new_manual_screen.dart';
import 'open_checks_screen.dart';
import 'record_result.dart';
import 'review_dialog.dart';
import 'rewind_panel.dart';
import 'sidebar.dart';

/// ログインで受け取ったトークンをブラウザ（shared_preferences）に覚えておくときのキー
const tokenKey = 'token';

/// 前の版が未整理メモをブラウザ（shared_preferences）に置いていたときのキー。サーバーに移したら消す（ADR 0015）
const memosKey = 'memos';

const _noMic = 'マイクを使えません。ブラウザの設定でマイクを許可してください';

/// 最近の記録に並べる数
const _recentCount = 5;

/// サムネイルで見せる形式（HEIC は Safari 以外で描けないので名前だけにする）
const _previewable = {'image/png', 'image/jpeg', 'image/webp'};

/// アプリを開いて最初の画面。題名の右のトグルを ON にすると、書く欄の代わりにリワインドの待ち受けを出す。
/// ためた未整理メモを手直しし、書く（音声入力つき）・ファイルを添えるで記録する。
/// どのマニュアルかは選ばなくてよい（ADR 0005）。記録先が分かっていれば、入力欄の「記録先」で先に選べる
class InputScreen extends StatefulWidget {
  const InputScreen({
    super.key,
    required this.api,
    this.newRecorder = AudioRecorder.new,
    this.pickFiles = pickWithFilePicker,
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
  /// 狭い画面のメニュー（Drawer）を閉じるため
  final _scaffold = GlobalKey<ScaffoldState>();
  final _text = TextEditingController();
  final _files = <Attachment>[];
  var _attachMenu = false;

  /// 入力欄から送るときの記録先。空なら関係するノートを AI が選ぶ
  final _targets = <String>{};
  var _busy = false;

  /// リワインドのトグル。ON の間だけ書く欄の代わりに待ち受けの面を出し、待ち受ける
  var _rewind = false;

  /// リワインドで話し終わりを待っている間。トグルで待ち受けを止めさせない
  var _capturing = false;

  /// 広い画面と狭い画面で並べ方が変わっても（スマホを横にしたときなど）、待ち受けを途切れさせない
  final _rewindKey = GlobalKey();

  /// 照らし合わせを待っている記録。押した順で、先頭から1件ずつ送る
  final _queue = <_Pending>[];
  var _sending = false;

  /// 照らし合わせた結果。入力欄の下にカードで新しいものを上に並べる。迷う所の無いカードは次の結果が出るか、閉じるか、
  /// 食い違いがもう当てはまらなくなるまで残す（#112・#119）。確かめることが残ったカードと、確定していない食い違いのある
  /// カードは、確かめる・確定するか閉じるまで残す
  final _results = <_Result>[];
  final _scroll = ScrollController();

  /// ほかの画面がこのページの上に重なっているか。戻ってきたら入力欄の見える位置から始める（#119）
  var _covered = false;

  /// 書き直している未整理メモ
  Memo? _editingMemo;
  final _memoText = TextEditingController();

  /// 入力欄に流し込んだメモ。差分を作れたら未整理メモから消す
  final _poured = <Memo>[];

  /// 音声入力の録音。話し終わると null になり、確定の文面が届いてソケットが閉じるのを待つ
  Dictation? _dictation;
  WebSocketChannel? _dictationSocket;

  /// 音声入力を始めたときの入力欄。届いた文面はこの後ろに足す
  var _beforeDictation = '';

  late final void Function() _stopWatchingDrops;

  /// アプリに戻ってきたときに読み直し、ほかの人の編集やほかの端末でためたメモを出す
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // ドロップはページ全体で受けるので、上にノートを作る画面を開いている間は受けない
    _stopWatchingDrops = onFilesDropped((f, _) {
      if (ModalRoute.of(context)?.isCurrent ?? true) _addPicked(f);
    });
    _lifecycle = AppLifecycleListener(onResume: _refresh);
    widget.api.store.addListener(_onStore);
    _refresh();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 上に別のページが重なると、このページは描かれず TickerMode が切れる。ダイアログ（「確かめる」など）では切れないので、
    // ダイアログを閉じただけでは送らない。サイドバーは pushAndRemoveUntil・removeRoute で移るので、_push では拾えない
    final shown = TickerMode.valuesOf(context).enabled;
    if (_covered && shown) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(0);
      });
    }
    _covered = !shown;
  }

  @override
  void dispose() {
    widget.api.store.removeListener(_onStore);
    _scroll.dispose();
    _text.dispose();
    _memoText.dispose();
    _stopWatchingDrops();
    _lifecycle.dispose();
    _dictation?.stop();
    _dictationSocket?.sink.close();
    super.dispose();
  }

  /// 入力ページを開いたとき・ログインしたとき・アプリに戻ってきたときに、GET /home で全部を読み直す（ADR 0021）。
  /// 前の版がブラウザにためていた未整理メモがあれば、サーバーに移してからもう1度読む
  Future<void> _refresh() async {
    final store = widget.api.store;
    final loading = store.load();
    try {
      if (!await _moveLocalMemos()) return;
    } on ApiException {
      // ログインの前や通信の失敗では移せない。次に読み直すときにまた試す
      return;
    }
    await loading;
    await store.load();
  }

  /// store（自分のノートと共有されたノート・未整理メモ）が変わったら描き直し、結果のカードを今の状態に合わせる
  void _onStore() {
    if (!mounted) return;
    final store = widget.api.store;
    setState(() {
      if (store.notes case final manuals?) _results.removeWhere((r) => _stale(r, manuals, store.memos));
      if (!store.memos.contains(_editingMemo)) _editingMemo = null;
    });
  }

  /// 結果のカードを外すか。確かめることが残ったカードは、ここで records を今の状態に作り直す。
  /// - 関係するノートが無かったカードは、そのメモが未整理メモから記録された・消されたら外す。
  ///   残すと、カードの「記録先を選ぶ」からもう1度送れて二重に記録する。添付だけの記録はメモが無いので外さない
  /// - 確かめることが残ったカード（records は照らし合わせた時点の写し）は、ほかの画面で書き込んだ・確定した今の状態に
  ///   作り直す。外すのはノートが消えたときと、作り直して確かめることが無くなったうえで、食い違いがほかの画面で確定されたとき。
  ///   確かめることが残っていれば、入口として残す
  /// - それ以外のカードは、食い違いがほかの画面で確定された・ノートが消されたら外す
  bool _stale(_Result r, List<ManualState> manuals, List<Memo> memos) {
    if (r.missed case final m?) return m.memoIds.any((id) => !memos.any((x) => x.id == id));
    if (!needsReview(r.records)) return _outdated(r.records, manuals, r.settled);
    if (r.records.any((x) => !manuals.any((m) => m.id == x.manualId))) return true;
    // 確定されたかは、作り直す前の写しで比べる（作り直すと、確定された食い違いはもう開いていない）
    final outdated = _outdated(r.records, manuals, r.settled);
    r.records = [for (final t in r.targets) (manualId: t.c.manualId, utteranceId: t.utteranceId, state: t.c.state!)];
    return outdated && !needsReview(r.records);
  }

  /// 結果のカードが古くなったか。カードの食い違いが1つでもほかの画面で確定された、またはノートが消された・共有を外されたら、
  /// カードの見出しと比較はもう今と合わない。残りの食い違いは下の「あとで確認」に出ている（#119）。
  /// settled はカードで決着させた食い違いで、カードが決着した形で映しているので比べない
  static bool _outdated(List<Recorded> records, List<ManualState> manuals, Set<String> settled) => records.any((r) {
        final now = manuals.where((m) => m.id == r.manualId).firstOrNull;
        return now == null ||
            r.state.checks
                .where((c) => c.utteranceId == r.utteranceId && c.isOpen && !settled.contains(c.id))
                .any((c) => now.checkOf(c.patchId)?.isOpen != true);
      });

  /// 「もう一度読み込む」とログインのあと。読み込み中の表示にしてから読む
  void _reload() {
    _refresh();
    setState(() {});
  }

  /// 前の版がブラウザにためていた未整理メモを、サーバーに移す。移すものがあったら true
  Future<bool> _moveLocalMemos() async {
    final p = await SharedPreferences.getInstance();
    final left = p.getStringList(memosKey);
    if (left == null) return false;
    // 先に消して、読み直しが重なっても二重に移さない。移せなかった分は戻す
    await p.remove(memosKey);
    try {
      while (left.isNotEmpty) {
        final m = jsonDecode(left.first) as Map<String, dynamic>;
        await widget.api.addMemo(DateTime.parse(m['at']), m['text']);
        left.removeAt(0);
      }
    } finally {
      if (left.isNotEmpty) await p.setStringList(memosKey, left);
    }
    return true;
  }

  Future<void> _login(String id, String password) async {
    final String token;
    try {
      token = await widget.api.login(id, password);
    } on ApiException catch (e) {
      if (mounted) showError(context, e);
      return;
    }
    // 次に開いたときにまたログインしなくて済むよう、ブラウザに覚えておく
    await (await SharedPreferences.getInstance()).setString(tokenKey, token);
    _reload();
  }

  bool get _ready => _text.text.trim().isNotEmpty || _files.isNotEmpty;

  /// 選んだ・撮った・貼り付けた・ドロップしたファイルを添える。受け付けない形式は除き、大きな画像は縮める
  Future<void> _addPicked(List<PickedFile> picked) async {
    if (_busy || picked.isEmpty) return;
    final (files: added, :rejected) = await toAttachments(picked);
    if (!mounted) return;
    if (rejected) showError(context, '添えられるのは PDF と画像（PNG・JPEG・WebP・HEIC）です');
    _addFiles(added);
  }

  void _addFiles(List<Attachment> added) {
    if (!mounted || added.isEmpty) return;
    final total = [..._files, ...added].fold(0, (n, f) => n + f.bytes.length);
    if (total > maxAttachmentBytes) {
      showError(context, 'ファイルは合わせて10MBまでです。減らしてから添えてください');
      return;
    }
    setState(() => _files.addAll(added));
  }

  /// トグルを押した操作で待ち受けの面を出すので、ブラウザはそのままマイクを開ける
  void _toggleRewind(bool on) => setState(() {
        _rewind = on;
        _capturing = false;
        _editingMemo = null;
      });

  /// サイドバーの「言われたことを記録」で、書く欄（最初の画面）に戻す。トグルと同じく、話し終わり待ちの間は止めない
  void _leaveRewind() {
    if (_rewind && !_capturing) _toggleRewind(false);
  }

  /// メモを入力欄の後ろに足す。続けて入れると1つの指示にまとめられる
  void _pour(Memo m) => setState(() {
        _text.text = [_text.text.trimRight(), m.text].where((t) => t.isNotEmpty).join('\n');
        _poured.add(m);
      });

  void _editMemo(Memo m) => setState(() {
        _editingMemo = m;
        _memoText.text = m.text;
      });

  /// リワインドの合間に、書き直しているメモ1件だけを記録する。言われた日は切り出した日にする。
  /// 入力欄から送るのと同じ列に積み、欄はすぐ閉じる
  void _sendMemo() {
    final m = _editingMemo;
    final text = _memoText.text.trim();
    if (m == null || text.isEmpty || _busy) return;
    final p = _Pending(text: text, today: DateFormat('yyyy-MM-dd').format(m.at), memo: m);
    if (text != m.text) {
      // 書き直した文面を先にメモに残す。途中でタブを閉じても、直した文面が残る
      _keep(p, () => widget.api.editMemo(m.id, text), onFailed: () {
        // ほかの端末で消したり記録したりしていれば、今のメモに合わせる（消えたメモの欄は _onStore が閉じる）
        unawaited(widget.api.store.load());
        // 欄を開き直すのは、リワインドのままで、ほかのメモを書き直していないときだけ
        if (!_rewind || _editingMemo != null) return;
        _editingMemo = m;
        _memoText.text = text;
      });
    }
    setState(() => _editingMemo = null);
    _enqueue(p);
  }

  /// 書き直したメモに差し替える。入力欄に入れた後でも、入力欄の文面は変えない
  Future<void> _saveMemo() async {
    final m = _editingMemo;
    final text = _memoText.text.trim();
    if (m == null || text.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      await widget.api.editMemo(m.id, text);
      if (!mounted) return;
      setState(() {
        // 外を押した先がほかのメモなら、そちらの欄はもう開いている
        if (_editingMemo == m) _editingMemo = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      showError(context, e);
      // ほかの端末で消したり記録したりしていれば、今のメモに合わせる
      unawaited(widget.api.store.load());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteMemo(Memo m) async {
    try {
      await widget.api.deleteMemo(m.id);
    } on ApiException catch (e) {
      if (mounted) showError(context, e);
      return;
    }
    if (mounted) setState(() => _poured.remove(m));
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

  /// 入力を控えて入力欄をすぐ空け、裏で照らし合わせる。文面はすぐ未整理メモに置き、途中でタブを閉じても残す（ADR 0015）
  void _submit(List<ManualState> manuals) {
    if (!_ready || _busy || _dictating) return;
    final poured = [..._poured];
    final earliest = poured.isEmpty ? null : poured.map((m) => m.at).reduce((a, b) => a.isBefore(b) ? a : b);
    // メモから書いたときは、言われた日を切り出した日にする（後日まとめて整理しても日付がずれない）
    final saidOn = earliest == null ? today() : DateFormat('yyyy-MM-dd').format(earliest);
    final targets = [for (final m in manuals) if (_targets.contains(m.id)) m.id];
    final text = _text.text.trim();
    final p = _Pending(
      text: text,
      files: [..._files],
      manualIds: targets.isEmpty ? null : targets,
      today: saidOn,
      poured: poured,
    );
    // メモは文字しか持てないので、ファイルは送り終えるまでアプリの中に持つ
    if (text.isNotEmpty) {
      // 失敗して送り直すときも言われた日がずれないよう、流し込んだメモの時刻を引き継ぐ
      _keep(p, () => widget.api.addMemo(earliest ?? DateTime.now(), text), onFailed: () {
        // 待っている間に書き始めた文は消さず、その前に戻す。音声入力の途中なら、次に届く文面で上書きされないよう、
        // 音声入力の前の文面にも足す
        _text.text = [text, _text.text.trim()].where((t) => t.isNotEmpty).join('\n');
        if (_dictating) _beforeDictation = [text, _beforeDictation].where((t) => t.isNotEmpty).join('\n');
        _files.insertAll(0, p.files);
        _poured.addAll(poured);
      });
    }
    setState(() {
      _text.clear();
      _files.clear();
      _poured.clear();
    });
    _enqueue(p);
  }

  /// 文面を未整理メモに置く（書き直す）。置けなければ送らず、書いていた所へ戻して知らせる
  void _keep(_Pending p, Future<Memo> Function() save, {required VoidCallback onFailed}) {
    p.saved = () async {
      try {
        final m = await save();
        if (!mounted) return false;
        setState(() => p.memo = m);
        return true;
      } catch (e) {
        if (!mounted) return false;
        showError(context, _failure(e, 'もう一度送ってください'));
        setState(() {
          _queue.remove(p);
          onFailed();
        });
        return false;
      }
    }();
  }

  void _enqueue(_Pending p) {
    setState(() => _queue.add(p));
    unawaited(_drain());
  }

  /// 待っている記録を、押した順に1件ずつ照らし合わせる。並べて送ると、続けて書いた2つが互いに照らされず、
  /// 食い違いを取りこぼす（設計書 0021 §3）
  Future<void> _drain() async {
    if (_sending) return;
    _sending = true;
    try {
      while (mounted && _queue.isNotEmpty) {
        final p = _queue.first;
        try {
          await _process(p);
        } catch (e) {
          // 想定外の失敗でも、後ろの記録は止めずに送る
          if (mounted) showError(context, _failure(e, _recordUnknown));
        } finally {
          if (mounted) setState(() => _queue.remove(p));
        }
      }
    } finally {
      _sending = false;
    }
  }

  /// 1件を記録し、サーバーが書き込んだ結果をカードで出す。関係するノートが無ければ、記録先を選ぶカードを出す
  Future<void> _process(_Pending p) async {
    if (!await p.saved) return;
    final IntakeResult r;
    try {
      r = await widget.api.intake(
        text: p.text,
        files: p.files,
        manualIds: p.manualIds,
        today: p.today,
        memoIds: p.memoIds,
        write: true,
      );
    } catch (e) {
      if (!mounted) return;
      showError(context, _failure(e, _recordUnknown));
      setState(() {
        // 文面は待ちを外せば未整理メモに出る。ファイルはメモに置けないので入力欄に戻す
        _files.insertAll(0, p.files);
        // 記録先を選び直して送ったものは、カードを戻す。ファイルだけの記録は、読み取った文面がカードにしか無い
        if (p.retryOf case final r?) _results.insert(0, r);
      });
      // 応答が途中で切れただけで、サーバーは記録してメモを消しているかもしれない。読み直して未整理メモとノートを合わせる
      unawaited(widget.api.store.load());
      return;
    }
    if (!mounted) return;
    final result = r.results.isEmpty
        // ファイルや録音はもう読み取ったので、選び直したら読み取った文面だけを送る。メモはサーバーに残っている
        ? _Result.missed(_Pending(text: r.text, today: p.today, poured: p.poured, memo: p.memo))
        : _Result(r.results, [
            for (final x in r.results) (c: ManualController(widget.api, x.manualId, x.state), utteranceId: x.utteranceId),
          ]);
    setState(() {
      // 記録できたメモは、サーバーが消し、Api が store からも外している
      if (r.results.isNotEmpty) _poured.removeWhere((m) => p.memoIds.contains(m.id));
      _results
        ..removeWhere((x) => !x.kept)
        ..insert(0, result);
    });
    // 次を書いている途中なら、書いている所を動かさない
    if (!_writing) WidgetsBinding.instance.addPostFrameCallback((_) => _revealResult(result.key));
  }

  bool get _writing => _text.text.trim().isNotEmpty || _files.isNotEmpty || _editingMemo != null;

  /// 関係するノートが見つからなかった記録を、選んだノートと照らし合わせる
  Future<void> _pickFor(_Result result, List<ManualState> manuals) async {
    final m = result.missed!;
    final ids = await _pickManuals(manuals, heard: m.text);
    if (ids == null || !mounted) return;
    setState(() => _results.remove(result));
    _enqueue(_Pending(text: m.text, manualIds: ids, today: m.today, poured: m.poured, memo: m.memo, retryOf: result));
  }

  /// 結果のカードを、見出しから下の端まで見える所へ送る。画面より高いカードは見出しを上の端に合わせる。
  /// 見えていれば動かさない。動きを減らす設定（Web では prefers-reduced-motion）なら、動かさずに移る
  void _revealResult(GlobalKey key) {
    final card = key.currentContext?.findRenderObject();
    if (!mounted || card == null || !_scroll.hasClients) return;
    final viewport = RenderAbstractViewport.of(card);
    final top = viewport.getOffsetToReveal(card, 0).offset;
    final bottom = viewport.getOffsetToReveal(card, 1).offset;
    final p = _scroll.position;
    final to = p.pixels.clamp(math.min(top, bottom), top).clamp(p.minScrollExtent, p.maxScrollExtent).toDouble();
    if (to == p.pixels) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      p.jumpTo(to);
    } else {
      p.animateTo(to, duration: context.tokens.scrollToResult, curve: Curves.easeOutCubic);
    }
  }

  /// 記録先を選んでもらう。1回の指示が複数にまたがることもあるので、いくつでも選べる。
  /// heard は関係するマニュアルが見つからなかったときの読み取った文面で、選んだらそのまま送る。
  /// 無ければ送る前に記録先を決めるだけで、1冊も選ばなければ AI に選ばせる
  Future<List<String>?> _pickManuals(List<ManualState> manuals, {String? heard, Set<String> initial = const {}}) {
    final k = context.tokens;
    final picked = {...initial};
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
                Text('どのノートに記録しますか？', style: k.text.title),
                if (heard != null) ...[
                  SizedBox(height: k.space.xs),
                  Text('関係するノートが見つかりませんでした。記録するノートを選んでください', style: k.text.small),
                  SizedBox(height: k.space.md),
                  Text('「$heard」', style: k.text.body),
                ],
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
                  MoonOutlinedButton(label: const Text('やめる'), onTap: () => Navigator.pop(ctx)),
                  const Spacer(),
                  MoonFilledButton(
                    label: Text(heard == null ? '記録先を決める' : '選んだノートと照らし合わせる'),
                    onTap: heard != null && picked.isEmpty
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

  /// 戻ってきても読み直さない。ほかの画面で書いた応答は store に入っている（ADR 0021）
  Future<void> _push(Widget screen) => Navigator.push(context, MaterialPageRoute(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    final narrow = !showsSidebar(context);
    // 広い幅に変わったとき、メニューが開いていたら、外す前に閉じる。drawer を外しただけでは Scaffold が「開いている」を
    // 覚えたままで、狭い幅に戻るとまた開いて出る（レビュー31）。閉じ終わったら onDrawerChanged で作り直し、drawer を外す
    final open = _scaffold.currentState?.isDrawerOpen ?? false;
    if (!narrow && open) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scaffold.currentState?.closeDrawer());
    }
    return Scaffold(
      key: _scaffold,
      onDrawerChanged: (_) => setState(() {}),
      // 左の端からのなぞりでは開かない。iPhone の Safari の「戻る」のなぞりとぶつかるので、三本線だけで開く
      drawerEnableOpenDragGesture: false,
      // 狭い画面では、サイドバーの代わりに上部バーの三本線から左にメニューを出す（Claude・ChatGPT のスマホ版と同じ）。
      // 広い幅に変わったらメニューは外す（開いていたら閉じる）
      drawer: narrow || open ? SidebarDrawer(api: widget.api, place: Place.input, open: _push, onRecord: _leaveRewind) : null,
      body: WithSidebar(
        api: widget.api,
        place: Place.input,
        onRecord: _leaveRewind,
        child: GridBackground(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TopBar(
            // アプリ名は、広い画面ではサイドバーの一番上に出すので、上部バーには何も出さない。
            // 狭い画面はサイドバーが無いので、三本線の隣にアプリ名を出す
            crumbs: narrow ? const ['DiffNote'] : const [],
            // ノート一覧・自分のページへは、狭い画面ではメニューから、広い画面ではサイドバーから移る
            leading: narrow
                ? Builder(
                    builder: (context) => MoonButton.icon(
                      semanticLabel: 'メニュー',
                      icon: Icon(LucideIcons.menu, color: k.colors.ink),
                      onTap: () => Scaffold.of(context).openDrawer(),
                    ),
                  )
                : null,
          ),
          Expanded(child: _body()),
        ])),
      ),
    );
  }

  /// 一度読めたあとは、戻ってきたときの読み直しに失敗しても今の表示のまま残し、待ち受けや書きかけを消さない。
  /// ログインが切れていたら（401）ログインの欄を出す
  Widget _body() {
    final store = widget.api.store;
    if (store.error case ApiException(status: 401, :final message)) {
      return _LoginForm(message: message, onSubmit: _login);
    }
    final manuals = store.notes;
    if (manuals == null) {
      return store.error == null ? const Loading() : LoadFailed(message: store.error.toString(), onRetry: _reload);
    }

    final k = context.tokens;
    return LayoutBuilder(builder: (context, box) {
      // 広い画面では、入力とあとで確認を左に、最近の付箋を右に並べ、書きながら前の記録を見られるようにする。
      // リワインドでは、左に待ち受けの面、右に最近の記録の代わりに未整理メモを置き、1件ずつ書き直して記録できるようにする
      final wide = box.maxWidth >= k.wideLayout;
      // 狭い画面では付箋を幅いっぱいにする（決まった幅のままだと1列に1枚しか入らず、右が空く）
      final noteWidth = wide ? null : double.infinity;
      final main = _rewind
          ? [
              RewindPanel(
                key: _rewindKey,
                api: widget.api,
                newRecorder: widget.newRecorder,
                onCapturing: (v) => setState(() => _capturing = v),
              ),
              // リワインドの間に未整理メモを記録したときも、待っている記録と結果は待ち受けの面の下に出す
              ..._pending(noteWidth: noteWidth),
              ..._resultCards(manuals),
            ]
          : [
              ..._unsorted(noteWidth: noteWidth),
              _composer(manuals, wide: wide),
              ..._pending(noteWidth: noteWidth),
              ..._resultCards(manuals),
              SizedBox(height: k.space.xxl),
              ..._openChecks(manuals),
            ];
      List<Widget> side({double? noteWidth}) =>
          _rewind ? _unsorted(noteWidth: noteWidth) : _recent(manuals, noteWidth: noteWidth);
      return Narrow(
        maxWidth: wide ? k.readableWidth + k.space.xxl + k.panelWidth : null,
        child: ListView(controller: _scroll, padding: EdgeInsets.fromLTRB(k.space.xl, k.space.xxl, k.space.xl, k.space.xxl), children: [
          PageTitle(
            '言われたことを記録',
            // ON にしても題名とトグルの位置は変えず、ページを移った感じを出さない
            trailing: manuals.isEmpty
                ? null
                : Row(mainAxisSize: MainAxisSize.min, children: [
                    Text('リワインド', style: k.text.heading),
                    SizedBox(width: k.space.sm),
                    MoonSwitch(
                      value: _rewind,
                      semanticLabel: 'リワインド',
                      // 音声入力とマイクを取り合わない。切り出しの途中で待ち受けを止めない
                      onChanged: _dictating || _capturing ? null : _toggleRewind,
                    ),
                  ]),
          ),
          // ノートが無いときは、同じ一文を空状態の案内に出す
          if (manuals.isNotEmpty) ...[SizedBox(height: k.space.sm), _about(wide: wide)],
          SizedBox(height: k.space.xl),
          if (manuals.isEmpty)
            _empty()
          else ...[
            if (wide)
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: main)),
                SizedBox(width: k.space.xxl),
                SizedBox(
                  width: k.panelWidth,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: side(noteWidth: k.panelWidth)),
                ),
              ])
            else ...[
              // 狭い画面でも待ち受けの面を先に置き、メモが増えてもボタンの位置が動かないようにする
              ...main,
              SizedBox(height: k.space.xxl),
              ...side(noteWidth: noteWidth),
            ],
          ],
        ]),
      );
    });
  }

  /// 題名の下に、何の道具かと、リワインドが何をするかを一言ずつ添える。広い画面では、リワインドの一言をトグルの下（右の列の上）に置く
  Widget _about({required bool wide}) {
    final k = context.tokens;
    final purpose = Text(appPurpose, style: k.text.small);
    // 音声は押すまで送らないが、切り出した発話は書き起こしのためにサーバーへ送る（ADR 0005）。「端末の中で文字にする」とは書かない
    final rewind = Text('リワインドは、直前60秒の音声を端末の中だけに持ち、言われた後にボタンを押すと、その声を切り出して文字にします', style: k.text.small);
    if (!wide) return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [purpose, SizedBox(height: k.space.sm), rewind]);
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: purpose),
      SizedBox(width: k.space.xxl),
      SizedBox(width: k.panelWidth, child: rewind),
    ]);
  }

  /// リワインドでためた未整理メモ。リワインドが OFF なら押すと入力欄に入り、無ければ何も出さない。
  /// ON なら押すとその場で書き直して1件ずつ記録でき、無くても見出しを出して右の列を空けない。
  /// 照らし合わせを待っている記録のメモは、押した瞬間に入力欄がずれないよう出さない（入力欄の下に付箋で出す）
  List<Widget> _unsorted({double? noteWidth}) {
    final k = context.tokens;
    final waiting = {for (final p in _queue) ...p.memoIds};
    final memos = [for (final m in widget.api.store.memos) if (!waiting.contains(m.id)) m];
    if (memos.isEmpty && !_rewind) return [];
    return [
      Text('未整理メモ', style: k.text.title),
      if (memos.isEmpty) ...[
        SizedBox(height: k.space.xs),
        Text('いま言われたことをメモすると、ここにたまります', style: k.text.small),
      ],
      Padding(
        padding: EdgeInsets.only(top: k.space.sm),
        child: Wrap(spacing: k.space.lg, runSpacing: k.space.xl, children: [
          for (final m in memos)
            SizedBox(
              width: noteWidth ?? k.stickyWidth,
              child: m == _editingMemo ? _memoEditor(m) : _memoNote(m),
            ),
        ]),
      ),
      if (!_rewind) SizedBox(height: k.space.xxl),
    ];
  }

  Widget _memoNote(Memo m) {
    final k = context.tokens;
    final poured = _poured.contains(m);
    return StickyNote(
      onTap: _busy
          ? null
          : _rewind
              ? () => _editMemo(m)
              : (!poured && !_dictating ? () => _pour(m) : null),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(DateFormat('M/d HH:mm').format(m.at), style: k.text.small)),
          MoonButton.icon(
            buttonSize: MoonButtonSize.xs,
            semanticLabel: 'メモを消す',
            icon: Icon(LucideIcons.x, color: k.colors.inkMuted),
            onTap: _busy ? null : () => _deleteMemo(m),
          ),
        ]),
        SizedBox(height: k.space.sm),
        Text(m.text, style: k.text.body),
        if (poured) ...[
          SizedBox(height: k.space.sm),
          Text('入力欄に入れました', style: k.text.small),
        ],
      ]),
    );
  }

  bool get _memoFilled => _memoText.text.trim().isNotEmpty;

  /// リワインドの間に付箋のまま書き直す欄。そのまま記録するか、外を押して直した文だけ残す
  Widget _memoEditor(Memo m) {
    final k = context.tokens;
    return TapOutside(
      onTapOutside: _closeMemo,
      child: StickyNote(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(DateFormat('M/d HH:mm').format(m.at), style: k.text.small),
          SizedBox(height: k.space.sm),
          MoonTextArea(
            controller: _memoText,
            autofocus: true,
            // 高さを決めないと1行分の高さになり、付箋の幅で折り返した文が見えない。
            // expands は付けない（moon_design 1.1.0 は expands のとき文字を縦の真ん中に置く）
            height: k.memoEditorHeight,
            readOnly: _busy,
            textStyle: k.text.inputArea,
          ),
          SizedBox(height: k.space.sm),
          Align(
            alignment: Alignment.centerLeft,
            // 打つたびにページ全体を作り直さないよう、欄の文で変わるボタンだけを作り直す
            child: ListenableBuilder(
              listenable: _memoText,
              builder: (_, _) => MoonFilledButton(
                buttonSize: MoonButtonSize.sm,
                onTap: _memoFilled && !_busy ? _sendMemo : null,
                label: const Text('ノートと照らし合わせる'),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  /// 書き直す欄の外を押したら、直した文を残して閉じる。直していない・空にしたなら元のまま閉じる
  void _closeMemo() {
    final m = _editingMemo;
    if (m == null || _busy) return;
    final text = _memoText.text.trim();
    if (text.isEmpty || text == m.text) {
      setState(() => _editingMemo = null);
      return;
    }
    _saveMemo();
  }

  /// 書く欄。白い面に載せる。Ctrl/⌘+Enter でも送れる（Slack やレビューのコメントを貼って、そのまま送る使い方のため）
  Widget _composer(List<ManualState> manuals, {bool wide = false}) {
    final k = context.tokens;
    void submit() => _submit(manuals);
    // 送るときと同じく、今あるノートに当たらない記録先は選んでいないのと同じ
    final auto = !manuals.any((m) => _targets.contains(m.id));
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): submit,
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): submit,
      },
      child: PaperSheet(
        padding: EdgeInsets.fromLTRB(k.space.lg, k.space.xl, k.space.lg, k.space.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // 書く欄と、その下の添付・マイクのボタンを1つの枠に入れる。moon_design 1.1.0 の MoonTextArea は、文字の上下に
          // textPadding の下の値を使い、例文には上の値を使うので、ボタンの分を下に空けると文字だけ下にずれる。
          // そこで欄の上下の余白はそろえ、ボタンは欄の下の行に置く（枠は外側に描く）
          // 中の書く欄にフォーカスがあるかを見るだけ。この Focus 自身にはフォーカスを移さない
          Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onFocusChange: (_) => setState(() {}),
            child: Builder(
              // 枠は中の欄の上に描く（後ろに描くと、中の欄の白い地に隠れる）
              builder: (context) => DecoratedBox(
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(
                  borderRadius: k.radius.control,
                  border: Border.all(
                    color: Focus.of(context).hasFocus ? k.colors.action : k.colors.rule,
                    width: k.hairline,
                  ),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  MoonTextArea(
                    controller: _text,
                    height: k.composerHeight - k.composerTools,
                    readOnly: _dictating,
                    textStyle: k.text.inputArea,
                    // 枠は外側の DecoratedBox が描く
                    backgroundColor: k.colors.canvas,
                    inactiveBorderColor: k.colors.canvas,
                    hoverBorderColor: k.colors.canvas,
                    activeBorderColor: k.colors.canvas,
                    textPadding: EdgeInsets.symmetric(horizontal: k.space.lg, vertical: k.space.md),
                    hintText: '例: 田中さんから、塩は小さじ1/2でいいと言われた',
                    // 消し切ったら、流し込んだメモはもう使っていない。打つたびにページ全体は作り直さず
                    // （送るボタンは欄を聞いて作り直す）、付箋の印を外すときだけ作り直す
                    onChanged: (v) {
                      if (v.trim().isEmpty && _poured.isNotEmpty) setState(_poured.clear);
                    },
                  ),
                  SizedBox(
                    height: k.composerTools,
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: k.space.sm),
                      // Flexible と Spacer で分けると、記録先が使わなかった幅が余ってマイクが右端に届かない
                      child: Row(children: [
                        _attach(),
                        Expanded(child: Align(alignment: Alignment.centerLeft, child: _target(manuals))),
                        _mic(),
                      ]),
                    ),
                  ),
                ]),
              ),
            ),
          ),
          // 何が自動なのかを、記録先のすぐ下で言う。選んだ後は AI が選ばないので出さない
          if (auto) ...[
            SizedBox(height: k.space.sm),
            Text('記録先が自動のままなら、どのノートの話かを AI が選びます', style: k.text.small),
          ],
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
              child: Text('聞き取り中。話し終わると止まります', style: k.text.small),
            ),
          ],
          SizedBox(height: k.space.lg),
          Align(
            alignment: Alignment.centerLeft,
            // 照らし合わせは裏で進むので、押したあとも止めない
            child: ListenableBuilder(
              listenable: _text,
              builder: (_, _) => MoonFilledButton(
                onTap: _ready && !_busy && !_dictating ? submit : null,
                label: const Text('ノートと照らし合わせる'),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  /// 照らし合わせを待っている記録。結果のカードが出る所に、言われたことの付箋で新しいものを上にして並べる
  List<Widget> _pending({double? noteWidth}) {
    final k = context.tokens;
    if (_queue.isEmpty) return [];
    return [
      SizedBox(height: k.space.lg),
      Wrap(spacing: k.space.lg, runSpacing: k.space.xl, children: [
        for (final p in _queue.reversed)
          SizedBox(
            width: noteWidth ?? k.stickyWidth,
            child: StickyNote(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (p.text.isNotEmpty) Text(p.text, style: k.text.body),
                if (p.files.isNotEmpty) ...[
                  if (p.text.isNotEmpty) SizedBox(height: k.space.xs),
                  Text(p.files.map((f) => f.name).join('、'), style: k.text.small),
                ],
                SizedBox(height: k.space.sm),
                // 進んでいることの知らせはタグにせず、小さい文字で添える（「聞き取り中」と同じ）
                Text('照らし合わせています…', style: k.text.small),
              ]),
            ),
          ),
      ]),
    ];
  }

  /// 記録した結果のカード。トーストのように消えず、下の「あとで確認」にも重ならない
  List<Widget> _resultCards(List<ManualState> manuals) => [
        for (final r in _results) ...[
          SizedBox(height: context.tokens.space.lg),
          if (r.missed != null)
            _missedCard(r, manuals)
          else
            RecordResultCard(
              key: r.key,
              records: r.records,
              targets: r.targets,
              onSettling: r.settled.add,
              onClose: () => setState(() => _results.remove(r)),
              // 確かめたあとの書き込み・発言者を、カードに映す
              onReviewed: () => setState(() => r.records = [
                    for (final t in r.targets) (manualId: t.c.manualId, utteranceId: t.utteranceId, state: t.c.state!),
                  ]),
            ),
        ],
      ];

  /// 関係するノートが見つからなかったときのカード。書いている途中に記録先の選択を割り込ませず、ここから開く
  Widget _missedCard(_Result r, List<ManualState> manuals) {
    final k = context.tokens;
    final m = r.missed!;
    return PaperSheet(
      key: r.key,
      padding: EdgeInsets.fromLTRB(k.space.xl, k.space.lg, k.space.lg, k.space.xl),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(top: k.space.xs),
              child: Text('関係するノートが見つかりませんでした', style: k.text.title),
            ),
          ),
          SizedBox(width: k.space.sm),
          MoonButton.icon(
            semanticLabel: '結果を閉じる',
            icon: Icon(LucideIcons.x, color: k.colors.ink),
            onTap: () => setState(() => _results.remove(r)),
          ),
        ]),
        SizedBox(height: k.space.md),
        Text('「${m.text}」', style: k.text.body),
        SizedBox(height: k.space.xl),
        Wrap(
          spacing: k.space.md,
          runSpacing: k.space.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            MoonFilledButton(onTap: () => _pickFor(r, manuals), label: const Text('記録先を選ぶ')),
            if (m.memoIds.isNotEmpty) Text('未整理メモに残しています', style: k.text.small),
          ],
        ),
      ]),
    );
  }

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
      // 上に開くと書いている文字に重なるので、下に開く
      dropdownAnchorPosition: MoonDropdownAnchorPosition.bottomLeft,
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
          content: Text('PDF・画像', style: k.text.small),
        ),
        if (onPhone)
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

  /// 入力欄の中の記録先。押すと記録先を選ぶ。選んだノートが1冊なら題名で、2冊以上なら冊数で見せる
  Widget _target(List<ManualState> manuals) {
    final k = context.tokens;
    final titles = [for (final m in manuals) if (_targets.contains(m.id)) m.title];
    return MoonTextButton(
      buttonSize: MoonButtonSize.sm,
      onTap: _busy
          ? null
          : () async {
              final ids = await _pickManuals(manuals, initial: _targets);
              if (ids == null || !mounted) return;
              setState(() => _targets
                ..clear()
                ..addAll(ids));
            },
      // moon_design 1.1.0 はラベルを幅の決まらない Row に入れるので、Flexible で包まないと長い題名がはみ出す
      label: Flexible(
        child: Text(
          '記録先：${switch (titles) { [] => '自動', [final t] => t, _ => '${titles.length} 冊' }}',
          style: k.text.small.copyWith(color: titles.isEmpty ? k.colors.inkMuted : k.colors.action),
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  /// 入力欄の中のマイク。聞き取り中は色で示し、確定の文面を待つ間は読み込み中にする
  Widget _mic() {
    final k = context.tokens;
    final listening = _dictation != null;
    return MoonButton.icon(
      buttonSize: MoonButtonSize.sm,
      semanticLabel: listening ? '声での入力をやめる' : '声で入力する',
      backgroundColor: listening ? k.colors.pendingBg : null,
      onTap: _busy || (_dictating && !listening) ? null : _toggleDictation,
      icon: _dictating && !listening
          ? MoonCircularLoader(color: k.colors.inkMuted, circularLoaderSize: MoonCircularLoaderSize.x2s)
          : Icon(LucideIcons.mic, color: listening ? k.colors.pending : k.colors.inkMuted),
    );
  }

  /// 「あとで確認」への導線。中身はサイドバーから開く「あとで確認」の画面と同じ部品
  List<Widget> _openChecks(List<ManualState> manuals) {
    final k = context.tokens;
    final open = manuals.fold(0, (n, s) => n + s.openChecks.length);
    return [
      // 件数は各ノートの行の札で出すので、見出しには合計を文字で添えるだけにする（札を重ねない）
      Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
        Text('あとで確認', style: k.text.title),
        if (open > 0) ...[
          SizedBox(width: k.space.sm),
          Text('全部で $open 件', style: k.text.small),
        ],
      ]),
      SizedBox(height: k.space.sm),
      OpenChecksList(manuals: manuals, onOpen: (s) => _push(CheckListScreen(c: ManualController(widget.api, s.id, s)))),
    ];
  }

  /// 全マニュアルの記録を新しい順に、言われたことの付箋で並べる。押すとそのマニュアルを開く
  /// noteWidth は付箋1枚の幅。広い画面の右の列では、列の幅いっぱいに縦に積む
  List<Widget> _recent(List<ManualState> manuals, {double? noteWidth}) {
    final k = context.tokens;
    final recent = [
      for (final s in manuals)
        for (final u in s.said) (manual: s, u: u),
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
        Text('まだノートがありません', style: k.text.heading),
        SizedBox(height: k.space.sm),
        Text(
          '$appPurpose\n今あるマニュアルを貼り付けても、白紙から始めてもかまいません。',
          style: k.text.small,
          textAlign: TextAlign.center,
        ),
        SizedBox(height: k.space.xl),
        MoonFilledButton(label: const Text('ノートを作る'), onTap: () => _push(NewManualScreen(api: widget.api))),
      ]),
    );
  }
}

/// 失敗を知らせる文。応答の形が違ったとき（TypeError など）に、英語の例外の文を出さない。then はどうすればいいか
Object _failure(Object e, String then) => e is ApiException ? e : 'サーバーの応答を読めませんでした。$then';

/// 照らし合わせの応答を読めなかったとき。サーバーは記録できているかもしれないので、送り直しは勧めない
const _recordUnknown = '記録できていなければ、文面は未整理メモに残ります';

/// 「ノートと照らし合わせる」を押して、照らし合わせを待っている記録
class _Pending {
  _Pending({
    required this.text,
    this.files = const [],
    this.manualIds,
    required this.today,
    this.poured = const [],
    this.memo,
    this.retryOf,
  });
  final String text;
  final List<Attachment> files;
  final List<String>? manualIds;
  final String today;

  /// 入力欄に流し込んだ未整理メモ
  final List<Memo> poured;

  /// 関係するノートが見つからず、記録先を選んで送り直したときの、そのカード。失敗したら戻す
  final _Result? retryOf;

  /// 文面を置いた未整理メモ。置き終わるまでと、文面が無い（ファイルだけの）ときは null
  Memo? memo;

  /// 文面をメモに置く呼び出し。置けなければ false になり、送らない
  Future<bool> saved = Future.value(true);

  /// 記録できたらサーバーが消すメモ
  List<String> get memoIds => [?memo?.id, for (final m in poured) m.id];
}

/// 結果のカード1枚。missed があれば、関係するノートが見つからなかった記録（text は読み取った文面）
class _Result {
  _Result(this.records, this.targets) : missed = null;
  _Result.missed(_Pending this.missed)
      : records = const [],
        targets = const [];

  /// サーバーが書き込んだ後の状態。確かめたあとは今の状態に合わせ直す
  List<Recorded> records;
  final List<ReviewTarget> targets;
  final _Pending? missed;

  /// カードで記録を見せて決着させた食い違い。ほかの画面での確定と違い、カードはそれを映しているので消さない
  final settled = <String>{};
  final key = GlobalKey();

  /// 次の結果が出ても消さない。確かめること・記録先を選ぶこと・確定していない食い違いが残っている
  bool get kept => missed != null || needsReview(records) || hasOpenConflict(records);
}

class _LoginForm extends StatefulWidget {
  const _LoginForm({required this.message, required this.onSubmit});
  final String message;
  final Future<void> Function(String id, String password) onSubmit;

  @override
  State<_LoginForm> createState() => _LoginFormState();
}

class _LoginFormState extends State<_LoginForm> {
  final _id = TextEditingController();
  final _password = TextEditingController();
  final _passwordFocus = FocusNode();
  var _busy = false;

  @override
  void dispose() {
    _id.dispose();
    _password.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final id = _id.text.trim();
    if (_busy || id.isEmpty || _password.text.isEmpty) return;
    setState(() => _busy = true);
    await widget.onSubmit(id, _password.text);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    return Narrow(
      child: SingleChildScrollView(
        padding: EdgeInsets.symmetric(horizontal: k.space.xl, vertical: k.space.xxl),
        // ブラウザのパスワード管理に覚えさせられるよう、ID とパスワードを1つのまとまりにする
        child: AutofillGroup(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // 初めて開いた人は、ログインの前に何の道具かを知らない
            Text(appPurpose, style: k.text.body),
            SizedBox(height: k.space.xl),
            Text(widget.message, style: k.text.heading),
            SizedBox(height: k.space.xs),
            Text('ID とパスワードは、このアプリを紹介した人に聞いてください', style: k.text.small),
            SizedBox(height: k.space.lg),
            MoonTextInput(
              controller: _id,
              autofocus: true,
              hintText: 'ID',
              autofillHints: const [AutofillHints.username],
              textInputAction: TextInputAction.next,
              onSubmitted: (_) => _passwordFocus.requestFocus(),
            ),
            SizedBox(height: k.space.sm),
            MoonTextInput(
              controller: _password,
              focusNode: _passwordFocus,
              obscureText: true,
              hintText: 'パスワード',
              autofillHints: const [AutofillHints.password],
              onSubmitted: (_) => _submit(),
            ),
            SizedBox(height: k.space.md),
            Align(
              alignment: Alignment.centerLeft,
              child: MoonFilledButton(
                onTap: _busy ? null : _submit,
                leading: _busy ? const ButtonLoader() : null,
                label: Text(_busy ? 'ログインしています…' : 'ログインする'),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
