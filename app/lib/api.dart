import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'models.dart';

class ApiException implements Exception {
  ApiException(this.message, [this.status]);
  final String message;
  final int? status;

  @override
  String toString() => message;
}

class Api {
  Api({http.Client? client, String? baseUrl, this.passcode, WebSocketChannel Function(Uri)? connect})
      : _client = client ?? http.Client(),
        _connect = connect ?? WebSocketChannel.connect,
        baseUrl = baseUrl ?? const String.fromEnvironment('API_URL', defaultValue: 'http://localhost:8787');

  final http.Client _client;
  final WebSocketChannel Function(Uri) _connect;
  final String baseUrl;

  /// API の合言葉。サーバーが合言葉を決めていないとき（ローカル開発）は null のままでよい
  String? passcode;

  /// 記録や確定でデータが変わるたびに増える。どの画面で変えても、サイドバーの件数を合わせるため
  final changes = ValueNotifier(0);

  Future<List<ManualSummary>> listManuals() async =>
      [for (final m in await _send('GET', '/manuals')) ManualSummary.fromJson(m)];

  Future<ManualState> createManual(String title, String body) async =>
      ManualState.fromJson(await _send('POST', '/manuals', {'title': title, 'body': body}));

  Future<ManualState> getManual(String id) async => ManualState.fromJson(await _send('GET', '/manuals/$id'));

  /// 入力ページから記録する。manualIds を省くと、関係するマニュアルをバックエンドが選ぶ
  Future<IntakeResult> intake({
    required String text,
    List<Attachment> files = const [],
    List<String>? manualIds,
    required String today,
  }) async =>
      IntakeResult.fromJson(await _send('POST', '/utterances', {
        'text': text,
        'files': [
          for (final f in files) {'mimeType': f.mimeType, 'data': base64Encode(f.bytes)},
        ],
        'manualIds': ?manualIds,
        'today': today,
      }));

  /// テキスト欄の音声入力。16kHz・16bit の PCM を送ると途中の文面（{text}）が届き、"end" を送ると
  /// 確定の文面（{text, done: true}）が届いて閉じる。失敗したら {error} が届く。記録はしない
  WebSocketChannel dictation() {
    final base = Uri.parse(baseUrl);
    return _connect(base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '${base.path}/dictation',
      // ブラウザの WebSocket はヘッダーを付けられないので、合言葉はクエリで渡す
      queryParameters: passcode == null ? null : {'passcode': passcode},
    ));
  }

  Future<ManualState> editUtterance(String manualId, String id, {String? speaker, String? saidAt}) async =>
      ManualState.fromJson(await _send('PATCH', '/manuals/$manualId/utterances/$id', {
        'speaker': ?speaker,
        'saidAt': ?saidAt,
      }));

  Future<ManualState> applyPatch(String manualId, String id, {String? text}) async =>
      ManualState.fromJson(await _send('POST', '/manuals/$manualId/patches/$id/apply', {'text': ?text}));

  Future<ManualState> discardPatch(String manualId, String id) async =>
      ManualState.fromJson(await _send('POST', '/manuals/$manualId/patches/$id/discard', {}));

  Future<ManualState> resolve(
    String manualId,
    String checkId, {
    required String decidedBy,
    required String decidedAt,
    required String text,
    required String note,
  }) async =>
      ManualState.fromJson(await _send('POST', '/manuals/$manualId/checks/$checkId/resolve', {
        'decidedBy': decidedBy,
        'decidedAt': decidedAt,
        'text': text,
        'note': note,
      }));

  Future<dynamic> _send(String method, String path, [Map<String, dynamic>? body]) async {
    final req = http.Request(method, Uri.parse('$baseUrl$path'));
    if (passcode case final p?) req.headers['X-Passcode'] = p;
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final http.Response res;
    try {
      res = await http.Response.fromStream(await _client.send(req));
    } on http.ClientException {
      throw ApiException('サーバーにつながりません');
    }
    final json = res.bodyBytes.isEmpty ? null : jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode >= 400) {
      throw ApiException(json?['error'] ?? 'エラーが起きました（${res.statusCode}）', res.statusCode);
    }
    if (method != 'GET') changes.value++;
    return json;
  }
}
