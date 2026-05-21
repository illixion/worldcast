#!/usr/bin/env node
// Pure-Node PNG icon generator. No external deps — just zlib + Buffer math.
// Produces solid-color tiles with a centered "W" glyph, written to public/icons/.

import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { deflateSync, crc32 } from 'node:zlib';

const __dirname = dirname(fileURLToPath(import.meta.url));
const OUT = resolve(__dirname, '..', 'public', 'icons');
mkdirSync(OUT, { recursive: true });

// Hand-drawn 12x12 "W" mask (1 = ink, 0 = bg). Will be scaled with nearest-neighbour.
const W = [
  '100000000001',
  '100000000001',
  '100000000001',
  '100000000001',
  '100000000001',
  '100010001001',
  '100010001001',
  '100101010001',
  '100101010001',
  '110100010011',
  '011000000110',
  '001000000100',
];

const BG = [0x12, 0x12, 0x14];
const FG = [0xff, 0x6b, 0x35];

function makeIcon(size) {
  const stride = size * 3;
  const pixels = Buffer.alloc(stride * size);
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const o = y * stride + x * 3;
      pixels[o]     = BG[0];
      pixels[o + 1] = BG[1];
      pixels[o + 2] = BG[2];
    }
  }
  const glyphSize = Math.floor(size * 0.62);
  const x0 = Math.floor((size - glyphSize) / 2);
  const y0 = Math.floor((size - glyphSize) / 2);
  const scale = glyphSize / W[0].length;
  for (let gy = 0; gy < W.length; gy++) {
    for (let gx = 0; gx < W[0].length; gx++) {
      if (W[gy][gx] === '0') continue;
      const px0 = x0 + Math.floor(gx * scale);
      const py0 = y0 + Math.floor(gy * scale);
      const pxN = x0 + Math.floor((gx + 1) * scale);
      const pyN = y0 + Math.floor((gy + 1) * scale);
      for (let py = py0; py < pyN; py++) {
        for (let px = px0; px < pxN; px++) {
          const o = py * stride + px * 3;
          pixels[o]     = FG[0];
          pixels[o + 1] = FG[1];
          pixels[o + 2] = FG[2];
        }
      }
    }
  }
  return encodePng(size, size, pixels);
}

function encodePng(width, height, rgb) {
  const sig = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8;  // bit depth
  ihdr[9] = 2;  // colour type 2 (truecolor RGB)
  ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;

  // Add filter byte 0 at the start of each scanline.
  const stride = width * 3;
  const raw = Buffer.alloc((stride + 1) * height);
  for (let y = 0; y < height; y++) {
    raw[y * (stride + 1)] = 0;
    rgb.copy(raw, y * (stride + 1) + 1, y * stride, y * stride + stride);
  }
  const idatData = deflateSync(raw, { level: 9 });

  return Buffer.concat([
    sig,
    chunk('IHDR', ihdr),
    chunk('IDAT', idatData),
    chunk('IEND', Buffer.alloc(0))
  ]);
}

function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length, 0);
  const typeBuf = Buffer.from(type, 'ascii');
  const crcBuf = Buffer.alloc(4);
  crcBuf.writeUInt32BE(crc32(Buffer.concat([typeBuf, data])) >>> 0, 0);
  return Buffer.concat([len, typeBuf, data, crcBuf]);
}

for (const size of [180, 192, 512]) {
  const png = makeIcon(size);
  const path = join(OUT, `icon-${size}.png`);
  writeFileSync(path, png);
  console.log(`wrote ${path} (${png.length} bytes)`);
}
