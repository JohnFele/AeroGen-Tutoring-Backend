import assert from 'node:assert/strict';
import test from 'node:test';
import { updateMe } from '../src/controllers/user.controller.js';
import { requireTutorApproval } from '../src/middleware/auth.middleware.js';

async function save(body) {
  const row = { id: 'profile-owner', first_name: 'Sam', last_name: 'Tester', bio: 'Previous bio', role: 'tutor' };
  let updates;
  const query = {
    update(values) { updates = values; return this; },
    eq(column, value) { assert.deepEqual([column, value], ['id', row.id]); return this; },
    select() { return this; },
    async single() {
      if (updates.bio === null) return { error: { code: '23502', message: 'profiles.bio cannot be null' } };
      return { data: { ...row, ...updates } };
    },
  };
  const req = { body, userId: row.id, supabase: { from(table) { assert.equal(table, 'profiles'); return query; } } };
  const res = { status(code) { this.statusCode = code; return this; }, json(payload) { this.payload = payload; return this; } };
  await updateMe(req, res, assert.ifError);
  return { res, updates };
}

test('a profile save can clear a bio and other optional fields', async () => {
  const { res, updates } = await save({ firstName: ' Samuel ', bio: ' ', phone: '', location: '' });
  assert.deepEqual(updates, { first_name: 'Samuel', phone: null, location: null, bio: '' });
  assert.equal(res.statusCode, 200);
  assert.equal(res.payload.user.firstName, 'Samuel');
  assert.equal(res.payload.user.bio, '');
});

test('partial profile edits leave unsent and protected fields alone', async () => {
  const { res, updates } = await save({ lastName: 'New surname', role: 'admin', profileSetupPending: false, tutorApproved: true });
  assert.deepEqual(updates, { last_name: 'New surname' });
  assert.equal(res.payload.user.bio, 'Previous bio');
  assert.equal(res.payload.user.role, 'tutor');
  assert.equal(res.payload.user.tutorApproved, false);
});

test('workspace API checks persisted approval for tutor accounts', async () => {
  for (const [role, tutorProfile, expected] of [
    ['tutor', null, 403],
    ['tutor', { is_approved: false }, 403],
    ['tutor', { is_approved: true, is_accepting_students: false }, 200],
    ['student', null, 200],
    ['superUser', null, 200],
  ]) {
    const req = { userId: 'caller', supabase: { from(table) {
      assert.equal(table, 'profiles');
      return {
        select(fields) { assert.match(fields, /is_approved/); return this; },
        eq(field, value) { assert.deepEqual([field, value], ['id', req.userId]); return this; },
        async maybeSingle() { return { data: { role, tutor_profile: tutorProfile } }; },
      };
    } } };
    const res = { status(code) { this.statusCode = code; return this; }, json(body) { this.body = body; return this; } };
    await requireTutorApproval(req, res, error => { assert.ifError(error); res.statusCode = 200; });
    assert.equal(res.statusCode, expected);
    if (expected === 403) assert.equal(res.body.code, 'TUTOR_APPROVAL_REQUIRED');
  }
});

test('onboarding only clears the review flag when all required details are submitted together', async () => {
  const incomplete = await save({ firstName: 'Sam', completeSetup: true });
  assert.equal(incomplete.res.statusCode, 400);
  assert.equal(incomplete.updates, undefined);
  const completed = await save({ firstName: 'Sam', lastName: 'Tester', phone: '+27821234567', location: 'Johannesburg', completeSetup: true });
  assert.equal(completed.res.statusCode, 200);
  assert.equal(completed.updates.profile_setup_pending, false);
  assert.equal(completed.res.payload.user.profileSetupPending, false);
});

test('profile updates store stable curriculum codes and allow clearing the selection', async () => {
  const { res, updates } = await save({ curriculumCodes: ['caps-ieb', 'cambridge-igcse', 'caps-ieb'] });
  assert.equal(res.statusCode, 200);
  assert.deepEqual(updates, { curriculum_codes: ['caps-ieb', 'cambridge-igcse'] });
  assert.deepEqual(res.payload.user.curriculumCodes, updates.curriculum_codes);
  assert.deepEqual((await save({ curriculumCodes: [] })).updates, { curriculum_codes: [] });
  assert.equal((await save({ curriculumCodes: 'CAPS / NSC · IEB' })).res.statusCode, 400);
});
