import { test } from 'node:test';
import assert from 'node:assert/strict';
import { applySupportSearch, parseSupportSearch } from '../src/utils/supportSearch.js';

test('support searches accept full references, prefixes, and previous ticket aliases', () => {
  assert.deepEqual(parseSupportSearch({ reference: 'bil-stu-sub-20261105t142530z-123' }, 'tickets').match,
    ['case_reference', 'BIL-STU-SUB-20261105T142530Z-123', true]);
  assert.deepEqual(parseSupportSearch({ reference: 'BIL-STU-SUB-' }, 'tickets').match, ['case_reference', 'BIL-STU-SUB-', false]);
  assert.deepEqual(parseSupportSearch({ reference: 'BIL-123' }, 'tickets').match, ['category_reference', 'BIL-123', true]);
  assert.deepEqual(parseSupportSearch({ reference: 'AG-123' }, 'tickets').match, ['reference', 'AG-123', true]);
  const oldEnquiry = 'be000000-0000-4000-8000-000000000001';
  assert.deepEqual(parseSupportSearch({ reference: oldEnquiry }, 'enquiries').match, ['id', oldEnquiry, true]);
});

test('searches use a bounded UTC day and reject wildcard or malformed query values', () => {
  const calls = [];
  const query = Object.fromEntries(['like','eq','gte','lt'].map(method => [method, (...args) => { calls.push([method, ...args]); return query; }]));
  applySupportSearch(query, parseSupportSearch({ reference: 'TUT-GST', createdOn: '2026-11-05' }, 'enquiries'));
  assert.deepEqual(calls, [
    ['like', 'case_reference', 'TUT-GST%'],
    ['gte', 'created_at', '2026-11-05T00:00:00.000Z'],
    ['lt', 'created_at', '2026-11-06T00:00:00.000Z'],
  ]);
  for (const reference of ['%', 'BIL_%', 'BIL,STU', ['BIL']]) assert.equal(parseSupportSearch({ reference }, 'tickets'), null);
  assert.equal(parseSupportSearch({ createdOn: '2026-02-30' }, 'enquiries'), null);
});
