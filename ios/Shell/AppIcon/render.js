const fs = require('fs');
const path = require('path');
const { Resvg } = require('@resvg/resvg-js');

const [, , svgPath, outPath, sizeArg] = process.argv;
const size = parseInt(sizeArg || '1024', 10);
const svg = fs.readFileSync(svgPath, 'utf8');

const resvg = new Resvg(svg, {
  fitTo: { mode: 'width', value: size },
  background: 'transparent',
  font: { loadSystemFonts: true },
});
const png = resvg.render().asPng();
fs.mkdirSync(path.dirname(outPath), { recursive: true });
fs.writeFileSync(outPath, png);
console.log(`${outPath} (${size}px, ${png.length} bytes)`);
