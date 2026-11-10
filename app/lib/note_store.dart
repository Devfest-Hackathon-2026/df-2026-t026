import 'package:flutter/foundation.dart';

import 'api.dart';
import 'models.dart';

/// アプリの状態の置き場（ADR 0020）。自分・全部のノートのサーバーの状態・未整理メモを1か所に持ち、画面はここから描く。
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

  /// 最後に読めなかったときの失敗。読めたら null
  Object? error;

  Future<void>? _loading;

  /// 書き込みの応答を入れるたびに増やす。読み込みの応答が、読んでいる間に書いた所を古い状態に戻さないよう比べる
  var _writes = 0;
  final _noteWrittenAt = <String, int>{};
  var _meWrittenAt = 0;
  var _memosWrittenAt = 0;

  /// 直接書いた行の確かめで分かった確認（ADR 0007）。確かめより前に読まれた応答で消えないよう、応答に入るまで重ねる
  final _checked = <String, List<Check>>{};

  ManualState? note(String id) => _notes.where((s) => s.id == id).firstOrNull;

  /// まだ1度も読めていなければ読む。入力ページ以外の画面をいきなり開いたときのため
  void ensureLoaded() {
    if (!_loaded) load();
  }

  /// GET /home で全部を読み直す。読んでいる途中なら、その読み込みを待つ。
  /// 画面を作っている最中に呼ばれてもよいよう、読み始めでは知らせない
  Future<void> load() => _loading ??= _fetch().whenComplete(() => _loading = null);

  Future<void> _fetch() async {
    error = null;
    final since = _writes;
    try {
      final h = await _api.home();
      final next = [
        for (final s in h.notes)
          if ((_noteWrittenAt[s.id] ?? 0) <= since) _withChecked(s) else ?note(s.id),
      ];
      // 読んでいる間に作ったノートは残す
      for (final s in _notes) {
        if ((_noteWrittenAt[s.id] ?? 0) > since && !next.any((x) => x.id == s.id)) _insert(next, s);
      }
      _notes = next;
      if (_meWrittenAt <= since) me = h.me;
      if (_memosWrittenAt <= since) memos = h.memos;
      _loaded = true;
    } catch (e) {
      // 応答の形が違ったときも、画面に出せる失敗として持つ
      error = e;
    }
    notifyListeners();
  }

  /// 1冊を GET /manuals/:id で読み直す（ノートを開いたとき）。読んでいる間に書き込んだら、書き込みの応答の方を残す
  Future<void> refresh(String id) async {
    final since = _writes;
    final s = await _api.getManual(id);
    if ((_noteWrittenAt[id] ?? 0) > since) return;
    _replace(_withChecked(s));
    notifyListeners();
  }

  /// 書き込みの応答の状態を入れる。Api が呼ぶ
  ManualState put(ManualState s) {
    _noteWrittenAt[s.id] = ++_writes;
    _replace(_withChecked(s));
    notifyListeners();
    return s;
  }

  /// ノートを消した・共有を自分で外したとき。Api が呼ぶ
  void remove(String id) {
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
