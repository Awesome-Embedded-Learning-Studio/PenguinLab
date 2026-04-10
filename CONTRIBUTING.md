# 参与贡献

感谢你对 PenguinLab 的关注！欢迎提交 PR 共同完善这份学习资料。

## 贡献流程

1. Fork 本仓库
2. 创建特性分支：`git checkout -b feature/your-topic`
3. 提交更改
4. 发起 Pull Request

## 文档规范

- 教程和文档使用**中文**编写
- 代码注释可使用中文或英文
- 新教程请遵循现有结构：`做什么` → `要了解什么` → `练习` → `延伸阅读`
- 命令块中的命令必须可直接复制执行

## 代码规范

- C 代码遵循项目根目录的 `.clang-format` 配置
- 内核模块代码遵循 [Linux 内核代码风格](https://www.kernel.org/doc/html/latest/process/coding-style.html)
- Shell 脚本参考 `scripts/` 目录下的现有脚本

## 添加示例

每个示例目录必须包含：

- **源码**（`.c` / `.h`）
- **Makefile**（使用 `KDIR ?=` 引用 `third_party/linux`）
- **README.md**（说明：构建方法、测试步骤、学习要点）

## 添加教程

- 放在 `tutorial/`（Week 1）或 `todo/`（Week 2–4）目录下
- 包含可运行的代码示例
- 在对应的 `example/` 目录提供配套练习代码
- 在「延伸阅读」中引用 `document/booklist.md` 中的相关章节
