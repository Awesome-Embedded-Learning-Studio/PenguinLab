---
title: 构建本网站
description: PenguinLab 站点用 VitePress 构建——分卷并行 + 增量缓存 + 搜索索引合并，以及几个踩过的认知坑
maturity: verified
---

# 构建本网站

## 技术栈：VitePress（不是 Docusaurus）

先纠一个流传过的误会：本站用的是 **VitePress**，不是 Docusaurus。证据摆在眼前——配置在 `site/.vitepress/`，`site/package.json` 的脚本调的是 `vitepress`，构建编排 `scripts/build.ts` 跑的也是 `vitepress build`。早期文档里残留的「Docusaurus」字样是历史包袱，别被带偏。

## package.json 的四个脚本

```json
{
  "scripts": {
    "dev": "vitepress dev .",             // 本地热更新预览
    "build": "tsx ../scripts/build.ts",   // 生产构建（分卷，推荐）
    "build:single": "vitepress build .",  // 单实例构建（调试用）
    "preview": "vitepress preview ."      // 预览构建产物
  }
}
```

日常开发：

```bash
cd site
pnpm install        # 首次
pnpm dev            # 起 dev server，改 markdown 即时刷新
```

生产构建：

```bash
cd site
pnpm build          # 走 scripts/build.ts，产物在 site/.vitepress/dist
pnpm preview        # 本地预览构建结果
```

> 历史坑：仓库里曾有 `scripts/site-dev.sh`、`scripts/site-serve.sh` 两个脚本，注释写着 Docusaurus、调用 `pnpm start` / `pnpm serve`——但 package.json 里**根本没有** `start` 和 `serve` 这两个脚本，所以它们一直是坏的。现已修正为 `pnpm dev` / `pnpm build` + `pnpm preview`。认准上面四个脚本名就好。

## 为什么 build 要单独写个 build.ts

站点内容分成了多个「卷」：`tutorials/foundations`、`tutorials/kernel`、…、`notes`、`blog`、`guides`。单个 VitePress 实例构建整站，内容一多就慢、还容易内存吃紧。`scripts/build.ts` 的做法是：

- **分卷并行**：每个卷起一个独立的 VitePress 实例并行构建（并发度 `BUILD_CONCURRENCY`，默认 4），卷与卷之间不互相拖。
- **增量缓存**：对每个卷算 sha256（内容 + 构建脚本 + package + lockfile），没变的卷直接复用上次产物（缓存在 `site/.vitepress/.build-cache/`），只重建变了的。`--force` 强制全量重建。
- **搜索索引合并**：VitePress 的本地搜索是按实例一份的，分卷后得把各卷的中/英文搜索索引合并成一份，否则站内搜索搜不全。
- **跨卷数据统一**：把各卷的 hash map、site data 抹平成一致，保证跨卷跳转和资源引用不断。

这一套是「内容多了之后不得不做的工程化」。理解它有助于排查「为什么我改了 A 卷，B 卷没更新」之类的缓存问题——清 `site/.vitepress/.build-cache/` 或加 `--force`。

## 卷是怎么定义的

两个地方配合：

- `scripts/build.ts` 的 `VOLUMES` 数组：每个卷 `{ name, srcDir, urlPrefix }`，告诉构建器「`document/<srcDir>/` 是一个卷，URL 前缀是 `<urlPrefix>`」。
- `site/.vitepress/config/sidebar.ts` 的 `buildSidebar()`：为每个卷注册一个侧边栏，`volumeSidebar()` 会**自动扫描**卷目录、按文件名数字前缀排序、从 frontmatter `title:` 取标题。

加一个新卷（本卷 `guides` 就是这样加的）：

1. `build.ts` 的 `VOLUMES` 加一行 `{ name: 'guides', srcDir: 'guides', urlPrefix: '/guides' }`。
2. `sidebar.ts` 的 `buildSidebar()` 加一行 `'/guides/': volumeSidebar('guides', '/guides')`。
3. `nav.ts` 加一个导航入口（可选）。
4. 在 `document/guides/` 下放 `_category_.json`（设卷标签）和 markdown 文章。

侧边栏会自动从目录内容生成，不用手写每一项。

## 文件命名与排序

`sidebar.ts` 按文件名开头的数字排序：`00-xxx`、`01-xxx`… 所以这一卷是 `index.md`（卷首页）+ `01-kernel-build.md`、`02-rootfs.md`… 这样编号，侧边栏顺序就稳了。标题取 frontmatter 的 `title:`，没有就 humanize 文件名。

## 多语言

站点支持中英双语。中文内容在 `document/`（各卷目录），英文在 `document/en/` 下镜像。`build.ts` 会同时构建两种语言，搜索索引也按语言分别合并。
