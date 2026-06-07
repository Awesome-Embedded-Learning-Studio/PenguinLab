import DefaultTheme from 'vitepress/theme'
import type { Theme } from 'vitepress'
import { setupMermaid } from './mermaid-client'
import './custom.css'

export default {
  extends: DefaultTheme,
  setup() {
    setupMermaid()
  },
} satisfies Theme
