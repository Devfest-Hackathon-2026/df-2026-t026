import 'package:diff_note/models.dart';
import 'package:diff_note/screens/input_screen.dart';
import 'package:flutter_test/flutter_test.dart';

ManualState _note(String id, String title, List<Map<String, dynamic>> utterances) => ManualState.fromJson({
      'owner': 'demo',
      'me': 'demo',
      'manual': {'id': id, 'title': title, 'base': '', 'createdAt': '2026-11-01T00:00:00Z'},
      'lines': <Map<String, dynamic>>[],
      'utterances': utterances,
      'patches': <Map<String, dynamic>>[],
      'checks': <Map<String, dynamic>>[],
    });

Map<String, dynamic> _u(String id, String text, String createdAt, {String speaker = '鈴木さん'}) =>
    {'id': id, 'text': text, 'speaker': speaker, 'saidAt': '2026-11-10', 'createdAt': createdAt};

void main() {
  const gas = 'ガスの元栓は閉めたら写真も撮っておいて';

  test('1つの入力から2冊にできた記録は、1枚にまとめ、ノートを新しく記録した順に並べる', () {
    final kitchen = _note('m1', 'キッチン', [_u('u1', gas, '2026-11-10T05:00:00.010Z')]);
    final closing = _note('m2', '閉店作業メモ', [_u('u2', gas, '2026-11-10T05:00:00.020Z')]);
    final recent = sameInput([
      (manual: closing, u: closing.said.single),
      (manual: kitchen, u: kitchen.said.single),
    ]);
    expect(recent, hasLength(1));
    expect(recent.single.manuals.map((m) => m.title), ['閉店作業メモ', 'キッチン']);
  });

  test('同じ文でも、1分より離れて記録したもの・言った人が違うものはまとめない', () {
    final kitchen = _note('m1', 'キッチン', [_u('u1', gas, '2026-11-10T05:00:00Z')]);
    final later = _note('m2', '閉店作業メモ', [_u('u2', gas, '2026-11-10T05:02:00Z')]);
    final other = _note('m3', 'ホール', [_u('u3', gas, '2026-11-10T05:00:00Z', speaker: '田中さん')]);
    final recent = sameInput([
      (manual: later, u: later.said.single),
      (manual: kitchen, u: kitchen.said.single),
      (manual: other, u: other.said.single),
    ]);
    expect(recent, hasLength(3));
  });
}
