import { spawn } from 'node:child_process';
import WebSocket from 'ws';

/** Lance un relais sur `port` avec les variables d'environnement données. */
export async function startServer(port, extraEnv) {
  const proc = spawn(process.execPath, ['src/index.js'], {
    env: { ...process.env, PORT: String(port), NAVETTE_TOKEN: '', NAVETTE_OPEN: '', ...extraEnv },
    stdio: ['ignore', 'pipe', 'inherit'],
  });
  // On continue de vider stdout après le démarrage, sinon le serveur prend un EPIPE.
  await new Promise((resolve) => {
    proc.stdout.on('data', (chunk) => {
      if (chunk.toString().includes('écoute')) resolve();
    });
  });
  return proc;
}

export function connect(port, device, token) {
  return new WebSocket(`ws://127.0.0.1:${port}/ws`, {
    headers: { Authorization: `Bearer ${token}`, 'X-Navette-Device': device },
  });
}
