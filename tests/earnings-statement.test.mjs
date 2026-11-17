import test from 'node:test';
import assert from 'node:assert/strict';
import { earningsStatement } from '../src/controllers/billingSupport.controller.js';

function response() {
  return { status(code) { this.code=code; return this; }, set() {}, json(value) { this.body=value; return this; } };
}

test('earnings statement validates real calendar dates before requesting financial data', async () => {
  for (const query of [{}, {from:'2026-02-30',to:'2026-03-01'}, {from:'0000-01-01',to:'2026-03-01'}, {from:['2026-01-01'],to:'2026-03-01'}]) {
    const res=response();
    await earningsStatement({query,supabase:{rpc(){assert.fail('Invalid dates reached the database');}}},res,assert.ifError);
    assert.equal(res.code,400);
  }
});

test('earnings statement derives account ownership in the database and preserves date errors', async () => {
  const res=response();
  const supabase={rpc(name,args){
    assert.equal(name,'my_tutor_earnings_statement');
    assert.deepEqual(args,{_from:'2026-08-01',_to:'2026-10-31'});
    return {abortSignal:async()=>({error:{code:'22023',message:'Choose up to 12 calendar months.'}})};
  }};
  await earningsStatement({query:{from:'2026-08-01',to:'2026-10-31',owner:'another-user'},supabase},res,assert.ifError);
  assert.equal(res.code,400);
  assert.equal(res.body.message,'Choose up to 12 calendar months.');
});
