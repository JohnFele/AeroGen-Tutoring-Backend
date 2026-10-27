import { test } from 'node:test'
import assert from 'node:assert/strict'
import http from 'node:http'

process.env.BREVO_API_KEY = 'xkeysib-test-only-not-a-real-key'
process.env.BREVO_SENDER_EMAIL = 'sender@example.test'
const { sendSubjectRequest } = await import('../src/controllers/site.controller.js')
const request = { firstName: 'Demo', lastName: 'Learner', email: 'demo@example.test', subjectName: 'Advanced Computational Fluid Dynamics', moduleCode: 'MEC4021', educationLevel: 'undergraduate', institution: 'Example University', programme: 'Mechanical Engineering', studyYear: 'Fourth year', lessonMode: 'online', location: '', helpNeeded: 'I need help with finite volume methods and turbulence models.', website: '' }
const response = () => ({ code: 0, body: null, status(code) { this.code = code; return this }, json(body) { this.body = body; return this } })

test('unlisted university modules are accepted and routed to the fixed team inbox', async () => {
  const previous = globalThis.fetch
  let payload
  globalThis.fetch = async (_url, options) => { payload = JSON.parse(options.body); return { ok: true } }
  try {
    const res = response()
    await sendSubjectRequest({ body: request }, res)
    assert.equal(res.code, 202)
    assert.equal(payload.to[0].email, 'aerogentutoring@gmail.com')
    assert.equal(payload.replyTo.email, request.email)
    for (const value of [request.subjectName, request.moduleCode, request.institution, request.programme, request.studyYear, request.helpNeeded]) assert(payload.textContent.includes(value), value)
    assert.equal(payload.subject, '[AeroGen] Subject or university module request')
  } finally { globalThis.fetch = previous }
})

test('invalid requests never call the provider', async () => {
  const previous = globalThis.fetch
  globalThis.fetch = async () => { throw new Error('Provider must not be called') }
  try {
    for (const changes of [{ subjectName: '' }, { subjectName: 'x'.repeat(151) }, { educationLevel: 'invented' }, { institution: '' }, { moduleCode: 'x'.repeat(61) }, { helpNeeded: 'short' }, { lessonMode: 'invalid' }, { lessonMode: 'in-person', location: '' }, { website: 'bot.example' }, { email: 'invalid' }, { firstName: 'x'.repeat(61) }]) {
      const res = response()
      await sendSubjectRequest({ body: { ...request, ...changes } }, res)
      assert.equal(res.code, 400, JSON.stringify(changes))
    }
  } finally { globalThis.fetch = previous }
})

test('school requests do not require a university or module code, and user HTML is escaped', async () => {
  const previous = globalThis.fetch
  let payload
  globalThis.fetch = async (_url, options) => { payload = JSON.parse(options.body); return { ok: true } }
  try {
    const res = response()
    await sendSubjectRequest({ body: { ...request, subjectName: 'Specialised reading support', educationLevel: 'foundation', institution: '', moduleCode: '', helpNeeded: '<script>unsafe()</script> I need help with early reading skills.' } }, res)
    assert.equal(res.code, 202)
    assert(payload.htmlContent.includes('&lt;script&gt;'))
    assert(!payload.htmlContent.includes('<script>'))
  } finally { globalThis.fetch = previous }
})

test('provider failures return an error without claiming delivery', async () => {
  const previous = globalThis.fetch
  globalThis.fetch = async () => ({ ok: false, status: 503, text: async () => 'Mock provider outage' })
  try {
    const res = response()
    await sendSubjectRequest({ body: request }, res)
    assert.equal(res.code, 502)
  } finally { globalThis.fetch = previous }
})

test('public subject request route sends a validated module request without requiring sign-in', async () => {
  const { default: app } = await import('../src/app.js')
  const server = app.listen(0, '127.0.0.1')
  await new Promise(resolve => server.once('listening', resolve))
  const previous = globalThis.fetch
  globalThis.fetch = async () => ({ ok: true })
  try {
    const result = await new Promise((resolve, reject) => {
      const req = http.request({ hostname: '127.0.0.1', port: server.address().port, path: '/api/v1/site/subject-requests', method: 'POST', headers: { 'Content-Type': 'application/json' } }, res => {
        let data = ''; res.on('data', chunk => data += chunk); res.on('end', () => resolve({ code: res.statusCode, body: JSON.parse(data) }))
      })
      req.on('error', reject); req.end(JSON.stringify(request))
    })
    assert.equal(result.code, 202)
    assert(result.body.message.includes('subject request was sent'))
  } finally { globalThis.fetch = previous; await new Promise(resolve => server.close(resolve)) }
})
