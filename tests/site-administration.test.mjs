import {test} from 'node:test';
import assert from 'node:assert/strict';
import {validateContact,validateOpening,validateEnquiry,createEnquiryHandler,replyToEnquiry,updateEnquiry} from '../src/controllers/siteAdmin.controller.js';
const contact={email:'support@example.test',phone:'+27620882443',weekday_hours:'08:00–18:00',saturday_hours:'09:00–13:00',sunday_hours:'Closed',operator_name:'John Fele',registration_number:'',business_address:'',privacy_email:'privacy@example.test',information_officer:''};
const opening={title:'Tutor support',department:'Operations',employment_type:'Part-time',location:'Remote',salary:'',description:'Help tutors prepare and deliver effective lessons.',requirements:['Clear communication'],status:'draft',closes_on:null};
const id='de000000-0000-4000-8000-000000000901';
const response=()=>({code:200,status(n){this.code=n;return this},json(body){this.body=body;return this}});
test('contact and opening allowlists reject unsafe or protected values',()=>{
  assert.equal(validateContact(contact).business_address,'');assert.equal(validateOpening(opening).status,'draft');
  for(const value of [{...contact,phone:'javascript:alert(1)'},{...contact,email:'bad'},{...contact,role:'admin'}])assert.throws(()=>validateContact(value));
  for(const value of [{...opening,description:'short'},{...opening,status:'approved'},{...opening,closes_on:'2026-02-30'},{...opening,requirements:['']},{...opening,version:2}])assert.throws(()=>validateOpening(value));
});
test('contact submissions require valid email, bounded text and an idempotency UUID',()=>{
  const good={id,firstName:'Demo',lastName:'User',email:'Demo@example.test',category:'general',message:'A useful enquiry message.'};
  assert.equal(validateEnquiry(good).email,'demo@example.test');
  for(const body of [{...good,email:'bad'},{...good,message:'short'},{...good,website:'spam'},{...good,id:'bad'},{...good,category:'talent'},{...good,firstName:' '.repeat(2)}])assert.throws(()=>validateEnquiry(body));
});
test('enquiries persist before email, remain accepted during delivery failure and do not resend duplicates',async()=>{
  const order=[];let created=true;
  const client={rpc:async(name,args)=>{order.push('store');assert.equal(name,'submit_contact_enquiry');assert.equal(args._id,id);return{data:{id,created},error:null}}};
  const handler=createEnquiryHandler({getClient:()=>client,getContact:async()=>contact,deliver:async()=>{order.push('email');return{status:502,message:'Provider failed'}}});
  const req={body:{id,firstName:'Demo',lastName:'User',email:'demo@example.test',category:'general',message:'A useful enquiry message.'}};
  const res=response();await handler(req,res,assert.ifError);assert.equal(res.code,202);assert.equal(res.body.reference,id);assert(!res.body.message.includes('email was sent'));assert.deepEqual(order,['store','email']);
  created=false;await handler(req,response(),assert.ifError);assert.deepEqual(order,['store','email','store']);
});
test('database failures never notify email or claim an enquiry was received',async()=>{
  let mailed=false;
  const handler=createEnquiryHandler({getClient:()=>({rpc:async()=>({error:{code:'42P01'}})}),getContact:async()=>contact,deliver:async()=>{mailed=true}});
  const res=response();await handler({body:{id,firstName:'Demo',lastName:'User',email:'demo@example.test',category:'general',message:'A useful enquiry message.'}},res,assert.ifError);
  assert.equal(res.code,503);assert.equal(mailed,false);
});
test('enquiry update cannot change sender, content, ownership or reply state',async()=>{
  const res=response();await updateEnquiry({params:{id},body:{expectedVersion:1,changes:{email:'attacker@example.test'}}},res,assert.ifError);assert.equal(res.code,400);
});
test('a replayed reply returns its recorded outcome without invoking the provider',async()=>{
  const req={params:{id},body:{id,expectedVersion:1,message:'Thank you for contacting us.'},supabase:{rpc:()=>({abortSignal:async()=>({data:{created:false,reply:{id,delivery_status:'sent'}}})})}};
  const res=response();await replyToEnquiry(req,res,assert.ifError);assert.equal(res.code,200);assert.equal(res.body.reply.delivery_status,'sent');
});
