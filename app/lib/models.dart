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

/// 資料の一覧の1件（ADR 0019）。Flutter の Material とぶつからないよう、Material 単独の名前にしない
class MaterialSummary {
  MaterialSummary.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        title = j['title'],
        pageCount = j['pageCount'],
        lineCount = j['lineCount'],
        tokens = j['tokens'],
        createdAt = j['createdAt'],
        addedBy = j['addedBy'] == null ? null : _person(j['addedBy']);

  final String id;
  final String title;

  /// 貼り付けた文なら null
  final int? pageCount;
  final int lineCount;
  final int tokens;

  /// 足した日時（ISO 8601）
  final String createdAt;

  /// 足した人と、その時点の名前。前からある資料には無い（ADR 0018 の記録した人と同じ形）
  final Person? addedBy;
}

/// 資料の中身。lines の位置 + 1 が行番号（ページをまたいで通し）
class MaterialBody extends MaterialSummary {
  MaterialBody.fromJson(super.j)
      : lines = [for (final l in j['lines']) (page: l['page'] as int?, text: l['text'] as String)],
        super.fromJson();

  final List<({int? page, String text})> lines;
}

/// 食い違い・同じ内容の相手が資料の行のときの、その場所（ADR 0019）
class MaterialRef {
  MaterialRef.fromJson(Map<String, dynamic> j)
      : materialId = j['materialId'],
        title = j['title'],
        page = j['page'],
        lineNo = j['lineNo'];

  final String materialId;

  /// 取り込んだときの題名の写し。資料を消しても出せる
  final String title;
  final int? page;

  /// 資料の行番号（1始まり、ページをまたいで通し）
  final int lineNo;

  /// 「資料「店舗マニュアル」p.3」。貼り付けた文ならページを付けない
  String get label => '資料「$title」${page == null ? '' : 'p.$page'}';
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
  Utterance({
    required this.id,
    required this.text,
    required this.speaker,
    required this.saidAt,
    required this.fromEdit,
    required this.editedBy,
    required this.recordedBy,
    required this.createdAt,
  });

  Utterance.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        text = j['text'],
        speaker = j['speaker'],
        saidAt = j['saidAt'],
        fromEdit = j['fromEdit'] ?? false,
        editedBy = j['editedBy'],
        recordedBy = j['recordedBy'] == null ? null : _person(j['recordedBy']),
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

  /// この記録を入れた人と、その時点の名前。前からある記録には無い（ADR 0018）
  final Person? recordedBy;

  /// 記録した日時（ISO 8601）
  final String createdAt;
}

class Patch {
  Patch({
    required this.id,
    required this.utteranceId,
    required this.op,
    required this.line,
    required this.text,
    required this.summary,
    required this.status,
    required this.createdAt,
    required this.appliedAt,
  });

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
        answeredBy = j['answeredBy'],
        decidedAt = j['decidedAt'],
        text = j['text'],
        note = j['note'],
        shown = switch (j['shown']) {
          {'by': final Map<String, dynamic> by, 'at': final String at} => (by: _person(by), at: at),
          _ => null,
        };

  /// 確認の答えとして記録した発言。記録を見せて済ませた確定では、見せた人が記録を見せたという発言
  final String utteranceId;
  final String? patchId;
  final String decidedBy;

  /// 共有された人が自分の答えとして確定したときの、その人の ID。聞いた結果を記録したときは null（ADR 0017）
  final String? answeredBy;

  /// 決めた人の後ろに添える言葉。本人が決めたのか、聞いて記録したのかを分ける
  String get verb => answeredBy == null ? 'に確認' : 'が決定';
  final String decidedAt;
  final String text;
  final String note;

  /// 聞き直さず、前の確定の記録を見せて済ませたときの、見せた人と日（#118）。ほかの中身は前の確定の写し
  final ({Person by, String at})? shown;
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
        resolution = j['resolution'] == null ? null : Resolution.fromJson(j['resolution']),
        materialRef = j['materialRef'] == null ? null : MaterialRef.fromJson(j['materialRef']);

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

  /// 相手（conflictLine・sameLine）が資料の行なら、その場所。ノートの行が相手なら null（前からある確認にも無い）
  final MaterialRef? materialRef;

  bool get isOpen => kind == Kind.contradiction && resolution == null;

  /// 確定して、その決定の元になった記録か。記録を見せて済ませた確定は元の確定を指すので、行の印や証拠にはしない（#118）
  bool get isDecision => resolution != null && resolution!.shown == null;
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
        owner = j['owner'],
        me = j['me'],
        sharedBy = j['sharedBy'] == null ? null : _person(j['sharedBy']);

  ManualState._from(
    ManualState s, {
    required this.lines,
    required this.utterances,
    required this.patches,
    required this.checks,
  })  : id = s.id,
        title = s.title,
        base = s.base,
        createdAt = s.createdAt,
        owner = s.owner,
        me = s.me,
        sharedBy = s.sharedBy;

  /// 行・記録・差分・確認を差し替えた写し。サーバーの応答の前に、手元の編集を重ねて見せるときに使う
  ManualState copyWith({
    List<ManualLine>? lines,
    List<Utterance>? utterances,
    List<Patch>? patches,
    List<Check>? checks,
  }) =>
      ManualState._from(
        this,
        lines: lines ?? this.lines,
        utterances: utterances ?? this.utterances,
        patches: patches ?? this.patches,
        checks: checks ?? this.checks,
      );

  final String id;
  final String title;

  /// ほかの人から共有されたノートなら、その持ち主。自分のノートなら null（ADR 0013）
  final Person? sharedBy;

  /// ノートの持ち主と、読んでいる自分のログイン ID
  final String owner;
  final String me;

  /// 記録を直す・書き込むかを決められるのは、記録した本人だけ。前からある記録は、共有された人の直接の編集ならその人、
  /// それ以外は持ち主の記録とみなす（ADR 0018）
  bool recordedByMe(Utterance u) => (u.recordedBy?.id ?? u.editedBy ?? owner) == me;

  /// 発言者の候補に出す名前。記録を見せた答えは見せた人の名前で残るので、自分の名前（決めていなければログイン ID）を
  /// ほかの人として並べない（#125）。自分のノートでは「自分」にまとめ、ログイン ID を打っても出るよう ID を添える。
  /// 共有されたノートの「自分」は持ち主の直接の編集なので（ADR 0013）、まとめると持ち主と取り違える。そこでは自分を出さない
  ({String name, String? id})? speakerCandidate(Utterance u) {
    final n = u.speaker;
    if (n == null) return null;
    // 前からある、共有された人の直接の編集は、記録した人が無く発言者がその人の名前（ADR 0013）
    final mine = n == me || (u.recordedBy?.id == me && n == u.recordedBy!.name) || u.editedBy == me;
    if (sharedBy != null) return mine ? null : (name: n, id: null);
    return mine || n == '自分' ? (name: '自分', id: me) : (name: n, id: null);
  }

  /// 作ったときの本文。以後の変更はパッチとして積む（ADR 0001）
  final String base;

  /// ノートを作った日時（ISO 8601）
  final String createdAt;
  final List<ManualLine> lines;
  final List<Utterance> utterances;
  final List<Patch> patches;
  final List<Check> checks;

  // 索引。画面は行ごと・記録ごとに引くので、毎回先頭から探さず、最初に引いたときに1回だけ組む。
  // 中身を変えるときは copyWith で別の状態を作るので、組み直しは要らない。同じ ID が並んだら、先頭から探したときと同じく先のもの
  late final _utteranceById = _first(utterances, (u) => u.id);
  late final _patchById = _first(patches, (p) => p.id);
  late final _checkByPatch = _first(checks, (c) => c.patchId);
  late final _patchesByUtterance = _group(patches, (p) => p.utteranceId);
  late final _lineByText = _first(lines, (l) => l.text);

  /// 確定した内容の文 → その文に決まった最後の確認
  late final _decisionByText = {
    for (final c in checks)
      if (c.isDecision && !(c.materialRef != null && c.resolution!.text == c.conflictLine)) c.resolution!.text: c,
  };

  late final _sameByLine =
      _group([for (final c in checks) if (c.kind == Kind.same && c.materialRef == null) c], (c) => c.sameLine);

  /// まだ確認していない項目（openChecks の位置）を、付く行の文か、付く行の差分で引く。1件はどちらか一方にだけ入る
  late final ({Map<String, List<int>> text, Map<String, List<int>> patch}) _openAt = () {
    final text = <String, List<int>>{};
    final patch = <String, List<int>>{};
    for (final (i, c) in openChecks.indexed) {
      final conflict = c.conflictLine;
      if (c.materialRef == null && conflict != null && _lineByText.containsKey(conflict)) {
        (text[conflict] ??= []).add(i);
      } else {
        (patch[c.patchId] ??= []).add(i);
      }
    }
    return (text: text, patch: patch);
  }();

  late final _checksByMaterialLine = _group(
      [for (final c in checks) if (c.materialRef != null) c], (c) => (c.materialRef!.materialId, c.materialRef!.lineNo));

  static Map<K, T> _first<K, T>(List<T> xs, K Function(T) key) {
    final m = <K, T>{};
    for (final x in xs) {
      m.putIfAbsent(key(x), () => x);
    }
    return m;
  }

  static Map<K, List<T>> _group<K, T>(List<T> xs, K Function(T) key) {
    final m = <K, List<T>>{};
    for (final x in xs) {
      (m[key(x)] ??= []).add(x);
    }
    return {for (final e in m.entries) e.key: List.unmodifiable(e.value)};
  }

  Utterance utterance(String id) => _utteranceById[id] ?? (throw StateError('No element'));

  /// 口頭で言われた記録。直接編集の記録は付箋や記録の数に入れない
  late final List<Utterance> said = List.unmodifiable(utterances.where((u) => !u.fromEdit));
  Patch patch(String id) => _patchById[id] ?? (throw StateError('No element'));
  Check? checkOf(String patchId) => _checkByPatch[patchId];
  List<Patch> patchesOf(String utteranceId) => _patchesByUtterance[utteranceId] ?? const [];

  late final List<Check> openChecks = List.unmodifiable(checks.where((c) => c.isOpen));
  late final List<Check> resolvedChecks = List.unmodifiable(checks.where((c) => c.resolution != null));

  /// この行を確定させた確認の記録。確定した内容と同じ文面の行に付く。
  /// 補足（qualification）で書き換わった行は、書き換える前の行の確認を引き継ぐ
  Check? confirmationFor(ManualLine line) => _confirmedAs(line.text) ?? _beforeQualification(line.patchId);

  /// 「資料のまま」に決まった確定は資料の行のもの。同じ資料から作ったノートに同じ文の行があっても、そこには付けない
  Check? _confirmedAs(String text) => _decisionByText[text];

  /// 確認待ちの食い違いの相手が確定済みの記録なら、その確認。相手の行がノートにあればその行の確認の印、
  /// 書き換えられてもう無ければ（#86）同じ内容に確定した確認。
  /// 相手が資料の行なら、その資料の行に結び付いた確定（資料のまま・違う内容のどちらも）
  Check? confirmedRecordFor(Check c) {
    final conflict = c.conflictLine;
    if (!c.isOpen || conflict == null) return null;
    if (c.materialRef case final m?) {
      return checksAt(m.materialId, m.lineNo).where((x) => x.isDecision).lastOrNull;
    }
    final line = _lineByText[conflict];
    return line == null ? _confirmedAs(conflict) : confirmationFor(line);
  }

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

  /// この行と同じことを言った記録。行の裏付けとして見せる。資料と同じ内容の記録は、ノートの行の裏付けにしない
  List<Check> sameChecksFor(ManualLine line) => _sameByLine[line.text] ?? const [];

  /// この行と食い違っていて、まだ確認していない項目。相手の行がもうノートに無ければ
  /// （確定済みの行を書き換えたときなど、#86）、その確認の差分が書いた行に付ける。
  /// 資料と食い違った確認は、同じ文の行がノートにあってもそこには付けない。直接書いた行が資料と食い違ったときだけ、書いた行に付く
  List<Check> openChecksFor(ManualLine line) {
    // 文で付くものと差分で付くものの両方を拾う行もあるので、openChecks の並びに戻す
    final at = [...?_openAt.text[line.text], ...?_openAt.patch[line.patchId]]..sort();
    return [for (final i in at) openChecks[i]];
  }

  /// 資料のその行が相手の確認（食い違い・確定・同じ内容）。資料の中の画面で使う
  List<Check> checksAt(String materialId, int lineNo) => _checksByMaterialLine[(materialId, lineNo)] ?? const [];

  /// その資料と食い違った、まだ確認していない項目
  List<Check> openChecksIn(String materialId) =>
      openChecks.where((c) => c.materialRef?.materialId == materialId).toList();
}
