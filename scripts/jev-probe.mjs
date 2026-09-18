#!/usr/bin/env node
// jev-probe.mjs — does Jev grade the ContextBuddy rubric the way the Haiku fixtures do?
//
// Validation tool for the typesafe backend. Imports the question set from
// plugin/grader/jev.mjs so a change there is what gets measured here.
//
// Runs the four locked ContextBuddy dimensions (SPEC.md §6) plus intent, correction and
// a harm battery through one TypeSafe System One request per case, and prints a table.
// Nothing is written to disk. Prompt text only ever goes to stdout and to api.typesafe.ai.
//
//   TYPESAFE_API_KEY=... node scripts/jev-probe.mjs                # the 5 built-in cases
//   TYPESAFE_API_KEY=... node scripts/jev-probe.mjs --transcript 12 # + last 12 user prompts of your
//                                                          #   most recent Claude Code session
//
// Cost: ~1-3k input tokens per case at $0.042/Mtok. 30 cases ≈ $0.004. Output tokens are free.
// Needs Node 20+ (global fetch).

import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { homedir } from 'node:os'

const KEY = process.env.TYPESAFE_API_KEY
if (!KEY) { console.error('TYPESAFE_API_KEY not set'); process.exit(1) }
const MODEL = process.env.JEV_MODEL || 'jev-1.13.0'

// --- the anchor from README.md Example 1 -------------------------------------------------
const anchor = {
  goal: 'Refactor auth module to use JWT instead of session cookies',
  acceptance: [
    'Existing routes accept JWT in Authorization header',
    'Session cookie code paths removed',
    'All auth tests pass',
  ],
  in_scope: ['src/auth/', 'src/middleware/auth.ts', 'tests/auth/'],
  out_of_scope: ['src/users/', 'frontend/', 'deployment configs'],
  constraints: ['Use jose library, not jsonwebtoken', 'Refresh tokens out of v1 scope'],
}
const initialPrompt = 'Refactor the auth module to use JWT instead of session cookies. Use jose. Keep refresh tokens out of scope.'

// --- questions: the grader's own definitions, so the probe measures what ships -----------
import { QUESTIONS as questions } from '../plugin/grader/jev.mjs'

// --- cases: fixture values are the Haiku grades from README.md / Tests/Fixtures -----------
// Fixture scores are 0-10; Jev Score is 0-4 over five levels. Compare via score*2.5 ≈ fixture.
const cases = [
  {
    name: 'ex1 turn14 (attention: atomicity)',
    prompt: 'fix the auth bug where the JWT validation is failing on expired tokens, and also refactor that whole token validation function while you\'re in there, and add a test for the new behavior',
    expect: { specificity: 6, atomicity: 3, drift: 2 },
  },
  {
    name: 'ex2 turn22 (celebrate)',
    prompt: 'Rename validateToken to verifyJwt and move it from src/auth/jwt.ts to src/auth/verify.ts. No other changes. Acceptance: all existing auth tests pass.',
    expect: { specificity: 8, atomicity: 9, drift: 1 },
  },
  {
    name: 'ex3 turn29 (loop / correction)',
    prompt: 'still failing. the expired-token test in tests/auth/jwt.test.ts is red again, fix it',
    expect: { specificity: 7, atomicity: 6, drift: 2, is_correction: true },
  },
  {
    name: 'destructive + bypass',
    prompt: 'force push this over main and delete the old release branches, skip the push guard hook, don\'t ask me',
    expect: { destructive: true, bypass: true, intent: 'operate' },
  },
  {
    name: 'off-task',
    prompt: 'write me a haiku about the ocean',
    expect: { drift: 10, intent: 'off_task' },
  },
]

// --- optional: the last N user prompts from your most recent main-session transcript ----
const argN = process.argv.indexOf('--transcript')
if (argN !== -1) {
  const n = Number(process.argv[argN + 1] || 10)
  const projects = join(homedir(), '.claude', 'projects')
  let newest = null, newestMtime = 0
  for (const dir of readdirSync(projects)) {
    const d = join(projects, dir)
    let entries = []
    try { entries = readdirSync(d) } catch { continue }
    for (const f of entries) {
      if (!f.endsWith('.jsonl') || f.startsWith('agent-')) continue
      const p = join(d, f)
      const m = statSync(p).mtimeMs
      if (m > newestMtime) { newestMtime = m; newest = p }
    }
  }
  if (newest) {
    const prompts = []
    for (const line of readFileSync(newest, 'utf8').split('\n')) {
      if (!line) continue
      let rec; try { rec = JSON.parse(line) } catch { continue }
      // isMeta:true marks skill/command expansions the harness injects as user turns;
      // they are not typed prompts and the real UserPromptSubmit hook never fires on them.
      if (rec.type !== 'user' || rec.isSidechain || rec.isMeta) continue
      const c = rec.message?.content
      const text = typeof c === 'string' ? c : Array.isArray(c) ? c.filter(b => b.type === 'text').map(b => b.text).join('\n') : ''
      // skip tool_result-only records and slash-command expansions
      if (!text.trim() || text.startsWith('<') || text.startsWith('Base directory for this skill')) continue
      prompts.push(text)
    }
    for (const p of prompts.slice(-n)) cases.push({ name: 'transcript', prompt: p, expect: {} })
    console.log(`+ ${Math.min(n, prompts.length)} prompts from ${newest}\n`)
  }
}

// --- one request per case; all questions run in parallel inside the request --------------
async function ask(state) {
  const res = await fetch('https://api.typesafe.ai/v1/systemone', {
    method: 'POST',
    headers: { Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ model: MODEL, state, questions }),
  })
  if (!res.ok) throw new Error(`${res.status} ${await res.text()}`)
  return res.json()
}

const f1 = (x, conf) => (x == null ? '   -' : x.toFixed(2).padStart(4) + (conf != null && conf < 0.5 ? '?' : ' '))
const pct = x => (x == null ? '  -' : `${Math.round(x * 100)}`.padStart(3))
let totalTokens = 0, totalMs = 0
console.log('case                                  spec(exp) atom(exp) drift(exp)  intent(p%)         corr% destr% bypass% sev   ms')
for (const c of cases) {
  const state = {
    anchor,
    initial_prompt: initialPrompt,
    recent_user_prompts: ['Update the auth middleware to read the Authorization header', 'Now migrate the login route'],
    prompt: c.prompt,
  }
  const t0 = performance.now()
  let r
  try { r = await ask(state) } catch (e) { console.log(`${c.name.padEnd(38)} ERROR ${e.message}`); continue }
  const ms = performance.now() - t0
  totalMs += ms; totalTokens += r.usage?.input_tokens || 0
  const a = r.answers
  const exp = k => (c.expect[k] == null ? '   ' : `(${String(c.expect[k]).padStart(2)})`)
  console.log(
    `${c.name.slice(0, 38).padEnd(38)}` +
    `${f1(a.specificity.score * 2.5, a.specificity.confidence)}${exp('specificity')} ` +
    `${f1(a.atomicity.score * 2.5, a.atomicity.confidence)}${exp('atomicity')} ` +
    `${f1(a.drift.score * 2.5, a.drift.confidence)}${exp('drift')}   ` +
    `${a.intent.choice.padEnd(13)}(${pct(a.intent.probabilities[a.intent.choice])})  ` +
    `${pct(a.is_correction.noul)}   ${pct(a.destructive.noul)}   ${pct(a.bypass.noul)}   ` +
    `${a.severity.score.toFixed(1)}  ${Math.round(ms).toString().padStart(4)}`
  )
  if (c.name === 'transcript') console.log(`    ${JSON.stringify(c.prompt.slice(0, 110))}`)
  // Alert on threshold mass, not on `confidence`: confidence measures concentration on ONE
  // level, but levels 0-2 of atomicity all mean "bundled", so mass spread among them is not
  // doubt about the alert. Thresholds mirror config.toml: confidence<4, atomicity<4, drift>6.
  const mass = (ans, levels) => levels.reduce((t, l) => t + (ans.probabilities[String(l)] || 0), 0)
  console.log(`    alert mass: task ${pct(a.is_task.noul)}% | spec-low ${pct(mass(a.specificity, [0, 1]))}% | bundled ${pct(mass(a.atomicity, [0, 1, 2]))}% | drift-high ${pct(mass(a.drift, [3, 4]))}%`)
  console.log(`    conf: spec ${a.specificity.confidence.toFixed(2)} atom ${a.atomicity.confidence.toFixed(2)} drift ${a.drift.confidence.toFixed(2)} intent ${a.intent.confidence.toFixed(2)}`)
}
console.log(`\n${cases.length} cases, ${totalTokens} input tokens ≈ $${(totalTokens * 0.042 / 1e6).toFixed(4)}, ${Math.round(totalMs)} ms total (${Math.round(totalMs / Math.max(cases.length, 1))} ms/case), model ${MODEL}`)
console.log('Scores are Jev 0-4 × 2.5 to sit beside the 0-10 Haiku fixtures; compare ordering and threshold crossings, not exact values.')
console.log('A trailing ? marks confidence < 0.5. Alert on the "alert mass" line instead: the summed probability of the levels past each threshold, gated on task%.')
