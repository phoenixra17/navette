import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import crypto from 'node:crypto';
import { deriveKeys, seal, open } from './protocol.js';
import { startServer, connect as connectTo } from './helpers.js';

const PORT = 3299;
const BASE = `http://127.0.0.1:${PORT}`;
const SECRET = 'q3l2m9d1Xv0kPZ3n4wYtR8sE5uA7bC6fGhJiKlMnOpQ';
const { token, encKey } = deriveKeys(SECRET);
let proc;

before(async () => {
  proc = await startServer(PORT, { NAVETTE_TOKEN: token });
});

after(() => proc.kill());

function connect(device, authToken = token) {
  return connectTo(PORT, device, authToken);
}

test('health sans jeton', async () => {
  const res = await fetch(`${BASE}/api/health`);
  assert.equal(res.status, 200);
});

test('refuse un mauvais jeton', async () => {
  const res = await fetch(`${BASE}/api/devices`, { headers: { Authorization: 'Bearer nope' } });
  assert.equal(res.status, 401);
  const ws = connect('intrus', 'mauvais');
  const [err] = await once(ws, 'error');
  assert.match(err.message, /401/);
});

test('relaie un élément chiffré vers les autres appareils, pas vers l’émetteur', async () => {
  const mac = connect('mac');
  const phone = connect('s24');
  await Promise.all([once(mac, 'open'), once(phone, 'open')]);

  let echoed = false;
  mac.on('message', () => { echoed = true; });

  const clip = seal(encKey, { kind: 'text', text: 'Bonjour depuis le Mac 👋' });
  const received = once(phone, 'message');
  mac.send(JSON.stringify({ type: 'clip', ...clip }));

  const [raw] = await received;
  const msg = JSON.parse(raw.toString());
  assert.equal(msg.from, 'mac');
  assert.deepEqual(open(encKey, msg).text, 'Bonjour depuis le Mac 👋');
  await new Promise((r) => setTimeout(r, 100));
  assert.equal(echoed, false, 'l’émetteur ne reçoit pas son propre élément');
  mac.removeAllListeners('message');

  // Envoi HTTP depuis le téléphone → le Mac le reçoit.
  const reply = seal(encKey, { kind: 'text', text: 'Réponse du S24' });
  const toMac = once(mac, 'message');
  const res = await fetch(`${BASE}/api/clip`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'X-Navette-Device': 's24', 'Content-Type': 'application/json' },
    body: JSON.stringify(reply),
  });
  assert.deepEqual(await res.json(), { ok: true, delivered: 1 });
  const [raw2] = await toMac;
  assert.equal(open(encKey, JSON.parse(raw2.toString())).text, 'Réponse du S24');

  const lastRes = await fetch(`${BASE}/api/clip/last`, { headers: { Authorization: `Bearer ${token}` } });
  assert.equal(open(encKey, await lastRes.json()).text, 'Réponse du S24');

  mac.close();
  phone.close();
});

test('un contenu altéré est rejeté au déchiffrement', () => {
  const clip = seal(encKey, { kind: 'text', text: 'secret' });
  const tampered = { ...clip, id: 'autre-id' };
  assert.throws(() => open(encKey, tampered));
});

test('relaie une grosse image (≈ 5 Mo) par WebSocket et par HTTP', async () => {
  const mac = connect('mac');
  const phone = connect('s24');
  await Promise.all([once(mac, 'open'), once(phone, 'open')]);
  const image = crypto.randomBytes(5 * 1024 * 1024).toString('base64');
  const clip = seal(encKey, { kind: 'image', mime: 'image/png', data: image });

  const received = once(phone, 'message');
  mac.send(JSON.stringify({ type: 'clip', ...clip }));
  const [raw] = await received;
  assert.equal(open(encKey, JSON.parse(raw.toString())).data, image);

  const toMac = once(mac, 'message');
  const res = await fetch(`${BASE}/api/clip`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'X-Navette-Device': 's24', 'Content-Type': 'application/json' },
    body: JSON.stringify(clip),
  });
  assert.equal(res.status, 200);
  const [raw2] = await toMac;
  assert.equal(open(encKey, JSON.parse(raw2.toString())).mime, 'image/png');
  mac.close();
  phone.close();
});

test('un élément éphémère est relayé sans remplacer le dernier presse-papier', async () => {
  const mac = connect('mac');
  const phone = connect('s24');
  await Promise.all([once(mac, 'open'), once(phone, 'open')]);
  const clip = seal(encKey, { kind: 'text', text: 'presse-papier' });
  const got1 = once(phone, 'message');
  mac.send(JSON.stringify({ type: 'clip', ...clip }));
  await got1;

  const event = seal(encKey, { kind: 'battery', level: 42, charging: false });
  const got2 = once(mac, 'message');
  phone.send(JSON.stringify({ type: 'clip', ephemeral: true, ...event }));
  const [raw] = await got2;
  assert.equal(open(encKey, JSON.parse(raw.toString())).level, 42);

  const lastRes = await fetch(`${BASE}/api/clip/last`, { headers: { Authorization: `Bearer ${token}` } });
  assert.equal(open(encKey, await lastRes.json()).text, 'presse-papier');
  mac.close();
  phone.close();
});
