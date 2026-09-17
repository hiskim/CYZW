# xcode-project —— 登记新文件进 GameLobby.xcodeproj

这个工程**没有**用 Xcode 的「文件系统同步组」（`PBXFileSystemSynchronizedRootGroup`），
也不是 SwiftPM，所以往 `Sources/` 里扔一个新 `.swift` **不会**被编译。
新文件必须显式登记**四处**：

| # | 位置 | 漏了的表现 |
|---|---|---|
| ① | `PBXBuildFile` | 不参与编译 |
| ② | `PBXFileReference` | Xcode 里看不到文件 |
| ③ | 所属 `PBXGroup.children` | 同上（且 diff 看着像"登记过了"） |
| ④ | 所属 target 的 `PBXSourcesBuildPhase.files` | 不参与编译 |

**这四处漏任何一处都不会在构建时报错**——只有当另一处用到了那个符号时才报
「cannot find X in scope」，非常容易误判成别的问题。

## 用法

```bash
cd LobbyCoreSystem
python3 ../.workbuddy/tools/xcode-project/add_sources.py Sources/LobbyEngine/Foo.swift
# 目标模块由目录名推导（LobbyEngine / LobbyDomain / LobbyIPC / LobbyStorage / LobbyUI）；
# 也可以直接传 project.pbxproj 的路径作为第一个参数。
```

幂等：已登记的文件会跳过。UUID 沿用本工程的顺序号风格（`C1` + 20 个 0 + 2 位十六进制），
自动取下一个空位。

## 改完之后务必核一遍

自检只能证明「那条字符串在文件里」，**证明不了它落在对的地方**。独立核对用 `plutil`
（pbxproj 就是一份老式 plist）：

```bash
plutil -lint GameLobby.xcodeproj/project.pbxproj
plutil -convert json -o - GameLobby.xcodeproj/project.pbxproj | python3 -c "
import json,sys
d=json.load(sys.stdin)['objects']
for t in d.values():
    if t.get('isa')!='PBXNativeTarget': continue
    files=[]
    for p in t['buildPhases']:
        if d[p].get('isa')=='PBXSourcesBuildPhase':
            files += [d[d[f]['fileRef']].get('path') for f in d[p].get('files',[])]
    print(t['name'], '→', sorted(x for x in files if x))
"
```

## 踩过的两个坑（都写进了脚本的注释）

1. **锚点必须匹配整行**。只匹配行首（`… = {isa = PBXBuildFile;`）会把锚点行劈成两半，
   插入文本直接挤进条目中间 —— 而且 `plutil -lint` 当时居然还报 OK。
2. **UUID 前缀里 0 的个数要精确**（`C1` 后面是 **20 个** 0）。少数一个，捕获组就落在
   `0X` 上，已占用的后缀被判成空闲 → 两个文件拿到同一个 UUID。
