# wkwebview-probe

用**真实 WKWebView** 验证「页面里某个写法，WebKit 到底怎么处理」的最小探针。
本次用它证明了 `<a download>` + Blob 的下载路径与代理契约。

```bash
cd .workbuddy/tools/wkwebview-probe
swiftc -O -o dlprobe main.swift

./dlprobe --kind=blob          # 脱离文档的 <a download href=blob:...> + a.click()
./dlprobe --kind=data          # data: URL
./dlprobe --shim               # 额外注入页面侧垫片，看它会不会抢在 WebKit 前面
```

输出会打印策略判定、`didBecome download`、目的地询问与最终落盘结果，
写入 `/tmp/dlprobe/result.txt`。

结论（macOS 26 / Xcode 26）：
- `shouldPerformDownload == true` 对**脱离文档**的锚点同样成立；
- WebKit 会把锚点 `download` 属性的值原样带进 `suggestedFilename`；
- 只要宿主实现 `decideDestinationUsing`，`blob:` 与 `data:` 都能正常落盘；
- 页面侧垫片一旦接管，WebKit 就再也不走下载通道了。
