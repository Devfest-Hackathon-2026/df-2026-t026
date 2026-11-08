import { Firestore } from '@google-cloud/firestore';

import type { Manual } from './foundation/manual.ts';
import type { Store } from './store.ts';

/** users/{userId}/manuals/{manualId}/{collection}/{id} に保存する */
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
}
