import 'package:flutter/foundation.dart';

import 'api.dart';
import 'models.dart';

/// アプリの状態の置き場（ADR 0021）。自分・全部のノートのサーバーの状態・未整理メモ・通知を1か所に持ち、画面はここから描く。
/// 開いたとき・戻ってきたときに GET /home で読み、書き込みの応答は Api がここに入れる（書いたあとは取り直さない）
class NoteStore extends ChangeNotifier {
  NoteStore(this._api);
  final Api _api;

  /// ログインしている自分。読めるまで null
  Me? me;

  /// 全部のノート。自分のノート（作った新しい順）→ 共有されたノート（共有された新しい順）で、サーバーの並びのまま。
  /// 1度も読めていなければ null
  List<ManualState>? get notes => _loaded ? _notes : null;
  var _notes = <ManualState>[];
  var _loaded = false;

  /// 未整理メモ。切り出した順
  var memos = <Memo>[];

  /// 自分のノートで、共有した相手が答えた・直したこと（ADR 0020）。ほかの人がしたことなので、自分が書いても変わらない。
  /// 開いたとき・戻ってきたときの GET /home でだけ新しくなる。1度も読めていなければ null
  Notices? notices;

  /// 新しい通知（最後に見た時刻より後）の数。サイドバーの自分の右に出す
  int get freshNotices {
    final n = notices;
    if (n == null) return 0;
    return n.items.where((x) => n.seenAt == null || x.at.compareTo(n.seenAt!) > 0).length;
  }

  /// 最後に読めなかったときの失敗。読めたら null
  Object? error;

  Future<void>? _loading;

  /// ログアウトで空にするたびに増やす。空にする前に読み始めた読み込みの失敗を、次の人の画面に出さないよう比べる
  var _session = 0;

  /// 書き込みの応答を入れるたびに増やす。読み込みの応答が、読んでいる間に書いた所を古い状態に戻さないよう比べる
  var _writes = 0;
  final _noteWrittenAt = <String, int>{};
  var _meWrittenAt = 0;
  var _memosWrittenAt = 0;
  var _noticesWrittenAt = 0;

  /// 直接書いた行の確かめで分かった確認（ADR 0007）。確かめより前に読まれた応答で消えないよう、応答に入るまで重ねる
  final _checked = <String, List<Check>>{};

  /// 消した・共有を外した（外された）ノート。そのあとに届いた書き込みの応答や、1冊の読み直しでは戻さない。
  /// 外したあとに読み始めた GET /home が返したら（共有され直した）、また入れる
  final _removed = <String>{};

  ManualState? note(String id) => _notes.where((s) => s.id == id).firstOrNull;

  /// まだ1度も読めていなければ読む。入力ページ以外の画面をいきなり開いたときのため
  void ensureLoaded() {
    if (!_loaded) load();
  }

  /// GET /home で全部を読み直す。読んでいる途中なら、その読み込みを待つ。
  /// 画面を作っている最中に呼ばれてもよいよう、読み始めでは知らせない
  Future<void> load() {
    if (_loading case final loading?) return loading;
    late final Future<void> loading;
    loading = _fetch().whenComplete(() {
      // 空にしたあとに始めた読み込みを、前の読み込みが終わったときに外さない
      if (identical(_loading, loading)) _loading = null;
    });
    return _loading = loading;
  }

  Future<void> _fetch() async {
    error = null;
    final since = _writes;
    final session = _session;
    try {
      final h = await _api.home();
      final next = [
        for (final s in h.notes)
          if ((_noteWrittenAt[s.id] ?? 0) <= since && !_older(s)) _withChecked(s) else ?note(s.id),
      ];
      // 読んでいる間に作ったノートは残す
      for (final s in _notes) {
        if ((_noteWrittenAt[s.id] ?? 0) > since && !next.any((x) => x.id == s.id)) _insert(next, s);
      }
      _notes = next;
      _removed.removeAll([for (final s in next) s.id]);
      if (_meWrittenAt <= since) me = h.me;
      if (_memosWrittenAt <= since) memos = h.memos;
      // 読んでいる間に見たことにしても、通知そのものは古くならない。古くなるのは見た時刻だけなので、新しい方を残す
      final seen = notices?.seenAt;
      notices = _noticesWrittenAt > since && seen != null && seen.compareTo(h.notices.seenAt ?? '') > 0
          ? (seenAt: seen, items: h.notices.items)
          : h.notices;
      _loaded = true;
    } catch (e) {
      // ログアウトで空にする前に読み始めた読み込みの失敗（前の人の応答は Api が捨てる）は、次の人の画面に出さない
      if (session != _session) return;
      // ログインが切れた（ほかのタブでログアウトしたなど）ら、ログインの欄の横に前の人の中身を出さない。
      // それ以外の失敗では、1度読めた表示を残す
      if (e is ApiException && e.status == 401) _reset();
      // 応答の形が違ったときも、画面に出せる失敗として持つ
      error = e;
    }
    notifyListeners();
  }

  /// 1冊を GET /manuals/:id で読み直す（ノートを開いたとき）。読んでいる間に書き込んだら、そちらを残す。
  /// 見つからなければ（消された・共有を外された）外す。外したノートは、読めても入れない
  Future<void> refresh(String id) async {
    final since = _writes;
    final ManualState s;
    try {
      s = await _api.getManual(id);
    } on ApiException catch (e) {
      if (e.status == 404) remove(id);
      rethrow;
    }
    if ((_noteWrittenAt[id] ?? 0) > since || _removed.contains(id) || _older(s)) return;
    _replace(_withChecked(s));
    notifyListeners();
  }

  /// ログアウトしたとき。次にログインした人に前の人の中身を一瞬も出さないよう、全部を空にする。
  /// 送っている途中の読み込み・書き込みの応答は、トークンが替わったので Api が捨てる
  void clear() {
    _reset();
    notifyListeners();
  }

  void _reset() {
    _session++;
    me = null;
    _notes = [];
    _loaded = false;
    memos = [];
    notices = null;
    error = null;
    _loading = null;
    _writes = 0;
    _noteWrittenAt.clear();
    _meWrittenAt = _memosWrittenAt = _noticesWrittenAt = 0;
    _checked.clear();
    _removed.clear();
  }

  /// 書き込みの応答の状態を入れる。Api が呼ぶ。応答の届く順は入れ替わるので、今持っている状態より前に読んだものは入れない
  ManualState put(ManualState s) {
    if (_removed.contains(s.id) || _older(s)) return s;
    _noteWrittenAt[s.id] = ++_writes;
    _replace(_withChecked(s));
    notifyListeners();
    return s;
  }

  /// ノートを消した・共有を自分で外したとき。Api が呼ぶ
  void remove(String id) {
    _removed.add(id);
    _noteWrittenAt[id] = ++_writes;
    _notes = [for (final s in _notes) if (s.id != id) s];
    notifyListeners();
  }

  /// 直接書いた行の確かめで分かった確認を、今の状態に足す。確かめの応答の全体は確かめを始めたときに読んだものなので、
  /// 入れるとその間に書いた行が消える（ADR 0007）。Api が呼ぶ
  void addCheck(String manualId, Check c) {
    final s = note(manualId);
    if (s == null || s.checks.any((x) => x.id == c.id)) return;
    (_checked[manualId] ??= []).add(c);
    _replace(s.copyWith(checks: [...s.checks, c]));
    notifyListeners();
  }

  void putMe(Me m) {
    _meWrittenAt = ++_writes;
    me = m;
    notifyListeners();
  }

  /// 足した・書き直したメモ。書き直したメモは同じ id なので置き換わる
  void putMemo(Memo m) {
    _memosWrittenAt = ++_writes;
    memos = [...memos.where((x) => x != m), m]..sort((a, b) => a.at.compareTo(b.at));
    notifyListeners();
  }

  void removeMemos(List<String> ids) {
    _memosWrittenAt = ++_writes;
    memos = [for (final m in memos) if (!ids.contains(m.id)) m];
    notifyListeners();
  }

  /// 通知を見たことにしたとき。Api が呼ぶ。サーバーは見た時刻を「今」にするので、手元では今ある通知をすべて見たことにする
  void seeNotices() {
    final n = notices;
    if (n == null) return;
    _noticesWrittenAt = ++_writes;
    final newest = n.items.firstOrNull?.at;
    if (newest != null && (n.seenAt == null || newest.compareTo(n.seenAt!) > 0)) {
      notices = (seenAt: newest, items: n.items);
    }
    notifyListeners();
  }

  /// s が、今持っているそのノートより前にサーバーが読んだ状態か。どちらかに asOf が無ければ（古いサーバー）比べない
  bool _older(ManualState s) {
    final at = s.asOf, current = note(s.id)?.asOf;
    return at != null && current != null && at.compareTo(current) < 0;
  }

  void _replace(ManualState s) {
    final i = _notes.indexWhere((x) => x.id == s.id);
    _notes = [..._notes];
    if (i < 0) {
      _insert(_notes, s);
    } else {
      _notes[i] = s;
    }
  }

  /// まだ無いノートを入れる。自分のノートは作った新しい順なので先頭に、共有されたノートは共有されたノートの先頭に
  static void _insert(List<ManualState> notes, ManualState s) {
    final shared = notes.indexWhere((x) => x.sharedBy != null);
    notes.insert(s.sharedBy == null ? 0 : (shared < 0 ? notes.length : shared), s);
  }

  ManualState _withChecked(ManualState s) {
    final extra = _checked[s.id];
    if (extra == null) return s;
    extra.removeWhere((c) => s.checks.any((x) => x.id == c.id));
    if (extra.isEmpty) _checked.remove(s.id);
    final add = [for (final c in extra) if (s.patches.any((p) => p.id == c.patchId)) c];
    return add.isEmpty ? s : s.copyWith(checks: [...s.checks, ...add]);
  }
}
