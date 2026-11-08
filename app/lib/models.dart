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
        createdAt = j['createdAt'];

  final String id;
  final String text;
  final String? speaker;

  /// YYYY-MM-DD
  final String saidAt;

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
        status = j['status'];

  final String id;
  final String utteranceId;

  /// replace / insert
  final String op;
  final String? line;
  final String text;
  final String summary;

  /// proposed / applied / discarded
  final String status;
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
        lines = [for (final l in j['lines']) ManualLine.fromJson(l)],
        utterances = [for (final u in j['utterances']) Utterance.fromJson(u)],
        patches = [for (final p in j['patches']) Patch.fromJson(p)],
        checks = [for (final c in j['checks']) Check.fromJson(c)];

  final String id;
  final String title;
  final List<ManualLine> lines;
  final List<Utterance> utterances;
  final List<Patch> patches;
  final List<Check> checks;

  Utterance utterance(String id) => utterances.firstWhere((u) => u.id == id);
  Patch patch(String id) => patches.firstWhere((p) => p.id == id);
  Check? checkOf(String patchId) => checks.where((c) => c.patchId == patchId).firstOrNull;
  List<Patch> patchesOf(String utteranceId) => patches.where((p) => p.utteranceId == utteranceId).toList();

  List<Check> get openChecks => checks.where((c) => c.isOpen).toList();
  List<Check> get resolvedChecks => checks.where((c) => c.resolution != null).toList();

  /// この行を確定させた確認の記録。確定した内容と同じ文面の行に付く
  Check? confirmationFor(ManualLine line) =>
      resolvedChecks.where((c) => c.resolution!.text == line.text).lastOrNull;

  /// この行と同じことを言った記録。行の裏付けとして見せる
  List<Check> sameChecksFor(ManualLine line) =>
      checks.where((c) => c.kind == Kind.same && c.sameLine == line.text).toList();

  /// この行と食い違っていて、まだ確認していない項目
  List<Check> openChecksFor(ManualLine line) =>
      openChecks.where((c) => c.conflictLine == line.text).toList();
}
