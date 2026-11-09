import { Firestore } from '@google-cloud/firestore';

import type { Account, Session } from './auth.ts';
import type { Manual } from './foundation/manual.ts';
import type { Memo, Profile, Shared, Store } from './store.ts';

/**
 * users/{userId}/manuals/{manualId}/{collection}/{id} に保存する。名前とアイコンは users/{userId} そのもの。
 * ノートに付けた資料は users/{userId}/manuals/{manualId}/materials/{id}（ADR 0019）。
 * 共有されたノートの索引は users/{userId}/shared/{manualId}（ADR 0013）。未整理メモは users/{userId}/memos/{id}（ADR 0015）。
 * アカウントは accounts/{ログイン ID}、ログイン中のトークンは sessions/{トークンの SHA-256}
 */
export class FirestoreStore implements Store {
  private db = new Firestore();

  private manuals(userId: string) {
    return this.db.collection('users').doc(userId).collection('manuals');
  }

  async listManuals(userId: string) {
    const snap = await this.manuals(userId).get();
    return snap.docs.map((d) => d.data() as Manual);
  }

  async getManual(userId: string, id: string) {
    const doc = await this.manuals(userId).doc(id).get();
    return doc.exists ? (doc.data() as Manual) : null;
  }

  async putManual(userId: string, manual: Manual) {
    await this.manuals(userId).doc(manual.id).set(manual);
  }

  async list<T>(userId: string, manualId: string, collection: string) {
    const snap = await this.manuals(userId).doc(manualId).collection(collection).get();
    return snap.docs.map((d) => d.data() as T);
  }

  async put<T extends { id: string }>(userId: string, manualId: string, collection: string, doc: T) {
    await this.manuals(userId).doc(manualId).collection(collection).doc(doc.id).set(doc);
  }

  async remove(userId: string, manualId: string, collection: string, id: string) {
    await this.manuals(userId).doc(manualId).collection(collection).doc(id).delete();
  }

  // サブコレクションは親と一緒に消えないので一つずつ消し、本文は最後に消す。
  // 途中で失敗しても本文が残り、持ち主がもう一度消せる（ADR 0014）
  async removeManual(userId: string, manualId: string) {
    const doc = this.manuals(userId).doc(manualId);
    for (const name of ['shares', 'utterances', 'patches', 'checks', 'materials']) await this.db.recursiveDelete(doc.collection(name));
    await doc.delete();
  }

  async getAccount(id: string) {
    const doc = await this.db.collection('accounts').doc(id).get();
    return doc.exists ? (doc.data() as Account) : null;
  }

  async putAccount(account: Account) {
    await this.db.collection('accounts').doc(account.id).set(account);
  }

  async getSession(id: string) {
    const doc = await this.db.collection('sessions').doc(id).get();
    return doc.exists ? (doc.data() as Session) : null;
  }

  async putSession(session: Session) {
    await this.db.collection('sessions').doc(session.id).set(session);
  }

  async getProfile(userId: string) {
    const doc = await this.db.collection('users').doc(userId).get();
    return doc.exists ? (doc.data() as Profile) : null;
  }

  async putProfile(userId: string, profile: Profile) {
    await this.db.collection('users').doc(userId).set(profile);
  }

  private shared(userId: string) {
    return this.db.collection('users').doc(userId).collection('shared');
  }

  async listShared(userId: string) {
    const snap = await this.shared(userId).get();
    return snap.docs.map((d) => d.data() as Shared);
  }

  async getShared(userId: string, manualId: string) {
    const doc = await this.shared(userId).doc(manualId).get();
    return doc.exists ? (doc.data() as Shared) : null;
  }

  async putShared(userId: string, shared: Shared) {
    await this.shared(userId).doc(shared.id).set(shared);
  }

  async removeShared(userId: string, manualId: string) {
    await this.shared(userId).doc(manualId).delete();
  }

  private memos(userId: string) {
    return this.db.collection('users').doc(userId).collection('memos');
  }

  async listMemos(userId: string) {
    const snap = await this.memos(userId).get();
    return snap.docs.map((d) => d.data() as Memo);
  }

  async getMemo(userId: string, id: string) {
    const doc = await this.memos(userId).doc(id).get();
    return doc.exists ? (doc.data() as Memo) : null;
  }

  async putMemo(userId: string, memo: Memo) {
    await this.memos(userId).doc(memo.id).set(memo);
  }

  async removeMemo(userId: string, id: string) {
    await this.memos(userId).doc(id).delete();
  }
}
