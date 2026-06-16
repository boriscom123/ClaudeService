const https = require('https');
const fs = require('fs');
const path = require('path');
const config = require('../config');

const ATTACHMENTS_DIR = '/attachments';

function downloadFile(url, destPath) {
  return new Promise((resolve, reject) => {
    const file = fs.createWriteStream(destPath);
    https.get(url, res => {
      res.pipe(file);
      file.on('finish', () => file.close(() => resolve(destPath)));
    }).on('error', err => {
      fs.unlink(destPath, () => {});
      reject(err);
    });
  });
}

async function downloadPhoto(message) {
  if (!message.photo && !message.video && !message.document) return null;

  try {
    fs.mkdirSync(ATTACHMENTS_DIR, { recursive: true });

    let fileId, ext;
    if (message.photo) {
      const largest = message.photo[message.photo.length - 1];
      fileId = largest.file_id;
      ext = 'jpg';
    } else if (message.video) {
      fileId = message.video.file_id;
      ext = 'mp4';
    } else {
      fileId = message.document.file_id;
      ext = path.extname(message.document.file_name || '.bin').slice(1) || 'bin';
    }

    const infoUrl = `https://api.telegram.org/bot${config.token}/getFile?file_id=${fileId}`;
    const info = await new Promise((resolve, reject) => {
      https.get(infoUrl, res => {
        let data = '';
        res.on('data', c => data += c);
        res.on('end', () => resolve(JSON.parse(data)));
      }).on('error', reject);
    });

    if (!info.ok) return null;

    const filePath = info.result.file_path;
    const fileName = `${fileId.slice(-16)}.${ext}`;
    const destPath = path.join(ATTACHMENTS_DIR, fileName);
    const downloadUrl = `https://api.telegram.org/file/bot${config.token}/${filePath}`;

    await downloadFile(downloadUrl, destPath);
    return destPath;
  } catch (e) {
    console.error('[downloader] Ошибка скачивания:', e.message);
    return null;
  }
}

module.exports = { downloadPhoto };
