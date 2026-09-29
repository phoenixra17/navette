import { test } from 'node:test';
import assert from 'node:assert/strict';
import { deriveKeys, seal, open, ReplayGuard, MAX_AGE_MS, localProof, sealBinary, openBinary } from './protocol.js';

// Mêmes vecteurs que mac/Tests/NavetteTests/CryptoTests.swift et NavetteCryptoTest.kt.
const SECRET = 'q3l2m9d1Xv0kPZ3n4wYtR8sE5uA7bC6fGhJiKlMnOpQ';
const keys = deriveKeys(SECRET);

test('jeton et empreinte de référence', () => {
  assert.equal(keys.token, 'Jv5bGo1CghHCCO7ugYKeymbfe7oZz08o42kCTc3GPWY');
  assert.equal(keys.fingerprint, '887 085');
});

test('v2 : un élément ne s’ouvre qu’avec le rôle de son expéditeur (pas de renvoi à l’envoyeur)', () => {
  const fromMac = seal(keys.encKey, { kind: 'ring' }, undefined, 'mac');
  assert.equal(open(keys.encKey, fromMac, 'mac').kind, 'ring');
  assert.throws(() => open(keys.encKey, fromMac, 'phone'));
  const fromPhone = seal(keys.encKey, { kind: 'text', text: 'x' }, undefined, 'phone');
  assert.throws(() => open(keys.encKey, fromPhone, 'mac'));
});

test('v2 : les vecteurs du téléphone et du Mac s’ouvrent', () => {
  const phoneText = { id: 'vecteur-1', iv: 'giZdjdbUFijiLaTs', data: 'hOnL6bx+Xs/mP7P9vfMTHfmPVoSrMLOyEH0TVDqwwu2trPtOdIpUWv6dhwExdsNQ/tkjXzBHVx7uloS3npgE88PF0+b4t5G3KxVpRtLy' };
  const macText = { id: 'vecteur-1', iv: 'WYec3cCDeuT2QEv+', data: 'WWWKLCs6C7yifCeuctCL41nkxLSQvDBYeOZhdBnPrWwBx98p4NxmyX78NkrngiM550nlv9CGxgSD9DxlNzEhIjUV9FCqGgMNWvMCA7BO' };
  assert.equal(open(keys.encKey, phoneText, 'phone').text, 'Héllo 👋 Navette');
  assert.equal(open(keys.encKey, macText, 'mac').text, 'Héllo 👋 Navette');
});

test('anti-rejeu : un id n’est accepté qu’une fois, et seulement s’il est récent', () => {
  const guard = new ReplayGuard();
  const now = Date.now();
  assert.equal(guard.accept('a', now, now), true);
  assert.equal(guard.accept('a', now, now), false, 'rejeu du même id');
  assert.equal(guard.accept('b', now - MAX_AGE_MS - 1, now), false, 'trop ancien');
  assert.equal(guard.accept('c', now + MAX_AGE_MS + 1, now), false, 'trop dans le futur');
  assert.equal(guard.accept('d', undefined, now), false, 'sans horodatage');
  assert.equal(guard.accept('e', now - 60_000, now), true, 'une minute de décalage d’horloge passe');
});

test('liaison locale : identifiant et preuves de référence', () => {
  assert.equal(keys.localId, '40887ecd84b3');
  const macNonce = 'bWFjLW5vbmNl';
  const phoneNonce = 'cGhvbmUtbm9uY2U=';
  assert.equal(localProof(keys.localKey, 'phone', macNonce, phoneNonce), 'BC1+z0iTeOIAbQ28jAHhtnR00orTsTHKlQlVMIWM/P0=');
  assert.equal(localProof(keys.localKey, 'mac', macNonce, phoneNonce), 'EusgLaWSRbBDltrLYEArMN58ELg5q44KIAVxJd5nubE=');
  assert.notEqual(localProof(keys.localKey, 'mac', phoneNonce, macNonce), localProof(keys.localKey, 'mac', macNonce, phoneNonce));
});

test('morceaux binaires : vecteur de référence, rôles et données associées séparés', () => {
  const box = Buffer.from('kPxGVlEPxme7U89aWoEcmUdfL9BccFQahZXH+HfoapHETk8wLVAPesK5TCgqXULFMxJkk/Oxn7IRB5N+ogyXCpFOKClRbexALD6GvtSAuyGWsKoUyN+uFllGlPxBia1Sr3Cl+J61sVxh+xcvfWNkQPtoblc=', 'base64');
  const chunk = { id: 'vecteur-binaire', iv: Buffer.from('000102030405060708090a0b', 'hex'), box };
  const { meta, bytes } = openBinary(keys.encKey, chunk, 'phone');
  assert.equal(meta.name, 'é.bin');
  assert.equal(meta.t, 1790000000000);
  assert.deepEqual([...bytes], [0, 1, 2, 250, 251, 255]);
  assert.throws(() => openBinary(keys.encKey, chunk, 'mac'), 'renvoyé à son expéditeur');
  // Un bloc binaire ne se déchiffre pas comme un élément JSON, ni l'inverse.
  const asClip = { id: chunk.id, iv: chunk.iv.toString('base64'), data: box.toString('base64') };
  assert.throws(() => open(keys.encKey, asClip, 'phone'));
  const clip = seal(keys.encKey, { kind: 'text', text: 'x' }, 'id-json', 'phone');
  assert.throws(() => openBinary(keys.encKey, { id: clip.id, iv: Buffer.from(clip.iv, 'base64'), box: Buffer.from(clip.data, 'base64') }, 'phone'));
  const empty = sealBinary(keys.encKey, { kind: 'file' }, Buffer.alloc(0), 'vide', 'mac');
  assert.equal(openBinary(keys.encKey, empty, 'mac').bytes.length, 0);
});
