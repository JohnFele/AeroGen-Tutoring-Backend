import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { createCorsOptions, normalizeOrigins } from '../src/config/cors.config.js';
import { createApp } from '../src/app.js';
import { createAuthorize, authorizeRole, requireTutorApproval } from '../src/middleware/auth.middleware.js';

const cors = origins => createCorsOptions({NODE_ENV:'production',FRONTEND_ORIGINS_PROD:origins});
const decision = (options, origin) => new Promise(resolve => options.origin(origin,(error,allowed)=>resolve({error,allowed})));

test('empty production origins deny every browser origin instead of permitting everyone', async () => {
  const result = await decision(cors(''), 'https://untrusted.example');
  assert.equal(result.error.code, 'CORS_FORBIDDEN');
  assert.equal(result.allowed, undefined);
  assert.equal((await decision(cors(''),undefined)).allowed,true);
});

test('production allowlist normalizes hostnames and trailing slashes but uses exact origin matching', async () => {
  const options = cors('aerogen-tut.netlify.app, https://portal.example/');
  assert.equal((await decision(options,'https://aerogen-tut.netlify.app')).allowed,true);
  assert.equal((await decision(options,'https://portal.example')).allowed,true);
  for (const origin of ['https://aerogen-tut.netlify.app.attacker.test','http://aerogen-tut.netlify.app','null','https://portal.example:8443']) {
    assert.equal((await decision(options,origin)).error.code,'CORS_FORBIDDEN',origin);
  }
  assert.deepEqual(normalizeOrigins([' https://portal.example/ ', 'https://portal.example']),['https://portal.example']);
});

test('unsafe or ambiguous origin configuration is rejected', () => {
  for(const value of ['*','https://*.example','https://user:password@example.test','https://example.test/path','https://example.test?x=y','https://example.test#hash','http://example.test','file://example.test']) {
    assert.throws(()=>cors(value),value);
  }
  assert.deepEqual(normalizeOrigins('http://localhost:5173'),['http://localhost:5173']);
});

test('HTTP CORS rejection is a generic 403, preflight works, and protected errors cannot be cached', async t => {
  const app=createApp({platformGate:(_req,_res,next)=>next(),corsConfig:cors('https://allowed.example')});
  const server=http.createServer(app);
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  t.after(()=>new Promise(resolve=>server.close(resolve)));
  const url=`http://127.0.0.1:${server.address().port}/api/v1`;
  const blocked=await fetch(`${url}/health`,{headers:{Origin:'https://blocked.example'}});
  assert.equal(blocked.status,403);
  assert.equal(blocked.headers.get('access-control-allow-origin'),null);
  assert.deepEqual(await blocked.json(),{code:'CORS_FORBIDDEN',message:'This browser origin is not permitted.'});
  const preflight=await fetch(`${url}/users/me`,{method:'OPTIONS',headers:{Origin:'https://allowed.example','Access-Control-Request-Method':'PATCH','Access-Control-Request-Headers':'authorization,content-type'}});
  assert.equal(preflight.status,204);
  assert.equal(preflight.headers.get('access-control-allow-origin'),'https://allowed.example');
  const privateResponse=await fetch(`${url}/users/me`,{headers:{Origin:'https://allowed.example'}});
  assert.equal(privateResponse.status,401);
  assert.match(privateResponse.headers.get('cache-control'),/no-store/);
  assert.match(privateResponse.headers.get('vary'),/Authorization/);
  assert.equal(privateResponse.headers.get('x-content-type-options'),'nosniff');
});

function response() {return {code:200,status(code){this.code=code;return this;},json(body){this.body=body;return this;}};}

test('verified tokens still require a live, owned session within the 30-day application window', async () => {
  const token=`header.${Buffer.from(JSON.stringify({aal:'aal2'})).toString('base64url')}.signature`;
  for(const valid of [true,false]) {
    let passed=false;const security={valid,admin_verified:valid,expires_at:'2026-12-01T00:00:00Z'};
    const handler=createAuthorize(()=>({auth:{getUser:async()=>({data:{user:{id:'owner'}}})},rpc(name){assert.equal(name,'my_session_security');return {abortSignal:async()=>({data:security})};}}));
    const req={headers:{authorization:`Bearer ${token}`}},res=response();
    await handler(req,res,()=>{passed=true;});
    assert.equal(passed,valid);
    if(valid){assert.equal(req.adminMfaVerified,true);assert.deepEqual(req.sessionSecurity,security);}
    else {assert.equal(res.code,401);assert.equal(res.body.code,'SESSION_EXPIRED');}
  }
});
function profileClient(profile,error=null) {
  return {from(table){assert.equal(table,'profiles');return {select(){return this;},eq(field,id){assert.equal(field,'id');assert.equal(id,'current-user');return this;},async single(){return {data:profile,error};},async maybeSingle(){return {data:profile,error};}};}};
}

test('admin access trusts the database role rather than supplied metadata or request fields', async () => {
  for(const profile of [{role:'student'},{role:'tutor'},null]) {
    const res=response();
    await authorizeRole(['admin','superUser'])({userId:'current-user',supabase:profileClient(profile),body:{role:'superUser'},user:{user_metadata:{role:'admin'}}},res,()=>assert.fail('Must not grant admin access'));
    assert.equal(res.code,403);
  }
  for(const role of ['admin','superUser']) {
    let called=false;const req={userId:'current-user',authAssurance:'aal2',adminMfaVerified:true,supabase:profileClient({role})};
    await authorizeRole(['admin','superUser'])(req,response(),()=>{called=true;});
    assert(called);assert.equal(req.userRole,role);
  }
});

test('an administrator role without a verified second factor cannot access admin endpoints', async () => {
  for(const role of ['admin','superUser']) for(const authAssurance of [undefined,'aal1','aal2','invalid']) {
    const res=response();
    await authorizeRole(['admin','superUser'])({userId:'current-user',authAssurance,supabase:profileClient({role})},res,()=>assert.fail('MFA is mandatory'));
    assert.equal(res.code,403);assert.equal(res.body.code,'ADMIN_MFA_REQUIRED');
  }
});

test('unapproved tutors remain blocked at the API boundary', async () => {
  const res=response();
  await requireTutorApproval({userId:'current-user',supabase:profileClient({role:'tutor',tutor_profile:{is_approved:false}})},res,()=>assert.fail('Approval must be required'));
  assert.equal(res.code,403);assert.equal(res.body.code,'TUTOR_APPROVAL_REQUIRED');
});
