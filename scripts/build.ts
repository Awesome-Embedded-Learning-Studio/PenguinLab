import { execFile, execSync } from 'child_process'
import {
  cpSync, mkdirSync, rmSync, writeFileSync,
  readdirSync, readFileSync, existsSync,
  symlinkSync, statSync,
} from 'fs'
import { join, resolve, relative, basename } from 'path'
import { createHash } from 'crypto'
import { createRequire } from 'module'
const require = createRequire(import.meta.url)

// ── CLI Flags ───────────────────────────────────────────────

const FORCE_REBUILD = process.argv.includes('--force') || process.argv.includes('--clean')
const CONCURRENCY = parseInt(process.env.BUILD_CONCURRENCY || '4', 10)

// ── Configuration ───────────────────────────────────────────

interface Volume {
  name: string
  srcDir: string
  urlPrefix: string
}

const VOLUMES: Volume[] = [
  { name: 'foundations', srcDir: 'tutorials/foundations', urlPrefix: '/tutorials/foundations' },
  { name: 'kernel', srcDir: 'tutorials/kernel', urlPrefix: '/tutorials/kernel' },
  { name: 'drivers', srcDir: 'tutorials/drivers', urlPrefix: '/tutorials/drivers' },
  { name: 'embedded', srcDir: 'tutorials/embedded', urlPrefix: '/tutorials/embedded' },
  { name: 'debugging', srcDir: 'tutorials/debugging', urlPrefix: '/tutorials/debugging' },
  { name: 'virtualization', srcDir: 'tutorials/virtualization', urlPrefix: '/tutorials/virtualization' },
  { name: 'notes', srcDir: 'notes', urlPrefix: '/notes' },
  { name: 'blog', srcDir: 'blog', urlPrefix: '/blog' },
]

const PROJECT_ROOT = resolve(import.meta.dirname, '..')
const SITE_DIR = join(PROJECT_ROOT, 'site')
const MAIN_VP = join(SITE_DIR, '.vitepress')
const BUILD_TMP = join(MAIN_VP, '.build-tmp')
const CACHE_DIR = join(MAIN_VP, '.build-cache')
const MANIFEST_PATH = join(CACHE_DIR, 'manifest.json')
const DIST_FINAL = join(MAIN_VP, 'dist')
const DOCUMENTS = join(PROJECT_ROOT, 'document')
const VITEPRESS_BIN = join(resolve(require.resolve('vitepress/package.json', { paths: [SITE_DIR] }), '..'), 'bin', 'vitepress.js')

// ── Logging ─────────────────────────────────────────────────

function ts(): string {
  return new Date().toISOString().substring(11, 19)
}

function log(msg: string) { console.log(`[${ts()}] ${msg}`) }
function logStep(msg: string) {
  console.log(`\n[${ts()}] ${'═'.repeat(60)}`)
  log(`  ${msg}`)
  console.log(`[${ts()}] ${'═'.repeat(60)}`)
}

function memMB(): string {
  const m = process.memoryUsage()
  return `RSS=${(m.rss / 1024 / 1024).toFixed(0)}MB Heap=${(m.heapUsed / 1024 / 1024).toFixed(0)}/${(m.heapTotal / 1024 / 1024).toFixed(0)}MB`
}

// ── Helpers ─────────────────────────────────────────────────

function ensureClean(dir: string) {
  if (existsSync(dir)) rmSync(dir, { recursive: true })
  mkdirSync(dir, { recursive: true })
}

function symlinkDir(target: string, link: string) {
  if (existsSync(link)) rmSync(link, { recursive: true })
  symlinkSync(target, link, 'dir')
}

function countMdFiles(dir: string): number {
  let count = 0
  try {
    for (const e of readdirSync(dir, { withFileTypes: true })) {
      if (e.name.startsWith('.')) continue
      const full = join(dir, e.name)
      if (e.isDirectory()) count += countMdFiles(full)
      else if (e.name.endsWith('.md')) count++
    }
  } catch { /* ignore */ }
  return count
}

function hashDir(dir: string): string {
  const h = createHash('sha256')
  function walk(d: string) {
    try {
      const entries = readdirSync(d, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))
      for (const e of entries) {
        if (e.name.startsWith('.')) continue
        const full = join(d, e.name)
        if (e.isDirectory()) { walk(full); continue }
        h.update(`file:${relative(dir, full)}\n`)
        h.update(readFileSync(full))
        h.update('\n')
      }
    } catch { /* ignore */ }
  }
  walk(dir)
  return h.digest('hex').substring(0, 16)
}

function hashFile(path: string): string {
  const h = createHash('sha256')
  if (!existsSync(path)) return ''
  h.update(readFileSync(path))
  return h.digest('hex').substring(0, 16)
}

function hashBuildInputs(): string {
  const h = createHash('sha256')
  for (const [label, value] of [
    ['site', hashDir(MAIN_VP)],
    ['package', hashFile(join(SITE_DIR, 'package.json'))],
    ['lockfile', hashFile(join(SITE_DIR, 'pnpm-lock.yaml'))],
    ['build-script', hashFile(join(PROJECT_ROOT, 'scripts', 'build.ts'))],
  ]) {
    h.update(`${label}:${value}\n`)
  }
  return h.digest('hex').substring(0, 16)
}

// ── Manifest (incremental build state) ──────────────────────

interface ManifestEntry { hash: string; timestamp: string }
type Manifest = Record<string, ManifestEntry>

function readManifest(): Manifest {
  if (FORCE_REBUILD) {
    log('  --force: discarding build cache')
    if (existsSync(CACHE_DIR)) rmSync(CACHE_DIR, { recursive: true })
    return {}
  }
  if (!existsSync(MANIFEST_PATH)) return {}
  try { return JSON.parse(readFileSync(MANIFEST_PATH, 'utf-8')) } catch { return {} }
}

function writeManifest(manifest: Manifest) {
  mkdirSync(CACHE_DIR, { recursive: true })
  writeFileSync(MANIFEST_PATH, JSON.stringify(manifest, null, 2))
}

// ── Config Generators ───────────────────────────────────────

function generateVolumeConfig(vol: Volume, lang: 'zh' | 'en', absSiteDir: string, absSrcDir: string): string {
  const relSrc = relative(absSiteDir, absSrcDir)
  const outDirName = lang === 'en' ? `${vol.name}-en` : vol.name
  const relOut = relative(absSiteDir, join(BUILD_TMP, 'output', outDirName))
  const prefix = lang === 'en' ? `/en${vol.urlPrefix}` : vol.urlPrefix
  const locale = lang === 'en'
    ? `locales: { root: { label: 'English', lang: 'en-US', title: 'PenguinLab', description: 'Linux Kernel Learning Station' } },`
    : `locales: { root: { label: '中文', lang: 'zh-CN', title: 'PenguinLab', description: 'Linux 内核学习站' } },`
  const vpDir = join(absSiteDir, '.vitepress')
  const relShared = relative(vpDir, join(MAIN_VP, 'config', 'shared')).replace(/\\/g, '/')
  const relSidebar = relative(vpDir, join(MAIN_VP, 'config', 'sidebar')).replace(/\\/g, '/')

  return `import { defineConfig } from 'vitepress'
import { sharedBase, ${lang === 'en' ? 'sharedEnThemeConfig' : 'sharedThemeConfig'} } from '${relShared}'
import { volumeSidebar } from '${relSidebar}'

export default defineConfig({
  ...sharedBase,
  srcDir: '${relSrc.replace(/\\/g, '/')}',
  outDir: '${relOut.replace(/\\/g, '/')}',
  ignoreDeadLinks: true,
  title: '${lang === 'en' ? 'PenguinLab' : 'PenguinLab'}',
  lang: '${lang === 'en' ? 'en-US' : 'zh-CN'}',
  ${locale}
  themeConfig: {
    ...${lang === 'en' ? 'sharedEnThemeConfig' : 'sharedThemeConfig'}(),
    sidebar: { '${prefix}': volumeSidebar('${vol.srcDir}', '${prefix}') },
  },
})
`
}

function generateRootConfig(absSiteDir: string, absSrcDir: string): string {
  const relSrc = relative(absSiteDir, absSrcDir)
  const relOut = relative(absSiteDir, join(BUILD_TMP, 'output', 'root'))
  const vpDir = join(absSiteDir, '.vitepress')
  const relShared = relative(vpDir, join(MAIN_VP, 'config', 'shared')).replace(/\\/g, '/')
  const relNav = relative(vpDir, join(MAIN_VP, 'config', 'nav')).replace(/\\/g, '/')
  const relSidebar = relative(vpDir, join(MAIN_VP, 'config', 'sidebar')).replace(/\\/g, '/')

  return `import { defineConfig } from 'vitepress'
import { sharedBase, sharedThemeConfig, sharedEnThemeConfig } from '${relShared}'
import { navZh, navEn } from '${relNav}'
import { buildSidebar } from '${relSidebar}'

export default defineConfig({
  ...sharedBase,
  srcDir: '${relSrc.replace(/\\/g, '/')}',
  outDir: '${relOut.replace(/\\/g, '/')}',
  ignoreDeadLinks: true,
  title: 'PenguinLab',
  description: 'Linux 内核学习站',
  lang: 'zh-CN',
  locales: {
    root: { label: '中文', lang: 'zh-CN', title: 'PenguinLab', description: 'Linux 内核学习站' },
    en: { label: 'English', lang: 'en-US', title: 'PenguinLab', description: 'Linux Kernel Learning Station', link: '/en/',
      themeConfig: { nav: navEn, editLink: { pattern: 'https://github.com/Awesome-Embedded-Learning-Studio/PenguinLab/edit/main/document/en/:path', text: 'Edit this page on GitHub' } } },
  },
  themeConfig: {
    nav: navZh, sidebar: buildSidebar(), search: { provider: 'local' },
    editLink: { pattern: 'https://github.com/Awesome-Embedded-Learning-Studio/PenguinLab/edit/main/document/:path', text: '在 GitHub 上编辑此页' },
    footer: { message: '基于 VitePress 构建', copyright: 'Copyright ${new Date().getFullYear()} Charliechen' },
    socialLinks: [{ icon: 'github', link: 'https://github.com/Awesome-Embedded-Learning-Studio/PenguinLab' }],
  },
})
`
}

// ── Build Tasks ─────────────────────────────────────────────

interface BuildTask {
  id: string
  vol: Volume
  lang: 'zh' | 'en'
  cacheKey: string
  cached: boolean
}

interface SearchIndexSource {
  dir: string
  lang: 'zh' | 'en' | 'mixed'
}

function prepareVolume(vol: Volume, lang: 'zh' | 'en', manifest: Manifest, buildInputsHash: string): BuildTask {
  const volDocDir = lang === 'en' ? join(DOCUMENTS, 'en', vol.srcDir) : join(DOCUMENTS, vol.srcDir)
  const id = lang === 'en' ? `${vol.name}-en` : vol.name
  const docHash = existsSync(volDocDir) ? hashDir(volDocDir) : ''
  const cacheKey = `${buildInputsHash}-${docHash}`
  const prev = manifest[id]
  const cached = !FORCE_REBUILD && prev && prev.hash === cacheKey && existsSync(join(CACHE_DIR, 'output', id))
  return { id, vol, lang, cacheKey, cached }
}

function execFileAsync(file: string, args: string[], opts?: { cwd?: string }): Promise<void> {
  return new Promise((resolve, reject) => {
    execFile(file, args, { cwd: opts?.cwd ?? PROJECT_ROOT }, (err, stdout, stderr) => {
      if (stdout) process.stdout.write(stdout)
      if (stderr) process.stderr.write(stderr)
      if (err) reject(err)
      else resolve()
    })
  })
}

/** Remove broken symlinks from a directory tree */
function removeBrokenSymlinks(dir: string) {
  try {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const full = join(dir, entry.name)
      if (entry.isDirectory()) {
        removeBrokenSymlinks(full)
      } else if (entry.isSymbolicLink() && !existsSync(full)) {
        rmSync(full)
      }
    }
  } catch { /* ignore */ }
}

/** Recursively copy asset dirs (images, etc.) from zh source that are missing in en target */
function copyMissingAssets(zhDir: string, enDir: string) {
  try {
    if (!existsSync(zhDir) || !statSync(zhDir).isDirectory()) return
    for (const entry of readdirSync(zhDir, { withFileTypes: true })) {
      if (!entry.isDirectory()) continue
      const zhPath = join(zhDir, entry.name)
      const enPath = join(enDir, entry.name)
      // Remove broken symlinks that point to zh source dirs
      if (existsSync(enPath) && !statSync(enPath).isDirectory()) {
        rmSync(enPath)
      }
      if (!existsSync(enPath)) {
        mkdirSync(enDir, { recursive: true })
        execSync(`cp -r "${zhPath}" "${enPath}"`, { stdio: 'pipe' })
      } else if (statSync(enPath).isDirectory()) {
        copyMissingAssets(zhPath, enPath)
      }
    }
  } catch (e: any) {
    log(`  ⚠ copyMissingAssets: ${e.message}`)
  }
}

/** Prepare source directory for a volume (done sequentially before parallel build) */
function prepareVolumeSource(task: BuildTask): void {
  const { id, vol, lang } = task
  if (task.cached) return

  const volDocDir = lang === 'en' ? join(DOCUMENTS, 'en', vol.srcDir) : join(DOCUMENTS, vol.srcDir)
  const volSrcDir = join(BUILD_TMP, `src-${id}`)
  const tmpSite = join(BUILD_TMP, `site-${id}`)

  if (lang === 'en') {
    const enTarget = join(volSrcDir, 'en', vol.srcDir)
    mkdirSync(join(enTarget, '..'), { recursive: true })
    cpSync(volDocDir, enTarget, { recursive: true })
    // Remove broken symlinks and replace with real assets from zh source
    removeBrokenSymlinks(enTarget)
    const zhVolDir = join(DOCUMENTS, vol.srcDir)
    if (existsSync(zhVolDir)) {
      copyMissingAssets(zhVolDir, enTarget)
    }
  } else {
    mkdirSync(volSrcDir, { recursive: true })
    cpSync(volDocDir, join(volSrcDir, vol.srcDir), { recursive: true })
  }

  mkdirSync(join(tmpSite, '.vitepress'), { recursive: true })
  writeFileSync(join(tmpSite, '.vitepress', 'config.ts'), generateVolumeConfig(vol, lang, tmpSite, volSrcDir))
  symlinkDir(join(MAIN_VP, 'theme'), join(tmpSite, '.vitepress', 'theme'))
  symlinkDir(join(MAIN_VP, 'plugins'), join(tmpSite, '.vitepress', 'plugins'))
  symlinkDir(join(MAIN_VP, 'public'), join(tmpSite, '.vitepress', 'public'))
}

async function buildVolume(task: BuildTask): Promise<string> {
  const { id, vol, lang } = task
  const volDocDir = lang === 'en' ? join(DOCUMENTS, 'en', vol.srcDir) : join(DOCUMENTS, vol.srcDir)
  const tmpSite = join(BUILD_TMP, `site-${id}`)
  const volOutput = join(BUILD_TMP, 'output', id)
  const cachedOutput = join(CACHE_DIR, 'output', id)

  if (task.cached) {
    log(`  ${id}: ✓ cached (unchanged)`)
    mkdirSync(volOutput, { recursive: true })
    cpSync(cachedOutput, volOutput, { recursive: true })
    return volOutput
  }

  const mdCount = countMdFiles(volDocDir)
  log(`  ${id}: building ${mdCount} files...`)

  const t0 = Date.now()
  await execFileAsync(process.execPath, [VITEPRESS_BIN, 'build', relative(PROJECT_ROOT, tmpSite)])
  const elapsed = ((Date.now() - t0) / 1000).toFixed(1)

  if (!existsSync(volOutput)) throw new Error(`${id}: output dir not found after build`)
  log(`  ${id}: ✓ built in ${elapsed}s (${mdCount} files, ${memMB()})`)

  mkdirSync(join(CACHE_DIR, 'output'), { recursive: true })
  if (existsSync(cachedOutput)) rmSync(cachedOutput, { recursive: true })
  cpSync(volOutput, cachedOutput, { recursive: true })

  return volOutput
}

async function runParallel<T>(tasks: T[], fn: (t: T) => Promise<void>, limit: number): Promise<void> {
  let idx = 0
  const workers: Promise<void>[] = []
  for (let i = 0; i < Math.min(limit, tasks.length); i++) {
    workers.push((async () => {
      while (idx < tasks.length) {
        const task = tasks[idx++]
        if (task) await fn(task)
      }
    })())
  }
  await Promise.all(workers)
}

// ── Cross-Volume Data Unification ────────────────────────────

function unifyCrossVolumeData(distDir: string) {
  logStep('Step 3.5/4: Unifying cross-volume hash maps & site data')

  const htmlFiles: string[] = []
  function walk(d: string) {
    for (const e of readdirSync(d, { withFileTypes: true })) {
      const full = join(d, e.name)
      if (e.isDirectory()) walk(full)
      else if (e.name.endsWith('.html')) htmlFiles.push(full)
    }
  }
  walk(distDir)
  log(`  Found ${htmlFiles.length} HTML files`)

  const mergedHashMap: Record<string, string> = {}
  let rootSiteDataExpr = ''

  for (const f of htmlFiles) {
    const c = readFileSync(f, 'utf-8')

    const hmMatch = c.match(/__VP_HASH_MAP__\s*=\s*JSON\.parse\("(.+?)"\)/)
    if (hmMatch) {
      try {
        const mapObj: Record<string, string> = JSON.parse(new Function(`return "${hmMatch[1]}"`)())
        Object.assign(mergedHashMap, mapObj)
      } catch { /* skip */ }
    }

    if (f === join(distDir, 'index.html')) {
      const sdMatch = c.match(/__VP_SITE_DATA__\s*=\s*JSON\.parse\("(.+?)"\)/)
      if (sdMatch) rootSiteDataExpr = sdMatch[1]
    }
  }

  const totalEntries = Object.keys(mergedHashMap).length
  log(`  Merged hash map: ${totalEntries} entries`)
  log(`  Root site data: ${rootSiteDataExpr ? 'found' : 'MISSING'}`)

  const hmJsLiteral = JSON.stringify(JSON.stringify(mergedHashMap))

  let patched = 0
  for (const f of htmlFiles) {
    let c = readFileSync(f, 'utf-8')
    let changed = false

    const hmReplace = c.replace(
      /__VP_HASH_MAP__\s*=\s*JSON\.parse\(".+?"\)/,
      `__VP_HASH_MAP__=JSON.parse(${hmJsLiteral})`
    )
    if (hmReplace !== c) { c = hmReplace; changed = true }

    if (rootSiteDataExpr && f !== join(distDir, 'index.html')) {
      const sdReplace = c.replace(
        /__VP_SITE_DATA__\s*=\s*JSON\.parse\(".+?"\)/,
        `__VP_SITE_DATA__=JSON.parse("${rootSiteDataExpr}")`
      )
      if (sdReplace !== c) { c = sdReplace; changed = true }
    }

    if (changed) {
      writeFileSync(f, c)
      patched++
    }
  }
  log(`  Patched ${patched} files with unified data`)
}

// ── Search Index Merge ──────────────────────────────────────

function findSearchIndexFiles(dir: string): Map<'root' | 'en', string> {
  const result = new Map<'root' | 'en', string>()
  const chunksDir = join(dir, 'assets', 'chunks')
  if (!existsSync(chunksDir)) return result
  for (const f of readdirSync(chunksDir)) {
    const m = f.match(/^@localSearchIndex(root|en)\.[^.]+\.js$/)
    if (m) result.set(m[1] as 'root' | 'en', join(chunksDir, f))
  }
  return result
}

type SerializedSearchIndex = {
  documentCount: number
  nextId: number
  documentIds: Record<string, string>
  fieldIds: Record<string, number>
  fieldLength: Record<string, number[]>
  averageFieldLength: number[]
  storedFields: Record<string, Record<string, unknown>>
  dirtCount: number
  index: Array<[string, Record<string, Record<string, number>>]>
  serializationVersion: number
}

function findSearchIndexExportStart(content: string): number {
  let match: RegExpExecArray | null
  let exportStart = -1
  const exportPattern = /;?\s*export\s*\{/g
  while ((match = exportPattern.exec(content)) !== null) {
    exportStart = match.index
  }
  return exportStart
}

function extractSearchIndex(indexPath: string): SerializedSearchIndex | null {
  const content = readFileSync(indexPath, 'utf-8')
  const assignment = content.match(/^const\s+\w+\s*=\s*/)
  const exportStart = findSearchIndexExportStart(content)
  if (!assignment || exportStart === -1) {
    log(`  ⚠ Could not parse: ${relative(PROJECT_ROOT, indexPath)}`)
    return null
  }
  let expr = content.slice(assignment[0].length, exportStart).trim()
  if (expr.endsWith(';')) expr = expr.slice(0, -1).trim()
  const jsonStr: string = new Function(`return (${expr})`)()
  return JSON.parse(jsonStr)
}

function mergeSerializedSearchIndexes(indexes: SerializedSearchIndex[]): SerializedSearchIndex {
  if (indexes.length === 0) throw new Error('No search indexes to merge')

  const fieldIds = indexes[0].fieldIds
  const fieldCount = Object.keys(fieldIds).length
  const merged: SerializedSearchIndex = {
    documentCount: 0,
    nextId: 0,
    documentIds: {},
    fieldIds,
    fieldLength: {},
    averageFieldLength: Array(fieldCount).fill(0),
    storedFields: {},
    dirtCount: 0,
    index: [],
    serializationVersion: indexes[0].serializationVersion,
  }

  const termIndex = new Map<string, Record<string, Record<string, number>>>()
  const fieldLengthSums = Array(fieldCount).fill(0)

  for (const data of indexes) {
    const localToGlobal = new Map<string, string>()
    const fieldMap = new Map<string, string>()

    for (const [fieldName, localFieldId] of Object.entries(data.fieldIds)) {
      const targetFieldId = fieldIds[fieldName]
      if (targetFieldId === undefined) {
        throw new Error(`Incompatible search field: ${fieldName}`)
      }
      fieldMap.set(String(localFieldId), String(targetFieldId))
    }

    for (const [localId, url] of Object.entries(data.documentIds)) {
      const globalId = String(merged.nextId++)
      localToGlobal.set(localId, globalId)
      merged.documentIds[globalId] = url
      merged.storedFields[globalId] = data.storedFields[localId] || {}
      const lengths = data.fieldLength[localId] || []
      merged.fieldLength[globalId] = Array(fieldCount).fill(0)
      for (const [localFieldId, targetFieldId] of fieldMap) {
        const len = lengths[Number(localFieldId)] || 0
        const targetIndex = Number(targetFieldId)
        merged.fieldLength[globalId][targetIndex] = len
        fieldLengthSums[targetIndex] += len
      }
    }

    merged.dirtCount += data.dirtCount || 0

    for (const [term, postings] of data.index) {
      const mergedPostings = termIndex.get(term) || {}
      for (const [localFieldId, docs] of Object.entries(postings)) {
        const targetFieldId = fieldMap.get(localFieldId)
        if (targetFieldId === undefined) continue
        const fieldPostings = mergedPostings[targetFieldId] || {}
        for (const [localId, frequency] of Object.entries(docs)) {
          const globalId = localToGlobal.get(localId)
          if (globalId === undefined) continue
          fieldPostings[globalId] = (fieldPostings[globalId] || 0) + frequency
        }
        mergedPostings[targetFieldId] = fieldPostings
      }
      termIndex.set(term, mergedPostings)
    }
  }

  merged.documentCount = Object.keys(merged.documentIds).length
  merged.averageFieldLength = fieldLengthSums.map((sum) => merged.documentCount > 0 ? sum / merged.documentCount : 0)
  merged.index = [...termIndex.entries()]
  return merged
}

function buildSearchIndexJs(index: SerializedSearchIndex): string {
  const json = JSON.stringify(index)
  return `const e=${JSON.stringify(json)};export{e as default};`
}

async function mergeSearchIndexes(sources: SearchIndexSource[], finalDist: string) {
  logStep('Step 3/4: Merging search indexes')

  const indexesByLang: Record<'zh' | 'en', SerializedSearchIndex[]> = { zh: [], en: [] }
  const targetsByLang: Record<'zh' | 'en', Set<string>> = { zh: new Set(), en: new Set() }

  for (const source of sources) {
    for (const [locale, indexPath] of findSearchIndexFiles(source.dir)) {
      const lang = source.lang === 'mixed'
        ? (locale === 'en' ? 'en' : 'zh')
        : source.lang
      const index = extractSearchIndex(indexPath)
      if (!index) continue
      log(`  ${lang}: ${index.documentCount} docs from ${relative(PROJECT_ROOT, source.dir)} (${locale})`)
      indexesByLang[lang].push(index)

      const target = join(finalDist, 'assets', 'chunks', basename(indexPath))
      if (existsSync(target)) {
        targetsByLang[lang].add(target)
      } else {
        log(`  ⚠ ${lang}: target missing for ${basename(indexPath)}`)
      }
    }
  }

  for (const lang of ['zh', 'en'] as const) {
    const indexes = indexesByLang[lang]
    if (indexes.length === 0) { log(`  ${lang}: no indexes, skipping`); continue }
    const mergedIndex = mergeSerializedSearchIndexes(indexes)
    log(`  ${lang}: merging ${mergedIndex.documentCount} total docs...`)
    const js = buildSearchIndexJs(mergedIndex)
    const allTargets = [...targetsByLang[lang]]
    if (allTargets.length === 0) {
      log(`  ⚠ ${lang}: no target index files in final dist!`)
      continue
    }
    writeFileSync(allTargets[0], js)
    const canonicalName = basename(allTargets[0])
    const stub = `export{default}from"./${canonicalName}";`
    for (let i = 1; i < allTargets.length; i++) {
      writeFileSync(allTargets[i], stub)
    }
    const savedMB = ((js.length - stub.length) * (allTargets.length - 1) / 1024 / 1024).toFixed(1)
    log(`  ${lang}: ✓ 1 canonical + ${allTargets.length - 1} stubs (saved ${savedMB} MB)`)
  }
}

// ── Main ────────────────────────────────────────────────────

async function main() {
  logStep('Split Build — VitePress per-volume build')
  log(`  Project:     ${PROJECT_ROOT}`)
  log(`  Concurrency: ${CONCURRENCY}`)
  log(`  Force:       ${FORCE_REBUILD}`)
  log(`  Memory:      ${memMB()}`)
  const start = Date.now()

  // ── Prepare ─────────────────────────────────────────────
  ensureClean(BUILD_TMP)
  ensureClean(DIST_FINAL)
  mkdirSync(join(BUILD_TMP, 'output'), { recursive: true })

  const manifest = readManifest()
  const buildInputsHash = hashBuildInputs()

  // ── Step 1: Build root ──────────────────────────────────
  logStep('Step 1/4: Building root site (index, booklist, qemu-reference)')

  const rootSrcDir = join(BUILD_TMP, 'root-src')
  mkdirSync(rootSrcDir, { recursive: true })

  // Use index.md as the homepage
  const indexPath = join(DOCUMENTS, 'index.md')
  if (existsSync(indexPath)) {
    cpSync(indexPath, join(rootSrcDir, 'index.md'))
  }

  // Copy standalone pages
  for (const f of ['booklist.md', 'qemu-reference.md']) {
    const s = join(DOCUMENTS, f)
    if (existsSync(s)) cpSync(s, join(rootSrcDir, f))
  }

  // Copy English root pages
  if (existsSync(join(DOCUMENTS, 'en'))) {
    mkdirSync(join(rootSrcDir, 'en'), { recursive: true })
    const enIndexPath = join(DOCUMENTS, 'en', 'index.md')
    if (existsSync(enIndexPath)) {
      cpSync(enIndexPath, join(rootSrcDir, 'en', 'index.md'))
    }
    for (const f of ['booklist.md', 'qemu-reference.md']) {
      const s = join(DOCUMENTS, 'en', f)
      if (existsSync(s)) cpSync(s, join(rootSrcDir, 'en', f))
    }
  }

  const rootTmpSite = join(BUILD_TMP, 'site-root')
  mkdirSync(join(rootTmpSite, '.vitepress'), { recursive: true })
  writeFileSync(join(rootTmpSite, '.vitepress', 'config.ts'), generateRootConfig(rootTmpSite, rootSrcDir))
  symlinkDir(join(MAIN_VP, 'theme'), join(rootTmpSite, '.vitepress', 'theme'))
  symlinkDir(join(MAIN_VP, 'plugins'), join(rootTmpSite, '.vitepress', 'plugins'))
  symlinkDir(join(MAIN_VP, 'public'), join(rootTmpSite, '.vitepress', 'public'))

  const rootT0 = Date.now()
  await execFileAsync(process.execPath, [VITEPRESS_BIN, 'build', '.'], { cwd: rootTmpSite })
  const rootOutput = join(BUILD_TMP, 'output', 'root')
  if (existsSync(rootOutput)) cpSync(rootOutput, DIST_FINAL, { recursive: true })
  log(`  Root: ${((Date.now() - rootT0) / 1000).toFixed(1)}s`)

  // ── Step 2: Build volumes in parallel ────────────────────
  logStep('Step 2/4: Building volumes (parallel)')

  const tasks: BuildTask[] = []
  for (const vol of VOLUMES) {
    for (const lang of ['zh', 'en'] as const) {
      const volDocDir = lang === 'en' ? join(DOCUMENTS, 'en', vol.srcDir) : join(DOCUMENTS, vol.srcDir)
      if (!existsSync(volDocDir)) continue
      if (countMdFiles(volDocDir) === 0) continue
      tasks.push(prepareVolume(vol, lang, manifest, buildInputsHash))
    }
  }

  const cachedCount = tasks.filter(t => t.cached).length
  const buildCount = tasks.length - cachedCount
  log(`  Tasks: ${tasks.length} total, ${cachedCount} cached, ${buildCount} to build`)
  log(`  Concurrency: ${CONCURRENCY}`)

  // Pre-copy all volume sources sequentially (avoids race conditions with shared images)
  for (const task of tasks) {
    if (!task.cached) prepareVolumeSource(task)
  }
  log(`  Sources prepared\n`)

  const searchSources: SearchIndexSource[] = [{ dir: rootOutput, lang: 'mixed' }]
  const newManifest: Manifest = {}

  await runParallel(tasks, async (task) => {
    const volOutput = await buildVolume(task)
    searchSources.push({ dir: volOutput, lang: task.lang })
    cpSync(volOutput, DIST_FINAL, { recursive: true })
    newManifest[task.id] = { hash: task.cacheKey, timestamp: new Date().toISOString() }
  }, CONCURRENCY)

  // ── Step 3: Merge search indexes ────────────────────────
  await mergeSearchIndexes(searchSources, DIST_FINAL)

  // ── Step 3.5: Unify hash maps and site data ─────────────
  unifyCrossVolumeData(DIST_FINAL)

  // ── Step 4: Finalize ────────────────────────────────────
  logStep('Step 4/4: Finalizing')
  rmSync(BUILD_TMP, { recursive: true })
  writeManifest(newManifest)

  let outputFiles = 0
  function countFiles(d: string) { for (const e of readdirSync(d, { withFileTypes: true })) { if (e.isDirectory()) countFiles(join(d, e.name)); else outputFiles++ } }
  countFiles(DIST_FINAL)

  const elapsed = ((Date.now() - start) / 1000).toFixed(1)
  log(`\n  ═══ Build Summary ═══`)
  log(`  Status:   ✓ SUCCESS`)
  log(`  Time:     ${elapsed}s (${cachedCount} cached, ${buildCount} built)`)
  log(`  Output:   ${relative(PROJECT_ROOT, DIST_FINAL)} (${outputFiles} files)`)
  log(`  Memory:   ${memMB()}`)
  log(`  Tip:      Use --force for full rebuild, BUILD_CONCURRENCY=N to adjust parallelism`)
}

main().catch((err) => {
  log('\n  BUILD FAILED')
  console.error(err)
  process.exit(1)
})
