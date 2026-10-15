#!/usr/bin/env node
"use strict";

// Author the vector master, then export every shipped raster from that one source.
// The website already includes Sharp through Next.js; NODE_PATH can supply it too.
const fs = require("node:fs/promises");
const path = require("node:path");
let sharp;
try {
  sharp = require("../website/node_modules/sharp");
} catch {
  try {
    sharp = require("sharp");
  } catch {
    console.error("Sharp is required. Run npm ci in website, then run this script again.");
    process.exit(1);
  }
}

const root = path.resolve(__dirname, "..");
const source = path.join(root, "Resources/Brand/FocusStudioIcon.svg");
const exportsToWrite = [
  ["Resources/Brand/FocusStudioIcon.png", 1024],
  ["website/public/icons/focus-studio.png", 1024],
  ["website/public/icons/icon-192.png", 192],
  ["website/public/icons/icon-512.png", 512],
  ["desktop/build/icon.png", 512],
];

async function main() {
  const svg = await fs.readFile(source);
  for (const [filename, size] of exportsToWrite) {
    const destination = path.join(root, filename);
    await fs.mkdir(path.dirname(destination), { recursive: true });
    // libvips/librsvg rasterizes at the target size, preserving precise vector edges.
    await sharp(svg, { density: (72 * size) / 1024 })
      .resize(size, size)
      .png({ compressionLevel: 9, adaptiveFiltering: true })
      .toFile(destination);
    console.log(`Exported ${filename} (${size} × ${size})`);
  }
  for (const filename of ["website/public/icons/focus-studio.svg", "website/public/favicon.svg"]) {
    await fs.writeFile(path.join(root, filename), svg);
    console.log(`Synced ${filename}`);
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
