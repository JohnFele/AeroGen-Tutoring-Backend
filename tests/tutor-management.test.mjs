import { test } from 'node:test'
import assert from 'node:assert/strict'
import { validateTutorEdit, editAdminTutor } from '../src/controllers/tutorAdmin.controller.js'
const stamp='2026-10-28T15:29:00.123456+00:00'
const edit=(changes,extra={})=>({changes,expectedUpdatedAt:stamp,...extra})
test('edits preserve PostgreSQL timestamp precision, trim strings and deduplicate subjects',()=>{
 const result=validateTutorEdit(edit({public_name:' Demo Tutor ',teaching_modes:['online','online'],hourly_rate:250},{subjectIds:[1,1,2]}))
 assert.equal(result.expectedUpdatedAt,stamp);assert.equal(result.changes.public_name,'Demo Tutor');assert.deepEqual(result.subjectIds,[1,2]);assert.deepEqual(result.changes.teaching_modes,['online'])
})
test('edits cannot elevate roles, alter ownership or erase demo markers',()=>{for(const field of ['role','user_id','demo_dataset','created_at','__proto__'])assert.throws(()=>validateTutorEdit(edit(JSON.parse('{"'+field+'":"admin"}'))))})
test('reject malformed values and incomplete changes',()=>{
 for(const body of [edit({is_featured:'true'}),edit({hourly_rate:-1}),edit({years_experience:Infinity}),edit({year_completed:2020.5}),edit({avatar_url:'javascript:alert(1)'}),edit({teaching_modes:['remote']}),edit({availability_slots:['']}),edit({bio:'x'.repeat(4001)}),edit({},{subjectIds:[-1]}),edit({},{subjectIds:['2']}),{changes:{is_featured:true}},edit({})]) assert.throws(()=>validateTutorEdit(body))
})
test('conflicting concurrent edits return 409 and do not read back or report success',async()=>{
 let result;const res={status(code){this.code=code;return this},json(body){result=body;return this}}
 await editAdminTutor({params:{id:'de000000-0000-4000-8000-000000000201'},body:edit({is_featured:true}),supabase:{rpc:()=>({abortSignal:async()=>({error:{code:'PT409'}})}),from(){throw Error('must not read after conflict')}}},res,error=>{throw error})
 assert.equal(res.code,409);assert.match(result.message,/Reload/)
})
