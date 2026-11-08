import 'dart:js_interop';

import 'package:web/web.dart' as web;

web.WakeLockSentinel? _lock;
var _wanted = false;
var _watching = false;

/// 待ち受け中は画面を点けたままにする。スマホのブラウザは画面が消えるとマイクを止めるため。
/// 画面の点灯はタブが隠れると外れるので、戻ったら取り直す
void keepScreenOn(bool on) {
  _wanted = on;
  if (!_watching) {
    _watching = true;
    web.document.addEventListener(
      'visibilitychange',
      ((web.Event _) {
        if (_wanted && web.document.visibilityState == 'visible') _request();
      }).toJS,
    );
  }
  if (on) {
    _request();
  } else {
    _lock?.release();
    _lock = null;
  }
}

/// 隠れていたタブが見えるようになるたびに f を呼ぶ。戻り値で呼ぶのをやめる
void Function() onScreenShown(void Function() f) {
  final listener = ((web.Event _) {
    if (web.document.visibilityState == 'visible') f();
  }).toJS;
  web.document.addEventListener('visibilitychange', listener);
  return () => web.document.removeEventListener('visibilitychange', listener);
}

Future<void> _request() async {
  if (_lock case final l? when !l.released) return;
  try {
    _lock = await web.window.navigator.wakeLock.request('screen').toDart;
  } catch (_) {
    // 対応していないブラウザや省電力中は取れない。待ち受けはそのまま続ける
  }
}
