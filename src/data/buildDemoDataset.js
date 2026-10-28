import { createHash } from 'node:crypto'
import { demoAccounts, demoBookingCases, demoDatasetName } from './demoDataset.js'

export function demoId(kind, key) {
  const bytes = createHash('sha1').update(`${demoDatasetName}:${kind}:${key}`).digest().subarray(0, 16)
  bytes[6] = (bytes[6] & 15) | 80
  bytes[8] = (bytes[8] & 63) | 128
  const hex = bytes.toString('hex')
  return `${hex.slice(0,8)}-${hex.slice(8,12)}-${hex.slice(12,16)}-${hex.slice(16,20)}-${hex.slice(20)}`
}

export function buildDemoDataset(anchorDate) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(anchorDate) || Number.isNaN(Date.parse(anchorDate))) throw new Error('Use an ISO seed date, YYYY-MM-DD.')
  const accounts = new Map(demoAccounts.map(account => [account.key, account]))
  const at = (days, hour, minute = 0) => {
    const date = new Date(`${anchorDate}T00:00:00+02:00`)
    date.setTime(date.getTime() + days * 86400000 + hour * 3600000 + minute * 60000)
    return date.toISOString()
  }
  const bookings = demoBookingCases.map(item => {
    const tutor = accounts.get(item.tutor)
    const start = at(item.dayOffset, item.hour)
    return { id: demoId('booking', item.key), key: item.key, student_id: accounts.get(item.student).id, tutor_id: tutor.id, subject: item.subject, starts_at: start, ends_at: new Date(Date.parse(start) + item.duration * 60000).toISOString(), duration_minutes: item.duration, hourly_rate: tutor.rate, total_amount: tutor.rate * item.duration / 60, status: item.status, teaching_mode: item.mode, payment_status: item.paymentStatus, created_at: at(item.dayOffset - 7, item.hour), special_requests: `[DEMO ${demoDatasetName}] ${item.student === 'student-university' ? 'Engineering module MEC-DEMO-201: worked examples and independent practice.' : 'Fictional integration-test booking. No lesson or charge is actually arranged.'}` }
  })
  const tutors = demoAccounts.filter(account => account.role === 'tutor').map(account => ({ ...account, application_id: demoId('application', account.key), public_name: `${account.firstName} ${account.lastName}`, bio: `[DEMO] Fictional ${account.scenario.toLowerCase()}. This profile is for integration testing only.` }))
  const payments = bookings.map(booking => ({ id: demoId('payment', booking.key), booking_id: booking.id, payer_id: booking.student_id, payee_id: booking.tutor_id, amount: booking.total_amount, platform_fee: Math.round(booking.total_amount * 0.1 * 100) / 100, status: booking.payment_status, provider: 'demo', provider_reference: `${demoDatasetName}:${booking.key}`, paid_at: ['paid','refunded'].includes(booking.payment_status) ? new Date(Math.min(Date.parse(booking.ends_at), Date.parse(at(-1, 12)))).toISOString() : null, created_at: booking.created_at }))
  const reviews = bookings.filter(booking => booking.status === 'completed').slice(0, 4).map((booking, index) => ({ id: demoId('review', booking.key), booking_id: booking.id, student_id: booking.student_id, tutor_id: booking.tutor_id, rating: index === 2 ? 4 : 5, body: '[DEMO] Clear explanations and useful practice exercises. Fictional review for testing.', created_at: new Date(Date.parse(booking.ends_at) + 3600000).toISOString() }))
  const conversations = bookings.filter(booking => ['primary-maths-completed','school-science-completed','university-engineering-completed','college-accounting-completed'].includes(booking.key)).map((booking, index) => ({ id: demoId('conversation', booking.key), booking_id: booking.id, created_by: booking.student_id, student_id: booking.student_id, tutor_id: booking.tutor_id, created_at: at(-3, 10 + index), student_read_at: at(-1, 10), tutor_read_at: at(0, 8) }))
  const messages = conversations.flatMap((conversation, index) => [
    { id: demoId('message', `${index}:1`), conversation_id: conversation.id, sender_id: conversation.student_id, body: '[DEMO] Could we review the practice questions in our next session?', created_at: at(-2, 10 + index) },
    { id: demoId('message', `${index}:2`), conversation_id: conversation.id, sender_id: conversation.tutor_id, body: '[DEMO] Yes. Bring your attempted solutions so we can work through your reasoning.', created_at: at(-1, 9) },
    { id: demoId('message', `${index}:3`), conversation_id: conversation.id, sender_id: conversation.tutor_id, body: '[DEMO] I have prepared another example for our upcoming lesson.', created_at: at(-1, 18) },
  ])
  const notifications = conversations.flatMap((conversation, index) => [
    { id: demoId('notification', `${index}:message`), user_id: conversation.student_id, kind: 'message', title: '[DEMO] New tutor message', body: 'Your demo tutor shared a practice update.', data: { demo_dataset: demoDatasetName, conversationId: conversation.id }, read_at: null, created_at: at(-1, 18) },
    { id: demoId('notification', `${index}:booking`), user_id: conversation.tutor_id, kind: 'booking', title: '[DEMO] Session history available', body: 'A completed demo lesson is available for reviewing reports.', data: { demo_dataset: demoDatasetName, bookingId: conversation.booking_id }, read_at: index % 2 ? null : at(0, 8), created_at: at(-2, 12) },
  ])
  notifications.push({ id: demoId('notification','pending-application'), user_id: accounts.get('tutor-pending').id, kind: 'application', title: '[DEMO] Application under review', body: 'This fictional tutor application is awaiting review.', data: { demo_dataset: demoDatasetName, applicationId: demoId('application','tutor-pending') }, read_at: null, created_at: at(-1, 12) })
  return { dataset: demoDatasetName, anchorDate, accounts: demoAccounts, tutors, bookings, payments, reviews, conversations, messages, notifications }
}
