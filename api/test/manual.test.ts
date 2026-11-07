import assert from 'node:assert/strict';
import { test } from 'node:test';

import { PatchError, render, type Patch } from '../src/foundation/manual.ts';

const patch = (p: Partial<Patch> & Pick<Patch, 'op' | 'line' | 'text'>): Patch => ({
  id: crypto.randomUUID(),
  utteranceId: 'u',
  summary: '',
  status: 'applied',
  createdAt: '2026-11-01T00:00:00.000Z',
  appliedAt: '2026-11-01T00:00:00.000Z',
  ...p,
});

test('反映済みのパッチだけを反映順に当て、行ごとに出どころを持つ', () => {
  const salt = patch({ op: 'replace', line: '- 塩 小さじ1', text: '- 塩 小さじ1/2', appliedAt: '2026-11-03T00:00:00.000Z' });
  const miso = patch({ op: 'insert', line: '- 塩 小さじ1/2', text: '- 味噌 大さじ2', appliedAt: '2026-11-04T00:00:00.000Z' });
  const proposed = patch({ op: 'insert', line: null, text: '- 未反映', status: 'proposed' });
  const lines = render('## 味噌汁\n- 塩 小さじ1\n## ご飯', [miso, proposed, salt]);
  assert.deepEqual(lines, [
    { text: '## 味噌汁', patchId: null },
    { text: '- 塩 小さじ1/2', patchId: salt.id },
    { text: '- 味噌 大さじ2', patchId: miso.id },
    { text: '## ご飯', patchId: null },
  ]);
});

test('対象の行がなければ当てない', () => {
  assert.throws(() => render('- 塩 小さじ1', [patch({ op: 'replace', line: '- 砂糖', text: '- 砂糖 少々' })]), PatchError);
});
