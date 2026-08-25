#!/usr/bin/env node
// probe.mjs — 触发一次新的 CDP 连接，用于测试 auto-allow watcher 是否生效。
// 用法:
//   node probe.mjs                 # 自动从 Edge/Chrome 默认用户数据目录读 DevToolsActivePort
//   node probe.mjs <port> <path>   # 手动指定，如 node probe.mjs 9222 /devtools/browser/xxxx
// 预期: 弹出 "Allow remote debugging?" 后几秒内被 watcher 自动点掉，
//       本脚本打印 WS OPEN + Browser.getVersion 回复即成功。
import { readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';

const ts = () => new Date().toISOString().slice(11, 23);

async function discover() {
  const [portArg, pathArg] = process.argv.slice(2);
  if (portArg && pathArg) return { port: Number(portArg), path: pathArg };
  const local = process.env.LOCALAPPDATA ?? join(homedir(), 'AppData', 'Local');
  const candidates = [
    join(local, 'Microsoft/Edge/User Data/DevToolsActivePort'),
    join(local, 'Google/Chrome/User Data/DevToolsActivePort'),
  ];
  for (const f of candidates) {
    try {
      const [port, path] = (await readFile(f, 'utf8')).split('\n');
      return { port: Number(port), path: path.trim() };
    } catch { /* try next */ }
  }
  throw new Error('DevToolsActivePort not found — pass <port> <path> manually');
}

const { port, path } = await discover();
console.log(`[${ts()}] target: ws://127.0.0.1:${port}${path}`);

const ws = new WebSocket(`ws://127.0.0.1:${port}${path}`);
const timer = setTimeout(() => {
  console.log(`[${ts()}] !! 20s TIMEOUT — dialog not auto-accepted (watcher not running?)`);
  process.exit(2);
}, 20000);

ws.onopen = () => {
  console.log(`[${ts()}] WS OPEN — sending Browser.getVersion`);
  ws.send(JSON.stringify({ id: 1, method: 'Browser.getVersion' }));
};
ws.onmessage = (ev) => {
  console.log(`[${ts()}] WS REPLY: ${String(ev.data).slice(0, 200)}`);
  console.log(`[${ts()}] ✓ SUCCESS — remote debugging authorized`);
  clearTimeout(timer);
  setTimeout(() => process.exit(0), 300);
};
ws.onerror = (e) => console.log(`[${ts()}] WS ERROR: ${e.message || e}`);
ws.onclose = (e) =>
  console.log(`[${ts()}] WS CLOSE code=${e.code} reason="${e.reason}"`);
