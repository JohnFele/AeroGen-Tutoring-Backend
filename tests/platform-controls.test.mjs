import{test}from'node:test';import assert from'node:assert/strict';
import{createPlatformGate,requireApplicationsOpen}from'../src/middleware/platform.middleware.js';
import{validatePlatformEdit}from'../src/controllers/platformSettings.controller.js';
import{createApplicationNotifier}from'../src/services/adminNotifications.js';
const settings={applications:true,studentRegistration:true,maintenance:false,notifications:true};
const response=()=>({code:200,headers:{},set(key,value){this.headers[key]=value;return this},status(code){this.code=code;return this},json(body){this.body=body;return this}});
test('platform edits accept only actual booleans and a captured version',()=>{
  assert.equal(validatePlatformEdit({settings,expectedVersion:1}).patch.applications,true);
  for(const body of [{settings:{...settings,maintenance:'false'},expectedVersion:1},{settings:{...settings,role:'admin'},expectedVersion:1},{settings,expectedVersion:0},{settings:{},expectedVersion:1}])assert.throws(()=>validatePlatformEdit(body));
});
test('maintenance blocks ordinary calls while public status, identity bootstrap and protected admin routes remain reachable',async()=>{
  const gate=createPlatformGate({load:async()=>({...settings,maintenance:true}),verifyAdmin:async()=>false});
  for(const path of ['/site/faqs','/workspace','/site/enquiries']){const res=response();let reached=false;await gate({originalUrl:'/api/v1'+path,method:'GET',headers:{}},res,()=>{reached=true});assert.equal(reached,false);assert.equal(res.code,503);assert.equal(res.body.code,'MAINTENANCE_MODE')}
  for(const path of ['/site/platform-settings','/site/contact-details','/users/me','/admin/platform-settings']){let reached=false;await gate({originalUrl:'/api/v1'+path,method:'GET',headers:{}},response(),()=>{reached=true});assert(reached,path)}
});
test('an admin bypass is based on verified server identity, not an input role or header',async()=>{
  const gate=createPlatformGate({load:async()=>({...settings,maintenance:true}),verifyAdmin:async req=>req.headers.authorization==='verified-admin'});
  let reached=false;await gate({originalUrl:'/api/v1/workspace',method:'GET',headers:{authorization:'verified-admin'}},response(),()=>{reached=true});assert(reached);
  const res=response();await gate({originalUrl:'/api/v1/workspace',method:'GET',headers:{'x-role':'admin'},body:{role:'admin'}},res,()=>assert.fail());assert.equal(res.code,503);
});
test('ordinary profile writes cannot use the identity bootstrap exception',async()=>{
  const gate=createPlatformGate({load:async()=>({...settings,maintenance:true}),verifyAdmin:async()=>false}),res=response();await gate({originalUrl:'/api/v1/users/me',method:'PATCH',headers:{}},res,()=>assert.fail());assert.equal(res.code,503);
});
test('settings failures fail closed for app operations while administrator recovery is preserved',async()=>{
  const gate=createPlatformGate({load:async()=>{throw Error('Unavailable')}}),res=response();await gate({originalUrl:'/api/v1/workspace',method:'GET',headers:{}},res,()=>assert.fail());assert.equal(res.code,503);assert.equal(res.body.code,'PLATFORM_UNAVAILABLE');
  let reached=false;await gate({originalUrl:'/api/v1/admin/platform-settings',method:'PUT',headers:{}},response(),()=>{reached=true});assert(reached);
});
test('application closure rejects submission before downstream upload work',()=>{
  const res=response();requireApplicationsOpen({platformSettings:{...settings,applications:false}},res,()=>assert.fail());assert.equal(res.code,403);assert.equal(res.body.code,'APPLICATIONS_PAUSED');
});
test('disabled admin emails do not call the provider, and enabled application emails use the company inbox without attachments',async()=>{
  let calls=0;const payload={id:'test',application:{firstName:'Demo',lastName:'Applicant',email:'demo@example.test',subjects:['Mathematics']}};
  const disabled=createApplicationNotifier({getClient:()=>({}),load:async()=>({notifications:false}),deliver:()=>assert.fail()});assert.deepEqual(await disabled(payload),{skipped:true});
  const client={from(){return{select(){return this},eq(){return this},single(){return this},abortSignal:async()=>({data:{email:'company@example.test'}})}}};
  const enabled=createApplicationNotifier({getClient:()=>client,load:async()=>({notifications:true}),deliver:async(body,options)=>{calls++;assert.equal(options.recipient,'company@example.test');assert.equal(options.siteAttachments,undefined);assert(body.message.includes('private storage'));return{status:202}}});await enabled(payload);assert.equal(calls,1);
});
