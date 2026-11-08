// 画面の点灯と、タブが見えるようになったことはブラウザでだけ扱う。テスト（VM）では何もしない
export 'screen_stub.dart' if (dart.library.js_interop) 'screen_web.dart';
