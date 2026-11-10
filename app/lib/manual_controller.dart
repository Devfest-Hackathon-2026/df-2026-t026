import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

import 'api.dart';
import 'history.dart';
import 'models.dart';

String today() => DateFormat('yyyy-MM-dd').format(DateTime.now());

final _random = Random.secure();

/// アプリで作る発言・差分の ID。サーバーの randomUUID と同じ UUID v4 の形にする
String _newId() {
  final b = [for (var i = 0; i < 16; i++) _random.nextInt(256)];
  b[6] = b[6] & 0x0f | 0x40;
  b[8] = b[8] & 0x3f | 0x80;
  final h = [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// 先に画面へ出した直接の編集。サーバーの応答の状態にこの差分が入るまで、手元で当てて見せる
class LocalEdit {
  LocalEdit(this.patch, this.utterance);
  final Patch patch;
  final Utterance utterance;

  /// サーバーに届いたか
  var sent = false;
  final _saved = Completer<bool>();

  /// 届いたら true、届かずに戻したら false
  Future<bool> get saved => _saved.future;
}

/// 届かなかった編集。count は戻した数（届かなかった1件と、その後ろに積んでいて送らなかった分）。
/// shown は戻す前に出していた行で、開いている欄の場所を合わせ直すのに使う
typedef EditFailure = ({LocalEdit edit, int count, ApiException error, List<ManualLine> shown});

/// 1冊のマニュアルの状態。状態の正はバックエンドにあり、応答は Api が store（NoteStore）に入れ、ここは store から読む。
/// 応答を受け取る道は store の1本だけで、ここへ直接は入れない（ADR 0020）。
/// 直接の編集だけは応答を待たずに先に出し、送信は裏でノートごとに1本ずつ、書いた順に送る（ADR 0007）
class ManualController extends ChangeNotifier {
  /// initial は、store にまだこのノートが無いときの土台
  ManualController(this.api, this.manualId, [ManualState? initial]) : _base = initial {
    if (initial != null) _rebuild();
  }

  final Api api;
  final String manualId;

  /// 画面に出す状態。サーバーの状態に、まだそこに入っていない自分の編集と確かめの結果を重ねたもの。
  /// 読むたびに store の最新を取り込む（取り込めないときは取っておく。_take）
  ManualState? get state {
    _take();
    return _state;
  }

  ManualState? _state;
  String? loadError;

  /// 画面の土台にしているサーバーの状態
  ManualState? _base;

  /// 土台にまだ入っていない自分の編集。書いた順
  final _local = <LocalEdit>[];

  /// 確かめで分かった確認。編集欄を開いている間は store の状態を土台に入れないので、ここでも重ねてすぐ出す
  final _checked = <Check>[];

  /// store で最後に見た状態と、そのうちまだ土台にしていないもの
  ManualState? _seen;
  ManualState? _held;
  var _editorOpen = false;
  Future<void> _sending = Future.value();
  Future<void> _checking = Future.value();

  /// 届かなかった編集を戻したときに呼ぶ。呼ぶときには state はもう戻してある
  void Function(EditFailure failure)? onEditFailed;

  /// まだサーバーに届いていない編集があるか
  bool get saving => _local.any((e) => !e.sent);

  /// 行の編集欄を開いているか。開いている間は、store から来た状態（応答も裏の取り直しも）を画面に入れない。
  /// 欄は行の番号で場所を覚えているので、ほかの人の編集で行がずれると、別の行を書き換えてしまう
  set editorOpen(bool open) {
    _editorOpen = open;
    _take();
    _notify();
  }

  /// 画面は、この1冊の手元の変化（先に出した編集・確かめ）と、store の変化（応答・取り直し）の両方で描き直す。
  /// store は画面が聞いている間だけ聞くので、閉じずに捨てたコントローラーが store に残らない
  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    api.store.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    api.store.removeListener(listener);
  }

  /// このノートを読み直す（ノートを開いたとき）。出せる状態が無いときだけ、読めなかったことを画面に出す
  Future<void> load() async {
    try {
      await api.store.refresh(manualId);
      loadError = null;
    } on ApiException catch (e) {
      loadError = e.message;
      // 消された・共有を外されたノートは、手元の古い内容を出さずに「見つかりません」を出す
      if (e.status == 404 && _local.isEmpty && !_editorOpen) _base = _state = _held = null;
    }
    _notify();
  }

  Future<void> editUtterance(String id, {String? speaker, String? saidAt, String? text}) =>
      _write(api.editUtterance(manualId, id, speaker: speaker, saidAt: saidAt, text: text));

  Future<void> applyPatch(String id, {String? text}) => _write(api.applyPatch(manualId, id, text: text));

  Future<void> discardPatch(String id) => _write(api.discardPatch(manualId, id));

  /// ノートを直接編集する。応答を待たずに画面へ出し、裏で送る。返した編集の saved で、届いたかが分かる
  LocalEdit edit(String op, {String? line, String text = ''}) {
    final e = _localEdit(state!, op, line, text);
    _local.add(e);
    _rebuild();
    _notify();
    _sending = _sending.then((_) => _send(e));
    return e;
  }

  /// 応答を待って直接編集する（衝突のダイアログの「自分のにする」）。届いた差分の ID を返す
  Future<String> editAndWait(String op, {String? line, String text = ''}) async {
    final e = _localEdit(state!, op, line, text);
    final sent = _sending.then((_) => _post(e));
    _sending = sent.then((_) {}, onError: (_) {});
    await sent;
    _take();
    _notify();
    return e.patch.id;
  }

  /// 直接書いた行を確かめ、食い違っていればその項目を返す。確かめは1本ずつ順に送る。
  /// 応答からはその確認1件だけを今の状態に足す（丸ごと差し替えると、確かめている間に書いた行が消える）
  Future<Check?> checkEdit(String patchId) {
    final r = _checking.then((_) => _check(patchId));
    _checking = r.then((_) {}, onError: (_) {});
    return r;
  }

  Future<void> resolve(
    String checkId, {
    String? decidedBy,
    required String decidedAt,
    required String text,
    required String note,
  }) =>
      _write(api.resolve(manualId, checkId, decidedBy: decidedBy, decidedAt: decidedAt, text: text, note: note));

  Future<void> resolveByRecord(String checkId, {required String shownFrom}) =>
      _write(api.resolveByRecord(manualId, checkId, shownFrom: shownFrom));

  /// 画面を閉じた後も、積んだ編集と確かめは送り切る。閉じた後は知らせない
  var _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  LocalEdit _localEdit(ManualState s, String op, String? line, String text) {
    final at = _stamp(s);
    final name = _myName(s);
    final u = Utterance(
      id: _newId(),
      text: op == 'delete' ? '「$line」を消した' : text,
      // 共有されたノートでは、直した人の名前を発言者にする（ADR 0013）
      speaker: s.sharedBy == null ? '自分' : name,
      saidAt: today(),
      fromEdit: true,
      editedBy: s.sharedBy == null ? null : s.me,
      recordedBy: (id: s.me, name: name),
      createdAt: at,
    );
    final p = Patch(
      id: _newId(),
      utteranceId: u.id,
      op: op,
      line: line,
      text: text,
      summary: const {'insert': '追記', 'replace': '書き換え', 'delete': '削除'}[op]!,
      status: 'applied',
      createdAt: at,
      appliedAt: at,
    );
    return LocalEdit(p, u);
  }

  /// 記録・反映の日時。履歴は反映した順に差分を当て直すので、端末の時計が遅れていても今ある差分より前にしない
  String _stamp(ManualState s) {
    final now = DateTime.fromMillisecondsSinceEpoch(DateTime.now().millisecondsSinceEpoch, isUtc: true);
    return s.patches.map((p) => p.appliedAt).nonNulls.fold(now.toIso8601String(), (a, b) => b.compareTo(a) > 0 ? b : a);
  }

  /// 応答が入るまでの、自分の名前の仮置き。サーバーは決めた名前（無ければログイン ID）を付ける。
  /// 前に記録・編集した記録から引き、引けなければログイン ID にする
  String _myName(ManualState s) {
    for (final u in s.utterances.reversed) {
      if (u.recordedBy case (:final id, :final name) when id == s.me) return name;
      if (u.editedBy == s.me && u.speaker != null) return u.speaker!;
    }
    return s.me;
  }

  Future<ManualState> _post(LocalEdit e) => api.edit(
        manualId,
        op: e.patch.op,
        line: e.patch.line,
        text: e.patch.text,
        today: e.utterance.saidAt,
        utteranceId: e.utterance.id,
        patchId: e.patch.id,
      );

  Future<void> _send(LocalEdit e) async {
    // 前の編集が届かず、一緒に戻した
    if (!_local.contains(e)) return;
    try {
      await _post(e);
    } catch (err) {
      // 応答を読めなかったときも戻す。投げたままにすると、後ろの編集が送られずに残る
      return _fail(e, err is ApiException ? err : ApiException('$err'));
    }
    e.sent = true;
    _take();
    _notify();
    e._saved.complete(true);
  }

  /// 届かなかった編集と、その後ろに積んでいた編集を戻す。後ろの編集は前の編集の行を指していることがあるので送らない
  void _fail(LocalEdit e, ApiException error) {
    final shown = state!.lines;
    final dropped = _local.sublist(_local.indexOf(e));
    _local.removeRange(_local.length - dropped.length, _local.length);
    _rebuild();
    if (!_disposed) onEditFailed?.call((edit: e, count: dropped.length, error: error, shown: shown));
    _take();
    _notify();
    for (final d in dropped) {
      d._saved.complete(false);
    }
  }

  Future<Check?> _check(String patchId) async {
    final chk = await api.checkEdit(manualId, patchId);
    if (chk == null) return null;
    _checked.add(chk);
    _rebuild();
    _notify();
    return chk.isOpen ? chk : null;
  }

  /// 確定・反映・記録を直すなど、行の編集でない書き込み。応答は Api が store に入れるので、ここでは store から取り込む。
  /// 欄を閉じていれば、送っている編集を待たずに土台にする（届いていない編集はその上に重ねて出る）
  Future<void> _write(Future<void> sent) async {
    await sent;
    _pull();
    if (_held case final h? when !_editorOpen) _setBase(h);
    _notify();
  }

  /// store にあるこのノートの最新を、まだ土台にしていないものとして取っておく
  void _pull() {
    final s = api.store.note(manualId);
    if (s != null && !identical(s, _seen)) {
      _seen = s;
      _held = s;
    }
  }

  /// store の最新を取り込む。編集欄を開いている間と、送っていない編集がある間は取っておき、
  /// どちらも済んでから土台にする（古い応答で、まだ届いていない編集の後ろの行をずらさない）。ここでは知らせない
  void _take() {
    _pull();
    if (_held case final h? when !saving && !_editorOpen) _setBase(h);
  }

  void _setBase(ManualState s) {
    _base = s;
    // 取っておいた応答は捨てる。そこにしか入っていない自分の編集は、_local から重ねて出る
    _held = null;
    _local.removeWhere((e) => e.sent && s.patches.any((p) => p.id == e.patch.id));
    _checked.removeWhere((c) => s.checks.any((x) => x.id == c.id));
    _rebuild();
  }

  /// 土台に、まだ入っていない自分の編集と確かめの結果を重ねる
  void _rebuild() {
    // 消されたノートで、出す状態をもう外した
    final base = _base;
    if (base == null) return;
    var lines = base.lines;
    final utterances = [...base.utterances];
    final patches = [...base.patches];
    for (final e in _local) {
      if (base.patches.any((p) => p.id == e.patch.id)) continue;
      try {
        lines = patchLines(lines, e.patch);
      } on StateError {
        // ほかの人の編集で、当てる行がもう無い。届けばサーバーの答え（衝突か、足す場所の付け替え）が出る
        continue;
      }
      utterances.add(e.utterance);
      patches.add(e.patch);
    }
    _state = base.copyWith(lines: lines, utterances: utterances, patches: patches, checks: [
      ...base.checks,
      for (final c in _checked)
        if (!base.checks.any((x) => x.id == c.id) && patches.any((p) => p.id == c.patchId)) c,
    ]);
  }
}
