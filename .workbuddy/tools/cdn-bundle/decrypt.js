const fs=require('fs');
const path=require('path');
// 仓库相对定位：本文件在 <repo>/.workbuddy/tools/cdn-bundle/ 下
const bootPath=path.resolve(__dirname,'../../../ios-cocos/cocos-project/src/ios2-web-boot.js');
const boot=fs.readFileSync(bootPath,'utf8');
const m=boot.match(/function decryptJSC\(data, keyText\) \{[\s\S]*?\n        return out;\n    \}/)
      || boot.match(/function decryptJSC\(data, keyText\) \{[\s\S]*?\n        return output;\n    \}/);
const decryptJSC = new Function('return ('+m[0]+')')();
const idx=JSON.parse(fs.readFileSync(process.env.HOME+'/Library/Application Support/GameLobby/CDN/index.json','utf8'));
const root=process.env.HOME+'/Library/Application Support/GameLobby/CDN/files';
for(const name of ['game','launcher']){
  const key=Object.keys(idx).find(k=>k.includes('/'+name+'/index.'));
  const rec=idx[key];
  const buf=fs.readFileSync(root+'/'+rec.path);
  let out, mode='decrypted';
  try{ out=Buffer.from(decryptJSC(new Uint8Array(buf),'0Aed5E79bbEa69f8')); }
  catch(e){ mode='plain(cache 已是明文)'; out=buf; }
  fs.writeFileSync('/tmp/dec-'+name+'.js', out);
  console.log(name.padEnd(9), mode, '| 缓存', buf.length, '字节 ->', out.length, '字节 |', key.split('/remote/')[1]);
}
