import { defineConfig } from 'vitepress'
import { sharedBase, sharedThemeConfig, sharedEnThemeConfig } from './shared'
import { navZh, navEn } from './nav'
import { buildSidebar } from './sidebar'

export default defineConfig({
  ...sharedBase,
  srcDir: '../document',

  title: 'PenguinLab',
  description: 'Linux 内核学习站',
  lang: 'zh-CN',

  locales: {
    root: {
      label: '中文',
      lang: 'zh-CN',
      title: 'PenguinLab',
      description: 'Linux 内核学习站',
    },
    en: {
      label: 'English',
      lang: 'en-US',
      title: 'PenguinLab',
      description: 'Linux Kernel Learning Station',
      link: '/en/',
      themeConfig: {
        nav: navEn,
        editLink: {
          pattern: 'https://github.com/Awesome-Embedded-Learning-Studio/PenguinLab/edit/main/document/en/:path',
          text: 'Edit this page on GitHub',
        },
      },
    },
  },

  themeConfig: {
    nav: navZh,
    sidebar: buildSidebar(),
    search: {
      provider: 'local',
    },
    editLink: {
      pattern: 'https://github.com/Awesome-Embedded-Learning-Studio/PenguinLab/edit/main/document/:path',
      text: '在 GitHub 上编辑此页',
    },
    footer: {
      message: '基于 VitePress 构建',
      copyright: `Copyright ${new Date().getFullYear()} Charliechen`,
    },
    socialLinks: [
      { icon: 'github', link: 'https://github.com/Awesome-Embedded-Learning-Studio/PenguinLab' },
    ],
    outline: {
      level: [2, 4],
      label: '目录',
    },
  },
})
