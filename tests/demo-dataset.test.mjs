import { test } from 'node:test'
import assert from 'node:assert/strict'
import { buildDemoDataset } from '../src/data/buildDemoDataset.js'
import { subjects } from '../src/data/subjectCatalog.js'

const fixture = buildDemoDataset('2026-10-28')
test('demo accounts use reserved addresses, distinct stable IDs, and ordinary student/tutor roles', () => {
  assert.equal(fixture.accounts.filter(account => account.role === 'student').length, 6)
  assert.equal(fixture.accounts.filter(account => account.role === 'tutor').length, 5)
  assert.equal(new Set(fixture.accounts.map(account => account.id)).size, 11)
  for (const account of fixture.accounts) { assert(account.email.endsWith('@example.test')); assert(['student','tutor'].includes(account.role)); assert(account.firstName.startsWith('Demo')) }
  assert.deepEqual(buildDemoDataset('2026-10-28'), fixture)
})
test('bookings reference matching demo accounts and valid tutor subjects, durations and amounts', () => {
  const accounts = new Map(fixture.accounts.map(account => [account.id, account]))
  const names = new Set(subjects.map(subject => subject.name))
  for (const booking of fixture.bookings) {
    assert.equal(accounts.get(booking.student_id).role, 'student')
    assert.equal(accounts.get(booking.tutor_id).role, 'tutor')
    assert(accounts.get(booking.tutor_id).subjects.includes(booking.subject))
    assert(names.has(booking.subject))
    assert.equal((Date.parse(booking.ends_at)-Date.parse(booking.starts_at))/60000, booking.duration_minutes)
    assert.equal(booking.total_amount, booking.hourly_rate*booking.duration_minutes/60)
  }
  assert.deepEqual(new Set(fixture.bookings.map(booking => booking.status)), new Set(['completed','confirmed','pending','cancelled','declined']))
})
test('payments are simulated, reviews refer to completed lessons, and messages stay within conversation membership', () => {
  const bookings = new Map(fixture.bookings.map(booking => [booking.id, booking]))
  for (const payment of fixture.payments) { assert.equal(payment.provider, 'demo'); assert.equal(payment.amount, bookings.get(payment.booking_id).total_amount) }
  for (const review of fixture.reviews) assert.equal(bookings.get(review.booking_id).status, 'completed')
  for (const message of fixture.messages) { const conversation = fixture.conversations.find(item => item.id === message.conversation_id); assert([conversation.student_id, conversation.tutor_id].includes(message.sender_id)) }
})
test('new student has empty-state coverage and pending tutor has no bookings', () => {
  const newcomer = fixture.accounts.find(account => account.key === 'student-new')
  assert(!fixture.bookings.some(booking => booking.student_id === newcomer.id))
  assert(!fixture.notifications.some(notification => notification.user_id === newcomer.id))
  assert(!fixture.conversations.some(conversation => conversation.student_id === newcomer.id))
  const pending = fixture.tutors.find(tutor => !tutor.approved)
  assert(!fixture.bookings.some(booking => booking.tutor_id === pending.id))
})
