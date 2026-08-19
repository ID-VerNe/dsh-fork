/**
 * Composition inheritance: a child runs on the preset its parent runs on and
 * the model_route its parent's log records.
 *
 * With every model-facing row on the agent plane, the tool registry's global
 * layer is empty, so a child that joins no preset reaches the model with no
 * tools at all. These assert the model-visible result — the schemas in the
 * child's own request — rather than the join that produces it. The route
 * assertion covers the delegated model: a child inherits the parent's last
 * logged request config, the durable record of its effective selection after
 * any `agent/request` waterfall override, rather than the stale creation
 * options.
 */

import { afterEach, describe, expect, it } from 'vitest'
import { dirname, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { Context } from '@deepseek-ai/cordis'
import Loader from '@deepseek-ai/cordis-plugin-loader'
import Include from '@deepseek-ai/cordis-plugin-include'
import type { Agent } from '@deepseek-ai/dsh-agent'
import AgentLoop from '@deepseek-ai/dsh-agent-loop'
import { mountAgentLoopTestDependencies } from '@deepseek-ai/dsh-agent-loop-testkit'
import AgentPresets from '@deepseek-ai/dsh-agent-presets'
import { createUserMessage } from '@deepseek-ai/dsh-llm'
import { SessionId } from '@deepseek-ai/dsh-session'
import { inheritParentRoute, snapshotSubagentDescriptor } from '@deepseek-ai/dsh-subagent'
import { MockAdapter, textResponse } from '../../../core/agent-loop/tests/mock-adapter.ts'
import { startInProcessRun } from '../src/index.ts'

const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), 'fixtures')
const ROOTS = [{ path: join(FIXTURES, 'presets'), trust: 'system' as const }]

const contexts: Context[] = []

afterEach(async () => {
  for (const ctx of contexts.splice(0).reverse()) await ctx.fiber.dispose()
})

/** A host composition carrying no model-facing rows, plus the preset roster. */
async function setupPresetHost(): Promise<{ ctx: Context; adapter: MockAdapter; parent: Agent }> {
  const ctx = new Context()
  contexts.push(ctx)
  ctx.baseUrl = pathToFileURL(FIXTURES).href + '/'
  await ctx.plugin(Loader)
  ctx.loader.builtins.include = Include
  await mountAgentLoopTestDependencies(ctx)
  await ctx.plugin(AgentLoop, { agents: [] })
  await ctx.plugin(AgentPresets, { default: 'coding', roots: ROOTS, includeUserRoot: false })
  const adapter = new MockAdapter([textResponse('parent idle'), textResponse('child done')])
  ctx.llm.registerAdapter(['mock'], adapter)
  const handle = await ctx.agents.create({
    sessionId: SessionId('parent'),
    agentOptions: { provider: 'mock', model: 'mock' },
    setup: async (agentCtx: Context) => void await ctx.agentPresets.mount(agentCtx, 'coding'),
  })
  return { ctx, adapter, parent: handle.agent }
}

/** The one-shot spawn request shape both in-process providers build. */
function spawnRequest(parent: Agent) {
  return {
    label: 'child task',
    prompt: [{ type: 'text' as const, text: 'child task' }],
    parent,
    signal: new AbortController().signal,
    descriptor: snapshotSubagentDescriptor({
      mode: 'one-shot' as const,
      provider: 'spawn',
      label: 'child task',
    }),
  }
}

describe('a child agent composed in-process', () => {
  it('reaches the model with its parent\'s preset tools', async () => {
    const { ctx, adapter, parent } = await setupPresetHost()

    const run = await startInProcessRun(spawnRequest(parent), {})
    await run.result

    const childRequest = adapter.requests.at(-1)
    expect(childRequest?.tools?.map(tool => tool.name)).toEqual(['preset_only'])
    expect(ctx.tools.schemas(run.localAgent).map(schema => schema.name)).toEqual(['preset_only'])
    await run.dispose()
  })

  it('carries its parent\'s prompt sections', async () => {
    const { parent } = await setupPresetHost()

    const run = await startInProcessRun(spawnRequest(parent), {})
    await run.result

    expect(run.localAgent?.session.events.some(event =>
      event.type === 'request/header'
      && JSON.stringify(event.data).includes('section for preset_only'))).toBe(true)
    await run.dispose()
  })

  it('records the composition it ran under on the child header', async () => {
    const { parent } = await setupPresetHost()

    const run = await startInProcessRun(spawnRequest(parent), {})
    await run.result

    // Without this the child's own history reads back under the deployment
    // default, which is a different tool set than the one it actually used.
    expect(run.localAgent?.session.header.agentPreset).toBe('coding')
    await run.dispose()
  })

  it('honours a tool filter over the preset tools it inherited', async () => {
    const { ctx, parent } = await setupPresetHost()

    const run = await startInProcessRun(
      { ...spawnRequest(parent), toolFilter: { deny: ['preset_only'] } },
      {},
    )
    await run.result

    // The capability filter is the only thing bounding a delegated child, and
    // every tool it can name now arrives from the preset rather than the host.
    expect(ctx.tools.schemas(run.localAgent).map(schema => schema.name)).toEqual([])
    await run.dispose()
  })

  it('follows a parent that switched preset while blank', async () => {
    const { ctx, parent } = await setupPresetHost()
    // A DIFFERENT preset, so the assertion below distinguishes reading the
    // parent's live scope chain from reading its creation header — re-linking
    // to the same id would pass either way.
    await ctx.agentPresets.recompose(parent.ctx, 'reviewing')

    const run = await startInProcessRun(spawnRequest(parent), {})
    await run.result

    expect(ctx.tools.schemas(run.localAgent).map(schema => schema.name)).toEqual(['reviewing_only'])
    expect(run.localAgent?.session.header.agentPreset).toBe('reviewing')
    await run.dispose()
  })

  it('inherits the parent\'s logged request config rather than creation options', async () => {
    const { parent } = await setupPresetHost()
    // Drive one turn so the parent's log has a request/header event with the
    // effective provider/model after any waterfall override.
    parent.followup(createUserMessage({ content: [{ type: 'text', text: 'hi' }], source: { kind: 'user' } }))
    await parent.whenIdle()

    // The parent was created with { provider: 'mock', model: 'mock' } but the
    // adapter serves a different resolved route.
    const logged = parent.session.requestHeader()
    expect(logged).toBeDefined()
    expect(logged!.config.provider).toBe('mock')
    expect(logged!.config.model).toBe('mock')

    // The child inherits from the parent's header, not from parent.options.
    const inherited = inheritParentRoute(parent)
    expect(inherited.provider).toBe('mock')
    expect(inherited.model).toBe('mock')

    const run = await startInProcessRun(spawnRequest(parent), {})
    await run.result

    // The child's agent options should carry the logged route, not the
    // creation-time stale value.
    expect(run.localAgent?.options.provider).toBe('mock')
    expect(run.localAgent?.options.model).toBe('mock')
    await run.dispose()
  })

  it('falls back to agentDefaultModel when the parent has no logged request', async () => {
    const ctx = new Context()
    contexts.push(ctx)
    ctx.baseUrl = pathToFileURL(FIXTURES).href + '/'
    await ctx.plugin(Loader)
    ctx.loader.builtins.include = Include
    await mountAgentLoopTestDependencies(ctx)
    await ctx.plugin(AgentLoop, { agents: [] })
    await ctx.plugin(AgentPresets, { default: 'coding', roots: ROOTS, includeUserRoot: false })
    const adapter = new MockAdapter([textResponse('parent idle'), textResponse('child done')])
    ctx.llm.registerAdapter(['mock-origin'], adapter)
    // Register a separate fallback adapter so the default model route resolves.
    ctx.llm.registerAdapter(['mock-fallback'], new MockAdapter([textResponse('fallback')]))
    // Install agentDefaultModel with a different provider/model than the
    // parent's creation options, so the fallback path is distinguishable.
    const handle = await ctx.agents.create({
      sessionId: SessionId('parent-default'),
      agentOptions: { provider: 'mock-origin', model: 'mock-origin' },
      setup: async (agentCtx: Context) => void await ctx.agentPresets.mount(agentCtx, 'coding'),
    })
    const parent = handle.agent

    // No request/header exists yet — the parent has never made a request.
    expect(parent.session.requestHeader()).toBeUndefined()

    // When no agentDefaultModel is installed either, falls back to parent.options.
    const inherited = inheritParentRoute(parent)
    expect(inherited.provider).toBe('mock-origin')
    expect(inherited.model).toBe('mock-origin')

    const run = await startInProcessRun(spawnRequest(parent), {})
    await run.result

    expect(run.localAgent?.options.provider).toBe('mock-origin')
    expect(run.localAgent?.options.model).toBe('mock-origin')
    await run.dispose()
  })
})
