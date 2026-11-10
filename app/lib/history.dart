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

  /// 版のとき、この版のあいだに残した、枝にしない記録（同じ内容・未反映・反映しない）
  final asides = <Commit>[];

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

  /// 確認していない枝が、記録した所から今まで通り抜けるレーン。点線で描く
  final waiting = <int>{};

  /// この行で枝のレーンを使っている記録。枝の線を、その記録の状態の色で描くため
  final branches = <int, Commit>{};
}

class History {
  History(this.rows, this.lanes);

  /// 新しい順
  final List<GraphRow> rows;
  final int lanes;
}

/// 元の本文と反映済みのパッチ（ADR 0001）から、ノートの版と枝を組み立てる。
/// 枝はノートと食い違った記録だけで、記録した時点の版から分かれ、確定した版に合流する。
/// まだ確認していない枝は、今（いちばん新しい行）まで伸ばす
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
    lines = e.patches.fold(lines, patchLines);
    trunk.add(Commit(
      id: e.patches.firstOrNull?.id ?? e.said.id,
      at: e.at,
      said: e.said,
      diff: _diff(before, lines),
      check: s.resolvedChecks.where((c) => c.resolution!.utteranceId == e.said.id).firstOrNull,
    ));
  }
  final records = [
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
  // 同じ内容・未反映・反映しないはノートと食い違っていないので、枝にせず記録したときの版に付ける
  final branches = [for (final r in records) if (r.check?.kind == Kind.contradiction) r];
  for (final r in records) {
    if (r.check?.kind == Kind.contradiction) continue;
    trunk.lastWhere((t) => t.at.compareTo(r.at) <= 0, orElse: () => trunk.first).asides.add(r);
  }

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
  // 幹は時間の軸として、いちばん新しい版の先も今まで伸ばし、確認していない枝と並べる
  for (final i in trunkRows) {
    rows[i]
      ..down = i != trunkRows.first
      ..up = true;
  }
  for (var i = trunkRows.first + 1; i < rows.length; i++) {
    if (rows[i].commit.onBranch) rows[i].through.add(0);
  }
  // 枝ごとに、空いているレーンを使い回す。laneEnds[n] はレーン n+1 を最後に使う行
  final laneEnds = <int>[];
  for (final (d, r) in rows.indexed) {
    if (!r.commit.onBranch) continue;
    final f = trunkRows.lastWhere((i) => i < d);
    final resolved = r.commit.check?.resolution;
    final open = r.commit.check?.isOpen ?? false;
    final m = resolved == null
        ? -1
        : rows.indexWhere((x) => !x.commit.onBranch && x.commit.said?.id == resolved.utteranceId);
    // 確認していない枝は、決着するまでレーンを空けない
    final end = m >= 0 ? m : (open ? rows.length - 1 : d);
    var lane = laneEnds.indexWhere((e) => e < f);
    if (lane < 0) {
      laneEnds.add(end);
      lane = laneEnds.length;
    } else {
      laneEnds[lane] = end;
      lane += 1;
    }
    rows[f].forks.add(lane);
    for (var i = f + 1; i < (m >= 0 ? m : d); i++) {
      if (i != d) rows[i].through.add(lane);
    }
    if (m < 0 && open) {
      for (var i = d + 1; i <= end; i++) {
        rows[i].waiting.add(lane);
      }
    }
    for (var i = f; i <= end; i++) {
      rows[i].branches[lane] = r.commit;
    }
    r
      ..lane = lane
      ..down = true
      ..up = m >= 0 || open;
    if (m >= 0) rows[m].merges.add(lane);
  }
  return History(rows.reversed.toList(), laneEnds.length + 1);
}

/// バックエンドの applyPatch と同じ当て方。反映済みのパッチはバックエンドで当てられることを確かめてある。
/// 直接の編集を、サーバーの応答を待たずに画面へ出すときにも使う（manual_controller.dart）
List<ManualLine> patchLines(List<ManualLine> lines, Patch p) {
  final added = p.op == 'delete' ? <ManualLine>[] : [for (final t in p.text.split('\n')) ManualLine(t, p.id)];
  if (p.op == 'insert' && p.line == null) return [...lines, ...added];
  final i = lines.indexWhere((l) => l.text == p.line);
  if (i < 0) throw StateError('ノートに「${p.line}」の行が見つかりません');
  return [...lines.sublist(0, p.op == 'insert' ? i + 1 : i), ...added, ...lines.sublist(i + 1)];
}

/// 2つの本文を行の文字列で突き合わせた差分。同じ行を最も多く残す並べ方（最長共通部分列）にする。
/// AI が整えた本文のように、行の出どころを持たない文どうしを比べるときに使う
List<DiffLine> lineDiff(List<String> before, List<String> after) {
  final n = before.length, m = after.length;
  // common[i][j]: before[i..] と after[j..] に共通して残せる行の数
  final common = List.generate(n + 1, (_) => List.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      common[i][j] = before[i] == after[j]
          ? common[i + 1][j + 1] + 1
          : (common[i + 1][j] >= common[i][j + 1] ? common[i + 1][j] : common[i][j + 1]);
    }
  }
  final out = <DiffLine>[];
  var i = 0, j = 0;
  while (i < n || j < m) {
    if (i < n && j < m && before[i] == after[j]) {
      out.add((text: after[j], change: LineChange.kept));
      i++;
      j++;
    } else if (i < n && (j == m || common[i + 1][j] >= common[i][j + 1])) {
      out.add((text: before[i++], change: LineChange.removed));
    } else {
      out.add((text: after[j++], change: LineChange.added));
    }
  }
  return out;
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
