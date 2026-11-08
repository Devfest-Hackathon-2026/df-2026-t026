import type { Manual } from './foundation/manual.ts';
import type { Store } from './store.ts';

/** デモ用のマニュアル。登場人物・店はすべて架空 */
export const demoManual: Omit<Manual, 'id' | 'createdAt'> = {
  title: 'キッチンマニュアル（定食屋 みのり）',
  base: `## 味噌汁
- 塩 小さじ1
- 味噌は火を止めてから溶く
## ご飯
- 大盛りは250gまで
- 炊けたら10分蒸らす
## 片付け
- 洗った皿は右の棚に戻す
- まな板は使うたびに熱湯をかける
## 閉店作業
- レジ締めは社員がやる
- ガスの元栓を閉めて写真を撮る`,
};

/** 1回の指示が複数のマニュアルにまたがる例（レジ締めなど）を見せるための2冊目 */
export const demoHallManual: Omit<Manual, 'id' | 'createdAt'> = {
  title: 'ホール接客マニュアル（定食屋 みのり）',
  base: `## お出迎え
- 入店したら「いらっしゃいませ」と声をかける
- お冷やは席に着いたらすぐ出す
## 会計
- レジは現金とカードのみ
- 領収書は宛名を聞いてから書く`,
};

export async function seed(store: Store, userId: string): Promise<void> {
  if ((await store.listManuals(userId)).length > 0) return;
  await store.putManual(userId, { ...demoManual, id: 'demo-kitchen', createdAt: '2026-11-01T00:00:00.000Z' });
  await store.putManual(userId, { ...demoHallManual, id: 'demo-hall', createdAt: '2026-11-01T00:00:01.000Z' });
}
