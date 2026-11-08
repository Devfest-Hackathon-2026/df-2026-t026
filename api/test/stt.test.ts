import assert from 'node:assert/strict';
import { test } from 'node:test';

import { lastSeconds, phraseHints } from '../src/stt.ts';

/** 16kHz・モノラル・16bit の WAV。標本の値は位置（0, 1, 2, …）にする */
function wav(samples: number): Buffer {
  const out = Buffer.alloc(44 + samples * 2);
  out.write('RIFF', 0, 'ascii');
  out.writeUInt32LE(36 + samples * 2, 4);
  out.write('WAVEfmt ', 8, 'ascii');
  out.writeUInt32LE(16, 16);
  out.writeUInt16LE(1, 20);
  out.writeUInt16LE(1, 22);
  out.writeUInt32LE(16000, 24);
  out.writeUInt32LE(32000, 28);
  out.writeUInt16LE(2, 32);
  out.writeUInt16LE(16, 34);
  out.write('data', 36, 'ascii');
  out.writeUInt32LE(samples * 2, 40);
  for (let i = 0; i < samples; i++) out.writeInt16LE(i % 32768, 44 + i * 2);
  return out;
}

test('WAV は末尾の指定秒数だけを残し、ヘッダーの大きさも合わせる', () => {
  const cut = lastSeconds(wav(16000 * 3), 1);
  assert.equal(cut.length, 44 + 32000);
  assert.equal(cut.readUInt32LE(4), cut.length - 8);
  assert.equal(cut.readUInt32LE(40), 32000);
  assert.equal(cut.readInt16LE(44), 16000 * 2);
});

test('短い WAV と WAV でないものはそのまま返す', () => {
  const short = wav(100);
  assert.equal(lastSeconds(short, 1), short);
  const other = Buffer.from('not a wav file');
  assert.equal(lastSeconds(other, 1), other);
});

test('フレーズヒントは見出しと各項目の頭の語を重複なく取る', () => {
  const lines = ['## 味噌汁', '- 塩 小さじ1', '- 味噌は火を止めてから溶く', '', '## 会計', '- 塩 小さじ2'];
  assert.deepEqual(phraseHints(lines), ['味噌汁', '塩', '味噌', '会計']);
});
