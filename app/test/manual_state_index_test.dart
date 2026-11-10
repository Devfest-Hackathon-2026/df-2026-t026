import 'package:diff_note/models.dart';
import 'package:flutter_test/flutter_test.dart';

// ManualState の索引が、索引を持つ前の探し方（毎回先頭から探す）と同じ答えを返すか。
// 前の探し方をここに写して、答えを比べる

Patch _patch(ManualState s, String id) => s.patches.firstWhere((p) => p.id == id);
Utterance _utterance(ManualState s, String id) => s.utterances.firstWhere((u) => u.id == id);
Check? _checkOf(ManualState s, String patchId) => s.checks.where((c) => c.patchId == patchId).firstOrNull;
List<Patch> _patchesOf(ManualState s, String utteranceId) =>
    s.patches.where((p) => p.utteranceId == utteranceId).toList();
List<Check> _openChecks(ManualState s) => s.checks.where((c) => c.isOpen).toList();

Check? _confirmedAs(ManualState s, String text) => s.checks
    .where((c) =>
        c.isDecision && c.resolution!.text == text && !(c.materialRef != null && c.resolution!.text == c.conflictLine))
    .lastOrNull;

Check? _beforeQualification(ManualState s, String? patchId) {
  final p = patchId == null ? null : _patch(s, patchId);
  if (p == null || p.op != 'replace' || p.line == null || p.appliedAt == null) return null;
  if (_checkOf(s, p.id)?.kind != Kind.qualification || _utterance(s, p.utteranceId).fromEdit) return null;
  final before = _confirmedAs(s, p.line!);
  if (before != null) return before;
  final from = (s.patches
          .where((x) => x.status == 'applied' && x.text == p.line && x.appliedAt!.compareTo(p.appliedAt!) < 0)
          .toList()
        ..sort((a, b) => a.appliedAt!.compareTo(b.appliedAt!)))
      .lastOrNull;
  return _beforeQualification(s, from?.id);
}

Check? _confirmationFor(ManualState s, ManualLine line) =>
    _confirmedAs(s, line.text) ?? _beforeQualification(s, line.patchId);

List<Check> _checksAt(ManualState s, String materialId, int lineNo) => s.checks
    .where((c) => c.materialRef?.materialId == materialId && c.materialRef?.lineNo == lineNo)
    .toList();

Check? _confirmedRecordFor(ManualState s, Check c) {
  final conflict = c.conflictLine;
  if (!c.isOpen || conflict == null) return null;
  if (c.materialRef case final m?) {
    return _checksAt(s, m.materialId, m.lineNo).where((x) => x.isDecision).lastOrNull;
  }
  final line = s.lines.where((l) => l.text == conflict).firstOrNull;
  return line == null ? _confirmedAs(s, conflict) : _confirmationFor(s, line);
}

List<Check> _sameChecksFor(ManualState s, ManualLine line) =>
    s.checks.where((c) => c.kind == Kind.same && c.materialRef == null && c.sameLine == line.text).toList();

List<Check> _openChecksFor(ManualState s, ManualLine line) => _openChecks(s)
    .where((c) => c.materialRef == null && s.lines.any((l) => l.text == c.conflictLine)
        ? c.conflictLine == line.text
        : c.patchId == line.patchId)
    .toList();

/// 索引の答えが、前の探し方の答えと同じか。確認・差分・発言は同じ物かで比べる
void _expectSameAnswers(ManualState s) {
  for (final p in s.patches) {
    expect(s.patch(p.id), same(_patch(s, p.id)));
    expect(s.checkOf(p.id), same(_checkOf(s, p.id)));
  }
  for (final u in s.utterances) {
    expect(s.utterance(u.id), same(_utterance(s, u.id)));
    expect(s.patchesOf(u.id), orderedEquals(_patchesOf(s, u.id)));
  }
  expect(s.said, orderedEquals(s.utterances.where((u) => !u.fromEdit)));
  expect(s.openChecks, orderedEquals(_openChecks(s)));
  expect(s.resolvedChecks, orderedEquals(s.checks.where((c) => c.resolution != null)));
  for (final (i, l) in s.lines.indexed) {
    expect(s.openChecksFor(l), orderedEquals(_openChecksFor(s, l)), reason: '$i 行目「${l.text}」のあとで確認');
    expect(s.confirmationFor(l), same(_confirmationFor(s, l)), reason: '$i 行目「${l.text}」の確定');
    expect(s.sameChecksFor(l), orderedEquals(_sameChecksFor(s, l)), reason: '$i 行目「${l.text}」の同じ内容');
  }
  for (final c in s.checks) {
    expect(s.confirmedRecordFor(c), same(_confirmedRecordFor(s, c)), reason: '${c.id} の確定済みの記録');
    if (c.materialRef case final m?) {
      expect(s.checksAt(m.materialId, m.lineNo), orderedEquals(_checksAt(s, m.materialId, m.lineNo)));
    }
  }
  expect(s.checksAt('mat', 99), isEmpty);
}

Map<String, dynamic> _u(String id, {bool fromEdit = false}) => {
      'id': id,
      'text': '言われたこと$id',
      'speaker': fromEdit ? '自分' : '田中さん',
      'saidAt': '2026-11-03',
      'fromEdit': fromEdit,
      'createdAt': '2026-11-03T10:00:00Z',
    };

Map<String, dynamic> _p(String id, String u, String op, String? line, String text, String status, String? appliedAt) => {
      'id': id,
      'utteranceId': u,
      'op': op,
      'line': line,
      'text': text,
      'summary': '',
      'status': status,
      'createdAt': '2026-11-03T10:00:00Z',
      'appliedAt': appliedAt,
    };

Map<String, dynamic> _c(
  String id,
  String patchId,
  String u,
  String kind, {
  String? conflictLine,
  String? sameLine,
  Map<String, dynamic>? resolution,
  Map<String, dynamic>? materialRef,
}) =>
    {
      'id': id,
      'patchId': patchId,
      'utteranceId': u,
      'kind': kind,
      'conflictLine': conflictLine,
      'sameLine': sameLine,
      'reason': '理由',
      'resolution': resolution,
      'materialRef': materialRef,
    };

Map<String, dynamic> _resolved(String text, {Map<String, dynamic>? shown}) => {
      'utteranceId': 'ur',
      'patchId': null,
      'decidedBy': '店長',
      'answeredBy': null,
      'decidedAt': '2026-11-05',
      'text': text,
      'note': '',
      'shown': shown,
    };

Map<String, dynamic> _mat(int lineNo) => {'materialId': 'mat', 'title': '店舗マニュアル', 'page': 1, 'lineNo': lineNo};

/// 索引が答えを変えやすい所を集めたノート
ManualState _state() => ManualState.fromJson({
      'owner': 'demo',
      'me': 'demo',
      'manual': {'id': 'm1', 'title': 'キッチン', 'base': '', 'createdAt': '2026-11-01T00:00:00Z'},
      'lines': [
        {'text': '- 塩 小さじ1', 'patchId': null},
        // 文で付く確認（c1）と、差分で付く確認（c3：相手の行がもう無い）の両方を拾う行
        {'text': '- 胡椒 少々', 'patchId': 'p3'},
        // 補足で書き換わった行。書き換える前の行（- 油 大さじ1）の確定（c5）を引き継ぐ
        {'text': '- 油 大さじ1（揚げ物は2）', 'patchId': 'p5'},
        // 資料と食い違った、直接書いた行。資料の確認は差分で付く
        {'text': '- 砂糖 大さじ2', 'patchId': 'p6'},
        // 同じ文の行が2つ。同じ内容の記録は両方に付く
        {'text': '- 皿は白', 'patchId': null},
        {'text': '- 皿は白', 'patchId': null},
        {'text': '## 片付け', 'patchId': null},
        // 記録を見せて済ませた確定（shown）と同じ文の行には、確定の印を付けない
        {'text': '- 床は毎日', 'patchId': null},
        // 補足を2回重ねた行。2つ前の行（- 鍋は中）の確定（c15）までさかのぼる
        {'text': '- 鍋は大（深いもの）', 'patchId': 'p14'},
      ],
      'utterances': [
        _u('u1'),
        _u('u2'),
        _u('u3'),
        _u('u4'),
        _u('u5'),
        _u('u6', fromEdit: true),
        _u('u7'),
        _u('u8'),
        _u('u9'),
        _u('u10'),
        _u('u12'),
        _u('u13'),
        _u('u14'),
        _u('u15'),
        // 同じ ID が2つあれば、前の探し方と同じく先のものを返す
        {..._u('u1'), 'text': '後ろの同じ ID'},
      ],
      'patches': [
        _p('p1', 'u1', 'replace', '- 塩 小さじ1', '- 塩 小さじ2', 'proposed', null),
        _p('p2', 'u2', 'insert', '- 塩 小さじ1', '- 塩 小さじ3', 'proposed', null),
        _p('p3', 'u3', 'replace', '- 胡椒 ひとつまみ', '- 胡椒 少々', 'applied', '2026-11-03T10:00:03Z'),
        _p('p4', 'u4', 'insert', null, '- 油 大さじ1', 'applied', '2026-11-03T10:00:01Z'),
        _p('p5', 'u5', 'replace', '- 油 大さじ1', '- 油 大さじ1（揚げ物は2）', 'applied', '2026-11-03T10:00:05Z'),
        _p('p6', 'u6', 'insert', null, '- 砂糖 大さじ2', 'applied', '2026-11-03T10:00:06Z'),
        _p('p7', 'u7', 'insert', null, '- 皿は白', 'discarded', null),
        _p('p8', 'u8', 'insert', null, '- 床は毎日', 'discarded', null),
        _p('p9', 'u9', 'insert', null, '- 胡椒 少々', 'proposed', null),
        _p('p10', 'u10', 'insert', null, '- 塩 小さじ1', 'proposed', null),
        _p('p12', 'u12', 'insert', null, '- 胡椒 たくさん', 'proposed', null),
        _p('p13', 'u13', 'replace', '- 鍋は中', '- 鍋は大', 'applied', '2026-11-03T10:00:13Z'),
        _p('p14', 'u14', 'replace', '- 鍋は大', '- 鍋は大（深いもの）', 'applied', '2026-11-03T10:00:14Z'),
        _p('p15', 'u15', 'insert', null, '- 鍋は小', 'discarded', null),
        // 同じ ID が2つあれば、前の探し方と同じく先のものを返す
        _p('p1', 'u9', 'insert', null, '後ろの同じ ID', 'proposed', null),
      ],
      'checks': [
        _c('c1', 'p1', 'u1', 'contradiction', conflictLine: '- 塩 小さじ1'),
        _c('c2', 'p2', 'u2', 'contradiction', conflictLine: '- 塩 小さじ1'),
        // 相手の行は書き換えられてもう無い（#86）。この確認の差分が書いた行に付く
        _c('c3', 'p3', 'u3', 'contradiction', conflictLine: '- 胡椒 ひとつまみ'),
        // c3 と同じ行に、文で付く。行には元の並び（c3 → c12）で付く
        _c('c12', 'p12', 'u12', 'contradiction', conflictLine: '- 胡椒 少々'),
        _c('c4', 'p4', 'u4', 'contradiction', conflictLine: '- 油 少し', resolution: _resolved('- 油 大さじ1')),
        _c('c5', 'p5', 'u5', 'qualification'),
        // 資料と食い違った確認。同じ文の行がノートにあっても、差分で付く
        _c('c6', 'p6', 'u6', 'contradiction', conflictLine: '- 塩 小さじ1', materialRef: _mat(3)),
        _c('c6b', 'p6', 'u6', 'contradiction', conflictLine: '- 砂糖 大さじ1', materialRef: _mat(4)),
        _c('c7', 'p7', 'u7', 'same', sameLine: '- 皿は白'),
        _c('c7m', 'p7', 'u7', 'same', sameLine: '- 皿は白', materialRef: _mat(5)),
        _c('c8', 'p8', 'u8', 'contradiction',
            conflictLine: '- 床は週1', resolution: _resolved('- 床は毎日', shown: {'by': {'id': 'demo', 'name': 'demo'}, 'at': '2026-11-06'})),
        // 資料のままに決まった確定は、同じ文の行に付けない
        _c('c9', 'p9', 'u9', 'contradiction',
            conflictLine: '- 塩 小さじ1', resolution: _resolved('- 塩 小さじ1'), materialRef: _mat(3)),
        // 資料の行に結び付いた確定。同じ資料の行の、まだ確認していない項目（c6）の確定済みの記録になる
        _c('c10', 'p10', 'u10', 'contradiction', conflictLine: '- 皿は白', resolution: _resolved('- 皿は白'), materialRef: _mat(3)),
        _c('c13', 'p13', 'u13', 'qualification'),
        _c('c14', 'p14', 'u14', 'qualification'),
        _c('c15', 'p15', 'u15', 'contradiction', conflictLine: '- 鍋は小', resolution: _resolved('- 鍋は中')),
      ],
      'sharedBy': null,
    });

void main() {
  test('索引で引いても、前の探し方と同じ答えを返す', () {
    final s = _state();
    _expectSameAnswers(s);
    // 写した前の探し方が、狙った形のノートを見ているか
    expect(s.openChecksFor(s.lines[0]).map((c) => c.id), ['c1', 'c2']);
    expect(s.openChecksFor(s.lines[1]).map((c) => c.id), ['c3', 'c12']);
    expect(s.openChecksFor(s.lines[3]).map((c) => c.id), ['c6', 'c6b']);
    expect(s.confirmationFor(s.lines[2])?.id, 'c4');
    expect(s.confirmationFor(s.lines[7]), isNull);
    expect(s.confirmationFor(s.lines[8])?.id, 'c15');
    expect(s.sameChecksFor(s.lines[5]).map((c) => c.id), ['c7']);
    expect(s.patch('p1').utteranceId, 'u1');
    expect(s.utterance('u1').text, '言われたことu1');
    expect(s.checksAt('mat', 3).map((c) => c.id), ['c6', 'c9', 'c10']);
    expect(s.confirmedRecordFor(s.checks.firstWhere((c) => c.id == 'c6'))?.id, 'c10');
  });

  test('無い ID を引くと、前の探し方と同じく StateError を投げる', () {
    final s = _state();
    expect(() => s.patch('none'), throwsStateError);
    expect(() => s.utterance('none'), throwsStateError);
    expect(s.checkOf('none'), isNull);
    expect(s.patchesOf('none'), isEmpty);
  });

  test('一覧を返すものは、索引を書き換えられないよう、呼んだ側で足し引きできない', () {
    final s = _state();
    expect(() => s.said.add(s.utterances.first), throwsUnsupportedError);
    expect(() => s.openChecks.clear(), throwsUnsupportedError);
    expect(() => s.resolvedChecks.clear(), throwsUnsupportedError);
    expect(() => s.patchesOf('u1').clear(), throwsUnsupportedError);
  });

  test('copyWith の写しは、差し替えた行・差分・確認から索引を作り直す', () {
    final s = _state();
    // 文で付いていた確認の相手の行（- 塩 小さじ1）を消すと、その確認は差分で付く先（無い）に移る
    final noSalt = s.copyWith(lines: [for (final l in s.lines) if (l.text != '- 塩 小さじ1') l]);
    _expectSameAnswers(noSalt);
    expect([for (final l in noSalt.lines) ...noSalt.openChecksFor(l)].map((c) => c.id), ['c3', 'c12', 'c6', 'c6b']);
    // 元の索引は変わらない
    expect(s.openChecksFor(s.lines[0]).map((c) => c.id), ['c1', 'c2']);

    final added = s.copyWith(
      utterances: [...s.utterances, Utterance.fromJson(_u('u11', fromEdit: true))],
      patches: [...s.patches, Patch.fromJson(_p('p11', 'u11', 'insert', null, '- 塩 小さじ1', 'applied', '2026-11-03T10:00:11Z'))],
      checks: [...s.checks, Check.fromJson(_c('c11', 'p11', 'u11', 'contradiction', conflictLine: '- 皿は白'))],
      lines: [...s.lines, ManualLine('- 塩 小さじ1', 'p11')],
    );
    _expectSameAnswers(added);
    expect(added.patch('p11').utteranceId, 'u11');
    expect(added.openChecks.map((c) => c.id), contains('c11'));
    expect(added.openChecksFor(added.lines[4]).map((c) => c.id), ['c11']);
    expect(() => s.patch('p11'), throwsStateError);
  });
}
