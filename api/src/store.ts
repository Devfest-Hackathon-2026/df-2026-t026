import type { Account, Session } from './auth.ts';
import type { Manual } from './foundation/manual.ts';

/** 本人が決めた名前とアイコン（ADR 0010）。アイコンは base64 */
export interface Profile {
  name: string;
  icon: { mimeType: string; data: string } | null;
}

/**
 * 共有の記録（ADR 0013）。持ち主の側はノートの下の shares（id は相手の ID）、
 * 相手の側は users/{相手}/shared（id はノートの ID）に置く
 */
export interface Share {
  id: string;
  createdAt: string;
}

/** 相手の側に置く、共有されたノートの索引 */
export interface Shared {
  id: string;
  ownerId: string;
  createdAt: string;
}

/** リワインドで切り出して書き起こした未整理メモ（ADR 0014）。at は切り出しボタンを押した時刻 */
export interface Memo {
  id: string;
  at: string;
  text: string;
}

/**
 * 保存先。マニュアルの下に、土台（utterances / patches）と
 * 衝突検知（checks）がそれぞれ自分のコレクションを持つ。
 */
export interface Store {
  listManuals(userId: string): Promise<Manual[]>;
  getManual(userId: string, id: string): Promise<Manual | null>;
  putManual(userId: string, manual: Manual): Promise<void>;
  list<T>(userId: string, manualId: string, collection: string): Promise<T[]>;
  put<T extends { id: string }>(userId: string, manualId: string, collection: string, doc: T): Promise<void>;
  remove(userId: string, manualId: string, collection: string, id: string): Promise<void>;
  /** ノートの本文と、その下のコレクションをまとめて消す（ADR 0014） */
  removeManual(userId: string, manualId: string): Promise<void>;
  getAccount(id: string): Promise<Account | null>;
  putAccount(account: Account): Promise<void>;
  getSession(id: string): Promise<Session | null>;
  putSession(session: Session): Promise<void>;
  getProfile(userId: string): Promise<Profile | null>;
  putProfile(userId: string, profile: Profile): Promise<void>;
  listShared(userId: string): Promise<Shared[]>;
  getShared(userId: string, manualId: string): Promise<Shared | null>;
  putShared(userId: string, shared: Shared): Promise<void>;
  removeShared(userId: string, manualId: string): Promise<void>;
  listMemos(userId: string): Promise<Memo[]>;
  getMemo(userId: string, id: string): Promise<Memo | null>;
  putMemo(userId: string, memo: Memo): Promise<void>;
  removeMemo(userId: string, id: string): Promise<void>;
}

/** テストと、GCP なしでのローカル開発用 */
export class MemoryStore implements Store {
  private manuals = new Map<string, Map<string, Manual>>();
  private docs = new Map<string, Map<string, unknown>>();
  private accounts = new Map<string, Account>();
  private sessions = new Map<string, Session>();
  private profiles = new Map<string, Profile>();
  private shared = new Map<string, Map<string, Shared>>();
  private memos = new Map<string, Map<string, Memo>>();

  async listManuals(userId: string) {
    return [...(this.manuals.get(userId)?.values() ?? [])];
  }

  async getManual(userId: string, id: string) {
    return this.manuals.get(userId)?.get(id) ?? null;
  }

  async putManual(userId: string, manual: Manual) {
    if (!this.manuals.has(userId)) this.manuals.set(userId, new Map());
    this.manuals.get(userId)!.set(manual.id, structuredClone(manual));
  }

  async list<T>(userId: string, manualId: string, collection: string) {
    const docs = this.docs.get(`${userId}/${manualId}/${collection}`);
    return [...(docs?.values() ?? [])].map((d) => structuredClone(d) as T);
  }

  async put<T extends { id: string }>(userId: string, manualId: string, collection: string, doc: T) {
    const key = `${userId}/${manualId}/${collection}`;
    if (!this.docs.has(key)) this.docs.set(key, new Map());
    this.docs.get(key)!.set(doc.id, structuredClone(doc));
  }

  async remove(userId: string, manualId: string, collection: string, id: string) {
    this.docs.get(`${userId}/${manualId}/${collection}`)?.delete(id);
  }

  async removeManual(userId: string, manualId: string) {
    for (const key of this.docs.keys()) if (key.startsWith(`${userId}/${manualId}/`)) this.docs.delete(key);
    this.manuals.get(userId)?.delete(manualId);
  }

  async getAccount(id: string) {
    return structuredClone(this.accounts.get(id) ?? null);
  }

  async putAccount(account: Account) {
    this.accounts.set(account.id, structuredClone(account));
  }

  async getSession(id: string) {
    return structuredClone(this.sessions.get(id) ?? null);
  }

  async putSession(session: Session) {
    this.sessions.set(session.id, structuredClone(session));
  }

  async getProfile(userId: string) {
    return structuredClone(this.profiles.get(userId) ?? null);
  }

  async putProfile(userId: string, profile: Profile) {
    this.profiles.set(userId, structuredClone(profile));
  }

  async listShared(userId: string) {
    return [...(this.shared.get(userId)?.values() ?? [])].map((x) => structuredClone(x));
  }

  async getShared(userId: string, manualId: string) {
    return structuredClone(this.shared.get(userId)?.get(manualId) ?? null);
  }

  async putShared(userId: string, shared: Shared) {
    if (!this.shared.has(userId)) this.shared.set(userId, new Map());
    this.shared.get(userId)!.set(shared.id, structuredClone(shared));
  }

  async removeShared(userId: string, manualId: string) {
    this.shared.get(userId)?.delete(manualId);
  }

  async listMemos(userId: string) {
    return [...(this.memos.get(userId)?.values() ?? [])].map((x) => structuredClone(x));
  }

  async getMemo(userId: string, id: string) {
    return structuredClone(this.memos.get(userId)?.get(id) ?? null);
  }

  async putMemo(userId: string, memo: Memo) {
    if (!this.memos.has(userId)) this.memos.set(userId, new Map());
    this.memos.get(userId)!.set(memo.id, structuredClone(memo));
  }

  async removeMemo(userId: string, id: string) {
    this.memos.get(userId)?.delete(id);
  }
}
