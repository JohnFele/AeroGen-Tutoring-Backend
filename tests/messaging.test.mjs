import test from 'node:test';import assert from 'node:assert/strict';
import {sendMessage,messageHistory} from '../src/controllers/messaging.controller.js';
const id='de000000-0000-4000-8000-000000000101';
const response=()=>({code:200,status(code){this.code=code;return this},set(){return this},json(body){this.body=body;return this}});
test('message retries carry a stable UUID and never accept a client supplied sender or price',async()=>{
 const res=response();let called=false;
 await sendMessage({params:{id},body:{body:'Hello',requestId:id,senderId:'other'},supabase:{rpc(name,args){called=true;assert.equal(name,'send_tutoring_message');assert.deepEqual(args,{_conversation_id:id,_body:'Hello',_request:id});return{abortSignal:async()=>({data:{message:{id}}})}}}},res,assert.ifError);
 assert(called);assert.equal(res.code,201);
 for(const body of [{body:'Hello'},{body:' ',requestId:id},{body:'Hello',requestId:'bad'}]){const invalid=response();await sendMessage({params:{id},body},invalid,assert.ifError);assert.equal(invalid.code,400)}
});
test('message cursors require both timestamp precision and a valid ID',async()=>{
 const res=response();await messageHistory({params:{id},query:{before:'invalid',beforeId:id}},res,assert.ifError);assert.equal(res.code,400);
});
