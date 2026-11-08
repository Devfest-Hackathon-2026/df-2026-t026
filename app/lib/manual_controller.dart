import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

import 'api.dart';
import 'models.dart';

String today() => DateFormat('yyyy-MM-dd').format(DateTime.now());

/// 1冊のマニュアルの状態。状態の正はバックエンドにあり、操作のたびに最新を受け取り直す
class ManualController extends ChangeNotifier {
  ManualController(this.api, this.manualId, [this.state]);

  final Api api;
  final String manualId;
  ManualState? state;
  String? loadError;

  Future<void> load() async {
    try {
      state = await api.getManual(manualId);
      loadError = null;
    } on ApiException catch (e) {
      loadError = e.message;
    }
    notifyListeners();
  }

  Future<void> editUtterance(String id, {String? speaker, String? saidAt, String? text}) async =>
      _set(await api.editUtterance(manualId, id, speaker: speaker, saidAt: saidAt, text: text));

  Future<void> applyPatch(String id, {String? text}) async => _set(await api.applyPatch(manualId, id, text: text));

  Future<void> discardPatch(String id) async => _set(await api.discardPatch(manualId, id));

  /// ノートを直接編集し、その編集のパッチを返す
  Future<Patch> edit(String op, {String? line, String text = ''}) async {
    _set(await api.edit(manualId, op: op, line: line, text: text, today: today()));
    return state!.patches.last;
  }

  /// 直接書いた行を確かめ、食い違っていればその項目を返す
  Future<Check?> checkEdit(String patchId) async {
    _set(await api.checkEdit(manualId, patchId));
    final chk = state!.checkOf(patchId);
    return chk != null && chk.isOpen ? chk : null;
  }

  Future<void> resolve(
    String checkId, {
    required String decidedBy,
    required String decidedAt,
    required String text,
    required String note,
  }) async =>
      _set(await api.resolve(manualId, checkId, decidedBy: decidedBy, decidedAt: decidedAt, text: text, note: note));

  /// 直接編集の確かめは画面を閉じた後に返ることがあるので、閉じた後は受け取らない
  var _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _set(ManualState s) {
    if (_disposed) return;
    state = s;
    notifyListeners();
  }
}
