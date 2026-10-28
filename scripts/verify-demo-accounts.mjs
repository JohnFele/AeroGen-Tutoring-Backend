// Integration check: signs in only the private manifest's demo accounts, reads
// their normal RLS-protected data, and signs out without sending email.
import fs from 'node:fs'
import assert from 'node:assert/strict'
import { createClient } from '@supabase/supabase-js'
import { ENV } from '../src/config/env.config.js'
import app from '../src/app.js'
import { fileURLToPath } from 'node:url'

const local = fileURLToPath(new URL('../.local/', import.meta.url))
const credentials = JSON.parse(fs.readFileSync(`${local}demo-accounts.json`, 'utf8'))
const fixture = JSON.parse(fs.readFileSync(`${local}demo-fixture.json`, 'utf8'))
assert.equal(new URL(ENV.SUPABASE_URL).hostname.split('.')[0], credentials.projectRef, 'Wrong Supabase project for the demo credentials')
const server = app.listen(0, '127.0.0.1')
await new Promise(resolve => server.once('listening', resolve))
const results = []
try {
  for (const account of credentials.accounts) {
    const client = createClient(ENV.SUPABASE_URL, ENV.SUPABASE_PUBLISHABLE_KEY, { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } })
    let signedIn = false
    try {
      const { data, error } = await client.auth.signInWithPassword({ email: account.email, password: account.password })
      if (error) throw new Error(`${account.key}: sign-in failed (${error.message})`)
      signedIn = true
      assert.equal(data.user.id, account.id)
      const response = await fetch(`http://127.0.0.1:${server.address().port}/api/v1/users/me`, { headers: { Authorization: `Bearer ${data.session.access_token}` } })
      assert.equal(response.status, 200, `${account.key}: backend profile request failed`)
      const { user } = await response.json()
      assert.equal(user.role, account.role)
      assert.equal(user.isDemo, true)
      assert.equal(user.isVerified, true)
      const tables = await Promise.all(['bookings','payments','messages','notifications','conversations'].map(async table => {
        const { data, error } = await client.from(table).select('id')
        if (error) throw new Error(`${account.key}: ${table} read failed (${error.message})`)
        return [table, data.length]
      }))
      const counts = Object.fromEntries(tables)
      const expectedBookings = fixture.bookings.filter(row => [row.student_id,row.tutor_id].includes(account.id)).length
      const conversationIds = fixture.conversations.filter(row => [row.student_id,row.tutor_id].includes(account.id)).map(row => row.id)
      assert.equal(counts.bookings, expectedBookings, `${account.key}: booking scope`)
      assert.equal(counts.payments, expectedBookings, `${account.key}: payment scope`)
      assert.equal(counts.messages, fixture.messages.filter(row => conversationIds.includes(row.conversation_id)).length, `${account.key}: message scope`)
      assert.equal(counts.notifications, fixture.notifications.filter(row => row.user_id === account.id).length, `${account.key}: notification scope`)
      assert.equal(counts.conversations, conversationIds.length, `${account.key}: conversation scope`)
      const { data: tutors, error: tutorError } = await client.from('tutor_profiles').select('user_id,is_approved').eq('demo_dataset', credentials.dataset)
      if (tutorError) throw new Error(`${account.key}: tutor discovery failed (${tutorError.message})`)
      assert.equal(tutors.length, account.key === 'tutor-pending' ? 5 : 4)
      if (account.key !== 'tutor-pending') assert(tutors.every(tutor => tutor.is_approved))
      results.push({ account: account.key, role: user.role, ...counts })
      console.log(`PASS ${account.key}: password sign-in, backend profile, private data scope and demo discovery`)
    } finally {
      if (signedIn) { const { error } = await client.auth.signOut({ scope: 'local' }); if (error) throw new Error(`${account.key}: test-session sign-out failed (${error.message})`) }
    }
  }
  const anonymous = createClient(ENV.SUPABASE_URL, ENV.SUPABASE_PUBLISHABLE_KEY, { auth: { persistSession: false, autoRefreshToken: false } })
  const { data: publicTutors, error } = await anonymous.from('tutor_profiles').select('user_id').eq('demo_dataset', credentials.dataset)
  if (error) throw new Error(`Anonymous discovery check failed (${error.message})`)
  assert.equal(publicTutors.length, 0)
  fs.writeFileSync(`${local}demo-verification.json`, JSON.stringify({ verifiedAt: new Date().toISOString(), dataset: credentials.dataset, accounts: results, anonymousDemoTutors: 0 }, null, 2))
  console.log(`Verified ${results.length} working accounts. Anonymous visitors cannot discover demo tutors. Test sessions signed out.`)
} finally { await new Promise(resolve => server.close(resolve)) }
