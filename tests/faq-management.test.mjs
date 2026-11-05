import {test} from 'node:test';
import assert from 'node:assert/strict';
import {validateFaq,createFaqHandlers} from '../src/controllers/faq.controller.js';
import {initialFaqs} from '../src/data/faqSeed.js';
const id='de000000-0000-4000-8000-000000000911';
const faq={category:'Getting Started',question:'How do I register?',answer:'Choose Sign Up and follow the instructions.',status:'published'};
const response=()=>({statusCode:200,set(){return this},status(code){this.statusCode=code;return this},json(body){this.body=body;return this}});
test('FAQ validation accepts edited content and rejects blank, oversized, protected or unsupported fields',()=>{
  assert.equal(validateFaq({...faq,category:' Getting Started '}).category,'Getting Started');
  for(const input of [{...faq,question:' '},{...faq,answer:'short'},{...faq,answer:'x'.repeat(8001)},{...faq,category:'All categories'},{...faq,category:'New\nCategory'},{...faq,status:'approved'},{...faq,created_at:'2026-01-01'},{...faq,version:2},{...faq,role:'admin'}])assert.throws(()=>validateFaq(input));
});
test('initial questions remain available in six categories without unsupported payment or screening guarantees',()=>{
  assert.equal(initialFaqs.length,21);assert.equal(new Set(initialFaqs.map(row=>row.category)).size,6);
  for(const row of initialFaqs)validateFaq(row);
  assert(!initialFaqs.some(row=>row.answer.includes('bank-level encryption')||row.answer.includes('withdraw earnings to your bank account weekly')));
});
test('FAQ updates check the captured version and keep a conflict from reporting success',async()=>{
  const calls=[];const client={from(table){assert.equal(table,'site_faqs');return{update(body){calls.push(['update',body]);return this},eq(key,value){calls.push([key,value]);return this},select(){return this},maybeSingle(){return this},abortSignal:async()=>({data:null})}}};
  const res=response();await createFaqHandlers().save({params:{id},body:{faq:{...faq,sort_order:1},expectedVersion:4},supabase:client},res,assert.ifError);
  assert.deepEqual(calls[0],['update',faq]);
  assert.equal(res.statusCode,409);assert(calls.some(([key,value])=>key==='version'&&value===4));assert(!res.body.faq);
});
test('creating an FAQ assigns the append rank on the server even if a legacy client sends a rank',async()=>{
  let inserted;
  const client={from(table){
    assert.equal(table,'site_faqs');
    return {insert(row){inserted=row;return this},select(){return this},maybeSingle(){return this},abortSignal:async()=>({data:{...inserted,id}})};
  }};
  const res=response();
  await createFaqHandlers().save({params:{},body:{faq:{...faq,sort_order:1}},supabase:client},res,assert.ifError);
  assert.equal(res.statusCode,201);
  assert.deepEqual(inserted,{...faq,sort_order:10000});
});
test('FAQ validation fails before any database operation and deletion requires a version',async()=>{
  const handlers=createFaqHandlers(),res=response();await handlers.save({params:{id},body:{faq:{...faq,answer:''},expectedVersion:1}},res,assert.ifError);assert.equal(res.statusCode,400);
  const deleted=response();await handlers.remove({params:{id},body:{}},deleted,assert.ifError);assert.equal(deleted.statusCode,400);
});
test('public FAQ reads force published status and do not return partial results after a page failure',async()=>{
  const calls=[];let page=0;const client={from(){return{select(){return this},eq(key,value){calls.push([key,value]);return this},order(key){calls.push(['order',key]);return this},range(){return this},abortSignal:async()=>++page===1?{data:Array.from({length:500},()=>faq)}:{error:{code:'42P01'}}}}};
  const res=response();await createFaqHandlers({getPublicClient:()=>client}).publicList({},res,assert.ifError);assert.equal(res.statusCode,503);assert(!res.body.faqs);assert(calls.some(([key,value])=>key==='status'&&value==='published'));
  assert.deepEqual(calls.filter(([key])=>key==='order').map(([,column])=>column),['sort_order','created_at','id','sort_order','created_at','id']);
});
