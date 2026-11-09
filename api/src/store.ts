import type { Account, Session } from './auth.ts';
import type { Manual } from './foundation/manual.ts';

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
  getAccount(id: string): Promise<Account | null>;
  putAccount(account: Account): Promise<void>;
  getSession(id: string): Promise<Session | null>;
  putSession(session: Session): Promise<void>;
}

/** テストと、GCP なしでのローカル開発用 */
export class MemoryStore implements Store {
  private manuals = new Map<string, Map<string, Manual>>();
  private docs = new Map<string, Map<string, unknown>>();
  private accounts = new Map<string, Account>();
  private sessions = new Map<string, Session>();

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
}
