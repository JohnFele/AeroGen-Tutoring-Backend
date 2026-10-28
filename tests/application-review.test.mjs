import { test } from 'node:test'
import assert from 'node:assert/strict'
import { submitApplication, applicationRecord, reviewApplication } from '../src/controllers/application.controller.js'
import { validateStudentEdit } from '../src/controllers/studentAdmin.controller.js'

const id = 'cf000000-0000-4000-8000-000000000001'
const userId = 'de000000-0000-4000-8000-000000000106'
const pdf = Buffer.from('%PDF-1.4\nFictional verification document.').toString('base64')
const application = { firstName: 'Demo', lastName: 'Applicant', email: 'demo@example.test', phone: '+27620882443', idNumber: 'TEST-ONLY', address: 'Example address', city: 'Johannesburg', province: 'Gauteng', highestQualification: 'BSc', institution: 'Example college', yearCompleted: '2025', yearsExperience: '1-2', teachingStyle: 'Explain and check understanding.', hourlyRate: '250', subjects: ['Mathematics'], studentAgeGroups: ['High school'], availability: ['Weekday Evenings'], teachingMode: ['online'] }
const documents = [{ kind: 'idDocument', name: 'identity.pdf', content: pdf }, { kind: 'qualificationDocument', name: 'qualification.pdf', content: pdf }]
const response = () => ({ code: 0, status(value) { this.code = value; return this }, json(value) { this.body = value; return this } })
function client({ reads = [{data:null},{data:[]},{data:[{id:1,name:'Mathematics'}]}], rpc = {data:id}, uploadError } = {}) {
  const calls = [], queue = [...reads]
  const next = () => { assert(queue.length, 'Unexpected database read'); return queue.shift() }
  const supabase = {
    from(table) {
      calls.push(['read',table])
      const builder = { select(columns) { calls.push(['select',columns]); return this }, eq() { return this }, in() { return this }, limit() { return this }, maybeSingle() { return Promise.resolve(next()) }, then(resolve,reject) { return Promise.resolve(next()).then(resolve,reject) } }
      return builder
    },
    storage: { from() { return { async upload(path, bytes, options) { calls.push(['upload',path,bytes.length,options]); return {error:uploadError} }, async remove(paths) { calls.push(['remove',paths]); return {} } } } },
    rpc(name,args) { calls.push(['rpc',name,args]); return {abortSignal:async()=>rpc} },
  }
  return {supabase,calls}
}
const request = supabase => ({userId,supabase,body:{application,documents,submissionId:id}})
const fail = error => {throw error}

test('application projection retains declared range and cannot include approval or account role',()=>{
  const record=applicationRecord({...application,status:'approved',role:'superUser',user_id:'someone-else'})
  assert.equal(record.experience_range,'1-2');assert.equal(record.years_experience,1);assert.equal(record.hourly_rate,250)
  assert(!Object.hasOwn(record,'role'));assert(!Object.hasOwn(record,'status'));assert(!Object.hasOwn(record,'user_id'))
  assert.throws(()=>applicationRecord({...application,province:'Invalid Province'}));assert.throws(()=>applicationRecord({...application,email:'invalid'}));assert.throws(()=>applicationRecord({...application,yearsExperience:'many'}))
})
test('successful submission uploads private documents then saves one atomic application',async()=>{
 const {supabase,calls}=client();const res=response();await submitApplication(request(supabase),res,fail)
 assert.equal(res.code,201);assert.equal(res.body.applicationId,id)
 const uploads=calls.filter(call=>call[0]==='upload');assert.equal(uploads.length,2)
 assert(uploads.every(call=>call[1].startsWith(userId+'/'+id+'/')&&call[3].upsert===false))
 const rpc=calls.find(call=>call[0]==='rpc');assert.equal(rpc[1],'submit_tutor_application');assert.equal(rpc[2]._documents[0].document_type,'identity');assert.deepEqual(rpc[2]._subjects,[1]);assert(!calls.some(call=>call[0]==='remove'))
})
test('retrying a committed submission returns the saved ID without uploading again',async()=>{
 const {supabase,calls}=client({reads:[{data:{id,status:'submitted'}}]});const res=response();await submitApplication(request(supabase),res,fail)
 assert.equal(res.code,200);assert(!calls.some(call=>['rpc','upload'].includes(call[0])))
})
test('a duplicate open application or unknown subject never uploads files',async()=>{
 for(const reads of [[{data:null},{data:[{id}]}],[{data:null},{data:[]},{data:[]}]]){
 const {supabase,calls}=client({reads});const res=response();await submitApplication(request(supabase),res,fail)
 assert([400,409].includes(res.code));assert(!calls.some(call=>call[0]==='upload'))
 }
})
test('missing schema fails before any private upload',async()=>{
 const {supabase,calls}=client({reads:[{data:null,error:{code:'42703',message:'missing column'}}]});const res=response();await submitApplication(request(supabase),res,fail)
 assert.equal(res.code,503);assert(!calls.some(call=>call[0]==='upload'))
})
test('a failed transaction removes unattached uploads and never reports success',async()=>{
 const {supabase,calls}=client({reads:[{data:null},{data:[]},{data:[{id:1}]},{data:null}],rpc:{error:{code:'22023',message:'Invalid application'}}});const res=response();await submitApplication(request(supabase),res,fail)
 assert.equal(res.code,400);assert.equal(calls.find(call=>call[0]==='remove')[1].length,2)
})
test('lost response after commit is recovered without deleting the accepted documents',async()=>{
 const {supabase,calls}=client({reads:[{data:null},{data:[]},{data:[{id:1}]},{data:{id}}],rpc:{error:{message:'Timeout'}}});const res=response();await submitApplication(request(supabase),res,fail)
 assert.equal(res.code,200);assert.equal(res.body.applicationId,id);assert(!calls.some(call=>call[0]==='remove'))
})
test('incomplete documents and malicious MIME disguises are rejected before database access',async()=>{
 const {supabase,calls}=client();const req=request(supabase);req.body={...req.body,documents:[documents[0],{...documents[1],name:'bad.exe'}]};const res=response();await submitApplication(req,res,fail);assert.equal(res.code,400);assert.equal(calls.length,0)
})
test('review rejects stale application versions and requires an explanation for rejection',async()=>{
 const {supabase,calls}=client({rpc:{error:{code:'PT409',message:'Reload application'}}});const req={params:{id},supabase,body:{status:'approved',notes:'Checked documents',expectedUpdatedAt:'2026-10-28T12:00:00.123456Z'}};const res=response();await reviewApplication(req,res,fail);assert.equal(res.code,409)
 const noReason=response();await reviewApplication({...req,body:{...req.body,status:'rejected',notes:''}},noReason,fail);assert.equal(noReason.code,400);assert.equal(calls.filter(call=>call[0]==='rpc').length,1)
})
test('student editing permits contact details but rejects roles, emails, markers and invalid phones',()=>{
 const edit=changes=>({changes,expectedUpdatedAt:'2026-10-28T12:00:00.123456Z'})
 assert.deepEqual(validateStudentEdit(edit({first_name:' Demo ',phone:'+27620882443'})),{first_name:'Demo',phone:'+27620882443'})
 for(const changes of [{role:'tutor'},{email:'other@example.test'},{demo_dataset:null},{is_verified:true},{first_name:''},{phone:'abc'},{bio:'x'.repeat(2001)}])assert.throws(()=>validateStudentEdit(edit(changes)))
})

test('all fields supplied by the tutor form map to corresponding review columns',()=>{
 const data={...application,yearsExperience:'3-5',certifications:'Example certification',previousPlatforms:'Example platform',studentsPerSession:'2-4'}
 const result=applicationRecord(data)
 for(const[input,column]of Object.entries({firstName:'first_name',lastName:'last_name',email:'contact_email',idNumber:'id_number',phone:'phone',address:'street_address',city:'city',province:'province',highestQualification:'highest_qualification',institution:'institution',certifications:'certifications',previousPlatforms:'previous_platforms',studentAgeGroups:'student_age_groups',teachingStyle:'teaching_style',availability:'availability_slots',teachingMode:'teaching_modes',studentsPerSession:'students_per_session'}))assert.deepEqual(result[column],data[input],input)
 assert.equal(result.experience_range,'3-5');assert.equal(result.years_experience,3);assert.equal(result.year_completed,2025);assert.equal(result.hourly_rate,250)
})
test('invalid optional text types, oversized fields and punctuation-only phones are rejected',async()=>{
 const{validateApplication}=await import('../src/controllers/site.controller.js')
 for(const extra of [{certifications:{}},{previousPlatforms:'x'.repeat(1001)},{firstName:'x'.repeat(61)},{phone:'()-------'}])assert.throws(()=>validateApplication({application:{...application,...extra},documents}))
})
