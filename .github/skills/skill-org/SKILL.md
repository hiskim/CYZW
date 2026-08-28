---
name: skill-org
description: 规范本项目 Codex skill 的归类、命名、保存位置和校验流程，适用于创建、迁移或更新项目技能时判断应放在哪里以及如何保持结构一致。
---

# 项目 Skill 归类与保存

## 目标

在本项目中创建或调整 Codex skill 时，先判断技能属于项目共享能力、个人全局能力还是外部插件/系统能力，再放到正确位置。默认把和本项目代码、构建、调试、运行模式或维护流程强相关的技能保存到项目内 `.github/skills/`。

## 保存位置

1. 项目专用技能放在 `.github/skills/<skill-name>/SKILL.md`。这类技能应随项目一起版本管理，例如 IOS2 账号管理、Cocos/WebKit 运行模式、项目内技能归类规范。
2. 个人通用技能才放在 `${CODEX_HOME:-~/.codex}/skills/<skill-name>/SKILL.md`。只有当技能不依赖当前仓库、可跨多个项目复用，并且用户明确希望作为个人技能保存时才使用该位置。
3. 系统技能位于 `.codex/skills/.system` 或运行环境提供的位置，只能读取参考，不要复制、修改或当作项目归档目录。
4. 插件技能由插件目录或插件缓存提供，不要把插件内部技能混入本项目，除非用户明确要求把其中的方法整理成项目内独立技能。

## 命名与归类

1. 技能目录名使用小写字母、数字和连字符，目录名必须与 frontmatter 的 `name` 一致。
2. 面向具体子系统的技能使用子系统前缀，例如 `ios2-fairygui-account`、`ios-cocos-runtime-modes`。
3. 面向项目流程或维护规范的技能优先使用短而清晰的名称，例如 `skill-org`；如果需要强调项目级规则，可使用 `project-` 前缀。
4. 一个技能只覆盖一个清晰主题。不要把账号 UI、运行模式、构建发布、资源处理等无关规则塞进同一个技能。
5. 创建新技能前先检查 `.github/skills/` 里是否已有相近主题；如果已有，应优先更新旧技能，而不是新增重复技能。

## 创建流程

1. 先读取用户请求和项目已有 `.github/skills/*/SKILL.md`，确认新技能的归类、名称和是否已有重复。
2. 如果技能服务于当前项目，创建 `.github/skills/<skill-name>/SKILL.md`。不要默认创建到个人目录。
3. `SKILL.md` frontmatter 只保留当前校验器支持的必要字段，至少包含 `name` 和 `description`。除非当前项目规范明确支持，否则不要添加旧式 `argument-hint`、`user-invocable`、`disable-model-invocation` 字段。
4. 技能说明默认使用中文；代码标识符、文件路径、命令和 API 名称保留原文，方便准确定位。
5. 正文只写会影响后续执行质量的约束、定位路径、修改原则和验证方式。不要写泛泛的使用教程，也不要添加空目录、占位文件或无用示例。

## 技能内容结构

推荐结构：

```md
---
name: <skill-name>
description: <中文说明，写清适用场景>
---

# <中文标题>

## 目标
## 核心约束
## 优先排查位置
## 修改原则
## 验证
```

可以按技能实际用途删减章节。简单技能不需要额外 `references/`、`scripts/` 或 `assets/`；只有当复用资料、脚本或模板确实能减少重复工作时才添加。

## 校验

创建或更新技能后，从仓库根目录执行：

```sh
python3 /Users/gg/.codex/skills/.system/skill-creator/scripts/quick_validate.py .github/skills/<skill-name>
git diff --check
git status --short
```

如果系统 Python 缺少 `PyYAML`，可以临时安装到隔离目录再运行校验，不要污染项目依赖：

```sh
SKILL_VALIDATE_PATH=$(mktemp -d /tmp/project-skill-validate.XXXXXX)
python3 -m pip install --quiet --target "$SKILL_VALIDATE_PATH" PyYAML
PYTHONPATH="$SKILL_VALIDATE_PATH" python3 /Users/gg/.codex/skills/.system/skill-creator/scripts/quick_validate.py .github/skills/<skill-name>
```

最终回复用户时说明技能保存路径、技能名、是否通过校验，以及是否有未处理的旧副本或无关未跟踪文件。
