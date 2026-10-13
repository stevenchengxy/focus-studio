'use strict';
const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
(async () => {
  const directory = path.join(__dirname, '..', 'dist');
  const files = (await fs.readdir(directory)).filter(file => /\.(exe|AppImage|deb)$/.test(file)).sort();
  if (!files.length) throw new Error('No installers were built.');
  const lines = await Promise.all(files.map(async file => `${crypto.createHash('sha256').update(await fs.readFile(path.join(directory, file))).digest('hex')}  ${file}`));
  await fs.writeFile(path.join(directory, 'SHA256SUMS.txt'), lines.join('\n') + '\n');
  console.log(`Checksums written for ${files.length} installer(s).`);
})().catch(error => { console.error(error.message); process.exitCode = 1; });
