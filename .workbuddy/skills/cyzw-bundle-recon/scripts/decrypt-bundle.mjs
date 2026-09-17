#!/usr/bin/env node
// 解密 CYZW/xyzw 线上 bundle（XXTEA）。
// 算法逐行照抄 ios-cocos/cocos-project/src/ios2-web-boot.js 的 decryptJSC（≈1003 行），
// 密钥同 AppDelegate.cpp 的 jsb_set_xxtea_key。
//
//   node decrypt-bundle.mjs <密文路径> <输出路径>
//
// 成功标志：输出的 js 以 `window.__require=function` 开头。

import fs from 'node:fs';

const KEY = '0Aed5E79bbEa69f8';

function decryptJSC(data, keyText) {
  const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
  const keyBytes = new TextEncoder().encode(keyText);
  const key = new Uint8Array(16);
  key.set(keyBytes.subarray(0, 16));

  function uint32(source, includeLength) {
    const length = source.length;
    const count = Math.ceil(length / 4);
    const values = new Uint32Array(count + (includeLength ? 1 : 0));
    for (let index = 0; index < length; index++) {
      values[index >>> 2] |= source[index] << ((index & 3) << 3);
    }
    if (includeLength) values[count] = length;
    return values;
  }

  const values = uint32(bytes, false);
  const keyValues = uint32(key, false);
  const last = values.length - 1;
  if (last < 1) return bytes;

  const rounds = Math.floor(6 + 52 / values.length);
  let sum = (rounds * 0x9E3779B9) >>> 0;
  let y = values[0];
  while (sum !== 0) {
    const e = (sum >>> 2) & 3;
    for (let position = last; position > 0; position--) {
      const z = values[position - 1];
      const mix = (((z >>> 5 ^ y << 2) + (y >>> 3 ^ z << 4)) ^
        ((sum ^ y) + (keyValues[(position & 3) ^ e] ^ z))) >>> 0;
      y = values[position] = (values[position] - mix) >>> 0;
    }
    const z = values[last];
    const mix = (((z >>> 5 ^ y << 2) + (y >>> 3 ^ z << 4)) ^
      ((sum ^ y) + (keyValues[e] ^ z))) >>> 0;
    y = values[0] = (values[0] - mix) >>> 0;
    sum = (sum - 0x9E3779B9) >>> 0;
  }

  const decodedLength = values[last];
  const maximumLength = last << 2;
  if (decodedLength < maximumLength - 3 || decodedLength > maximumLength) {
    throw new Error('Invalid XXTEA payload length: ' + decodedLength + ' vs ' + maximumLength);
  }
  const output = new Uint8Array(decodedLength);
  for (let index = 0; index < decodedLength; index++) {
    output[index] = (values[index >>> 2] >>> ((index & 3) << 3)) & 0xFF;
  }
  return output;
}

const [input, output] = process.argv.slice(2);
if (!input || !output) {
  console.error('usage: node decrypt-bundle.mjs <encrypted.jsc> <out.js>');
  process.exit(2);
}
const raw = fs.readFileSync(input);
const plain = decryptJSC(raw, KEY);
fs.writeFileSync(output, plain);
console.log('in=' + raw.length + ' out=' + plain.length);
console.log('head=' + Buffer.from(plain.subarray(0, 100)).toString('utf8'));
