import test from 'node:test';
import assert from 'node:assert/strict';
import {requestBooking,recurringBookingOptions} from '../src/controllers/booking.controller.js';
const tutor='de000000-0000-4000-8000-000000000101',student='de000000-0000-4000-8000-000000000102',requestId='de000000-0000-4000-8000-000000000103';
const body={tutorId:tutor,subjectId:1,startsAt:'2026-12-01T08:00:00Z',duration:60,mode:'in-person',type:'individual',series:{frequency:'weekly',count:4,requestId}};
const response=()=>({code:200,status(code){this.code=code;return this},set(){return this},json(body){this.body=body;return this}});
test('recurring requests delegate all price and credit decisions to the atomic database function',async()=>{
 const result={id:requestId,seriesId:requestId,count:4};let calls=0;
 const supabase={rpc(name,args){calls++;assert.equal(name,'request_recurring_tutoring_booking');assert.equal(args._student,student);assert.equal(args._mode,'in-person');assert.equal(args._count,4);assert.equal(args._request,requestId);assert(!Object.hasOwn(args,'_price'));return{abortSignal:async()=>({data:result})}}};
 const res=response();await requestBooking({body,userId:student,supabase},res,assert.ifError);
 assert.equal(calls,1);assert.equal(res.code,201);assert.deepEqual(res.body,result);
});
test('invalid recurring counts, frequencies and request keys are rejected before any write',async()=>{
 for(const series of [{...body.series,count:1},{...body.series,count:13},{...body.series,count:2.5},{...body.series,frequency:'yearly'},{...body.series,requestId:'bad'}]){
  const res=response();await requestBooking({body:{...body,series},userId:student,supabase:{rpc:()=>assert.fail('invalid series reached database')}},res,assert.ifError);assert.equal(res.code,400);
 }
 const res=response();await recurringBookingOptions({query:{tutorId:tutor,startsAt:body.startsAt,duration:'60',frequency:'weekly',count:'NaN'},userId:student},res,assert.ifError);assert.equal(res.code,400);
});
