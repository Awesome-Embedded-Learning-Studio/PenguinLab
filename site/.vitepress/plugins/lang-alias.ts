import type MarkdownIt from 'markdown-it'

const ALIASES: Record<string, string> = {
  gdb: 'bash',
  kconfig: 'ini',
}

export function langAliasPlugin(md: MarkdownIt): void {
  const defaultFence = md.renderer.rules.fence!.bind(md.renderer.rules)

  md.renderer.rules.fence = (tokens, idx, options, env, self) => {
    const token = tokens[idx]
    const alias = ALIASES[token.info.trim().split(/\s+/)[0]!]
    if (alias) {
      token.info = alias
    }
    return defaultFence(tokens, idx, options, env, self)
  }
}
