import {themes as prismThemes} from 'prism-react-renderer';
import type {Config} from '@docusaurus/types';
import type * as Preset from '@docusaurus/preset-classic';

const config: Config = {
  title: 'PenguinLab',
  tagline: 'Linux 内核学习站',
  favicon: 'img/favicon.ico',

  url: 'https://awesome-embedded-learning-studio.github.io',
  baseUrl: '/PenguinLab/',

  organizationName: 'Awesome-Embedded-Learning-Studio',
  projectName: 'PenguinLab',

  onBrokenLinks: 'warn',

  trailingSlash: false,

  i18n: {
    defaultLocale: 'zh-CN',
    locales: ['zh-CN', 'en'],
    localeConfigs: {
      'zh-CN': {
        label: '简体中文',
        path: 'zh-CN',
      },
      en: {
        label: 'English',
        direction: 'ltr',
      },
    },
  },

  markdown: {
    format: 'md',
    mermaid: true,
    mdx1Compat: {
      admonitions: true,
    },
    hooks: {
      onBrokenMarkdownLinks: 'warn',
      onBrokenMarkdownImages: 'warn',
    },
  },

  themes: ['@docusaurus/theme-mermaid'],

  presets: [
    [
      'classic',
      {
        docs: {
          path: '../document',
          routeBasePath: '/',
          sidebarPath: './sidebars.ts',
          showLastUpdateAuthor: true,
          showLastUpdateTime: true,
          editUrl:
            'https://github.com/Awesome-Embedded-Learning-Studio/PenguinLab/tree/main/',
        },
        blog: {
          path: 'blog',
          blogTitle: '内核 Feature 速递',
          blogDescription: '追踪 Linux 内核最新合并窗口和特性演进',
          postsPerPage: 10,
          blogSidebarCount: 'ALL',
          blogSidebarTitle: '最新文章',
          routeBasePath: 'blog',
        },
        theme: {
          customCss: './src/css/custom.css',
        },
      } satisfies Preset.Options,
    ],
  ],

  themeConfig: {
    navbar: {
      title: 'PenguinLab',
      logo: {
        alt: 'PenguinLab Logo',
        src: 'img/logo.png',
      },
      items: [
        {
          type: 'docSidebar',
          sidebarId: 'tutorialSidebar',
          position: 'left',
          label: '教程',
        },
        {
          type: 'docSidebar',
          sidebarId: 'referenceSidebar',
          position: 'left',
          label: '参考',
        },
        {
          type: 'docSidebar',
          sidebarId: 'notesSidebar',
          position: 'left',
          label: '笔记',
        },
        {to: '/blog', label: '内核新闻', position: 'left'},
        {
          type: 'localeDropdown',
          position: 'right',
        },
        {
          href: 'https://github.com/Awesome-Embedded-Learning-Studio/PenguinLab',
          label: 'GitHub',
          position: 'right',
        },
      ],
    },

    footer: {
      style: 'dark',
      copyright: `Copyright © ${new Date().getFullYear()} Charliechen`,
    },

    prism: {
      theme: prismThemes.oneLight,
      darkTheme: prismThemes.oneDark,
      additionalLanguages: [
        'bash',
        'c',
        'cpp',
        'diff',
        'python',
        'json',
        'markdown',
        'docker',
        'makefile',
      ],
    },

    colorMode: {
      defaultMode: 'light',
      disableSwitch: false,
      respectPrefersColorScheme: true,
    },

    tableOfContents: {
      minHeadingLevel: 2,
      maxHeadingLevel: 4,
    },
  } satisfies Preset.ThemeConfig,
};

export default config;
