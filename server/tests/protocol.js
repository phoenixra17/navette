// Implémentation de référence du protocole Navette v1 (voir PROTOCOLE.md).
// Les apps Mac (Swift) et Android (Kotlin) doivent produire exactement la même chose.
import crypto from 'node:crypto';

export function deriveKeys(secret) {
  const secretBytes = Buffer.from(secret, 'base64url');
  const hmac = (label) => crypto.createHmac('sha256', secretBytes).update(label).digest();
  return {
    token: hmac('navette/auth/v1').toString('base64url'),
    encKey: hmac('navette/enc/v1'),
  };
}

export function seal(encKey, payload, id = crypto.randomUUID()) {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', encKey, iv);
  cipher.setAAD(Buffer.from(id, 'utf8'));
  const plaintext = Buffer.from(JSON.stringify({ ...payload, t: Date.now() }), 'utf8');
  const data = Buffer.concat([cipher.update(plaintext), cipher.final(), cipher.getAuthTag()]);
  return { id, iv: iv.toString('base64'), data: data.toString('base64') };
}

export function open(encKey, { id, iv, data }) {
  const raw = Buffer.from(data, 'base64');
  const decipher = crypto.createDecipheriv('aes-256-gcm', encKey, Buffer.from(iv, 'base64'));
  decipher.setAAD(Buffer.from(id, 'utf8'));
  decipher.setAuthTag(raw.subarray(raw.length - 16));
  const plaintext = Buffer.concat([decipher.update(raw.subarray(0, raw.length - 16)), decipher.final()]);
  return JSON.parse(plaintext.toString('utf8'));
}
