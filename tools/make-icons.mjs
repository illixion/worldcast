#!/usr/bin/env node
// Pure-Node PNG icon generator. No external deps — just zlib + Buffer math.
// Produces web/iOS tiles plus the separate background and foreground layers
// required by the visionOS solid-image-stack app icon.

import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { deflateSync, crc32 } from 'node:zlib';

const __dirname = dirname(fileURLToPath(import.meta.url));
const WEB_OUT = resolve(__dirname, '..', 'public', 'icons');
const IOS_OUT = resolve(__dirname, '..', 'Worldcast', 'Worldcast', 'Assets.xcassets', 'AppIcon.appiconset');
const VISION_OUT = resolve(__dirname, '..', 'Worldcast', 'Worldcast', 'Assets.xcassets', 'AppIcon.solidimagestack');
mkdirSync(WEB_OUT, { recursive: true });
mkdirSync(IOS_OUT, { recursive: true });

// Hand-drawn 12x12 "W" mask (1 = ink, 0 = bg). Will be scaled with nearest-neighbour.
const W = [
  '10000000001',
  '10000000001',
  '10000000001',
  '10000000001',
  '10000000001',
  '10001010001',
  '10001010001',
  '10010101001',
  '10010101001',
  '11010001011',
  '01100000110',
  '00100000100',
];

const BG = [0x12, 0x12, 0x14];
const FG = [0xff, 0x6b, 0x35];

function makeIcon(size) {
  const stride = size * 4;
  const pixels = Buffer.alloc(stride * size);
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const o = y * stride + x * 4;
      pixels[o]     = BG[0];
      pixels[o + 1] = BG[1];
      pixels[o + 2] = BG[2];
      pixels[o + 3] = 0xff;
    }
  }
  drawGlyph(pixels, size, FG);
  return encodePng(size, size, pixels, 4);
}

function makeVisionForeground(size) {
  const pixels = Buffer.alloc(size * size * 4);
  drawGlyph(pixels, size, FG);
  return encodePng(size, size, pixels, 4);
}

function makeVisionBackground(size) {
  const pixels = Buffer.alloc(size * size * 4);
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const o = (y * size + x) * 4;
      pixels[o] = BG[0];
      pixels[o + 1] = BG[1];
      pixels[o + 2] = BG[2];
      pixels[o + 3] = 0xff;
    }
  }
  return encodePng(size, size, pixels, 4);
}

function drawGlyph(pixels, size, color) {
  const stride = size * 4;
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
          const o = py * stride + px * 4;
          pixels[o]     = color[0];
          pixels[o + 1] = color[1];
          pixels[o + 2] = color[2];
          pixels[o + 3] = 0xff;
        }
      }
    }
  }
}

function encodePng(width, height, pixels, channels) {
  const sig = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8;  // bit depth
  ihdr[9] = channels === 4 ? 6 : 2;  // RGBA or truecolor RGB
  ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;

  // Add filter byte 0 at the start of each scanline.
  const stride = width * channels;
  const raw = Buffer.alloc((stride + 1) * height);
  for (let y = 0; y < height; y++) {
    raw[y * (stride + 1)] = 0;
    pixels.copy(raw, y * (stride + 1) + 1, y * stride, y * stride + stride);
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

for (const size of [180, 192, 512, 1024]) {
  const png = makeIcon(size);
  const path = join(WEB_OUT, `icon-${size}.png`);
  writeFileSync(path, png);
  console.log(`wrote ${path} (${png.length} bytes)`);
  if (size === 1024) {
    const iosPath = join(IOS_OUT, 'icon-1024.png');
    writeFileSync(iosPath, png);
    console.log(`wrote ${iosPath} (${png.length} bytes)`);
  }
}

const frontOut = join(VISION_OUT, 'Front.solidimagestacklayer', 'Content.imageset');
const backOut = join(VISION_OUT, 'Back.solidimagestacklayer', 'Content.imageset');
mkdirSync(frontOut, { recursive: true });
mkdirSync(backOut, { recursive: true });
writeFileSync(join(frontOut, 'front-w.png'), makeVisionForeground(1024));
writeFileSync(join(backOut, 'background.png'), makeVisionBackground(1024));
console.log(`wrote ${VISION_OUT}`);
