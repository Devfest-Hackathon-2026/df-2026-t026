import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:moon_design/moon_design.dart';

import '../history.dart';
import '../manual_controller.dart';
import '../models.dart';
import '../theme.dart';
import 'check_list_screen.dart';
import 'common.dart';
import 'sidebar.dart';

/// ノートの履歴。版を幹、ノートに入らなかった記録を枝として、git のグラフのように新しい順に並べる。
/// 広い画面では左にグラフ、右に選んだ版の差分を並べる。見るだけで、前の版には戻さない（spec）
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.c});
  final ManualController c;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  ManualController get c => widget.c;

  /// 広い画面で右に出している版。選ぶまではいちばん新しいもの
  String? _selected;

  void _push(Commit x) => Navigator.push(context, MaterialPageRoute(builder: (_) => _CommitScreen(c: c, id: x.id)));

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final s = c.state!;
        final h = buildHistory(s);
        return Scaffold(
          body: WithSidebar(api: c.api, manualId: c.manualId, child: GridBackground(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TopBar(crumbs: ['DiffNote（仮）', s.title, '履歴']),
            Expanded(
              child: LayoutBuilder(builder: (context, box) {
                if (box.maxWidth < k.wideLayout) return _scroll(_list(s, h, onOpen: _push));
                final commits = h.rows.map((r) => r.commit);
                final selected = commits.where((x) => x.id == _selected).firstOrNull ?? commits.first;
                return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  SizedBox(
                    width: k.panelWidth,
                    child: _scroll(_list(s, h, selected: selected.id, onOpen: (x) => setState(() => _selected = x.id))),
                  ),
                  Container(width: k.hairline, color: k.colors.rule),
                  Expanded(child: _scroll(_CommitDetail(c: c, commit: selected))),
                ]);
              }),
            ),
          ]))),
        );
      },
    );
  }

  Widget _scroll(Widget child) {
    final k = context.tokens;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(k.space.xl, k.space.xxl, k.space.xl, k.space.xxl),
      child: Narrow(child: child),
    );
  }

  Widget _list(ManualState s, History h, {String? selected, required void Function(Commit) onOpen}) {
    final k = context.tokens;
    final versions = h.rows.where((r) => !r.commit.onBranch).length;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PageTitle('履歴', meta: [
        Text('版 $versions', style: k.text.small),
        if (s.openChecks.isNotEmpty)
          StatusTag('あとで確認 ${s.openChecks.length} 件', bg: k.colors.pendingBg, fg: k.colors.pending),
      ]),
      SizedBox(height: k.space.xl),
      // グラフの線が行の間で途切れないよう、行の間を空けずに1枚の白い面に載せる
      PaperSheet(
        padding: EdgeInsets.all(k.space.sm),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final r in h.rows) _row(h, r, selected: r.commit.id == selected, onTap: () => onOpen(r.commit)),
        ]),
      ),
      if (versions == 1) ...[
        SizedBox(height: k.space.md),
        Text('行を書き換えたり、教わったことを反映したりすると、ここに版が積み重なります', style: k.text.small),
      ],
    ]);
  }

  Widget _row(History h, GraphRow r, {required bool selected, required VoidCallback onTap}) {
    final k = context.tokens;
    final x = r.commit;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SizedBox(
              width: h.lanes * k.graphLane,
              child: CustomPaint(
                painter: _GraphPainter(
                  row: r,
                  lane: k.graphLane,
                  dot: k.graphDot,
                  // 点を、行の頭（誰が・いつ）の高さにそろえる
                  dotY: k.space.md * 2 + k.hairline * 2,
                  stroke: k.hairline * 2,
                  trunk: k.colors.ink,
                  branch: k.colors.inkMuted,
                  dotColor: x.onBranch && (x.check?.isOpen ?? false) ? k.colors.pending : (x.onBranch ? k.colors.inkMuted : k.colors.ink),
                ),
              ),
            ),
            Expanded(
              child: Container(
                padding: EdgeInsets.all(k.space.md),
                decoration: BoxDecoration(
                  borderRadius: k.radius.control,
                  // 選んでいない行も同じ太さの白い枠にして、選んだときに中身がずれないようにする
                  border: Border.all(color: selected ? k.colors.action : k.colors.canvas, width: k.hairline * 2),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _Who(x),
                  SizedBox(height: k.space.xs),
                  Text(_message(x), maxLines: 2, overflow: TextOverflow.ellipsis, style: k.text.body),
                  SizedBox(height: k.space.xs),
                  _Changes(x),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// 版1件の画面。狭い画面で履歴から開く
class _CommitScreen extends StatelessWidget {
  const _CommitScreen({required this.c, required this.id});
  final ManualController c;
  final String id;

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final s = c.state!;
        final x = buildHistory(s).rows.map((r) => r.commit).firstWhere((x) => x.id == id);
        return Scaffold(
          body: WithSidebar(api: c.api, manualId: c.manualId, child: GridBackground(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TopBar(crumbs: ['DiffNote（仮）', s.title, '履歴', x.onBranch ? '記録' : '版']),
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(k.space.xl, k.space.xxl, k.space.xl, k.space.xxl),
                child: Narrow(child: _CommitDetail(c: c, commit: x)),
              ),
            ),
          ]))),
        );
      },
    );
  }
}

/// 誰が・いつ → 何をしたか → 差分。版ならこの版のノート全文に増減の印を付け、枝ならノートに入れていない差分を見せる
class _CommitDetail extends StatelessWidget {
  const _CommitDetail({required this.c, required this.commit});
  final ManualController c;
  final Commit commit;

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    final x = commit;
    final unchanged = !x.onBranch && x.said != null && x.diff.every((l) => l.change == LineChange.kept);
    return PaperSheet(
      padding: EdgeInsets.fromLTRB(k.space.xl, k.space.xl, k.space.xl, k.space.xxl),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Align(alignment: Alignment.centerLeft, child: _Who(x)),
        SizedBox(height: k.space.sm),
        Text(_message(x), style: k.text.heading),
        SizedBox(height: k.space.sm),
        Align(alignment: Alignment.centerLeft, child: _Changes(x)),
        if (x.onBranch && x.check?.kind == Kind.contradiction) ...[
          SizedBox(height: k.space.md),
          Align(
            alignment: Alignment.centerLeft,
            child: MoonOutlinedButton(
              buttonSize: MoonButtonSize.sm,
              onTap: () => openCheckViaList(Navigator.of(context), c, x.check!.id),
              label: const Text('確認リストで開く'),
            ),
          ),
        ],
        SizedBox(height: k.space.xl),
        Text(x.onBranch ? 'ノートに入れていない差分' : 'この版のノート', style: k.text.title),
        SizedBox(height: k.space.md),
        if (unchanged) ...[
          Text('ノートは変えずに確定しました', style: k.text.small),
          SizedBox(height: k.space.md),
        ],
        if (x.diff.isEmpty)
          Text('白紙から作りました', style: k.text.small)
        else
          for (final l in x.diff) _diffLine(k, l),
      ]),
    );
  }

  Widget _diffLine(AppTokens k, DiffLine l) {
    final c = k.colors;
    final (mark, bg, fg) = switch (l.change) {
      LineChange.added => ('+', c.addedBg, c.added),
      // U+2212 は同梱フォントに無く、実行時にフォントを取りに行くので ASCII にする
      LineChange.removed => ('-', c.removedBg, c.removed),
      LineChange.kept => (' ', null, c.ink),
    };
    final base = l.text.startsWith('## ') ? k.text.heading : k.text.body;
    return Container(
      color: bg,
      padding: EdgeInsets.symmetric(horizontal: k.space.sm, vertical: k.space.xs),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: k.space.lg, child: Text(mark, style: k.text.body.copyWith(color: fg))),
        Expanded(
          child: Text(l.text.startsWith('- ') ? '・${l.text.substring(2)}' : plain(l.text), style: base.copyWith(color: fg)),
        ),
      ]),
    );
  }
}

/// 版や記録の頭：誰が・いつ。確定した版は確認印、ノートを作った版は作った日だけ
class _Who extends StatelessWidget {
  const _Who(this.x);
  final Commit x;

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    final r = x.onBranch ? null : x.check?.resolution;
    if (r != null) return ConfirmStamp(compact: true, who: r.decidedBy, day: r.decidedAt);
    if (x.said case final u?) return Speaker(name: u.speaker, day: u.saidAt);
    final day = DateFormat('yyyy-MM-dd').format(DateTime.parse(x.at).toLocal());
    return Text(fmtDay(day), style: k.text.small);
  }
}

/// 版なら増えた行と消えた行の数、枝ならノートに入らなかったわけ（状態）
class _Changes extends StatelessWidget {
  const _Changes(this.x);
  final Commit x;

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    final c = k.colors;
    if (x.onBranch) {
      final status = _status(x);
      final (bg, fg) = switch (status) {
        'あとで確認' => (c.pendingBg, c.pending),
        '確認済み' => (c.addedBg, c.added),
        _ => (c.rule, c.ink),
      };
      return StatusTag(status, bg: bg, fg: fg);
    }
    final added = x.diff.where((l) => l.change == LineChange.added).length;
    final removed = x.diff.where((l) => l.change == LineChange.removed).length;
    return Wrap(spacing: k.space.sm, children: [
      if (added > 0) Text('+$added 行', style: k.text.small.copyWith(color: c.added)),
      if (removed > 0) Text('-$removed 行', style: k.text.small.copyWith(color: c.removed)),
    ]);
  }
}

String _message(Commit x) => switch (x) {
      Commit(said: null) => 'ノートを作った',
      Commit(onBranch: false, check: Check(resolution: final r?)) => r.note,
      // 直接編集の記録は書いた行そのもの（「- 」付き）なので、人に見せる形にする
      Commit(said: final u?) => plain(u.text),
    };

/// 枝の記録がノートに入らなかったわけ。ノート画面の発言の状態と同じ言葉にする
String _status(Commit x) {
  final p = x.patch!;
  final chk = x.check;
  if (chk?.resolution != null) return '確認済み';
  if (chk?.isOpen ?? false) return 'あとで確認';
  if (chk?.kind == Kind.same && p.status == 'discarded') return '同じ内容';
  return p.status == 'discarded' ? '反映しない' : '未反映';
}

/// 1行分のグラフ。幹は濃い線、枝は薄い線で、分かれる所と合流する所は曲げてつなぐ
class _GraphPainter extends CustomPainter {
  _GraphPainter({
    required this.row,
    required this.lane,
    required this.dot,
    required this.dotY,
    required this.stroke,
    required this.trunk,
    required this.branch,
    required this.dotColor,
  });
  final GraphRow row;
  final double lane;
  final double dot;
  final double dotY;
  final double stroke;
  final Color trunk;
  final Color branch;
  final Color dotColor;

  @override
  void paint(Canvas canvas, Size size) {
    double x(int l) => lane * l + lane / 2;
    Paint pen(int l) => Paint()
      ..color = l == 0 ? trunk : branch
      ..strokeWidth = stroke
      ..style = PaintingStyle.stroke;
    final at = Offset(x(row.lane), dotY);
    for (final l in row.through) {
      canvas.drawLine(Offset(x(l), 0), Offset(x(l), size.height), pen(l));
    }
    if (row.up) canvas.drawLine(Offset(at.dx, 0), at, pen(row.lane));
    if (row.down) canvas.drawLine(at, Offset(at.dx, size.height), pen(row.lane));
    for (final l in row.forks) {
      canvas.drawPath(Path()..moveTo(at.dx, at.dy)..quadraticBezierTo(x(l), at.dy, x(l), 0), pen(l));
    }
    for (final l in row.merges) {
      canvas.drawPath(Path()..moveTo(x(l), size.height)..quadraticBezierTo(x(l), at.dy, at.dx, at.dy), pen(l));
    }
    canvas.drawCircle(at, dot / 2, Paint()..color = dotColor);
  }

  @override
  bool shouldRepaint(_GraphPainter old) => old.row != row || old.dotColor != dotColor;
}
