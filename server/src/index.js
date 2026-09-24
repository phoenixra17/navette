// Navette — relais presse-papier.
//
// Le serveur ne voit jamais le contenu : les clients chiffrent en AES-256-GCM avec une clé
// dérivée d'un secret que seuls le Mac et le téléphone connaissent. Il ne reçoit que le
// jeton d'accès (dérivé du même secret, mais à sens unique) et relaie des blobs opaques.
//
//   GET  /api/health          → { ok: true, open }                   (sans authentification)
//   POST /api/clip            → envoie un élément aux autres appareils du salon
//   GET  /api/clip/last       → dernier presse-papier reçu (pour rattraper après une coupure)
//   GET  /api/devices         → appareils connectés au salon
//   WS   /ws                  → reçoit les éléments en direct, peut aussi en envoyer
//
// Authentification : en-tête « Authorization: Bearer <jeton> ».
// Identité de l'appareil : en-tête « X-Navette-Device: <nom> » (ex. mac, s24).
//
// Salons : chaque jeton a son salon. Les appareils appairés entre eux partagent le même jeton,
// donc ne voient que leurs propres éléments. Deux modes :
//   - privé (NAVETTE_TOKEN=<jeton>[,<jeton>…]) : seuls les jetons listés sont acceptés ;
//   - ouvert (NAVETTE_OPEN=1) : tout jeton bien formé ouvre son salon, pour héberger un relais
//     partagé (testeurs, VPS). Les limites ci-dessous protègent alors le serveur.
//
// Un élément marqué « ephemeral: true » (notification, batterie, sonnerie…) est relayé mais
// n'écrase pas le dernier presse-papier gardé pour /api/clip/last.

import http from 'node:http';
import crypto from 'node:crypto';
import { WebSocketServer } from 'ws';

const env = (name, fallback) => Number(process.env[name] || fallback);

const PORT = env('PORT', 3200);
const OPEN = ['1', 'true', 'oui'].includes(String(process.env.NAVETTE_OPEN || '').toLowerCase());
const TOKENS = String(process.env.NAVETTE_TOKEN || '').split(',').map((t) => t.trim()).filter(Boolean);
// Les images (captures d’écran) passent aussi : chiffrées et en base64, compter ~1,8× leur taille.
const MAX_BYTES = env('NAVETTE_MAX_BYTES', 16 * 1024 * 1024);
const MAX_ROOMS = env('NAVETTE_MAX_ROOMS', 1000);
const MAX_DEVICES = env('NAVETTE_MAX_DEVICES', 8);
// Par salon et par minute : largement au-dessus d'un usage normal, même avec des rafales de notifications.
const RATE_MESSAGES = env('NAVETTE_RATE_MESSAGES', 300);
const RATE_BYTES = env('NAVETTE_RATE_MB', 100) * 1024 * 1024;
// Mémoire totale des derniers presse-papiers gardés ; au-delà, les plus anciens sont oubliés.
const STORE_BYTES = env('NAVETTE_STORE_MB', 256) * 1024 * 1024;
const LAST_TTL_MS = env('NAVETTE_LAST_HOURS', 24) * 3600_000;
const PING_MS = 25_000;
// Jeton produit par les apps : HMAC-SHA256 en base64url sans remplissage.
const TOKEN_FORMAT = /^[A-Za-z0-9_-]{43}$/;

if (!OPEN && (TOKENS.length === 0 || TOKENS.some((t) => t.length < 32))) {
  console.error('NAVETTE_TOKEN manquant ou trop court (copiez-le depuis le menu de l’app Mac),'
    + ' ou NAVETTE_OPEN=1 pour un relais partagé.');
  process.exit(1);
}

const digestOf = (token) => crypto.createHash('sha256').update(token).digest();
const allowed = TOKENS.map(digestOf);

/** Clé du salon (empreinte du jeton, jamais le jeton lui-même), ou null si refusé. */
function roomKeyOf(req) {
  const header = req.headers.authorization || '';
  const given = header.startsWith('Bearer ') ? header.slice(7).trim() : '';
  const digest = digestOf(given);
  if (OPEN) return TOKEN_FORMAT.test(given) ? digest.toString('hex') : null;
  let ok = false;
  for (const candidate of allowed) ok = crypto.timingSafeEqual(digest, candidate) || ok;
  return ok ? digest.toString('hex') : null;
}

function deviceOf(req) {
  const raw = String(req.headers['x-navette-device'] || 'inconnu');
  return raw.replace(/[^\w.-]/g, '').slice(0, 40) || 'inconnu';
}

/**
 * @typedef {{ key: string, name: string, sockets: Set<any>, last: string | null, lastAt: number,
 *             windowStart: number, messages: number, bytes: number }} Room
 * @type {Map<string, Room>}
 */
const rooms = new Map();
/** Salons qui gardent un dernier presse-papier, du plus ancien au plus récent. */
const stored = new Set();
let storedBytes = 0;

/** Renvoie le salon, en le créant si besoin ; null si le serveur est plein. */
function roomFor(key) {
  let room = rooms.get(key);
  if (room) return room;
  if (rooms.size >= MAX_ROOMS) return null;
  room = { key, name: key.slice(0, 6), sockets: new Set(), last: null, lastAt: 0, windowStart: 0, messages: 0, bytes: 0 };
  rooms.set(key, room);
  return room;
}

function forgetLast(room) {
  if (!room.last) return;
  storedBytes -= room.last.length;
  stored.delete(room);
  room.last = null;
}

function keepLast(room, message) {
  forgetLast(room);
  room.last = message;
  room.lastAt = Date.now();
  stored.add(room);
  storedBytes += message.length;
  for (const oldest of stored) {
    if (storedBytes <= STORE_BYTES) break;
    forgetLast(oldest);
  }
}

/** Compte l'élément dans la fenêtre d'une minute du salon ; false si la limite est dépassée. */
function withinRate(room, size) {
  const now = Date.now();
  if (now - room.windowStart >= 60_000) {
    room.windowStart = now;
    room.messages = 0;
    room.bytes = 0;
  }
  room.messages++;
  room.bytes += size;
  return room.messages <= RATE_MESSAGES && room.bytes <= RATE_BYTES;
}

function validClip(body) {
  return body
    && typeof body.id === 'string' && body.id.length <= 64
    && typeof body.iv === 'string' && body.iv.length <= 64
    && typeof body.data === 'string' && body.data.length > 0 && body.data.length <= MAX_BYTES;
}

function relay(room, clip, from) {
  const message = JSON.stringify({
    type: 'clip',
    id: clip.id,
    iv: clip.iv,
    data: clip.data,
    from,
    at: Date.now(),
  });
  if (clip.ephemeral !== true) keepLast(room, message);
  let delivered = 0;
  for (const ws of room.sockets) {
    if (ws.device === from || ws.readyState !== ws.OPEN) continue;
    ws.send(message);
    delivered++;
  }
  if (process.env.NAVETTE_VERBOSE || (!OPEN && clip.ephemeral !== true)) {
    log(room, `élément ${clip.id.slice(0, 8)} de ${from} (${clip.data.length} o) → ${delivered} appareil(s)`);
  }
  return delivered;
}

function log(room, msg) {
  // En mode privé, un seul salon : inutile d'encombrer le journal avec son nom.
  const prefix = OPEN && room ? `[${room.name}] ` : '';
  console.log(`${new Date().toISOString()} ${prefix}${msg}`);
}

function send(res, status, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
  });
  res.end(body);
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_BYTES) {
        reject(Object.assign(new Error('trop volumineux'), { status: 413 }));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')));
      } catch {
        reject(Object.assign(new Error('JSON invalide'), { status: 400 }));
      }
    });
    req.on('error', reject);
  });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');

  if (url.pathname === '/api/health') return send(res, 200, { ok: true, open: OPEN });
  const key = roomKeyOf(req);
  if (!key) return send(res, 401, { error: 'Jeton invalide' });

  try {
    if (req.method === 'POST' && url.pathname === '/api/clip') {
      const body = await readJson(req);
      if (!validClip(body)) return send(res, 400, { error: 'Élément invalide' });
      const room = roomFor(key);
      if (!room) return send(res, 503, { error: 'Relais complet' });
      if (!withinRate(room, body.data.length)) return send(res, 429, { error: 'Trop d’envois, réessayez dans une minute' });
      const delivered = relay(room, body, deviceOf(req));
      return send(res, 200, { ok: true, delivered });
    }
    if (req.method === 'GET' && url.pathname === '/api/clip/last') {
      const last = rooms.get(key)?.last;
      if (!last) return send(res, 204, {});
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
      return res.end(last);
    }
    if (req.method === 'GET' && url.pathname === '/api/devices') {
      const sockets = rooms.get(key)?.sockets ?? [];
      return send(res, 200, { devices: [...sockets].map((ws) => ws.device) });
    }
    return send(res, 404, { error: 'Route introuvable' });
  } catch (err) {
    return send(res, err.status || 500, { error: err.message });
  }
});

const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_BYTES });

function refuse(socket, status) {
  socket.write(`HTTP/1.1 ${status}\r\nConnection: close\r\n\r\n`);
  socket.destroy();
}

server.on('upgrade', (req, socket, head) => {
  const url = new URL(req.url, 'http://localhost');
  const key = url.pathname === '/ws' ? roomKeyOf(req) : null;
  if (!key) return refuse(socket, '401 Unauthorized');
  const room = roomFor(key);
  if (!room) return refuse(socket, '503 Service Unavailable');
  const device = deviceOf(req);
  const others = [...room.sockets].filter((ws) => ws.device !== device);
  if (others.length >= MAX_DEVICES) return refuse(socket, '403 Forbidden');

  wss.handleUpgrade(req, socket, head, (ws) => {
    ws.device = device;
    ws.alive = true;
    // Un appareil qui se reconnecte remplace son ancienne connexion (dans son salon seulement).
    for (const other of room.sockets) {
      if (other.device === ws.device) other.terminate();
    }
    room.sockets.add(ws);
    log(room, `${ws.device} connecté (${room.sockets.size} dans le salon, ${rooms.size} salon(s))`);

    ws.on('pong', () => { ws.alive = true; });
    ws.on('message', (raw) => {
      let msg;
      try { msg = JSON.parse(raw.toString('utf8')); } catch { return; }
      if (msg.type !== 'clip' || !validClip(msg)) return;
      if (!withinRate(room, msg.data.length)) {
        if (room.messages === RATE_MESSAGES + 1) log(room, 'limite d’envois atteinte, éléments ignorés');
        return;
      }
      relay(room, msg, ws.device);
    });
    ws.on('close', () => {
      room.sockets.delete(ws);
      log(room, `${ws.device} déconnecté (${room.sockets.size} dans le salon)`);
    });
  });
});

const heartbeat = setInterval(() => {
  const now = Date.now();
  for (const room of rooms.values()) {
    for (const ws of room.sockets) {
      if (!ws.alive) { ws.terminate(); continue; }
      ws.alive = false;
      ws.ping();
    }
    if (room.last && now - room.lastAt > LAST_TTL_MS) forgetLast(room);
    if (room.sockets.size === 0 && !room.last) rooms.delete(room.key);
  }
}, PING_MS);

server.on('close', () => clearInterval(heartbeat));

server.listen(PORT, () => log(null, `Navette à l’écoute sur le port ${PORT} (mode ${OPEN ? 'ouvert' : 'privé'})`));

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    for (const room of rooms.values()) {
      for (const ws of room.sockets) ws.close(1001, 'arrêt');
    }
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 2000).unref();
  });
}
