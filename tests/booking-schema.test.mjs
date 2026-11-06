import assert from 'node:assert/strict';
import test from 'node:test';
import { listSafetyCases } from '../src/controllers/booking.controller.js';
import { adminData } from '../src/controllers/tutorAdmin.controller.js';

function response() {
  return {
    statusCode: 200,
    status(code) { this.statusCode = code; return this; },
    json(body) { this.body = body; return this; },
  };
}

test('missing booking metrics do not take down account and application analytics', async () => {
  const users = [{ id: 'student' }];
  const applications = [{ id: 'application' }];
  const tables = { profiles: users, tutor_profiles: [], tutor_applications: applications };
  const supabase = {
    from(table) {
      assert(Object.hasOwn(tables, table), 'analytics must not read private booking or payment rows as a fallback');
      return { select() { return this; }, order() { return this; }, range() { return this; },
        abortSignal: async () => ({ data: tables[table] }) };
    },
    rpc(name) {
      if (name === 'admin_active_accounts') return { abortSignal: async () => ({ data: { live: 1, all: 2 } }) };
      assert.equal(name, 'admin_booking_metrics');
      return { abortSignal: async () => ({ error: { code: 'PGRST202' } }) };
    },
  };
  const res = response();
  await adminData({ supabase }, res, assert.ifError);
  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.body, {
    users, tutors: [], applications, bookings: [], bookingActivity: [], payments: [], bookingMetricsAvailable: false,
    activeAccounts: { live: 1, all: 2 },
  });
});

test('Safety & Quality reports the missing migration without returning database internals', async () => {
  const supabase = {
    from() {
      return { select() { return this; }, eq() { return this; }, order() { return this; }, range() { return this; },
        abortSignal: async () => ({ error: { code: 'PGRST205', message: 'Unfiltered database error' } }) };
    },
  };
  const res = response();
  await listSafetyCases({ supabase, query: {} }, res, assert.ifError);
  assert.equal(res.statusCode, 503);
  assert.equal(res.body.code, 'BOOKING_SCHEMA_UNAVAILABLE');
  assert(!JSON.stringify(res.body).includes('Unfiltered database error'));
});

test('All safety cases use the same pagination and ordering as individual statuses', async () => {
  const calls = [];
  const rows = [{ status: 'new' }, { status: 'investigating' }, { status: 'resolved' }];
  const query = {
    select() { return this; },
    eq(...args) { calls.push(['eq', ...args]); return this; },
    order(column) { calls.push(['order', column]); return this; },
    range(...args) { calls.push(['range', ...args]); return this; },
    abortSignal: async () => ({ data: rows, count: 28 }),
  };
  const supabase = { from(table) { assert.equal(table, 'booking_safety_cases'); return query; } };
  const res = response();
  await listSafetyCases({ supabase, query: { status: 'all', page: '2' } }, res, assert.ifError);
  assert.deepEqual(calls, [['order', 'created_at'], ['order', 'id'], ['range', 25, 49]]);
  assert.deepEqual(res.body, { cases: rows, total: 28 });

  calls.length = 0;
  await listSafetyCases({ supabase, query: {} }, response(), assert.ifError);
  assert.deepEqual(calls[0], ['eq', 'status', 'new']);
});
