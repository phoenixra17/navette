// Implémentation de référence du protocole Navette v2 (voir PROTOCOL.md).
// Les apps Mac (Swift) et Android (Kotlin) doivent produire exactement la même chose.
//
// v2 : les données associées (AAD) lient chaque élément à son expéditeur (« mac » ou « phone »).
// Un élément renvoyé à son propre expéditeur ne se déchiffre donc pas.
import crypto from 'node:crypto';

export const ROLES = ['mac', 'phone'];
/** Âge maximal d'un message reçu en direct (horloges du Mac et du téléphone comprises). */
export const MAX_AGE_MS = 5 * 60 * 1000;

export function deriveKeys(secret) {
  const secretBytes = Buffer.from(secret, 'base64url');
  const hmac = (label) => crypto.createHmac('sha256', secretBytes).update(label).digest();
  return {
    token: hmac('navette/auth/v1').toString('base64url'),
    encKey: hmac('navette/enc/v1'),
    fingerprint: fingerprintOf(hmac('navette/fingerprint/v1')),
  };
}

/** Code à 6 chiffres affiché au Mac et au téléphone pour vérifier qu'ils partagent le même secret. */
function fingerprintOf(digest) {
  const n = digest.readUInt32BE(0) % 1_000_000;
  const s = String(n).padStart(6, '0');
  return `${s.slice(0, 3)} ${s.slice(3)}`;
}

function aad(from, id) {
  if (!ROLES.includes(from)) throw new Error(`rôle inconnu : ${from}`);
  return Buffer.from(`navette/v2|${from}|${id}`, 'utf8');
}

export function seal(encKey, payload, id = crypto.randomUUID(), from = 'mac') {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', encKey, iv);
  cipher.setAAD(aad(from, id));
  const plaintext = Buffer.from(JSON.stringify({ ...payload, t: Date.now() }), 'utf8');
  const data = Buffer.concat([cipher.update(plaintext), cipher.final(), cipher.getAuthTag()]);
  return { id, iv: iv.toString('base64'), data: data.toString('base64') };
}

/** `from` : l'expéditeur attendu. Lève une exception si l'élément vient d'ailleurs ou a été altéré. */
export function open(encKey, { id, iv, data }, from = 'mac') {
  const raw = Buffer.from(data, 'base64');
  if (raw.length <= 16) throw new Error('élément tronqué');
  const decipher = crypto.createDecipheriv('aes-256-gcm', encKey, Buffer.from(iv, 'base64'));
  decipher.setAAD(aad(from, id));
  decipher.setAuthTag(raw.subarray(raw.length - 16));
  const plaintext = Buffer.concat([decipher.update(raw.subarray(0, raw.length - 16)), decipher.final()]);
  return JSON.parse(plaintext.toString('utf8'));
}

/** Refuse les messages reçus en direct qui sont périmés ou déjà vus (rejeu). */
export class ReplayGuard {
  constructor(capacity = 4096) {
    this.capacity = capacity;
    this.seen = new Set();
  }

  accept(id, t, now = Date.now()) {
    if (typeof t !== 'number' || Math.abs(now - t) > MAX_AGE_MS || this.seen.has(id)) return false;
    this.seen.add(id);
    if (this.seen.size > this.capacity) this.seen.delete(this.seen.values().next().value);
    return true;
  }
}
