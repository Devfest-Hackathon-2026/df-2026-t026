import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

import 'api.dart';
import 'models.dart';

String today() => DateFormat('yyyy-MM-dd').format(DateTime.now());

/// 1冊のマニュアルの状態。状態の正はバックエンドにあり、操作のたびに最新を受け取り直す
class ManualController extends ChangeNotifier {
  ManualController(this.api, this.manualId);

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

  Future<String> record(String text) async {
    final (id, s) = await api.record(manualId, text, today());
    _set(s);
    return id;
  }

  Future<void> editUtterance(String id, {String? speaker, String? saidAt}) async =>
      _set(await api.editUtterance(manualId, id, speaker: speaker, saidAt: saidAt));

  Future<void> applyPatch(String id, {String? text}) async => _set(await api.applyPatch(manualId, id, text: text));

  Future<void> discardPatch(String id) async => _set(await api.discardPatch(manualId, id));

  Future<void> resolve(
    String checkId, {
    required String decidedBy,
    required String decidedAt,
    required String text,
    required String note,
  }) async =>
      _set(await api.resolve(manualId, checkId, decidedBy: decidedBy, decidedAt: decidedAt, text: text, note: note));

  void _set(ManualState s) {
    state = s;
    notifyListeners();
  }
}
