#!/usr/bin/env node
// Render a single HTML diagram to webp.
// Usage: node render-diagrams.js <path-to-html>
// Output: <same-dir>/<basename>.webp (1920x1080, quality=90)

const path = require('path');
const { chromium } = require('playwright');
const sharp = require('sharp');

async function main() {
  const htmlPath = process.argv[2];
  if (!htmlPath) {
    console.error('Usage: node render-diagrams.js <html>');
    process.exit(2);
  }
  const abs = path.resolve(htmlPath);
  const out = abs.replace(/\.html$/, '.webp');
  const fileUrl = 'file://' + abs;

  const browser = await chromium.launch({ headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 1920, height: 1080 } });
    await page.goto(fileUrl, { waitUntil: 'networkidle' });
    const png = await page.screenshot({ type: 'png', fullPage: false, omitBackground: false });
    await sharp(png).webp({ quality: 90 }).toFile(out);
    console.log(`OK  ${path.basename(out)}`);
  } finally {
    await browser.close();
  }
}

main().catch((err) => {
  console.error('FAIL', err.message);
  process.exit(1);
});
