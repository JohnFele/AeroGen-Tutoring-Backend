import {test} from 'node:test';import assert from 'node:assert/strict';
import {parseNotificationQuery,notificationCursor,markNotificationRead,deleteNotification,deleteNotifications} from '../src/controllers/notification.controller.js';
const id='de000000-0000-4000-8000-000000000101';
const response=()=>({code:200,status(value){this.code=value;return this},json(body){this.body=body;return this}});
test('notification pagination preserves timestamp precision and rejects invalid filters and cursor injection',()=>{
 const record={id,created_at:'2026-11-04T12:00:00.123456+00:00'},cursor=notificationCursor(record);
 assert.deepEqual(parseNotificationQuery({cursor,filter:'unread'}),{filter:'unread',before:[record.created_at,id]});assert.deepEqual(parseNotificationQuery({}),{filter:'all',before:null});
 for(const query of [{filter:'any'},{cursor:'malformed'},{cursor:Buffer.from(JSON.stringify(["x),user_id.neq.null",id])).toString('base64url')}])assert.throws(()=>parseNotificationQuery(query));
});
test('read acknowledgement is owner scoped and cannot rewrite an existing read timestamp',async()=>{
 const calls=[];const query={update(body){calls.push(['update',body]);return this},eq(...args){calls.push(['eq',...args]);return this},is(...args){calls.push(['is',...args]);return this},in(...args){calls.push(['in',...args]);return this},abortSignal:async()=>({error:null})};
 const res=response();await markNotificationRead({userId:id,body:{all:true},supabase:{from:()=>query}},res,error=>{throw error});assert.equal(res.code,200);assert(calls.some(c=>c[0]==='eq'&&c[1]==='user_id'&&c[2]===id));assert(calls.some(c=>c[0]==='is'&&c[1]==='read_at'&&c[2]===null));assert(!calls.some(c=>c[0]==='in'));
 const invalid=response();await markNotificationRead({body:{all:true,ids:[id]}},invalid,()=>assert.fail());assert.equal(invalid.code,400);
});
test('deleting an absent or inaccessible notification returns 404 without claiming success',async()=>{
 const calls=[];const query={delete(){return this},eq(...args){calls.push(args);return this},select(){return this},maybeSingle(){return this},abortSignal:async()=>({data:null,error:null})};
 const res=response();await deleteNotification({userId:id,params:{id},supabase:{from:()=>query}},res,error=>{throw error});assert.equal(res.code,404);assert(calls.some(c=>c[0]==='user_id'&&c[1]===id));
});

test('bulk deletion is atomic, owner scoped and deduplicated, returning only deleted rows',async()=>{
 const other='de000000-0000-4000-8000-000000000102',calls=[];
 const deleted=[{id,read_at:null}];
 const query={delete(){calls.push(['delete']);return this},eq(...args){calls.push(['eq',...args]);return this},in(...args){calls.push(['in',...args]);return this},select(...args){calls.push(['select',...args]);return this},abortSignal:async()=>({data:deleted,error:null})};
 const res=response();res.set=()=>res;
 await deleteNotifications({userId:id,body:{ids:[id,id,other]},supabase:{from:table=>{assert.equal(table,'notifications');return query}}},res,assert.ifError);
 assert.equal(res.code,200);assert.deepEqual(res.body,{deleted});
 assert(calls.some(c=>c[0]==='eq'&&c[1]==='user_id'&&c[2]===id));
 assert.deepEqual(calls.find(c=>c[0]==='in'),['in','id',[id,other]]);
 assert.equal(calls.filter(c=>c[0]==='delete').length,1);
});

test('invalid bulk deletion input never reaches the database',async()=>{
 for(const ids of [undefined,[],['bad-id'],[null],Array(501).fill(id)]){
  const res=response();await deleteNotifications({body:{ids},supabase:{from:()=>assert.fail('invalid IDs reached the database')}},res,assert.ifError);
  assert.equal(res.code,400);
 }
});
