import 'package:flutter/material.dart';

import '../models.dart';

/// YYYY-MM-DD → 11/3
String fmtDay(String ymd) {
  final p = ymd.split('-');
  return p.length == 3 ? '${int.parse(p[1])}/${int.parse(p[2])}' : ymd;
}

/// 「- 」「## 」を外した、人に見せる形
String plain(String line) => line.replaceFirst(RegExp(r'^(## |- )'), '');

const addBg = Color(0xFFE6F4EA), addFg = Color(0xFF1E6B34);
const delBg = Color(0xFFFCE8E6), delFg = Color(0xFFA50E0E);
const warnBg = Color(0xFFFFF1DB), warnFg = Color(0xFF8A4B00);

(Color, Color) kindColors(Kind k) => switch (k) {
      Kind.addition => (addBg, addFg),
      Kind.qualification => (const Color(0xFFE3EEFA), const Color(0xFF1A4F8B)),
      Kind.contradiction => (warnBg, warnFg),
    };

class KindChip extends StatelessWidget {
  const KindChip(this.kind, {super.key});
  final Kind kind;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = kindColors(kind);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4)),
      child: Text(kind.label, style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.bold)),
    );
  }
}

/// マニュアルの1行（## を見出し、- を箇条書きとして扱う）
class LineText extends StatelessWidget {
  const LineText(this.line, {super.key});
  final String line;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    if (line.startsWith('## ')) {
      return Text(line.substring(3), style: t.titleSmall?.copyWith(fontWeight: FontWeight.bold));
    }
    return Text(line.startsWith('- ') ? '・${line.substring(2)}' : line, style: t.bodyMedium);
  }
}

/// パッチを赤緑の行差分で見せる
class PatchDiff extends StatelessWidget {
  const PatchDiff({super.key, required this.op, required this.line, required this.text});
  final String op;
  final String? line;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(border: Border.all(color: Colors.black12), borderRadius: BorderRadius.circular(8)),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (line != null) op == 'replace' ? _row('−', line!, delBg, delFg) : _row(' ', line!, null, Colors.black45),
        for (final l in text.split('\n')) _row('+', l, addBg, addFg),
      ]),
    );
  }

  Widget _row(String mark, String text, Color? bg, Color fg) => Container(
        color: bg,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        child: Text('$mark  $text', style: TextStyle(color: fg, fontSize: 13, height: 1.5)),
      );
}

/// 衝突を並べて見せる。「マニュアル：塩 小さじ1 ／ 田中さん（11/3）：小さじ1/2」
class ConflictPair extends StatelessWidget {
  const ConflictPair({
    super.key,
    required this.leftLabel,
    required this.left,
    required this.rightLabel,
    required this.right,
  });
  final String leftLabel;
  final String left;
  final String rightLabel;
  final String right;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    Widget side(String label, String text, Color bg) => Expanded(
          child: Container(
            color: bg,
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: t.labelMedium?.copyWith(color: Colors.black54)),
              const SizedBox(height: 6),
              Text(plain(text), style: t.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
            ]),
          ),
        );
    return Container(
      decoration: BoxDecoration(border: Border.all(color: warnFg.withValues(alpha: 0.4)), borderRadius: BorderRadius.circular(10)),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          side(leftLabel, left, Colors.white),
          Container(
            width: 32,
            color: warnBg,
            alignment: Alignment.center,
            child: const Text('／', style: TextStyle(color: warnFg, fontWeight: FontWeight.bold)),
          ),
          side(rightLabel, right, Colors.white),
        ]),
      ),
    );
  }
}

/// 幅を抑えて中央に置く（モックと同じ 720）
class Narrow extends StatelessWidget {
  const Narrow({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 720), child: child));
}

void showError(BuildContext context, Object e) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
}
