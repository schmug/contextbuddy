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

test('parseTranscript sums the last assistant usage into tokensUsed', () => {
  const w = grader.parseTranscript(transcriptText, { windowTurns: 3 })
  assert.equal(w.tokensUsed, 60200)
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

test('buildState substitutes the missing-anchor sentinel', () => {
  const s = grader.buildState({ anchorYaml: null, firstPrompt: 'a', recentPrompts: [], prompt: 'a', lastAssistantText: '', phase: 'pre' })
  assert.equal(s.anchor, 'session.md not found')
})

test('mapAnswers turns the recorded ex1 response into a §4.1 grade with atomicity as dominant signal', () => {
  const g = grader.mapAnswers({ answers: ex1.answers, phase: 'pre', turn: 14, timestamp: '2026-09-17T12:00:00Z', tokensUsed: 47823, tokensLimit: 200000, pollution: { value: 4, rationale: '(carried from turn 13) x' }, thresholds, anchorMissing: false, model: 'jev-1.13.0' })
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
  const g = grader.mapAnswers({ answers: clean, phase: 'post', turn: 2, timestamp: 't', tokensUsed: 1, tokensLimit: 200000, pollution: { value: 1, rationale: 'r' }, thresholds, anchorMissing: false, model: 'm' })
  assert.equal(g.dominant_signal, null)
  assert.equal(g.scores.atomicity.value, 10)
})

test('mapAnswers prefixes anchor-dependent rationales when session.md is missing and keeps them under 120 chars', () => {
  const g = grader.mapAnswers({ answers: ex1.answers, phase: 'pre', turn: 1, timestamp: 't', tokensUsed: 0, tokensLimit: 200000, pollution: { value: 0, rationale: 'no prior grade' }, thresholds, anchorMissing: true, model: 'm' })
  assert.ok(g.scores.drift.rationale.startsWith('session.md not found — '))
  assert.ok(g.scores.confidence.rationale.startsWith('session.md not found — '))
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
  tokens_limit: 200000, window_turns: 3, model: 'jev-latest', thresholds,
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
  assert.ok(String(capture.url).endsWith('/v1/systemone'))
  assert.equal(capture.init.headers.Authorization, 'Bearer k-test')
  const body = JSON.parse(capture.init.body)
  assert.equal(body.model, 'jev-latest')
  assert.deepEqual(Object.keys(body.questions).sort(), Object.keys(grader.QUESTIONS).sort())
  assert.equal(body.state.prompt, 'fix the auth bug and also refactor the validator and add a test')
  assert.equal(body.state.anchor.split('\n')[0], 'goal: Refactor auth module to use JWT')
  assert.ok(!JSON.stringify(body.state).includes('xxxx'), 'tool output must not reach the state')
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

test('grade on pre tolerates a missing transcript and still grades the hook prompt', async () => {
  const capture = {}
  const r = await grader.grade(baseJob({ hook: { transcript_path: '/nonexistent/x.jsonl', prompt: 'p' } }), { fetchImpl: fakeFetch(ex1, { capture }), env })
  assert.equal(JSON.parse(capture.init.body).state.prompt, 'p')
  assert.equal(r.grade.tokens_used, 0)
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
