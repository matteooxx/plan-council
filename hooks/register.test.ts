// Tests for the plan-council guards. Run: claude plugin test <plugin-folder>
// The hooks registered here stand for the engine beneath the plugin.
import { expect, test } from 'claude-code/testing'

const AGENT_FILE = [
  '---',
  'name: implementer',
  '# Purpose: a comment line the parser must skip',
  'tools: Read, Edit',
  'model: claude-opus-5-5',
  '---',
  'body',
].join('\n')

function engine(on: any, opts: { envThrows?: boolean } = {}) {
  on('env.get', () => {
    if (opts.envThrows) throw new Error('env unavailable')
    return { value: undefined }
  })
  on('fs.list', () => ({
    value: [{ name: 'implementer.md', kind: 'file', size: 1, mtimeMs: 0, isLink: false }],
  }))
  on('fs.read', () => ({ value: AGENT_FILE }))
  on('tool.call', () => ({ result: { text: 'ran' } }))
}

const refused = (r: unknown) => /plan-council:/.test(JSON.stringify(r))

test('a dispatch with no model and no pinned definition is refused', async ($, on) => {
  engine(on)
  const r = await ($.tool.call as any)({ tool: 'Agent', description: 'd', prompt: 'p', subagent_type: 'general-purpose' })
  expect(refused(r)).toBe(true)
})

test('a dispatch that names a model passes', async ($, on) => {
  engine(on)
  const r = await ($.tool.call as any)({ tool: 'Agent', description: 'd', prompt: 'p', model: 'sonnet' })
  expect(refused(r)).toBe(false)
})

test('a dispatch of an agent whose frontmatter pins a model passes', async ($, on) => {
  engine(on)
  const r = await ($.tool.call as any)({ tool: 'Agent', description: 'd', prompt: 'p', subagent_type: 'implementer' })
  expect(refused(r)).toBe(false)
})

test('the guard fails open when it cannot work', async ($, on) => {
  engine(on, { envThrows: true })
  const r = await ($.tool.call as any)({ tool: 'Agent', description: 'd', prompt: 'p', subagent_type: 'general-purpose' })
  expect(refused(r)).toBe(false)
})

test('a subagent may not push, delete recursively or deploy', async ($, on) => {
  engine(on)
  for (const command of ['git push origin main', 'cd app && rm -rf build', 'npm run deploy', 'git -C app commit -m x']) {
    const r = await ($.tool.call as any)({ tool: 'Bash', command, agentId: 'a1' })
    expect(refused(r)).toBe(true)
  }
})

test('a subagent may read git and grep for words', async ($, on) => {
  engine(on)
  for (const command of ['git diff --stat', 'grep -rn deploy README.md', 'git log --oneline -5', 'rm -f out.txt']) {
    const r = await ($.tool.call as any)({ tool: 'Bash', command, agentId: 'a1' })
    expect(refused(r)).toBe(false)
  }
})

test('the main session is not restricted', async ($, on) => {
  engine(on)
  const r = await ($.tool.call as any)({ tool: 'Bash', command: 'git push origin main' })
  expect(refused(r)).toBe(false)
})
