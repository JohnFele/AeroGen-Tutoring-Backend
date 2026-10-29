import { test } from 'node:test'
import assert from 'node:assert/strict'
import { validateDraft,saveDraft,resolveSavedDocuments } from '../src/controllers/applicationDraft.controller.js'
const id='cf100000-0000-4000-8000-000000000001',savedId='cf100000-0000-4000-8000-000000000002',saveId='cf100000-0000-4000-8000-000000000003'
const base={id,saveId,expectedVersion:null,application:{firstName:'Partial',idNumber:'TEST-ONLY',address:'Example'},documents:[],step:1,furthestStep:1}
const pdf=Buffer.from('%PDF-1.4\nFictional draft document.').toString('base64')
const file={kind:'idDocument',name:'identity.pdf',content:pdf}
const response=()=>({code:200,set(){},status(code){this.code=code;return this},json(body){this.body=body;return this}})
function client(reads=[null],rpc={data:{id,application:base.application,documents:[],version:1,step:1,furthest_step:1}}){
  const calls=[];return {calls,from(){return{select(){return this},eq(){return this},maybeSingle(){return this},abortSignal:async()=>{const result=reads.shift();if(result instanceof Error)throw result;return{data:result}}}},rpc(name,args){calls.push(['rpc',name,args]);return{abortSignal:async()=>rpc}},storage:{from(){return{async upload(path){calls.push(['upload',path]);return{}},async remove(paths){calls.push(['remove',paths]);return{}},async download(path){calls.push(['download',path]);return{data:new Blob([Buffer.from(pdf,'base64')])}}}}}}
}
const request=supabase=>({supabase,userId:'owner',body:{...base,documents:[file]}})
test('a changed signed-in account cannot receive another accounts pending form save',async()=>{
  const supabase=client(),res=response(),req=request(supabase);req.body.accountId='another-account';await saveDraft(req,res,()=>{throw Error('Account mismatch passed')});assert.equal(res.code,403);assert.equal(supabase.calls.length,0)
})
test('partial drafts permit incomplete fields and retain private identity fields only in the account payload',()=>{
  assert.equal(validateDraft(base),base)
  assert.throws(()=>validateDraft({...base,application:{role:'superUser'}}))
  assert.throws(()=>validateDraft({...base,expectedVersion:undefined}))
  assert.throws(()=>validateDraft({...base,documents:[{...file,content:Buffer.from('not a PDF').toString('base64')}]}))
  assert.throws(()=>validateDraft({...base,documents:[file,file]}))
})
test('saving uploads private documents before an owner-bound atomic draft RPC',async()=>{
  const supabase=client(),res=response();await saveDraft(request(supabase),res,error=>{throw error})
  assert.equal(res.code,200);assert.equal(supabase.calls[0][0],'upload');const rpc=supabase.calls.find(c=>c[0]==='rpc');assert.equal(rpc[1],'save_tutor_application_draft');assert.equal(rpc[2]._documents[0].kind,'idDocument');assert(rpc[2]._documents[0].path.startsWith('owner/'+id+'/'));assert(!res.body.draft.documents.some(d=>Object.hasOwn(d,'path')))
})
test('outdated versions cannot overwrite a draft or upload files',async()=>{
  const supabase=client([{id,version:2,save_id:savedId}]),res=response();await saveDraft(request(supabase),res,error=>{throw error});assert.equal(res.code,409);assert.equal(supabase.calls.length,0)
})
test('definite failed writes clean up uploads but uncertain network outcomes retain them',async()=>{
  for(const error of [{code:'PT409',message:'stale'},{message:'network timeout'}]){
    const supabase=client([null,null],{error}),res=response();await saveDraft(request(supabase),res,()=>{});assert.equal(supabase.calls.some(c=>c[0]==='remove'),error.code==='PT409')
  }
})
test('lost write responses recover the saved draft without deleting its files',async()=>{
  const row={id,save_id:saveId,version:1,application:{},documents:[],step:1,furthest_step:1},supabase=client([null,row],{error:{message:'timeout'}}),res=response();await saveDraft(request(supabase),res,error=>{throw error});assert.equal(res.body.draft.id,id);assert(!supabase.calls.some(c=>c[0]==='remove'))
})
test('resuming saved files resolves only document IDs in the callers own current draft',async()=>{
  const row={id,version:2,documents:[{id:savedId,kind:'idDocument',name:'identity.pdf',size:Buffer.from(pdf,'base64').length,path:'owner/private-document'}]}
  const supabase=client([row]),req={supabase,userId:'owner',body:{submissionId:id,draftVersion:2,documents:[{kind:'idDocument',savedId}]}},res=response();let passed=false;await resolveSavedDocuments(req,res,()=>{passed=true});assert(passed);assert.equal(req.body.documents[0].content,pdf);assert.equal(req.applicationDraft.id,id)
  const denied=client([row]),bad={...req,supabase:denied,body:{submissionId:id,draftVersion:2,documents:[{kind:'idDocument',savedId:saveId}]}};await resolveSavedDocuments(bad,res,()=>{throw Error('Unowned file accepted')});assert.equal(res.code,409);assert(!denied.calls.length)
})
