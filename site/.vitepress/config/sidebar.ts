import type { DefaultTheme } from 'vitepress'
import { readdirSync, statSync, readFileSync, existsSync } from 'fs'
import { join } from 'path'

type SidebarItem = DefaultTheme.SidebarItem

interface CategoryMeta {
  label?: string
  position?: number
  collapsed?: boolean
  collapsible?: boolean
}

const DOCS_ROOT = join(import.meta.dirname, '../../../document')

function extractTitle(filePath: string): string | null {
  try {
    const content = readFileSync(filePath, 'utf-8')
    const fmMatch = content.match(/^---[\s\S]*?^title:\s*['"]?(.+?)['"]?\s*$/m)
    if (fmMatch) return fmMatch[1]
    const h1 = content.match(/^#\s+(.+)$/m)
    if (h1) return h1[1].replace(/\{.*?\}/g, '').trim()
  } catch { /* ignore */ }
  return null
}

function readCategoryJson(dir: string): CategoryMeta | null {
  const p = join(dir, '_category_.json')
  if (!existsSync(p)) return null
  try {
    return JSON.parse(readFileSync(p, 'utf-8'))
  } catch { return null }
}

function humanize(name: string): string {
  return name
    .replace(/^\d+[-]?/, '')
    .replace(/[-_]/g, ' ')
    .replace(/\b\w/g, c => c.toUpperCase())
}

function sortEntries(a: string, b: string): number {
  const na = a.match(/^(\d+)/)?.[1]
  const nb = b.match(/^(\d+)/)?.[1]
  if (na && nb) return parseInt(na) - parseInt(nb)
  if (na) return -1
  if (nb) return 1
  return a.localeCompare(b, 'zh-CN')
}

function scanDir(dir: string, urlPrefix: string, depth = 0): SidebarItem[] {
  if (depth > 5) return []

  let entries: string[]
  try {
    entries = readdirSync(dir).filter(e =>
      !e.startsWith('.') &&
      e !== 'images' &&
      e !== 'stylesheets' &&
      e !== 'javascripts'
    )
  } catch { return [] }

  entries.sort(sortEntries)
  const items: SidebarItem[] = []

  for (const name of entries) {
    const fullPath = join(dir, name)
    if (!statSync(fullPath).isDirectory() && !name.endsWith('.md')) continue

    if (statSync(fullPath).isDirectory()) {
      const subItems = scanDir(fullPath, `${urlPrefix}/${name}`, depth + 1)
      const indexPath = join(fullPath, 'index.md')
      const cat = readCategoryJson(fullPath)
      const title = cat?.label || extractTitle(indexPath) || humanize(name)

      if (subItems.length > 0) {
        items.push({
          text: title,
          link: existsSync(indexPath) ? `${urlPrefix}/${name}/` : undefined,
          items: subItems,
          collapsed: depth > 0 ? (cat?.collapsed ?? true) : (cat?.collapsed ?? false),
        })
      } else if (existsSync(indexPath)) {
        items.push({ text: title, link: `${urlPrefix}/${name}/` })
      }
    } else if (name !== 'index.md') {
      const title = extractTitle(fullPath) || humanize(name.replace(/\.md$/, ''))
      items.push({ text: title, link: `${urlPrefix}/${name.replace(/\.md$/, '')}` })
    }
  }

  return items
}

export function volumeSidebar(relDir: string, urlPrefix: string): DefaultTheme.SidebarItem[] {
  const dir = join(DOCS_ROOT, relDir)
  const cat = readCategoryJson(dir)
  const overviewTitle = cat?.label || extractTitle(join(dir, 'index.md')) || humanize(relDir)
  const items = scanDir(dir, urlPrefix)

  return [
    { text: overviewTitle, link: `${urlPrefix}/` },
    ...items,
  ]
}

export function buildSidebar(): DefaultTheme.Sidebar {
  const sidebar: DefaultTheme.Sidebar = {
    '/tutorials/foundations/': volumeSidebar('tutorials/foundations', '/tutorials/foundations'),
    '/tutorials/kernel/': volumeSidebar('tutorials/kernel', '/tutorials/kernel'),
    '/tutorials/drivers/': volumeSidebar('tutorials/drivers', '/tutorials/drivers'),
    '/tutorials/embedded/': volumeSidebar('tutorials/embedded', '/tutorials/embedded'),
    '/tutorials/debugging/': volumeSidebar('tutorials/debugging', '/tutorials/debugging'),
    '/tutorials/virtualization/': volumeSidebar('tutorials/virtualization', '/tutorials/virtualization'),
    '/guides/': volumeSidebar('guides', '/guides'),
    '/notes/': volumeSidebar('notes', '/notes'),
    '/blog/': [
      { text: '内核新闻', link: '/blog/' },
    ],
  }

  return sidebar
}
