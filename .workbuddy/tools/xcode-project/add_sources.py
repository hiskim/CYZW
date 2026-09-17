#!/usr/bin/env python3
"""把新增的 Swift 文件登记进 GameLobby.xcodeproj。

为什么需要它：这个工程**没有**用 Xcode 的「文件系统同步组」（PBXFileSystemSynchronizedRootGroup），
所以新文件必须显式登记**四处**：

    ① PBXBuildFile        （编译产物条目）
    ② PBXFileReference    （文件引用）
    ③ 所属 PBXGroup.children
    ④ 所属 target 的 PBXSourcesBuildPhase.files

少任何一处的表现都是「文件在盘上、但没被编译」——编译器不会报错，只有符号找不到时才露馅
（在另一个模块里用时才报，很容易误判成别的问题）。

UUID 也用不着真随机：本工程一直用手写的顺序号（`C100000000000000000000xx` /
`C200000000000000000000xx`），脚本沿用同一套并自动取下一个空位。

用法（在 LobbyCoreSystem 目录下，或任意目录传全路径）：
    python3 add_sources.py Sources/LobbyEngine/Foo.swift Sources/LobbyDomain/Bar.swift

幂等：已登记的文件会跳过。
"""
import os
import re
import sys

DEFAULT_PROJECT = "GameLobby.xcodeproj/project.pbxproj"


def pbx_path(argv):
    for arg in argv:
        if arg.endswith("project.pbxproj"):
            return arg
    here = os.path.dirname(os.path.abspath(__file__))
    for candidate in (
        os.path.join(os.getcwd(), DEFAULT_PROJECT),
        os.path.join(here, "../../../LobbyCoreSystem", DEFAULT_PROJECT),
        os.path.join(here, DEFAULT_PROJECT),
    ):
        if os.path.exists(candidate):
            return candidate
    sys.exit(f"找不到 {DEFAULT_PROJECT}；请在 LobbyCoreSystem 目录下运行，或把它作为第一个参数传入")


def next_suffix(text):
    """取下一个没被占用的 UUID 后缀（本工程是顺序号，形如 `C1` + 20 个 0 + 2 位十六进制）。

    ⚠️ 前缀里 0 的个数必须精确：少写一个，捕获组就会落在「0X」上，
    于是已占用的后缀被判成空闲 → 生成重复 UUID（我踩过一次，两个文件拿到同一个号）。
    """
    used = {m.group(1) for m in re.finditer(r"C[12]00000000000000000000([0-9A-F]{2})", text)}
    for value in range(0x01, 0x100):
        suffix = f"{value:02X}"
        if suffix not in used:
            return suffix
    sys.exit("UUID 后缀用尽，请手工分段")


def blocK(text, object_id):
    """取出某条对象定义的正文（到 `\\n\\t\\t};` 为止）。

    ⚠️ 不要用 `[\\s\\S]*?` 直接跨到目标关键字：它**会跨过对象边界**，
    于是「找 path = LobbyEngine 的那份 group」会匹配到**第一个** group
    （然后 `path = LobbyEngine;` 出现在它后面的某个对象里）——登记就落到了别的分组上，
    而自检只查「这条字符串存在吗」，照样通过（这个 bug 我踩过一次）。
    """
    start = re.search(r"\n\t\t" + object_id + r" /\* [^*]+ \*/ = \{", text)
    if not start:
        sys.exit(f"找不到对象 {object_id}")
    end = text.find("\n\t\t};", start.start())
    if end < 0:
        sys.exit(f"对象 {object_id} 没有找到结束标记")
    return text[start.start():end]


def group_for(text, directory):
    """按 `path = <directory>;` 找到那份 PBXGroup，返回它的 id。"""
    for match in re.finditer(r"\n\t\t(C[0-9A-F]{23}) /\* [^*]+ \*/ = \{", text):
        body = blocK(text, match.group(1))
        if "isa = PBXGroup;" not in body:
            continue
        if f"\n\t\t\tpath = {directory};" in body:
            return match.group(1)
    sys.exit(f"找不到路径为 {directory} 的 PBXGroup")


def sources_phase_for(text, target_name):
    """按 target 名找到它 buildPhases 里的 Sources 阶段，返回 id。"""
    for match in re.finditer(r"\n\t\t(C[0-9A-F]{23}) /\* " + re.escape(target_name)
                             + r" \*/ = \{\n\t\t\tisa = PBXNativeTarget;", text):
        body = blocK(text, match.group(1))
        phase = re.search(r"(C[0-9A-F]{23}) /\* Sources \*/", body)
        if phase:
            return phase.group(1)
    sys.exit(f"找不到名为 {target_name} 的 target（或它没有 Sources 阶段）")


def children_anchor(text, group_id):
    """返回该 group 的 children 数组里最后一个条目行（含换行），用于插入。"""
    entries = re.findall(r"\n\t\t\t\tC[0-9A-F]{23} /\* [^*]+ \*/,\n", blocK(text, group_id))
    if not entries:
        sys.exit(f"group {group_id} 的 children 是空的，请手工补第一条")
    return entries[-1]


def phase_anchor(text, phase_id):
    entries = re.findall(r"\n\t\t\t\tC[0-9A-F]{23} /\* [^*]+ in Sources \*/,\n", blocK(text, phase_id))
    if not entries:
        sys.exit(f"Sources 阶段 {phase_id} 是空的，请手工补第一条")
    return entries[-1]


BUILD_LINE = re.compile(r"\n\t\tC[0-9A-F]{23} /\* [^*]+ \*/ = \{isa = PBXBuildFile; fileRef = [^}]*\};\n")
REF_LINE = re.compile(r"\n\t\tC[0-9A-F]{23} /\* [^*]+ \*/ = \{isa = PBXFileReference;[^}]*\};\n")


def insert_after_last_match(text, pattern, addition, label):
    """在**最后一条完整匹配行之后**插入。

    ⚠️ 锚点必须匹配**整行**（含结尾换行）。只匹配行首会把这行劈成两半——
    `{isa = PBXBuildFile;` 后面直接跟插入文本，原行的 `fileRef = …; };` 被推到下一行，
    整个条目就废了，而 `plutil -lint` 居然还是 OK（我踩过一次）。
    """
    matches = list(pattern.finditer(text))
    if not matches:
        sys.exit(f"找不到可插入的锚点行：{label}")
    end = matches[-1].end()
    return text[:end] + addition + text[end:]


def main(argv):
    files = [a for a in argv if a.endswith(".swift")]
    if not files:
        sys.exit(__doc__)
    path = pbx_path(argv)
    text = open(path, encoding="utf-8").read()
    changed = False

    for item in files:
        name = os.path.basename(item)
        directory = os.path.basename(os.path.dirname(os.path.abspath(item)))
        if f"path = {name};" in text:
            print(f"  跳过（已登记）：{name}")
            continue

        suffix = next_suffix(text)
        ref = "C200000000000000000000" + suffix
        build = "C100000000000000000000" + suffix
        if ref in text or build in text:
            sys.exit(f"UUID 冲突：{ref} / {build} 已被占用")
        group_id = group_for(text, directory)
        phase_id = sources_phase_for(text, directory)

        # ① PBXBuildFile
        text = insert_after_last_match(
            text, BUILD_LINE,
            f"\t\t{build} /* {name} in Sources */ = {{isa = PBXBuildFile; "
            f"fileRef = {ref} /* {name} */; }};\n", "PBXBuildFile")
        # ② PBXFileReference
        text = insert_after_last_match(
            text, REF_LINE,
            f"\t\t{ref} /* {name} */ = {{isa = PBXFileReference; "
            f"lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};\n",
            "PBXFileReference")
        # ③ group children（锚点本身就是整行）
        anchor = children_anchor(text, group_id)
        text = text.replace(anchor, anchor + f"\t\t\t\t{ref} /* {name} */,\n", 1)
        # ④ Sources 阶段
        anchor = phase_anchor(text, phase_id)
        text = text.replace(anchor, anchor + f"\t\t\t\t{build} /* {name} in Sources */,\n", 1)

        checks = {
            "PBXBuildFile": re.search(r"\n\t\t" + build + r" /\* " + re.escape(name)
                                      + r" in Sources \*/ = \{isa = PBXBuildFile; fileRef = " + ref + r" /\* " + re.escape(name) + r" \*/; \};\n", text),
            "PBXFileReference": re.search(r"\n\t\t" + ref + r" /\* " + re.escape(name)
                                          + r" \*/ = \{isa = PBXFileReference;[^}]*path = " + re.escape(name) + r";", text),
            "Group": f"{ref} /* {name} */,\n" in blocK(text, group_id),
            "Sources": f"{build} /* {name} in Sources */,\n" in blocK(text, phase_id),
        }
        ok = all(checks.values())
        print(("  OK   " if ok else "  FAIL ") + f"{item} → {directory}（{suffix}）"
              + ("" if ok else "  缺：" + ",".join(k for k, v in checks.items() if not v)))
        if not ok:
            sys.exit(1)
        changed = True

    if changed:
        open(path, "w", encoding="utf-8").write(text)
        print(f"已写入 {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
