// plan-council guards. Two hooks, both fail open: any error inside them lets
// the call through, because a broken guard must never stop someone working.
//
// 1. Agent dispatch with no explicitly chosen model is refused. "Chosen" means
//    the call passes `model`, or the agent type's definition pins `model:` in
//    its frontmatter (anything but `inherit`). The allow-list is rebuilt from
//    the agent files on every dispatch, so a newly written agent counts at once.
// 2. Inside a subagent, Bash commands that commit, push, rewrite git state,
//    deploy, open a remote shell or delete recursively are refused. This is a
//    deny-list on spellings: best effort, not a security boundary.

import type { Register } from 'claude-code'

type Pinned = Map<string, string>

const FRONTMATTER = /^---\r?\n([\s\S]*?)\r?\n---/

function field(block: string, key: string): string | undefined {
  for (const raw of block.split(/\r?\n/)) {
    const line = raw.trim()
    if (line.startsWith('#')) continue
    const m = line.match(/^([A-Za-z_-]+)\s*:\s*(.*)$/)
    if (m && m[1] === key) {
      const value = (m[2] ?? '').replace(/\s+#.*$/, '').replace(/^["']|["']$/g, '').trim()
      return value === '' ? undefined : value
    }
  }
  return undefined
}

async function readDir($: any, dir: string, prefix: string, into: Pinned) {
  let entries: { name: string; kind: string }[]
  try {
    entries = await $.fs.list(dir)
  } catch {
    return // a missing directory is normal
  }
  for (const entry of entries) {
    if (!entry.name.endsWith('.md')) continue
    try {
      const text: string = await $.fs.read(`${dir}/${entry.name}`)
      const fm = text.match(FRONTMATTER)
      const block = fm?.[1]
      if (block === undefined) continue
      const name = field(block, 'name') ?? entry.name.replace(/\.md$/, '')
      const model = field(block, 'model')
      if (model && model !== 'inherit') into.set(prefix + name, model)
    } catch {
      // unreadable file: skip it, never fail the dispatch on it
    }
  }
}

async function pinnedAgents($: any): Promise<Pinned> {
  const pinned: Pinned = new Map()
  const home = (await $.env.get('HOME')) ?? (await $.env.get('USERPROFILE'))
  await readDir($, `${$.plugin.root}/agents`, `${$.plugin.name}:`, pinned)
  if (home) await readDir($, `${home}/.claude/agents`, '', pinned)
  await readDir($, '.claude/agents', '', pinned)
  return pinned
}

// A program in command position: start of the line, after a separator, or
// after sudo/xargs/env. Matching only there keeps `grep deploy README` legal.
const AT = String.raw`(?:^|[;&|(\n]\s*|\b(?:sudo|xargs|env|exec)\s+)`
const rx = (body: string) => new RegExp(AT + body)

const FORBIDDEN_IN_SUBAGENT: [RegExp, string][] = [
  [rx(String.raw`git\s+(?:-[Cc]\s+\S+\s+)*(commit|push|checkout|restore|reset|clean|stash|rebase|merge|cherry-pick)\b`), 'changes git state (restore from a file backup, never git)'],
  [rx(String.raw`(ssh|scp|rsync|sftp)\b`), 'opens a remote connection'],
  [rx(String.raw`rm\s+(?:\S+\s+)*-(?:-recursive\b|[A-Za-z]*[rR])`), 'deletes recursively'],
  [rx(String.raw`(docker|podman)\s+(?:\S+\s+)*(build|push|compose\s+up)\b`), 'builds or ships an image'],
  [rx(String.raw`(kubectl\s+(apply|delete|rollout)|terraform\s+(apply|destroy)|helm\s+(install|upgrade))\b`), 'changes infrastructure'],
  [rx(String.raw`(npm|pnpm|yarn|make|fly|flyctl|vercel|netlify|firebase|wrangler|serverless)\b[^;&|\n]*\bdeploy\b`), 'deploys'],
]

export const register: Register = on => {
  on('tool.call', { tool: 'Agent' }, async ($, e, next) => {
    try {
      const input = e as any
      const type: string = input.subagent_type ?? 'general-purpose'
      if (input.model) return next(e)
      if (type === 'fork') return next(e) // a fork always runs on the parent's model
      const pinned = await pinnedAgents($)
      if (pinned.has(type)) return next(e)
      return {
        deny:
          `plan-council: no model was chosen for this dispatch of "${type}". ` +
          `Pass "model" explicitly, or dispatch an agent whose definition pins "model:" ` +
          `(pinned here: ${[...pinned.keys()].join(', ') || 'none found'}).`,
      }
    } catch {
      return next(e) // fail open
    }
  })

  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    try {
      if (!(e as any).agentId) return next(e) // the main session is the orchestrator's
      const command = String((e as any).command ?? '')
      for (const [pattern, why] of FORBIDDEN_IN_SUBAGENT) {
        if (pattern.test(command)) {
          return {
            deny:
              `plan-council: subagents may not run a command that ${why}. ` +
              `Report what you need done; the orchestrator does it with the human's confirmation.`,
          }
        }
      }
      return next(e)
    } catch {
      return next(e) // fail open
    }
  })
}
