import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'models.dart';
import 'note_store.dart';

class ApiException implements Exception {
  ApiException(this.message, [this.status, this.body]);
  final String message;
  final int? status;

  /// エラーの応答の本文（JSON）。メッセージのほかに渡すものがあるときに読む
  final Object? body;

  @override
  String toString() => message;
}

class Api {
  Api({http.Client? client, String? baseUrl, this.token, WebSocketChannel Function(Uri)? connect})
      : _client = client ?? http.Client(),
        _connect = connect ?? WebSocketChannel.connect,
        baseUrl = baseUrl ?? const String.fromEnvironment('API_URL', defaultValue: 'http://localhost:8787');

  final http.Client _client;
  final WebSocketChannel Function(Uri) _connect;
  final String baseUrl;

  /// ログインで受け取ったトークン。ログインしていなければ null
  String? token;

  /// 画面が描く状態の置き場。読むのは store で、書き込みの応答はここ（Api）から store に入れる（ADR 0021）
  late final store = NoteStore(this);

  /// 配った ID とパスワードでログインし、以後の呼び出しに使うトークンを返す
  Future<String> login(String id, String password) async {
    final t = (await _send('POST', '/login', {'id': id, 'password': password}))['token'] as String;
    token = t;
    // ログアウトを通らずに（ほかのタブでログアウトして 401 になった所から）別の人が入っても、前の人の中身を出さない
    store.clear();
    return t;
  }

  /// 自分・全部のノートの状態・未整理メモ・通知。store が読む
  Future<({Me me, List<ManualState> notes, List<Memo> memos, Notices notices})> home() async {
    final j = await _send('GET', '/home');
    final n = j['notices'];
    return (
      me: Me.fromJson(j['me']),
      notes: [for (final s in j['notes']) ManualState.fromJson(s)],
      memos: [for (final m in j['memos']) Memo.fromJson(m)],
      notices: (seenAt: n['seenAt'] as String?, items: [for (final x in n['items']) Notice.fromJson(x)]),
    );
  }

  /// サーバーでトークンを止めてから手放す。もう止まっていた（401）ときもログアウトしたことにする。
  /// 次に別の人がログインしても前の人の中身を出さないよう、store も空にする
  Future<void> logout() async {
    try {
      await _send('POST', '/logout');
    } on ApiException catch (e) {
      if (e.status != 401) rethrow;
    }
    token = null;
    store.clear();
  }

  /// 名前とアイコンを保存する。icon が null ならアイコンを外す
  Future<Me> updateMe(String name, IconImage? icon) async {
    final me = Me.fromJson(await _send('PUT', '/me', {
      'name': name,
      'icon': icon == null ? null : {'mimeType': icon.mimeType, 'data': base64Encode(icon.bytes)},
    }));
    store.putMe(me);
    return me;
  }

  Future<ManualState> createManual(String title, String body) async =>
      store.put(ManualState.fromJson(await _send('POST', '/manuals', {'title': title, 'body': body})));

  /// 本文を AI にマークダウンへ整えさせた案を返す。保存はしない
  Future<String> format(String text) async => (await _send('POST', '/format', {'text': text}))['text'] as String;

  /// PDF・画像から、書いてある通りの本文と題名の案を読み取らせる。保存はしない
  Future<({String title, String text})> readNote(List<Attachment> files) async {
    final r = await _send('POST', '/read', {
      'files': [
        for (final f in files) {'mimeType': f.mimeType, 'data': base64Encode(f.bytes)},
      ],
    });
    return (title: r['title'] as String, text: r['text'] as String);
  }

  /// 1冊を読む。store が読む（NoteStore.refresh）
  Future<ManualState> getManual(String id) async => ManualState.fromJson(await _send('GET', '/manuals/$id'));

  /// ノートを消す（ADR 0014）。持ち主だけ。本文は空（204）。store からも外し、サイドバーや一覧から消す
  Future<void> deleteManual(String id) async {
    await _send('DELETE', '/manuals/$id');
    store.remove(id);
  }

  /// ノートに付けた資料の一覧。足した順（ADR 0019）
  Future<List<MaterialSummary>> listMaterials(String manualId) async =>
      [for (final m in await _send('GET', '/manuals/$manualId/materials')) MaterialSummary.fromJson(m)];

  /// 資料の中身。書き起こした行をページつきで返す
  Future<MaterialBody> getMaterial(String manualId, String materialId) async =>
      MaterialBody.fromJson(await _send('GET', '/manuals/$manualId/materials/$materialId'));

  /// 資料を足す。共有された人も足せる。貼り付けた文（text）か、PDF 1つ・画像10枚までのファイルのどちらか。
  /// ファイルなら AI が読み取り、題名が空なら AI が付けた題名にする
  Future<MaterialSummary> addMaterial(String manualId,
          {String title = '', String text = '', List<Attachment> files = const []}) async =>
      MaterialSummary.fromJson(await _send('POST', '/manuals/$manualId/materials', {
        'title': title,
        'text': text,
        'files': [
          for (final f in files) {'mimeType': f.mimeType, 'data': base64Encode(f.bytes)},
        ],
      }));

  /// 資料を1冊消す。共有された人も消せる。本文は空（204）
  Future<void> deleteMaterial(String manualId, String materialId) async =>
      _send('DELETE', '/manuals/$manualId/materials/$materialId');

  /// 通知を見たことにする（ADR 0020）。見たことにできたら store の見た時刻を進め、サイドバーの件数が消える
  Future<void> seeNotices() async {
    await _send('POST', '/notices/seen');
    store.seeNotices();
  }

  /// このノートを共有している相手
  Future<List<Person>> shares(String manualId) async => _people(await _send('GET', '/manuals/$manualId/shares'));

  /// ログイン ID の人にノートを共有し、共有している相手を返す
  Future<List<Person>> share(String manualId, String userId) async =>
      _people(await _send('POST', '/manuals/$manualId/shares', {'userId': userId}));

  /// その人への共有をやめ、共有している相手を返す。共有された人が自分を外したら、そのノートはもう読めないので store から外す
  Future<List<Person>> unshare(String manualId, String userId) async {
    final people = _people(await _send('DELETE', '/manuals/$manualId/shares/$userId'));
    if (store.note(manualId)?.me == userId) store.remove(manualId);
    return people;
  }

  List<Person> _people(dynamic json) => [for (final p in json) (id: p['id'] as String, name: p['name'] as String)];

  /// 入力ページから記録する。manualIds を省くと、関係するマニュアルをバックエンドが選ぶ。
  /// memoIds は入力欄に入れた未整理メモで、記録できたらサーバーが消す。
  /// write なら、発言者が分かれば追記・補足の書き込みまでサーバーが済ませ、書き込んだ後の状態を返す（ADR 0006）
  Future<IntakeResult> intake({
    required String text,
    List<Attachment> files = const [],
    List<String>? manualIds,
    required String today,
    List<String> memoIds = const [],
    bool write = false,
  }) async {
    final r = IntakeResult.fromJson(await _send('POST', '/utterances', {
      'text': text,
      'files': [
        for (final f in files) {'mimeType': f.mimeType, 'data': base64Encode(f.bytes)},
      ],
      'manualIds': ?manualIds,
      'today': today,
      if (memoIds.isNotEmpty) 'memoIds': memoIds,
      if (write) 'write': true,
    }));
    for (final x in r.results) {
      store.put(x.state);
    }
    if (r.results.isNotEmpty && memoIds.isNotEmpty) store.removeMemos(memoIds);
    return r;
  }

  /// リワインドで切り出した WAV を書き起こし、未整理メモにためる。ノートには記録しない。at は切り出した時刻
  Future<Memo> listen(Uint8List wav, DateTime at) async =>
      _memo(await _send('POST', '/listen', {'data': base64Encode(wav), 'at': at.toUtc().toIso8601String()}));

  /// 未整理メモを置く。入力ページで照らし合わせる文面と、前の版が端末内に置いていたメモ
  Future<Memo> addMemo(DateTime at, String text) async =>
      _memo(await _send('POST', '/memos', {'at': at.toUtc().toIso8601String(), 'text': text}));

  Future<Memo> editMemo(String id, String text) async => _memo(await _send('PATCH', '/memos/$id', {'text': text}));

  Future<void> deleteMemo(String id) async {
    await _send('DELETE', '/memos/$id');
    store.removeMemos([id]);
  }

  Memo _memo(dynamic json) {
    final m = Memo.fromJson(json);
    store.putMemo(m);
    return m;
  }

  /// テキスト欄の音声入力。16kHz・16bit の PCM を送ると途中の文面（{text}）が届き、"end" を送ると
  /// 確定の文面（{text, done: true}）が届いて閉じる。失敗したら {error} が届く。記録はしない
  WebSocketChannel dictation() {
    final base = Uri.parse(baseUrl);
    return _connect(base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '${base.path}/dictation',
      // ブラウザの WebSocket はヘッダーを付けられないので、トークンはクエリで渡す
      queryParameters: token == null ? null : {'token': token},
    ));
  }

  /// text を変えると、その文面で差分と分類を作り直す
  Future<ManualState> editUtterance(String manualId, String id, {String? speaker, String? saidAt, String? text}) async =>
      store.put(ManualState.fromJson(await _send('PATCH', '/manuals/$manualId/utterances/$id', {
        'speaker': ?speaker,
        'saidAt': ?saidAt,
        'text': ?text,
      })));

  Future<ManualState> applyPatch(String manualId, String id, {String? text}) async =>
      store.put(ManualState.fromJson(await _send('POST', '/manuals/$manualId/patches/$id/apply', {'text': ?text})));

  /// ノートを直接編集する。op は insert（line の後ろ。null なら末尾）・replace・delete。
  /// 発言と差分の ID はアプリが作って送る（先に画面へ出した編集と取り違えないため。ADR 0007）。
  /// 書き換える・消す行をほかの人が先に直していたら [EditConflict] を投げる（ADR 0016）
  Future<ManualState> edit(String manualId,
      {required String op,
      String? line,
      String text = '',
      required String today,
      required String utteranceId,
      required String patchId}) async {
    try {
      return store.put(ManualState.fromJson(await _send('POST', '/manuals/$manualId/edits', {
        'op': op,
        'line': line,
        'text': text,
        'today': today,
        'utteranceId': utteranceId,
        'patchId': patchId,
      })));
    } on ApiException catch (e) {
      if (e.body case {'conflict': final Map<String, dynamic> j}) throw EditConflict.fromJson(e.message, j);
      rethrow;
    }
  }

  /// 直接書いた行が、ほかの行や確定済みの記録と食い違わないかを確かめ、その確認を返す。
  /// 応答の全体は確かめを始めたときに読んだものなので、store にはその確認1件だけを足す（ADR 0007）
  Future<Check?> checkEdit(String manualId, String patchId) async {
    final chk =
        ManualState.fromJson(await _send('POST', '/manuals/$manualId/patches/$patchId/check', {})).checkOf(patchId);
    if (chk != null) store.addCheck(manualId, chk);
    return chk;
  }

  Future<ManualState> discardPatch(String manualId, String id) async =>
      store.put(ManualState.fromJson(await _send('POST', '/manuals/$manualId/patches/$id/discard', {})));

  /// 確定する。共有された人は decidedBy を送らず、自分の答えとして確定する（ADR 0017）
  Future<ManualState> resolve(
    String manualId,
    String checkId, {
    String? decidedBy,
    required String decidedAt,
    required String text,
    required String note,
  }) async =>
      store.put(ManualState.fromJson(await _send('POST', '/manuals/$manualId/checks/$checkId/resolve', {
        'decidedBy': ?decidedBy,
        'decidedAt': decidedAt,
        'text': text,
        'note': note,
      })));

  /// 聞き直さず、前の確定（shownFrom はその確認の id）の記録を見せて確定する。決めた人・日付・内容はサーバーが前の確定から引き継ぐ（#118）
  Future<ManualState> resolveByRecord(String manualId, String checkId, {required String shownFrom}) async =>
      store.put(ManualState.fromJson(
          await _send('POST', '/manuals/$manualId/checks/$checkId/resolve', {'shownFrom': shownFrom})));

  Future<dynamic> _send(String method, String path, [Map<String, dynamic>? body]) async {
    final req = http.Request(method, Uri.parse('$baseUrl$path'));
    if (token case final t?) req.headers['Authorization'] = 'Bearer $t';
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final sentWith = token;
    final http.Response res;
    try {
      res = await http.Response.fromStream(await _client.send(req));
    } on http.ClientException {
      throw ApiException('サーバーにつながりません');
    }
    // 送っている間にログアウト・ログインし直したら、届いたのは前の人の中身なので、store に入れさせない
    if (sentWith != null && token != sentWith) throw ApiException('ログアウトしました');
    // 本文が JSON でない（混んだときの 5xx の HTML など）ときも、画面が受けられる ApiException にする。
    // FormatException のままだと、送る操作では何も出ず、読み込む画面では英語の例外の文が出る
    final dynamic json;
    try {
      json = res.bodyBytes.isEmpty ? null : jsonDecode(utf8.decode(res.bodyBytes));
    } on FormatException {
      throw ApiException('エラーが起きました（${res.statusCode}）', res.statusCode);
    }
    if (res.statusCode >= 400) {
      final error = json is Map ? json['error'] : null;
      throw ApiException(error is String ? error : 'エラーが起きました（${res.statusCode}）', res.statusCode, json);
    }
    return json;
  }
}

/// 直そうとした行を、ほかの人が先に書き換えた・消していた（ADR 0016）
class EditConflict extends ApiException {
  EditConflict.fromJson(String message, Map<String, dynamic> j)
      : line = j['line'],
        theirs = j['theirs'],
        after = j['after'],
        by = j['by'],
        at = j['at'],
        super(message, 409);

  /// 直そうとした元の行
  final String line;

  /// 相手が書き換えた行。消していれば null
  final String? theirs;

  /// 相手が消した行の1つ上にあり、今も残っている行。無ければ null（末尾）
  final String? after;
  final String by;

  /// YYYY-MM-DD
  final String at;
}
