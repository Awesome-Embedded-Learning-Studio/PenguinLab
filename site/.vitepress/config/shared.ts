import type { DefaultTheme } from 'vitepress'
import { mermaidPlugin } from '../plugins/mermaid-plugin'
import { escapeAngleBrackets } from '../plugins/escape-angle-brackets'

export const sharedBase = {
  base: '/PenguinLab/',
  cleanUrls: true,
  lastUpdated: true,

  vue: {
    template: {
      compilerOptions: {
        isCustomElement: (tag: string) => tag.includes('-') || tag.includes('.'),
      },
    },
  },

  vite: {
    build: {
      chunkSizeWarningLimit: 5000,
    },
  },

  head: [
    ['link', { rel: 'icon', href: '/PenguinLab/favicon.ico' }],
  ],

  markdown: {
    lineNumbers: true,
    theme: {
      light: 'github-light',
      dark: 'github-dark',
    },
    config(md) {
      md.use(escapeAngleBrackets)
      md.use(mermaidPlugin)
    },
  },
}

export function sharedThemeConfig(): DefaultTheme.Config {
  return {
    nav: [],
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
  }
}

export function sharedEnThemeConfig(): DefaultTheme.Config {
  return {
    nav: [],
    search: {
      provider: 'local',
    },
    editLink: {
      pattern: 'https://github.com/Awesome-Embedded-Learning-Studio/PenguinLab/edit/main/document/en/:path',
      text: 'Edit this page on GitHub',
    },
    footer: {
      message: 'Built with VitePress',
      copyright: `Copyright ${new Date().getFullYear()} Charliechen`,
    },
    socialLinks: [
      { icon: 'github', link: 'https://github.com/Awesome-Embedded-Learning-Studio/PenguinLab' },
    ],
  }
}
