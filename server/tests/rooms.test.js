import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import crypto from 'node:crypto';
import { deriveKeys, seal, open } from './protocol.js';
import { startServer, connect } from './helpers.js';

const OPEN_PORT = 3298;
const PRIVATE_PORT = 3297;
const SMALL_PORT = 3296;
const BASE = `http://127.0.0.1:${OPEN_PORT}`;
const newPair = () => deriveKeys(crypto.randomBytes(32).toString('base64url'));
const alice = newPair();
const bob = newPair();
let openServer;
let privateServer;
let smallServer;

before(async () => {
  [openServer, privateServer, smallServer] = await Promise.all([
    startServer(OPEN_PORT, { NAVETTE_OPEN: '1', NAVETTE_MAX_DEVICES: '3', NAVETTE_RATE_MESSAGES: '20', NAVETTE_STORE_MB: '0.002' }),
    startServer(PRIVATE_PORT, { NAVETTE_TOKEN: `${alice.token},${bob.token}` }),
    startServer(SMALL_PORT, { NAVETTE_OPEN: '1', NAVETTE_MAX_ROOMS: '2' }),
  ]);
});

after(() => {
  openServer.kill();
  privateServer.kill();
  smallServer.kill();
});

const post = (token, clip, port = OPEN_PORT) => fetch(`http://127.0.0.1:${port}/api/clip`, {
  method: 'POST',
  headers: { Authorization: `Bearer ${token}`, 'X-Navette-Device': 's24', 'Content-Type': 'application/json' },
  body: JSON.stringify(clip),
});
const pause = (ms) => new Promise((r) => setTimeout(r, ms));

test('mode ouvert : l’état de santé l’annonce', async () => {
  assert.deepEqual(await (await fetch(`${BASE}/api/health`)).json(), { ok: true, open: true });
});

test('mode ouvert : un jeton mal formé est refusé', async () => {
  const res = await fetch(`${BASE}/api/devices`, { headers: { Authorization: 'Bearer court' } });
  assert.equal(res.status, 401);
  const [err] = await once(connect(OPEN_PORT, 'mac', 'x'.repeat(42)), 'error');
  assert.match(err.message, /401/);
});

test('mode ouvert : chaque jeton a son salon, isolé des autres', async () => {
  // Mêmes noms d’appareils dans les deux salons : l’un ne doit pas déconnecter l’autre.
  const aliceMac = connect(OPEN_PORT, 'mac', alice.token);
  const alicePhone = connect(OPEN_PORT, 's24', alice.token);
  const bobMac = connect(OPEN_PORT, 'mac', bob.token);
  await Promise.all([aliceMac, alicePhone, bobMac].map((ws) => once(ws, 'open')));

  let bobReceived = false;
  bobMac.on('message', () => { bobReceived = true; });
  const received = once(aliceMac, 'message');
  const res = await post(alice.token, seal(alice.encKey, { kind: 'text', text: 'pour Alice' }));
  assert.deepEqual(await res.json(), { ok: true, delivered: 1 });
  assert.equal(open(alice.encKey, JSON.parse((await received)[0].toString())).text, 'pour Alice');
  await pause(100);
  assert.equal(bobReceived, false, 'Bob ne reçoit rien du salon d’Alice');
  assert.equal(bobMac.readyState, bobMac.OPEN, 'le Mac de Bob reste connecté');

  const devices = async (token) => (await (await fetch(`${BASE}/api/devices`, {
    headers: { Authorization: `Bearer ${token}` },
  })).json()).devices.sort();
  assert.deepEqual(await devices(alice.token), ['mac', 's24']);
  assert.deepEqual(await devices(bob.token), ['mac']);

  const last = (token) => fetch(`${BASE}/api/clip/last`, { headers: { Authorization: `Bearer ${token}` } });
  assert.equal(open(alice.encKey, await (await last(alice.token)).json()).text, 'pour Alice');
  assert.equal((await last(bob.token)).status, 204, 'Bob n’a pas de dernier presse-papier');

  for (const ws of [aliceMac, alicePhone, bobMac]) ws.close();
});

test('mode ouvert : nombre d’appareils limité par salon', async () => {
  const pair = newPair();
  const sockets = ['a', 'b', 'c'].map((name) => connect(OPEN_PORT, name, pair.token));
  await Promise.all(sockets.map((ws) => once(ws, 'open')));
  const [err] = await once(connect(OPEN_PORT, 'd', pair.token), 'error');
  assert.match(err.message, /403/);
  // Un appareil déjà connu peut toujours se reconnecter (il remplace l’ancienne connexion).
  const again = connect(OPEN_PORT, 'a', pair.token);
  await once(again, 'open');
  for (const ws of [...sockets, again]) ws.close();
});

test('mode ouvert : trop d’envois en une minute → 429', async () => {
  const pair = newPair();
  const clip = seal(pair.encKey, { kind: 'text', text: 'rafale' });
  const statuses = [];
  for (let i = 0; i < 21; i++) statuses.push((await post(pair.token, clip)).status);
  assert.deepEqual(statuses.slice(0, 20), Array(20).fill(200));
  assert.equal(statuses[20], 429);
});

test('mode ouvert : au-delà du plafond mémoire, les plus anciens presse-papiers sont oubliés', async () => {
  // Plafond de ~2 Ko pour ce serveur de test : deux éléments de ~1,4 Ko n’y tiennent pas ensemble.
  const [first, second] = [newPair(), newPair()];
  const text = 'x'.repeat(900);
  assert.equal((await post(first.token, seal(first.encKey, { kind: 'text', text }))).status, 200);
  assert.equal((await post(second.token, seal(second.encKey, { kind: 'text', text }))).status, 200);
  const last = (token) => fetch(`${BASE}/api/clip/last`, { headers: { Authorization: `Bearer ${token}` } });
  assert.equal((await last(first.token)).status, 204);
  assert.equal(open(second.encKey, await (await last(second.token)).json()).text, text);
});

test('mode privé : plusieurs jetons autorisés, chacun dans son salon', async () => {
  const stranger = newPair();
  assert.equal((await post(stranger.token, seal(stranger.encKey, { kind: 'text', text: 'x' }), PRIVATE_PORT)).status, 401);

  const bobMac = connect(PRIVATE_PORT, 'mac', bob.token);
  await once(bobMac, 'open');
  const res = await post(alice.token, seal(alice.encKey, { kind: 'text', text: 'Alice' }), PRIVATE_PORT);
  assert.deepEqual(await res.json(), { ok: true, delivered: 0 }, 'rien ne part vers le salon de Bob');

  const received = once(bobMac, 'message');
  await post(bob.token, seal(bob.encKey, { kind: 'text', text: 'Bob' }), PRIVATE_PORT);
  assert.equal(open(bob.encKey, JSON.parse((await received)[0].toString())).text, 'Bob');
  bobMac.close();
});

test('une trame JSON qui n’est pas un objet (null, nombre, tableau…) est ignorée sans arrêter le relais', async () => {
  const pair = newPair();
  const attacker = connect(OPEN_PORT, 'x', newPair().token);
  const [mac, phone] = [connect(OPEN_PORT, 'mac', pair.token), connect(OPEN_PORT, 's24', pair.token)];
  await Promise.all([attacker, mac, phone].map((ws) => once(ws, 'open')));
  for (const frame of ['null', '1', '"x"', '[]', 'true', '{}', '{"type":"clip","id":null}']) attacker.send(frame);
  await pause(200);
  assert.equal(openServer.exitCode, null, 'le processus du relais tourne toujours');
  const received = once(phone, 'message');
  mac.send(JSON.stringify({ type: 'clip', ...seal(pair.encKey, { kind: 'text', text: 'toujours là' }) }));
  assert.equal(open(pair.encKey, JSON.parse((await received)[0].toString())).text, 'toujours là');
  for (const ws of [attacker, mac, phone]) ws.close();
});

test('relais plein : un salon sans appareil connecté cède sa place à un nouvel appairage', async () => {
  const post = (pair) => fetch(`http://127.0.0.1:${SMALL_PORT}/api/clip`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${pair.token}`, 'X-Navette-Device': 's24', 'Content-Type': 'application/json' },
    body: JSON.stringify(seal(pair.encKey, { kind: 'text', text: 'occupe une place' })),
  });
  // Deux salons « presse-papier seul », sans aucun appareil connecté : le relais est plein.
  const [a, b] = [newPair(), newPair()];
  assert.equal((await post(a)).status, 200);
  assert.equal((await post(b)).status, 200);
  // Un nouvel appairage prend quand même une place : le plus ancien salon inoccupé est libéré.
  const fresh = newPair();
  const ws = connect(SMALL_PORT, 'mac', fresh.token);
  await once(ws, 'open');
  const last = (pair) => fetch(`http://127.0.0.1:${SMALL_PORT}/api/clip/last`, { headers: { Authorization: `Bearer ${pair.token}` } });
  assert.equal((await last(a)).status, 204, 'le plus ancien salon inoccupé a été libéré');
  assert.equal((await last(b)).status, 200);
  // Des salons avec des appareils connectés ne sont jamais libérés : là, le relais est vraiment plein.
  const other = connect(SMALL_PORT, 'mac', newPair().token);
  await once(other, 'open');
  const [err] = await once(connect(SMALL_PORT, 'mac', newPair().token), 'error');
  assert.match(err.message, /503/);
  ws.close(); other.close();
});
