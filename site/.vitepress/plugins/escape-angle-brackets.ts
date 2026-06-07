import type MarkdownIt from 'markdown-it'

const HTML_TAGS = new Set([
  'a','abbr','address','area','article','aside','audio',
  'b','base','bdi','bdo','blockquote','body','br','button',
  'canvas','caption','cite','code','col','colgroup',
  'data','datalist','dd','del','details','dfn','dialog','div','dl','dt',
  'em','embed','fieldset','figcaption','figure','footer','form',
  'h1','h2','h3','h4','h5','h6','head','header','hgroup','hr','html',
  'i','iframe','img','input','ins','kbd','label','legend','li','link',
  'main','map','mark','menu','meta','meter','nav','noscript',
  'object','ol','optgroup','option','output','p','picture','pre','progress',
  'q','rp','rt','ruby','s','samp','script','section','select','slot',
  'small','source','span','strong','style','sub','summary','sup',
  'table','tbody','td','template','textarea','tfoot','th','thead',
  'time','title','tr','track','u','ul','var','video','wbr',
  'client-only','content','doc-footer','doc-sidebar',
  'vp-code-group','vp-tab',
  'svg','path','g','rect','circle','line','polygon','polyline','text',
  'use','defs','clippath','lineargradient','radialgradient','stop',
  'title','desc','image','pattern','mask','marker','symbol','foreignobject',
])

function looksLikePlaceholder(inner: string): boolean {
  const trimmed = inner.trim()
  if (!trimmed) return false
  if (HTML_TAGS.has(trimmed.toLowerCase())) return false
  if (/^[A-Z][a-zA-Z0-9]+$/.test(trimmed)) return false
  return /^[A-Za-z_][A-Za-z0-9_:,\s*&.\-/]*(?:\.\.\.)?$/.test(trimmed)
}

function processLine(line: string): string {
  const segments = line.split(/(``[^`]*``|`[^`]*`)/)
  return segments.map((seg, i) => {
    if (i % 2 === 1) return seg
    return seg.replace(/<([^<>\n]+)>/g, (match, inner) => {
      return looksLikePlaceholder(inner)
        ? `&lt;${inner.trim()}&gt;`
        : match
    })
  }).join('')
}

function escapePlaceholders(src: string): string {
  const lines = src.split('\n')
  let inFence = false
  let fenceChar = ''

  return lines.map(line => {
    const fenceMatch = line.match(/^(\s*)(```+|~~~+)/)
    if (fenceMatch) {
      const marker = fenceMatch[2]
      if (!inFence) {
        inFence = true
        fenceChar = marker[0]
        return line
      }
      if (marker[0] === fenceChar && marker.length >= 3) {
        inFence = false
        fenceChar = ''
      }
      return line
    }

    if (inFence) return line
    return processLine(line)
  }).join('\n')
}

function sanitizeHtml(html: string): string {
  return html.replace(
    /<\/?([a-zA-Z][a-zA-Z0-9:-]*)([^>]*)>/g,
    (match, tag: string) => {
      if (HTML_TAGS.has(tag.toLowerCase())) return match
      if (tag[0] === tag[0].toUpperCase() && tag[0] !== tag[0].toLowerCase()) return match
      return match.replace(/^</, '&lt;').replace(/>$/, '&gt;')
    }
  )
}

export function escapeAngleBrackets(md: MarkdownIt): void {
  const originalRender = md.render.bind(md)

  md.render = function (src: string, env?: unknown): string {
    const processedSrc = escapePlaceholders(src)
    let html = originalRender(processedSrc, env)
    return sanitizeHtml(html)
  }
}
