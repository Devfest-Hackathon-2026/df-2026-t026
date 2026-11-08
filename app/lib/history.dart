import 'models.dart';

/// 前の版と比べた行の変わり方
enum LineChange { kept, added, removed }

typedef DiffLine = ({String text, LineChange change});

/// 履歴の1件。幹はノートの版、枝はノートに入らなかった記録（食い違い・反映しなかったもの）
class Commit {
  Commit({required this.id, required this.at, required this.said, required this.diff, this.patch, this.check});

  final String id;

  /// 並べる順の日時（ISO 8601）
  final String at;

  /// 誰がいつ言った・書いたか。ノートを作った版では null
  final Utterance? said;

  /// 幹ではこの版のノート全文に前の版からの増減を付けたもの、枝では入らなかったパッチの差分
  final List<DiffLine> diff;

  /// 枝のとき、ノートに入らなかったパッチ
  final Patch? patch;

  /// 枝ではその記録の確認、幹ではこの版を作った確定の記録
  final Check? check;

  bool get onBranch => patch != null;
}

/// グラフの1行。レーン0が幹で、枝は1から
class GraphRow {
  GraphRow(this.commit);
  final Commit commit;

  /// 点を置くレーン
  int lane = 0;

  /// 点から上（新しい側）・下（古い側）へ線をつなぐか
  bool up = false;
  bool down = false;

  /// 点を置かずに上下へ通り抜けるレーン
  final through = <int>{};

  /// この版から分かれて上へ伸びるレーン
  final forks = <int>{};

  /// 下から伸びてきて、この版に合流するレーン
  final merges = <int>{};
}

class History {
  History(this.rows, this.lanes);

  /// 新しい順
  final List<GraphRow> rows;
  final int lanes;
}

/// 元の本文と反映済みのパッチ（ADR 0001）から、ノートの版と枝を組み立てる。
/// 食い違った記録は、記録した時点の版から分かれ、確定した版に合流する枝として描く
History buildHistory(ManualState s) {
  // バックエンドの render と同じく反映した順に当てる。反映日時が同じなら記録した順（s.patches は記録順）
  final applied = [for (final (i, p) in s.patches.indexed) if (p.status == 'applied') (i, p)]
    ..sort((a, b) {
      final c = a.$2.appliedAt!.compareTo(b.$2.appliedAt!);
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
  // 同じ記録から続けて反映したパッチ（確定で2行を1行にまとめたときなど）は1つの版にする
  final events = <({String at, Utterance said, List<Patch> patches})>[];
  for (final (_, p) in applied) {
    if (events.lastOrNull?.said.id == p.utteranceId) {
      events.last.patches.add(p);
    } else {
      events.add((at: p.appliedAt!, said: s.utterance(p.utteranceId), patches: [p]));
    }
  }
  // 「ノートのまま」と確定した記録はパッチを作らないが、後で見せる証拠なので版として残す
  for (final c in s.resolvedChecks) {
    final u = s.utterance(c.resolution!.utteranceId);
    if (events.any((e) => e.said.id == u.id)) continue;
    final i = events.indexWhere((e) => e.at.compareTo(u.createdAt) > 0);
    events.insert(i < 0 ? events.length : i, (at: u.createdAt, said: u, patches: []));
  }

  var lines = [for (final t in s.base.isEmpty ? const <String>[] : s.base.split('\n')) ManualLine(t, null)];
  final trunk = [Commit(id: 'root', at: s.createdAt, said: null, diff: _diff(const [], lines))];
  for (final e in events) {
    final before = lines;
    lines = e.patches.fold(lines, _apply);
    trunk.add(Commit(
      id: e.patches.firstOrNull?.id ?? e.said.id,
      at: e.at,
      said: e.said,
      diff: _diff(before, lines),
      check: s.resolvedChecks.where((c) => c.resolution!.utteranceId == e.said.id).firstOrNull,
    ));
  }
  final branches = [
    for (final p in s.patches)
      if (p.status != 'applied')
        Commit(
          id: p.id,
          at: p.createdAt,
          said: s.utterance(p.utteranceId),
          diff: [
            if (p.line != null) (text: p.line!, change: p.op == 'insert' ? LineChange.kept : LineChange.removed),
            if (p.op != 'delete') for (final t in p.text.split('\n')) (text: t, change: LineChange.added),
          ],
          patch: p,
          check: s.checkOf(p.id),
        ),
  ];

  // 古い順に並べる。同じ日時なら幹を先にする
  final rows = <GraphRow>[];
  var j = 0;
  for (final b in branches) {
    while (j < trunk.length && trunk[j].at.compareTo(b.at) <= 0) {
      rows.add(GraphRow(trunk[j++]));
    }
    rows.add(GraphRow(b));
  }
  rows.addAll(trunk.skip(j).map(GraphRow.new));

  final trunkRows = [for (final (i, r) in rows.indexed) if (!r.commit.onBranch) i];
  for (final i in trunkRows) {
    rows[i]
      ..down = i != trunkRows.first
      ..up = i != trunkRows.last;
  }
  for (var i = trunkRows.first + 1; i < trunkRows.last; i++) {
    if (rows[i].commit.onBranch) rows[i].through.add(0);
  }
  // 枝ごとに、空いているレーンを使い回す。laneEnds[n] はレーン n+1 を最後に使う行
  final laneEnds = <int>[];
  for (final (d, r) in rows.indexed) {
    if (!r.commit.onBranch) continue;
    final f = trunkRows.lastWhere((i) => i < d);
    final resolved = r.commit.check?.resolution;
    final m = resolved == null
        ? -1
        : rows.indexWhere((x) => !x.commit.onBranch && x.commit.said?.id == resolved.utteranceId);
    final end = m < 0 ? d : m;
    var lane = laneEnds.indexWhere((e) => e < f);
    if (lane < 0) {
      laneEnds.add(end);
      lane = laneEnds.length;
    } else {
      laneEnds[lane] = end;
      lane += 1;
    }
    rows[f].forks.add(lane);
    for (var i = f + 1; i < end; i++) {
      if (i != d) rows[i].through.add(lane);
    }
    r
      ..lane = lane
      ..down = true
      ..up = m >= 0;
    if (m >= 0) rows[m].merges.add(lane);
  }
  return History(rows.reversed.toList(), laneEnds.length + 1);
}

/// バックエンドの applyPatch と同じ当て方。反映済みのパッチはバックエンドで当てられることを確かめてある
List<ManualLine> _apply(List<ManualLine> lines, Patch p) {
  final added = p.op == 'delete' ? <ManualLine>[] : [for (final t in p.text.split('\n')) ManualLine(t, p.id)];
  if (p.op == 'insert' && p.line == null) return [...lines, ...added];
  final i = lines.indexWhere((l) => l.text == p.line);
  if (i < 0) throw StateError('ノートに「${p.line}」の行が見つかりません');
  return [...lines.sublist(0, p.op == 'insert' ? i + 1 : i), ...added, ...lines.sublist(i + 1)];
}

/// パッチは行を差し込むだけで並びを入れ替えないので、残った行を同じ物かどうかで突き合わせれば差分になる
List<DiffLine> _diff(List<ManualLine> before, List<ManualLine> after) {
  final kept = after.toSet();
  final out = <DiffLine>[];
  var i = 0;
  for (final l in after) {
    while (i < before.length && !kept.contains(before[i])) {
      out.add((text: before[i++].text, change: LineChange.removed));
    }
    if (i < before.length && identical(before[i], l)) {
      out.add((text: l.text, change: LineChange.kept));
      i++;
    } else {
      out.add((text: l.text, change: LineChange.added));
    }
  }
  for (; i < before.length; i++) {
    out.add((text: before[i].text, change: LineChange.removed));
  }
  return out;
}
