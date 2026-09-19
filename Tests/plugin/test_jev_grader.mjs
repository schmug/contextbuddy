// test_jev_grader — unit tests for plugin/grader/jev.mjs (typesafe backend).
// Run: node --test Tests/plugin
// No network: fetch is injected. No prompt text is written anywhere by these tests.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const here = dirname(fileURLToPath(import.meta.url))
const fixtures = join(here, 'fixtures')
const grader = await import('../../plugin/grader/jev.mjs')

const transcriptText = readFileSync(join(fixtures, 'transcript_window.jsonl'), 'utf8')

test('parseTranscript keeps only the last N typed user prompts', () => {
  const w = grader.parseTranscript(transcriptText, { windowTurns: 3 })
  assert.deepEqual(w.prompts, [
    'Now migrate the login route',
    'Run the auth tests',
    'still failing. the expired-token test in tests/auth/jwt.test.ts is red again, fix it',
  ])
})

test('parseTranscript skips isMeta, sidechain and tool-result-only user records', () => {
  const w = grader.parseTranscript(transcriptText, { windowTurns: 10 })
  assert.equal(w.prompts.length, 5)
  assert.ok(!w.prompts.some(p => p.startsWith('Base directory')))
  assert.ok(!w.prompts.some(p => p.includes('sidechain')))
})

test('parseTranscript reports the first typed prompt and the last assistant text', () => {
  const w = grader.parseTranscript(transcriptText, { windowTurns: 3 })
  assert.equal(w.firstPrompt, 'Refactor the auth module to use JWT instead of session cookies. Use jose.')
  assert.equal(w.lastAssistantText, 'Fixed the expiry check; tests pass.')
})

test('parseTranscript strips <system-reminder> blocks from typed prompts and drops reminder-only records', () => {
  const w = grader.parseTranscript(transcriptText, { windowTurns: 10 })
  assert.ok(!w.prompts.some(p => p.includes('<system-reminder>')), 'reminder text must not reach the state')
  assert.ok(!w.prompts.some(p => p.includes('reminder-only')))
  assert.equal(w.firstPrompt, 'Refactor the auth module to use JWT instead of session cookies. Use jose.')
})

test('parseTranscript skips slash-command records so a /command cannot become the anchor', () => {
  // Mirrors jev_shadow.py _SKIP_PREFIXES: <command-name>, <local-command-stdout>, <local-command-caveat>.
  const w = grader.parseTranscript(transcriptText, { windowTurns: 10 })
  assert.ok(!w.prompts.some(p => p.startsWith('<command-name>')), 'slash command record leaked into prompts')
  assert.ok(!w.prompts.some(p => p.startsWith('<local-command-stdout>')), 'command stdout record leaked into prompts')
  assert.equal(w.firstPrompt, 'Refactor the auth module to use JWT instead of session cookies. Use jose.')
})

test('parseTranscript sums the last assistant usage into tokensUsed, ignoring a trailing <synthetic> record', () => {
  const w = grader.parseTranscript(transcriptText, { windowTurns: 3 })
  assert.equal(w.tokensUsed, 60200)
})

// Issue #47: the session model comes from the transcript (hook payloads carry none).
test('parseTranscript reports the model of the last non-synthetic assistant record', () => {
  const w = grader.parseTranscript(transcriptText, { windowTurns: 3 })
  assert.equal(w.model, 'claude-fable-5-1')
  assert.equal(grader.parseTranscript('{"type":"user","message":{"content":"x"}}').model, null)
  const synthOnly = '{"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":0}}}'
  assert.equal(grader.parseTranscript(synthOnly).model, null)
  const haikuThenSynth = '{"type":"assistant","message":{"model":"claude-haiku-4-5-20251001","usage":{"input_tokens":5}}}\n' + synthOnly
  assert.equal(grader.parseTranscript(haikuThenSynth).model, 'claude-haiku-4-5-20251001')
  assert.equal(grader.parseTranscript(haikuThenSynth).tokensUsed, 5)
})

test('contextWindowForModel reads the shared prefix table and honours CLAUDE_CODE_DISABLE_1M_CONTEXT', () => {
  for (const m of ['claude-fable-5-1', 'claude-mythos-5-1', 'claude-sonnet-5', 'claude-opus-5', 'claude-opus-4-8', 'claude-opus-4-7-20260301']) {
    assert.equal(grader.contextWindowForModel(m, {}), 1000000, m)
  }
  for (const m of ['claude-haiku-4-5-20251001', 'claude-sonnet-4-6', 'claude-opus-4-6', 'claude-sonnet-4-5-20250929', 'claude-nova-9', '', null]) {
    assert.equal(grader.contextWindowForModel(m, {}), 200000, String(m))
  }
  assert.equal(grader.contextWindowForModel('claude-fable-5-1', { CLAUDE_CODE_DISABLE_1M_CONTEXT: '1' }), 200000)
})

test('resolveContextWindow: override > autocompact > model > default, then the evidence floor', () => {
  const settings = JSON.stringify({ autoCompactWindow: '500k' })
  const readFile = p => { if (String(p).endsWith('/cfg/settings.json')) return settings; throw new Error('ENOENT') }
  const r = (over) => grader.resolveContextWindow({ model: 'claude-fable-5-1', tokensUsed: 176474, env: {}, readFile, home: '/nowhere', ...over })
  assert.deepEqual(r({}), { tokens_limit: 1000000, limit_source: 'model' })
  assert.deepEqual(r({ model: 'claude-haiku-4-5-20251001' }), { tokens_limit: 200000, limit_source: 'model' })
  assert.deepEqual(r({ model: null }), { tokens_limit: 200000, limit_source: 'default' })
  assert.deepEqual(r({ env: { CONTEXTBUDDY_CONTEXT_WINDOW: '300000' } }), { tokens_limit: 300000, limit_source: 'override' })
  assert.deepEqual(r({ env: { CONTEXTBUDDY_CONTEXT_WINDOW: '300k', CLAUDE_CODE_AUTO_COMPACT_WINDOW: '500k' } }), { tokens_limit: 300000, limit_source: 'override' })
  assert.deepEqual(r({ env: { CLAUDE_CODE_AUTO_COMPACT_WINDOW: '500k' } }), { tokens_limit: 500000, limit_source: 'autocompact' })
  assert.deepEqual(r({ env: { CLAUDE_CONFIG_DIR: '/cfg' } }), { tokens_limit: 500000, limit_source: 'autocompact' })
  assert.deepEqual(r({ env: { CONTEXTBUDDY_CONTEXT_WINDOW: 'lots' } }), { tokens_limit: 1000000, limit_source: 'model' })
  // evidence floor
  assert.deepEqual(r({ model: 'claude-haiku-4-5-20251001', tokensUsed: 250065 }), { tokens_limit: 1000000, limit_source: 'observed' })
  assert.deepEqual(r({ tokensUsed: 1200000 }), { tokens_limit: 1200000, limit_source: 'observed' })
  assert.deepEqual(r({ model: 'claude-haiku-4-5-20251001', tokensUsed: 200000 }), { tokens_limit: 200000, limit_source: 'model' })
  // a hook-resolved base (job.tokens_limit / job.limit_source) is respected, floor still applied
  assert.deepEqual(r({ resolved: { tokens_limit: 300000, limit_source: 'override' } }), { tokens_limit: 300000, limit_source: 'override' })
  assert.deepEqual(r({ resolved: { tokens_limit: 200000, limit_source: 'model' }, tokensUsed: 250065 }), { tokens_limit: 1000000, limit_source: 'observed' })
})

test('parseTranscript tolerates blank and unparseable lines', () => {
  const w = grader.parseTranscript('\n{not json}\n' + transcriptText + '\n', { windowTurns: 1 })
  assert.equal(w.prompts.length, 1)
})

test('mechanicalPollution counts stale reads, re-reads and large tool results', () => {
  const p = grader.mechanicalPollution(transcriptText)
  assert.deepEqual(p.counts, { stale_reads: 1, redundant_reads: 1, large_results: 1 })
  assert.equal(p.value, 4)
  assert.match(p.rationale, /stale reads 1/)
})

// --- questions, state, mapping ------------------------------------------------------------
const ex1 = JSON.parse(readFileSync(join(fixtures, 'jev_response_ex1.json'), 'utf8'))
const pasted = JSON.parse(readFileSync(join(fixtures, 'jev_response_pasted.json'), 'utf8'))
const thresholds = { confidence_attention: 4, atomicity_attention: 4, drift_attention: 6, pollution_attention: 7 }

test('QUESTIONS asks the nine validated judgments with their primitive types', () => {
  const types = Object.fromEntries(Object.entries(grader.QUESTIONS).map(([k, q]) => [k, q.type]))
  assert.deepEqual(types, {
    is_task: 'noul', specificity: 'score', atomicity: 'score', drift: 'score', intent: 'choice',
    is_correction: 'noul', destructive: 'noul', bypass: 'noul', severity: 'score',
  })
  assert.ok('plan_or_evaluate' in grader.QUESTIONS.intent.criteria)
})

test('buildState carries only bounded text fields and no tool output', () => {
  const long = 'y'.repeat(5000)
  const s = grader.buildState({ anchorYaml: long, firstPrompt: long, recentPrompts: [long, 'b'], prompt: long, lastAssistantText: long, phase: 'pre' })
  assert.deepEqual(Object.keys(s).sort(), ['anchor', 'initial_prompt', 'last_assistant_message', 'phase', 'prompt', 'recent_user_prompts'])
  for (const v of [s.anchor, s.initial_prompt, s.prompt, s.last_assistant_message, ...s.recent_user_prompts]) assert.ok(v.length <= 2000)
})

test('buildState on pre drops the current prompt from recent_user_prompts when the transcript already holds it', () => {
  const s = grader.buildState({ anchorYaml: 'goal: x', firstPrompt: 'a', recentPrompts: ['a', 'b', 'c'], prompt: 'c', lastAssistantText: '', phase: 'pre' })
  assert.deepEqual(s.recent_user_prompts, ['a', 'b'])
})

test('buildState anchors on the first typed prompt when session.md is absent', () => {
  const first = 'Refactor the auth module to use JWT instead of session cookies. Use jose.'
  const s = grader.buildState({ anchorYaml: null, firstPrompt: first, recentPrompts: [first, 'b'], prompt: 'b', lastAssistantText: '', phase: 'pre' })
  assert.equal(s.anchor, first)
  const blank = grader.buildState({ anchorYaml: '  \n', firstPrompt: first, recentPrompts: [], prompt: 'b', lastAssistantText: '', phase: 'pre' })
  assert.equal(blank.anchor, first)
})

test('buildState keeps session.md as the anchor when it exists and still sends the first prompt', () => {
  const s = grader.buildState({ anchorYaml: 'goal: x', firstPrompt: 'first', recentPrompts: [], prompt: 'p', lastAssistantText: '', phase: 'pre' })
  assert.equal(s.anchor, 'goal: x')
  assert.equal(s.initial_prompt, 'first')
})

test('buildState sends the first prompt once when it is the anchor', () => {
  const first = 'Refactor the auth module to use JWT instead of session cookies. Use jose.'
  const s = grader.buildState({ anchorYaml: null, firstPrompt: first, recentPrompts: [], prompt: 'b', lastAssistantText: '', phase: 'pre' })
  assert.equal(s.anchor, first)
  assert.equal(s.initial_prompt, '', 'anchor and initial_prompt must not carry the same text twice')
})

test('buildState clips a long first-prompt anchor to head plus tail within the field cap', () => {
  const first = 'H'.repeat(3000) + 'T'.repeat(3000)
  const s = grader.buildState({ anchorYaml: null, firstPrompt: first, recentPrompts: [], prompt: 'p', lastAssistantText: '', phase: 'pre' })
  assert.ok(s.anchor.length <= 2000, `anchor is ${s.anchor.length} chars`)
  assert.ok(s.anchor.startsWith('HHHH'), 'head kept')
  assert.ok(s.anchor.endsWith('TTTT'), 'tail kept')
})

test('buildState throws when neither session.md nor a first prompt exists (no sentinel anchor is ever sent)', () => {
  assert.throws(
    () => grader.buildState({ anchorYaml: null, firstPrompt: '', recentPrompts: [], prompt: 'a', lastAssistantText: '', phase: 'pre' }),
    /anchor/,
  )
  assert.equal(grader.ANCHOR_MISSING, undefined, 'sentinel export must be gone')
})

test('mapAnswers turns the recorded ex1 response into a §4.1 grade with atomicity as dominant signal', () => {
  const g = grader.mapAnswers({ answers: ex1.answers, phase: 'pre', turn: 14, timestamp: '2026-09-17T12:00:00Z', tokensUsed: 47823, tokensLimit: 200000, pollution: { value: 4, rationale: '(carried from turn 13) x' }, thresholds, anchorFromPrompt: false, model: 'jev-1.13.0' })
  assert.equal(g.schema_version, 1)
  assert.equal(g.phase, 'pre')
  assert.equal(g.turn, 14)
  assert.equal(g.scores.confidence.value, 5)
  assert.equal(g.scores.atomicity.value, 3)
  assert.equal(g.scores.drift.value, 2)
  assert.equal(g.scores.pollution.value, 4)
  assert.equal(g.dominant_signal, 'atomicity')
  assert.equal(g.scores.atomicity.rationale, ex1.answers.atomicity.legend['0'])
  assert.equal(g.tokens_used, 47823)
  assert.ok(g.signals.is_task >= 0.9)
  assert.equal(g.signals.intent.choice, 'fix_bug')
  assert.ok(g.signals.masses.atomicity_low > 0.6)
  assert.match(g.summary_update, /intent fix_bug/)
})

test('mapAnswers reports no dominant signal when every value is inside its threshold', () => {
  const clean = structuredClone(ex1.answers)
  clean.atomicity.probabilities = { 0: 0, 1: 0, 2: 0, 3: 0.1, 4: 0.9 }; clean.atomicity.score = 3.9
  const g = grader.mapAnswers({ answers: clean, phase: 'post', turn: 2, timestamp: 't', tokensUsed: 1, tokensLimit: 200000, pollution: { value: 1, rationale: 'r' }, thresholds, anchorFromPrompt: false, model: 'm' })
  assert.equal(g.dominant_signal, null)
  assert.equal(g.scores.atomicity.value, 10)
})

test('mapAnswers marks anchor-dependent rationales as judged against the first prompt when session.md is missing and keeps them under 120 chars', () => {
  const g = grader.mapAnswers({ answers: ex1.answers, phase: 'pre', turn: 1, timestamp: 't', tokensUsed: 0, tokensLimit: 200000, pollution: { value: 0, rationale: 'no prior grade' }, thresholds, anchorFromPrompt: true, model: 'm' })
  assert.ok(g.scores.drift.rationale.startsWith('(anchor: first prompt) '), g.scores.drift.rationale)
  assert.ok(g.scores.confidence.rationale.startsWith('(anchor: first prompt) '), g.scores.confidence.rationale)
  assert.ok(!g.scores.atomicity.rationale.startsWith('(anchor'))
  assert.ok(!/session\.md not found/.test(g.scores.drift.rationale))
  for (const d of ['confidence', 'atomicity', 'drift', 'pollution']) assert.ok(g.scores[d].rationale.length <= 120, d)
})

test('isTaskGated is true for the recorded pasted-output response and false for a real prompt', () => {
  assert.equal(grader.isTaskGated(pasted.answers), true)
  assert.equal(grader.isTaskGated(ex1.answers), false)
})

test('carryPollution re-prefixes the prior rationale with the prior turn and defaults when there is none', () => {
  assert.deepEqual(grader.carryPollution({ turn: 13, value: 4, rationale: '(carried from turn 12) three superseded plans' }), { value: 4, rationale: '(carried from turn 13) three superseded plans' })
  assert.deepEqual(grader.carryPollution(null), { value: 0, rationale: 'no prior grade' })
})

// --- orchestration: grade(job, deps) --------------------------------------------------------
import { spawn } from 'node:child_process'
import { createServer } from 'node:http'

const transcriptPath = join(fixtures, 'transcript_window.jsonl')
const baseJob = (over = {}) => ({
  phase: 'pre', turn: 14, timestamp: '2026-09-17T12:00:00Z',
  hook: { session_id: 's', transcript_path: transcriptPath, cwd: '/tmp/p', prompt: 'fix the auth bug and also refactor the validator and add a test' },
  session_md: 'goal: Refactor auth module to use JWT\nout_of_scope: [frontend/]',
  prior_pollution: { turn: 13, value: 4, rationale: 'three superseded plans' },
  tokens_limit: 200000, limit_source: 'model', session_model: 'claude-fable-5-1', window_turns: 3, model: 'jev-1.13.0', thresholds,
  ...over,
})
const fakeFetch = (body, { status = 200, capture = {} } = {}) => async (url, init) => {
  capture.url = url; capture.init = init
  return { ok: status < 400, status, text: async () => (typeof body === 'string' ? body : JSON.stringify(body)) }
}
const env = { TYPESAFE_API_KEY: 'k-test' }

test('grade sends one request with every question over a bounded state and returns the grade', async () => {
  const capture = {}
  const r = await grader.grade(baseJob(), { fetchImpl: fakeFetch(ex1, { capture }), env })
  assert.equal(r.gated, false)
  assert.equal(r.grade.turn, 14)
  assert.equal(r.grade.dominant_signal, 'atomicity')
  assert.equal(r.grade.scores.pollution.rationale, '(carried from turn 13) three superseded plans')
  assert.equal(r.grade.tokens_used, 60200)
  assert.equal(r.grade.tokens_limit, 200000, 'the job\'s hook-resolved limit is used as given')
  assert.equal(r.grade.limit_source, 'model')
  assert.equal(r.grade.model, 'claude-fable-5-1')
  assert.ok(String(capture.url).endsWith('/v1/systemone'))
  assert.equal(capture.init.headers.Authorization, 'Bearer k-test')
  const body = JSON.parse(capture.init.body)
  assert.equal(body.model, 'jev-1.13.0')
  assert.deepEqual(Object.keys(body.questions).sort(), Object.keys(grader.QUESTIONS).sort())
  assert.equal(body.state.prompt, 'fix the auth bug and also refactor the validator and add a test')
  assert.equal(body.state.anchor.split('\n')[0], 'goal: Refactor auth module to use JWT')
  assert.ok(!JSON.stringify(body.state).includes('xxxx'), 'tool output must not reach the state')
})

// Issue #27: without session.md the anchor used to be the literal 'session.md not found', which
// Jev read as "unrelated to the anchor goal" (drift 6+) on every turn of an anchorless session.
test('grade with no session_md anchors on the first typed prompt and does not blame a missing session.md for drift', async () => {
  const capture = {}
  const r = await grader.grade(baseJob({ session_md: null, hook: { session_id: 's', transcript_path: transcriptPath, cwd: '/tmp/p', prompt: 'Run the auth tests' } }), { fetchImpl: fakeFetch(ex1, { capture }), env })
  const body = JSON.parse(capture.init.body)
  assert.equal(body.state.anchor, 'Refactor the auth module to use JWT instead of session cookies. Use jose.')
  assert.equal(body.state.initial_prompt, '', 'first prompt is the anchor; do not send it twice')
  assert.ok(!JSON.stringify(body.state).includes('session.md not found'))
  assert.ok(r.grade.scores.drift.value <= 2, `drift ${r.grade.scores.drift.value}`)
  assert.ok(!r.grade.scores.drift.rationale.startsWith('session.md not found'), r.grade.scores.drift.rationale)
  assert.notEqual(r.grade.dominant_signal, 'drift')
})

test('grade on post phase grades the last typed prompt, the hook reply, and mechanical pollution', async () => {
  const capture = {}
  const r = await grader.grade(baseJob({ phase: 'post', hook: { transcript_path: transcriptPath, last_assistant_message: 'Fixed it (from hook).' } }), { fetchImpl: fakeFetch(ex1, { capture }), env })
  const body = JSON.parse(capture.init.body)
  assert.equal(body.state.prompt, 'still failing. the expired-token test in tests/auth/jwt.test.ts is red again, fix it')
  assert.equal(body.state.last_assistant_message, 'Fixed it (from hook).')
  assert.equal(r.grade.phase, 'post')
  assert.equal(r.grade.scores.pollution.value, 4)
  assert.match(r.grade.scores.pollution.rationale, /mechanical/)
})

test('grade returns gated for the recorded pasted-output response and produces no grade', async () => {
  const r = await grader.grade(baseJob(), { fetchImpl: fakeFetch(pasted), env })
  assert.equal(r.gated, true)
  assert.equal(r.grade, undefined)
  assert.ok(r.is_task < 0.5)
})

// Issue #8: [grader.typesafe] reaches the grader through the job. task_gate replaces the
// 0.5 default; endpoint is the request base unless TYPESAFE_BASE_URL overrides it.
test('grade gates on job.task_gate and sends the request to job.endpoint unless TYPESAFE_BASE_URL overrides it', async () => {
  const capture = {}
  const gated = await grader.grade(baseJob({ task_gate: 0.99, endpoint: 'http://127.0.0.1:1/base/' }), { fetchImpl: fakeFetch(ex1, { capture }), env })
  assert.equal(gated.gated, true, 'is_task 0.98 is below a 0.99 gate')
  assert.equal(capture.url, 'http://127.0.0.1:1/base/v1/systemone')
  const open = await grader.grade(baseJob({ task_gate: 0.01 }), { fetchImpl: fakeFetch(pasted), env })
  assert.equal(open.gated, false, 'is_task 0.05 clears a 0.01 gate')
  const overridden = {}
  await grader.grade(baseJob({ endpoint: 'http://127.0.0.1:1/base' }), { fetchImpl: fakeFetch(ex1, { capture: overridden }), env: { ...env, TYPESAFE_BASE_URL: 'http://127.0.0.1:2' } })
  assert.equal(overridden.url, 'http://127.0.0.1:2/v1/systemone')
})

// A single POST to a fixed path has no legitimate redirect; following one would forward the
// Bearer key to wherever the server pointed.
test('request sets redirect: "error" so a redirect never forwards the Bearer key', async () => {
  const capture = {}
  await grader.grade(baseJob(), { fetchImpl: fakeFetch(ex1, { capture }), env })
  assert.equal(capture.init.redirect, 'error')
})

// The base URL carries the Bearer key: plaintext http is only allowed to a loopback host.
// The config-driven base (job.endpoint) and the env override (TYPESAFE_BASE_URL) follow the
// same rule; Config.parse in Sources/ContextBuddyCore/Schemas.swift mirrors it.
test('grade refuses a non-loopback http endpoint with exit code 2 before any request', async () => {
  let called = false
  const never = async () => { called = true }
  await assert.rejects(grader.grade(baseJob({ endpoint: 'http://api.example.com' }), { fetchImpl: never, env }), e => e.exitCode === 2 && /https/.test(e.message))
  await assert.rejects(grader.grade(baseJob(), { fetchImpl: never, env: { ...env, TYPESAFE_BASE_URL: 'http://api.example.com' } }), e => e.exitCode === 2)
  await assert.rejects(grader.grade(baseJob({ endpoint: 'not a url' }), { fetchImpl: never, env }), e => e.exitCode === 2)
  assert.equal(called, false, 'no request is sent to a refused endpoint')
  for (const base of ['https://api.example.com', 'http://localhost:1', 'http://127.0.0.1:1', 'http://[::1]:1']) {
    const capture = {}
    await grader.grade(baseJob({ endpoint: base }), { fetchImpl: fakeFetch(ex1, { capture }), env })
    assert.equal(capture.url, `${base}/v1/systemone`)
  }
})

test('grade resolves the window from the transcript model when the job carries no tokens_limit, and floors an impossible one', async () => {
  const job = baseJob(); delete job.tokens_limit
  const r = await grader.grade(job, { fetchImpl: fakeFetch(ex1), env })
  assert.equal(r.grade.tokens_limit, 1000000)
  assert.equal(r.grade.limit_source, 'model')
  assert.equal(r.grade.model, 'claude-fable-5-1')
  const floored = await grader.grade(baseJob({ tokens_limit: 60000, limit_source: 'override' }), { fetchImpl: fakeFetch(ex1), env })
  assert.equal(floored.grade.tokens_limit, 200000)
  assert.equal(floored.grade.limit_source, 'observed')
  assert.ok(floored.grade.tokens_used <= floored.grade.tokens_limit)
})

test('grade on pre tolerates a missing transcript and still grades the hook prompt', async () => {
  const capture = {}
  const r = await grader.grade(baseJob({ hook: { transcript_path: '/nonexistent/x.jsonl', prompt: 'p' }, session_model: null }), { fetchImpl: fakeFetch(ex1, { capture }), env })
  assert.equal(JSON.parse(capture.init.body).state.prompt, 'p')
  assert.equal(r.grade.tokens_used, 0)
  assert.equal(r.grade.model, null, 'no transcript and no hook-resolved model: null')
  const hookModel = await grader.grade(baseJob({ hook: { transcript_path: '/nonexistent/x.jsonl', prompt: 'p' } }), { fetchImpl: fakeFetch(ex1), env })
  assert.equal(hookModel.grade.model, 'claude-fable-5-1', 'the hook-resolved session_model is kept when the transcript is unreadable')
})

test('grade fails with exit code 2 when post phase has no prompt to grade', async () => {
  await assert.rejects(grader.grade(baseJob({ phase: 'post', hook: { transcript_path: '/nonexistent/x.jsonl' } }), { fetchImpl: fakeFetch(ex1), env }), e => e.exitCode === 2)
})

test('grade fails with exit code 5 when TYPESAFE_API_KEY is absent, before any request', async () => {
  let called = false
  await assert.rejects(grader.grade(baseJob(), { fetchImpl: async () => { called = true }, env: {} }), e => e.exitCode === 5 && /TYPESAFE_API_KEY/.test(e.message))
  assert.equal(called, false)
})

test('grade fails with exit code 3 on HTTP errors and on network failures', async () => {
  await assert.rejects(grader.grade(baseJob(), { fetchImpl: fakeFetch('rate limited', { status: 429 }), env }), e => e.exitCode === 3 && /429/.test(e.message))
  await assert.rejects(grader.grade(baseJob(), { fetchImpl: async () => { throw new Error('ECONNRESET') }, env }), e => e.exitCode === 3)
})

test('grade fails with exit code 4 on a non-JSON body or a response missing an answer', async () => {
  await assert.rejects(grader.grade(baseJob(), { fetchImpl: fakeFetch('<html>'), env }), e => e.exitCode === 4)
  const partial = structuredClone(ex1); delete partial.answers.drift
  await assert.rejects(grader.grade(baseJob(), { fetchImpl: fakeFetch(partial), env }), e => e.exitCode === 4 && /drift/.test(e.message))
})

// --- CLI: real fetch against a local server, real exit codes ------------------------------
const cli = join(here, '..', '..', 'plugin', 'grader', 'jev.mjs')
function withServer(payload, fn) {
  return new Promise((resolve, reject) => {
    const srv = createServer((req, res) => { res.setHeader('content-type', 'application/json'); res.end(JSON.stringify(payload)) })
    srv.listen(0, '127.0.0.1', async () => {
      try { resolve(await fn(`http://127.0.0.1:${srv.address().port}`)) } catch (e) { reject(e) } finally { srv.close() }
    })
  })
}
// Async spawn: the fake server lives in this process, so a blocking spawnSync would starve it.
const runCli = (job, extraEnv) => new Promise(resolve => {
  const child = spawn(process.execPath, [cli], { env: { PATH: process.env.PATH, ...extraEnv } })
  let stdout = '', stderr = ''
  child.stdout.on('data', d => { stdout += d }); child.stderr.on('data', d => { stderr += d })
  child.on('close', status => resolve({ status, stdout, stderr }))
  child.stdin.end(typeof job === 'string' ? job : JSON.stringify(job))
})

test('cli prints the grade JSON on stdout and exits 0', async () => {
  await withServer(ex1, async base => {
    const r = await runCli(baseJob(), { TYPESAFE_API_KEY: 'k', TYPESAFE_BASE_URL: base })
    assert.equal(r.status, 0, r.stderr)
    const g = JSON.parse(r.stdout)
    assert.equal(g.dominant_signal, 'atomicity')
    assert.equal(r.stderr, '')
  })
})

test('cli exits 0 with empty stdout and a stderr note when the task gate skips the turn', async () => {
  await withServer(pasted, async base => {
    const r = await runCli(baseJob(), { TYPESAFE_API_KEY: 'k', TYPESAFE_BASE_URL: base })
    assert.equal(r.status, 0)
    assert.equal(r.stdout, '')
    assert.match(r.stderr, /^contextbuddy: task gate/)
  })
})

test('cli exits 5 with empty stdout when the key is missing, and 2 on an unparseable job', async () => {
  const r = await runCli(baseJob(), {})
  assert.equal(r.status, 5); assert.equal(r.stdout, ''); assert.match(r.stderr, /^contextbuddy: /)
  const bad = await runCli('{nope', { TYPESAFE_API_KEY: 'k' })
  assert.equal(bad.status, 2); assert.equal(bad.stdout, '')
})
