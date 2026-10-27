import { test } from 'node:test'
import assert from 'node:assert/strict'
import http from 'node:http'

process.env.BREVO_API_KEY = 'xkeysib-test-only-not-a-real-key';
process.env.BREVO_SENDER_EMAIL = 'sender@example.test';
const { sendEnquiry, sendTutorApplication, validateApplication } = await import('../src/controllers/site.controller.js');
const pdf = Buffer.from('%PDF-1.4\nDemonstration document for automated checks only.').toString('base64');
const application = { firstName: 'Demo', lastName: 'Tutor', email: 'demo@example.test', phone: '0620882443', idNumber: 'test-id-only', address: 'Example', city: 'Johannesburg', province: 'Gauteng', highestQualification: 'Bachelors', institution: 'Example college', yearCompleted: '2025', yearsExperience: '1-2', teachingStyle: 'Explain, practise and check understanding.', hourlyRate: '250', subjects: ['Mathematics'], studentAgeGroups: ['High school'], availability: ['Weekday Evenings'], teachingMode: ['online'] };
const documents = [{ kind: 'idDocument', name: 'id.pdf', content: pdf }, { kind: 'qualificationDocument', name: 'degree.pdf', content: pdf }];
const response = () => ({ code: 0, body: null, status(value) { this.code = value; return this; }, json(value) { this.body = value; return this; } });

test('application documents are validated and copied into provider attachments', () => {
  const result = validateApplication({ application, documents });
  assert.equal(result.attachments.length, 2);
  assert.equal(result.attachments[0].content, pdf);
});
test('missing, duplicate, mislabeled or oversized attachments are rejected', () => {
  for (const invalid of [[documents[0]], [documents[0], documents[0]], [documents[0], { ...documents[1], name: 'malware.exe' }], [documents[0], { ...documents[1], content: 'aGVsbG8=' }]]) assert.throws(() => validateApplication({ application, documents: invalid }));
  assert.throws(() => validateApplication({ application: { ...application, subjects: [] }, documents }));
  assert.throws(() => validateApplication({ application, documents: [{ ...documents[0], content: Buffer.alloc(5 * 1024 * 1024 + 1).toString('base64') }, documents[1]] }));
});
test('enquiry validates input before invoking email provider', async () => {
  const previous = globalThis.fetch;
  globalThis.fetch = () => { throw new Error('Provider must not be called'); };
  try {
    for (const body of [{}, { firstName: 'Demo', lastName: 'User', category: 'general', message: 'short' }, { firstName: 'Demo', lastName: 'User', email: 'bad', category: 'general', message: 'A useful enquiry message' }]) {
      const res = response(); await sendEnquiry({ body }, res); assert.equal(res.code, 400);
    }
  } finally { globalThis.fetch = previous; }
});
test('enquiry email goes only to the fixed business recipient and escapes user HTML', async () => {
  const previous = globalThis.fetch;
  let payload;
  globalThis.fetch = async (url, options) => { assert.equal(url, 'https://api.brevo.com/v3/smtp/email'); payload = JSON.parse(options.body); return { ok: true }; };
  try {
    const res = response(); await sendEnquiry({ body: { firstName: 'Demo', lastName: 'User', email: 'demo@example.test', category: 'careers', message: '<script>alert(1)</script> My application enquiry.' } }, res);
    assert.equal(res.code, 202); assert.equal(payload.to[0].email, 'aerogentutoring@gmail.com'); assert.equal(payload.replyTo.email, 'demo@example.test'); assert(payload.htmlContent.includes('&lt;script&gt;')); assert(!payload.htmlContent.includes('<script>'));
  } finally { globalThis.fetch = previous; }
});
test('tutor submission includes validated files and reports provider failure without success', async () => {
  const previous = globalThis.fetch;
  let payload;
  globalThis.fetch = async (url, options) => { payload = JSON.parse(options.body); return { ok: true }; };
  try {
    const res = response(); await sendTutorApplication({ userId: 'test-account', body: { application, documents } }, res);
    assert.equal(res.code, 202); assert.equal(payload.attachment.length, 2); assert(payload.textContent.includes('test-account'));
    globalThis.fetch = async () => ({ ok: false, status: 503, text: async () => 'Provider unavailable (mock)' });
    const failed = response(); await sendEnquiry({ body: { firstName: 'Demo', lastName: 'User', email: 'demo@example.test', category: 'general', message: 'A useful enquiry message.' } }, failed); assert.equal(failed.code, 502);
  } finally { globalThis.fetch = previous; }
});

test('HTTP routes protect uploads before parsing and expose enquiry validation', async () => {
  const { default: app } = await import('../src/app.js');
  const server = app.listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  const post = (path, body) => new Promise((resolve, reject) => {
    const req = http.request({ hostname: '127.0.0.1', port: server.address().port, path: `/api/v1/site/${path}`, method: 'POST', headers: { 'Content-Type': 'application/json', Origin: 'http://localhost:5173' } }, res => {
      let data = ''; res.on('data', chunk => data += chunk); res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: JSON.parse(data) }));
    });
    req.on('error', reject); req.end(body);
  });
  try {
    // An invalid payload without credentials must fail authentication before JSON parsing.
    const upload = await post('tutor-applications', '{not-json');
    assert.equal(upload.status, 401);
    assert.equal(upload.headers['access-control-allow-origin'], 'http://localhost:5173');
    assert.equal((await post('enquiries', '{}')).status, 400);
    assert.equal((await post('enquiries', '{not-json')).status, 400);
  } finally { await new Promise(resolve => server.close(resolve)); }
});
