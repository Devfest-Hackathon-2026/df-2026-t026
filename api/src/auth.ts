import { createHash, randomBytes, scrypt, timingSafeEqual } from 'node:crypto';
import { promisify } from 'node:util';

/** 配ったアカウント。ID がそのまま userId になる（ADR 0009） */
export interface Account {
  id: string;
  /** scrypt のソルトとハッシュ（16進） */
  salt: string;
  hash: string;
  createdAt: string;
}

/** ログイン中のトークン。トークンそのものは持たず、SHA-256 を id にする */
export interface Session {
  id: string;
  userId: string;
  createdAt: string;
}

/** Firestore のドキュメント ID にそのまま使うので、英数字・ハイフン・下線だけにする */
export const loginIdPattern = /^[A-Za-z0-9_-]{1,64}$/;

const scryptAsync = promisify(scrypt) as (password: string, salt: Buffer, keylen: number) => Promise<Buffer>;
const KEY_LENGTH = 64;

export async function hashPassword(password: string): Promise<Pick<Account, 'salt' | 'hash'>> {
  const salt = randomBytes(16);
  const hash = await scryptAsync(password, salt, KEY_LENGTH);
  return { salt: salt.toString('hex'), hash: hash.toString('hex') };
}

export async function verifyPassword(password: string, account: Pick<Account, 'salt' | 'hash'>): Promise<boolean> {
  const hash = await scryptAsync(password, Buffer.from(account.salt, 'hex'), KEY_LENGTH);
  return timingSafeEqual(hash, Buffer.from(account.hash, 'hex'));
}

export const newToken = () => randomBytes(32).toString('base64url');

export const sessionIdOf = (token: string) => createHash('sha256').update(token).digest('hex');
