// 画像の縮小・カメラ・貼り付けとドロップはブラウザでだけ扱う。テスト（VM）では何もしない
export 'files_stub.dart' if (dart.library.js_interop) 'files_web.dart';
