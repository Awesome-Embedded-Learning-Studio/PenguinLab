import type { DefaultTheme } from 'vitepress'

export const navZh: DefaultTheme.NavItem[] = [
  { text: '首页', link: '/' },
  {
    text: '教程',
    items: [
      { text: '通识基础', link: '/tutorials/foundations/' },
      { text: '内核子系统', link: '/tutorials/kernel/' },
      { text: '驱动开发', link: '/tutorials/drivers/' },
      { text: '嵌入式全栈', link: '/tutorials/embedded/' },
      { text: '调试与性能', link: '/tutorials/debugging/' },
      { text: '虚拟化与容器', link: '/tutorials/virtualization/' },
    ],
  },
  {
    text: '参考',
    items: [
      { text: '推荐书单', link: '/booklist' },
      { text: 'QEMU ARM 速查', link: '/qemu-reference' },
    ],
  },
  { text: '笔记', link: '/notes/' },
  { text: '内核新闻', link: '/blog/' },
  { text: 'GitHub', link: 'https://github.com/Awesome-Embedded-Learning-Studio/PenguinLab' },
]

export const navEn: DefaultTheme.NavItem[] = [
  { text: 'Home', link: '/en/' },
  {
    text: 'Tutorials',
    items: [
      { text: 'Foundations', link: '/en/tutorials/foundations/' },
      { text: 'Kernel Subsystems', link: '/en/tutorials/kernel/' },
      { text: 'Driver Development', link: '/en/tutorials/drivers/' },
      { text: 'Embedded Full Stack', link: '/en/tutorials/embedded/' },
      { text: 'Debugging & Performance', link: '/en/tutorials/debugging/' },
      { text: 'Virtualization & Containers', link: '/en/tutorials/virtualization/' },
    ],
  },
  {
    text: 'Reference',
    items: [
      { text: 'Booklist', link: '/en/booklist' },
      { text: 'QEMU ARM Reference', link: '/en/qemu-reference' },
    ],
  },
  { text: 'Notes', link: '/en/notes/' },
  { text: 'GitHub', link: 'https://github.com/Awesome-Embedded-Learning-Studio/PenguinLab' },
]
