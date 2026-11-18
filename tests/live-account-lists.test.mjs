import test from 'node:test';
import assert from 'node:assert/strict';
import { listStudents } from '../src/controllers/studentAdmin.controller.js';
import { listAdminTutors } from '../src/controllers/tutorAdmin.controller.js';
import { listApplications } from '../src/controllers/application.controller.js';
const res=()=>({json(body){this.body=body;return this;}});

test('student and tutor admin lists exclude demo accounts at query time', async () => {
  for(const [handler,key] of [[listStudents,'students'],[listAdminTutors,'tutors']]) {
    let filtered=false;
    const supabase={from(){return {select(){return this;},eq(){return this;},is(field,value){assert.equal(field,'demo_dataset');assert.equal(value,null);filtered=true;return this;},order(){return this;},range(){return this;},abortSignal:async()=>({data:filtered?[{id:'live'}]:[{id:'demo',demo_dataset:'test'}]})};}};
    const response=res();await handler({supabase},response,assert.ifError);assert(filtered);assert.deepEqual(response.body[key],[{id:'live'}]);
  }
});

test('application review queues omit demo applications while retaining real history', async () => {
  const data=[{id:'live',profiles:{demo_dataset:null}},{id:'demo',profiles:{demo_dataset:'test'}}];
  const supabase={from(){return {select(){return this;},order(){return this;},range(){return this;},abortSignal:async()=>({data})};}};
  const response=res();await listApplications({supabase},response,assert.ifError);assert.deepEqual(response.body.applications,[data[0]]);
});
