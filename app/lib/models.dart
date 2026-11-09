import 'dart:convert';
import 'dart:typed_data';

/// 分類名はコード・UI・評価で揃える（same / addition / qualification / contradiction）
enum Kind {
  same('同じ内容'),
  addition('追記'),
  qualification('条件付きの補足'),
  contradiction('矛盾');

  const Kind(this.label);
  final String label;
}

/// アイコンの画像
typedef IconImage = ({String mimeType, Uint8List bytes});

/// ログインしている自分。名前を決めていなければ ID が入る（ADR 0010）
class Me {
  Me.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        name = j['name'],
        icon = switch (j['icon']) {
          {'mimeType': final String mimeType, 'data': final String data} => (mimeType: mimeType, bytes: base64Decode(data)),
          _ => null,
        };

  final String id;
  final String name;
  final IconImage? icon;
}

/// ほかのアカウントの人。名前を決めていなければ ID が入る
typedef Person = ({String id, String name});

Person _person(Map<String, dynamic> j) => (id: j['id'] as String, name: j['name'] as String);

/// ほかの人から共有されたノート（ADR 0013）
class SharedManual {
  SharedManual.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        title = j['title'],
        sharedBy = _person(j['sharedBy']);

  final String id;
  final String title;

  /// ノートの持ち主
  final Person sharedBy;
}

class ManualSummary {
  ManualSummary.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        title = j['title'],
        utteranceCount = j['utteranceCount'],
        openCount = j['openCount'];

  final String id;
  final String title;
  final int utteranceCount;
  final int openCount;
}

class ManualLine {
  ManualLine(this.text, this.patchId);

  ManualLine.fromJson(Map<String, dynamic> j)
      : text = j['text'],
        patchId = j['patchId'];

  final String text;
  final String? patchId;
}

class Utterance {
  Utterance.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        text = j['text'],
        speaker = j['speaker'],
        saidAt = j['saidAt'],
        fromEdit = j['fromEdit'] ?? false,
        editedBy = j['editedBy'],
        createdAt = j['createdAt'];

  final String id;
  final String text;
  final String? speaker;

  /// YYYY-MM-DD
  final String saidAt;

  /// 利用者がノートを直接編集した記録。口頭で言われたことではない
  final bool fromEdit;

  /// 共有された人が直接編集したときの、その人の ID。持ち主の編集なら null（ADR 0013）
  final String? editedBy;

  /// 記録した日時（ISO 8601）
  final String createdAt;
}

class Patch {
  Patch.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        utteranceId = j['utteranceId'],
        op = j['op'],
        line = j['line'],
        text = j['text'],
        summary = j['summary'],
        status = j['status'],
        createdAt = j['createdAt'],
        appliedAt = j['appliedAt'];

  final String id;
  final String utteranceId;

  /// replace / insert / delete
  final String op;
  final String? line;
  final String text;
  final String summary;

  /// proposed / applied / discarded
  final String status;

  /// 記録した日時・ノートに反映した日時（ISO 8601）。ノートは反映した順にパッチを当てて組み立てる
  final String createdAt;
  final String? appliedAt;
}

class AskCandidate {
  AskCandidate.fromJson(Map<String, dynamic> j)
      : who = j['who'],
        why = j['why'];

  final String who;
  final String why;
}

class Resolution {
  Resolution.fromJson(Map<String, dynamic> j)
      : utteranceId = j['utteranceId'],
        patchId = j['patchId'],
        decidedBy = j['decidedBy'],
        decidedAt = j['decidedAt'],
        text = j['text'],
        note = j['note'];

  /// 確認の答えとして記録した発言
  final String utteranceId;
  final String? patchId;
  final String decidedBy;
  final String decidedAt;
  final String text;
  final String note;
}

class Check {
  Check.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        patchId = j['patchId'],
        utteranceId = j['utteranceId'],
        kind = Kind.values.byName(j['kind']),
        conflictLine = j['conflictLine'],
        sameLine = j['sameLine'],
        reason = j['reason'],
        candidates = [
          for (final c in (j['ask']?['candidates'] as List? ?? [])) AskCandidate.fromJson(c),
        ],
        question = j['ask']?['question'],
        resolution = j['resolution'] == null ? null : Resolution.fromJson(j['resolution']);

  final String id;
  final String patchId;
  final String utteranceId;
  final Kind kind;
  final String? conflictLine;

  /// 同じ内容が書かれているマニュアルの行。same のときだけ入る
  final String? sameLine;
  final String reason;
  final List<AskCandidate> candidates;
  final String? question;
  final Resolution? resolution;

  bool get isOpen => kind == Kind.contradiction && resolution == null;
}

/// 選んだ・撮った・貼り付けた・ドロップしたファイル。type はブラウザが付けた形式（分からなければ空）
typedef PickedFile = ({String name, String type, Uint8List bytes});

/// 入力ページで添えるファイル（PDF／画像）か録音
class Attachment {
  Attachment({required this.name, required this.mimeType, required this.bytes});
  final String name;
  final String mimeType;
  final Uint8List bytes;
}

/// リワインドで切り出して書き起こした未整理メモ。サーバーに置き、端末をまたいで同じものを見る（ADR 0015）
class Memo {
  Memo({required this.id, required this.at, required this.text});
  Memo.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        at = DateTime.parse(j['at']).toLocal(),
        text = j['text'];

  final String id;

  /// 切り出しボタンを押した時刻
  final DateTime at;
  final String text;

  // 読み直すと別のオブジェクトになるので、書き直し中・入力欄に入れた印を id で引き継ぐ
  @override
  bool operator ==(Object other) => other is Memo && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

typedef Recorded = ({String manualId, String utteranceId, ManualState state});

/// 入力ページから記録した結果。関係するマニュアルごとに1件
class IntakeResult {
  IntakeResult.fromJson(Map<String, dynamic> j)
      : text = j['text'],
        results = [
          for (final r in j['results'])
            (manualId: r['manualId'] as String, utteranceId: r['utteranceId'] as String, state: ManualState.fromJson(r['state'])),
        ];

  /// ファイルや録音を読み取ったあとの、記録した文面
  final String text;
  final List<Recorded> results;
}

class ManualState {
  ManualState.fromJson(Map<String, dynamic> j)
      : id = j['manual']['id'],
        title = j['manual']['title'],
        base = j['manual']['base'],
        createdAt = j['manual']['createdAt'],
        lines = [for (final l in j['lines']) ManualLine.fromJson(l)],
        utterances = [for (final u in j['utterances']) Utterance.fromJson(u)],
        patches = [for (final p in j['patches']) Patch.fromJson(p)],
        checks = [for (final c in j['checks']) Check.fromJson(c)],
        sharedBy = j['sharedBy'] == null ? null : _person(j['sharedBy']);

  final String id;
  final String title;

  /// ほかの人から共有されたノートなら、その持ち主。自分のノートなら null（ADR 0013）
  final Person? sharedBy;

  /// 作ったときの本文。以後の変更はパッチとして積む（ADR 0001）
  final String base;

  /// ノートを作った日時（ISO 8601）
  final String createdAt;
  final List<ManualLine> lines;
  final List<Utterance> utterances;
  final List<Patch> patches;
  final List<Check> checks;

  Utterance utterance(String id) => utterances.firstWhere((u) => u.id == id);

  /// 口頭で言われた記録。直接編集の記録は付箋や記録の数に入れない
  List<Utterance> get said => utterances.where((u) => !u.fromEdit).toList();
  Patch patch(String id) => patches.firstWhere((p) => p.id == id);
  Check? checkOf(String patchId) => checks.where((c) => c.patchId == patchId).firstOrNull;
  List<Patch> patchesOf(String utteranceId) => patches.where((p) => p.utteranceId == utteranceId).toList();

  List<Check> get openChecks => checks.where((c) => c.isOpen).toList();
  List<Check> get resolvedChecks => checks.where((c) => c.resolution != null).toList();

  /// この行を確定させた確認の記録。確定した内容と同じ文面の行に付く。
  /// 補足（qualification）で書き換わった行は、書き換える前の行の確認を引き継ぐ
  Check? confirmationFor(ManualLine line) => _confirmedAs(line.text) ?? _beforeQualification(line.patchId);

  Check? _confirmedAs(String text) => resolvedChecks.where((c) => c.resolution!.text == text).lastOrNull;

  /// 補足の差分をさかのぼって、書き換える前の行の確認を探す。食い違いの確定・追記・直接の編集で書き換えた行では止める
  Check? _beforeQualification(String? patchId) {
    final p = patchId == null ? null : patch(patchId);
    if (p == null || p.op != 'replace' || p.line == null || p.appliedAt == null) return null;
    if (checkOf(p.id)?.kind != Kind.qualification || utterance(p.utteranceId).fromEdit) return null;
    final before = _confirmedAs(p.line!);
    if (before != null) return before;
    // 書き換える前の行をつくった差分。行は patchId しか持たないので文面で探す。
    // それより前に反映したものに限って輪にならないようにし、並びは記録順なので反映した順に並べ直す
    final from = (patches
            .where((x) => x.status == 'applied' && x.text == p.line && x.appliedAt!.compareTo(p.appliedAt!) < 0)
            .toList()
          ..sort((a, b) => a.appliedAt!.compareTo(b.appliedAt!)))
        .lastOrNull;
    return _beforeQualification(from?.id);
  }

  /// この行と同じことを言った記録。行の裏付けとして見せる
  List<Check> sameChecksFor(ManualLine line) =>
      checks.where((c) => c.kind == Kind.same && c.sameLine == line.text).toList();

  /// この行と食い違っていて、まだ確認していない項目。相手の行がもうノートに無ければ
  /// （確定済みの行を書き換えたときなど、#86）、その確認の差分が書いた行に付ける
  List<Check> openChecksFor(ManualLine line) => openChecks
      .where((c) => lines.any((l) => l.text == c.conflictLine) ? c.conflictLine == line.text : c.patchId == line.patchId)
      .toList();
}
