import test from 'node:test';
import assert from 'node:assert/strict';
import { screenshotArgs } from '../src/utils/bugReports.js';

const data = (mime, bytes) => `data:${mime};base64,${bytes.toString('base64')}`;
const jpeg = Buffer.from('ffd8ffe000104a46494600010100000100010000ffd9', 'hex');
const png = Buffer.from('89504e470d0a1a0a0000000d49484452', 'hex');
const gif = Buffer.from('47494638396101000100800000000000ffffff2c00000000010001000002024401003b', 'hex');
const bmp = Buffer.concat([Buffer.from('BM'), Buffer.alloc(52)]);
const webp = Buffer.from('524946460c000000574542505650384c', 'hex');

test('screenshots accept the raster allowlist and normalise JPEG/JPS aliases', () => {
  for (const [mime, bytes, expected] of [
    ['image/jpeg', jpeg], ['image/jpg', jpeg, 'image/jpeg'], ['image/pjpeg', jpeg, 'image/jpeg'],
    ['image/jps', jpeg, 'image/jpeg'], ['image/x-jps', jpeg, 'image/jpeg'], ['IMAGE/JPEG', jpeg, 'image/jpeg'],
    ['image/png', png], ['image/x-png', png, 'image/png'], ['image/webp', webp],
    ['image/gif', gif], ['image/bmp', bmp], ['image/x-ms-bmp', bmp, 'image/bmp'],
  ]) {
    assert.deepEqual(screenshotArgs(data(mime, bytes)), { _mime: expected || mime, _base64: bytes.toString('base64') });
  }
});

test('screenshots reject SVG, mismatched signatures, corrupt base64 and oversized files', () => {
  assert.equal(screenshotArgs(data('image/svg+xml', Buffer.from('<svg onload="alert(1)"></svg>'))), null);
  assert.equal(screenshotArgs(data('image/jpeg', png)), null);
  assert.equal(screenshotArgs(data('image/gif', jpeg)), null);
  assert.equal(screenshotArgs(data('image/bmp', Buffer.from('BMtoo-short'))), null);
  assert.equal(screenshotArgs(data('image/webp', Buffer.from('RIFF0000NOTP'))), null);
  assert.equal(screenshotArgs('data:image/jpeg;base64,/9j/!!!!!!!!'), null);
  const tooLarge = Buffer.alloc(2 * 1024 * 1024 + 1);
  jpeg.copy(tooLarge);
  assert.equal(screenshotArgs(data('image/jpeg', tooLarge)), null);
  assert.equal(screenshotArgs(data('image/jpeg', Buffer.alloc(0))), null);
  assert.deepEqual(screenshotArgs(undefined), { _mime: null, _base64: null });
});
