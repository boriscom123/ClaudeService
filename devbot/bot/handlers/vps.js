const fs = require('fs');
const http = require('http');
const { execSync } = require('child_process');

function dockerRequest(path) {
  return new Promise((resolve, reject) => {
    const req = http.request(
      { socketPath: '/var/run/docker.sock', path, method: 'GET' },
      res => { let d = ''; res.on('data', c => d += c); res.on('end', () => { try { resolve(JSON.parse(d)); } catch { resolve([]); } }); }
    );
    req.on('error', reject);
    req.end();
  });
}

async function getVpsStatus() {
  const uptimeSec = parseFloat(fs.readFileSync('/proc/uptime', 'utf8').split(' ')[0]);
  const d = Math.floor(uptimeSec / 86400), h = Math.floor((uptimeSec % 86400) / 3600), m = Math.floor((uptimeSec % 3600) / 60);
  const uptime = d > 0 ? `${d}д ${h}ч ${m}м` : `${h}ч ${m}м`;
  const load = fs.readFileSync('/proc/loadavg', 'utf8').split(' ').slice(0, 3).join(' ');
  const mem = fs.readFileSync('/proc/meminfo', 'utf8');
  const total = parseInt(mem.match(/MemTotal:\s+(\d+)/)[1]);
  const avail = parseInt(mem.match(/MemAvailable:\s+(\d+)/)[1]);
  const used = total - avail;
  const toMb = kb => Math.round(kb / 1024);

  let disk = '—';
  try {
    const parts = execSync('df -h / --output=size,used,avail,pcent 2>/dev/null').toString().trim().split('\n')[1]?.trim().split(/\s+/);
    if (parts) disk = `${parts[1]}/${parts[0]} (${parts[3]})`;
  } catch {}

  let containers = '❓ Docker недоступен';
  try {
    const ctrs = await dockerRequest('/containers/json?all=true');
    containers = ctrs.map(c => `${c.State === 'running' ? '🟢' : '🔴'} ${c.Names[0].replace('/', '')}`).join('\n') || '(нет)';
  } catch {}

  return `<b>💻 Статус VPS</b>\n\n⏱ Uptime: ${uptime}\n⚡ Load: ${load}\n🧠 RAM: ${toMb(used)}/${toMb(total)} МБ (${Math.round(used/total*100)}%)\n💾 Диск: ${disk}\n\n<b>Контейнеры:</b>\n${containers}`;
}

module.exports = { getVpsStatus };
