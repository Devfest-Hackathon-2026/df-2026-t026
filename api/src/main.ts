import { serve } from '@hono/node-server';

import { createApp } from './app.ts';
import { fakeCheck, fakePatchify } from './fake-ai.ts';
import { seed } from './seed.ts';
import { MemoryStore } from './store.ts';

const store = new MemoryStore();
await seed(store, 'demo');

const app = createApp({ store, patchify: fakePatchify, check: fakeCheck });
const port = Number(process.env.PORT ?? 8787);
serve({ fetch: app.fetch, port }, () => console.log(`api: http://localhost:${port}（偽の Gemini・メモリ上のデータ）`));
