import {randomUUID} from 'node:crypto';
import {createPublicSupabaseClient} from '../config/supabase.js';
import {deliverSupportEmail} from './support.controller.js';

const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const emailPattern=/^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const contactLimits={email:254,phone:16,weekday_hours:100,saturday_hours:100,sunday_hours:100,operator_name:160,registration_number:80,business_address:1000,privacy_email:254,information_officer:160};
const openingLimits={title:160,department:100,employment_type:40,location:160,salary:160,description:8000};
const categories=new Set(['general','tutoring','billing','technical','partnership','careers','other']);
const text=(value,max,min=0)=>{if(typeof value!=='string'||value.trim().length<min||value.length>max)throw new Error(`Enter between ${min} and ${max} characters.`);return value.trim()};
function fields(body,limits,optional=[]){
  if(!body||typeof body!=='object'||Array.isArray(body)||Object.keys(body).some(key=>!Object.hasOwn(limits,key)))throw new Error('Send only the editable fields.');
  return Object.fromEntries(Object.entries(limits).map(([key,max])=>{try{return[key,text(body[key],max,optional.includes(key)?0:1)]}catch{throw new Error(`Enter a valid ${key.replaceAll('_',' ')} (up to ${max} characters).`)}}));
}
export function validateContact(body){
  const clean=fields(body,contactLimits,['registration_number','business_address','information_officer']);
  if(!emailPattern.test(clean.email)||!emailPattern.test(clean.privacy_email))throw new Error('Enter valid contact and privacy email addresses.');
  if(!/^\+[1-9][0-9]{7,14}$/.test(clean.phone))throw new Error('Use an international phone number, for example +27620882443.');
  if(clean.operator_name.length<2)throw new Error('Enter the legal operator name.');return clean;
}
export function validateOpening(body){
  if(!body||Object.keys(body).some(key=>!Object.hasOwn(openingLimits,key)&&!['requirements','status','closes_on'].includes(key)))throw new Error('Send only the editable opening fields.');
  const clean=fields(Object.fromEntries(Object.keys(openingLimits).map(key=>[key,body[key]])),openingLimits,['salary']);
  if(clean.title.length<2||clean.department.length<2||clean.location.length<2||clean.description.length<20)throw new Error('Complete the title, department, location and at least 20 characters of description.');
  if(!['Full-time','Part-time','Contract','Internship'].includes(clean.employment_type)||!['draft','published','closed'].includes(body.status))throw new Error('Choose an employment type and publication status.');
  if(!Array.isArray(body.requirements)||body.requirements.length>30||body.requirements.some(value=>typeof value!=='string'||!value.trim()||value.length>200))throw new Error('Enter up to 30 requirements, each at most 200 characters.');
  const date=body.closes_on;
  if(date!==null&&(typeof date!=='string'||!/^\d{4}-\d{2}-\d{2}$/.test(date)||!Number.isFinite(Date.parse(date))||new Date(date).toISOString().slice(0,10)!==date))throw new Error('Choose a valid closing date or leave it empty.');
  return {...clean,requirements:body.requirements.map(value=>value.trim()),status:body.status,closes_on:date};
}
export function validateEnquiry(body){
  if(!body||body.website)throw new Error('Unable to submit this enquiry.');
  const id=body.id??randomUUID();if(!uuid.test(id))throw new Error('Reload the form before sending.');
  const firstName=text(body.firstName,60,1),lastName=text(body.lastName,60,1),email=text(body.email,254,3).toLowerCase(),message=text(body.message,3500,10);
  if(!emailPattern.test(email))throw new Error('Enter a valid email address so we can reply.');
  if(!categories.has(body.category))throw new Error('Choose an enquiry subject.');
  return{id,firstName,lastName,email,category:body.category,message};
}
function siteError(res,error){
  const status={PT409:409,PT429:429,'42501':403,'23514':400,'22023':400,'22P02':400,'23505':409,'42P01':503,PGRST202:503,PGRST204:503}[error?.code];
  if(!status)return false;
  res.status(status).json({message:status===503?'Site administration is temporarily unavailable. Please try again later.':status===403?'Administrator access required.':status===409?'This record changed. Reload it before saving again.':status===429?'Too many requests. Please try again later.':error.message||'Check the submitted fields.'});return true;
}
const timeout=()=>AbortSignal.timeout(15000);
async function contactFrom(client){const{data,error}=await client.from('site_contact_settings').select('*').eq('id',true).single().abortSignal(timeout());if(error)throw error;return data;}
export const publicContact=async(req,res,next)=>{try{res.set('Cache-Control','no-store');return res.json({contact:await contactFrom(createPublicSupabaseClient())})}catch(error){if(!siteError(res,error))next(error)}};
export const publicOpenings=async(req,res,next)=>{try{
  const client=createPublicSupabaseClient(),openings=[];
  for(let offset=0;;offset+=500){const{data,error}=await client.from('career_openings').select('id,title,department,employment_type,location,salary,description,requirements,closes_on,created_at').order('created_at',{ascending:false}).order('id').range(offset,offset+499).abortSignal(timeout());if(error)throw error;openings.push(...data);if(data.length<500)break}
  res.set('Cache-Control','no-store');return res.json({openings});
}catch(error){if(!siteError(res,error))next(error)}};
export function createEnquiryHandler({getClient=createPublicSupabaseClient,getContact=contactFrom,deliver=deliverSupportEmail}={}){
  return async(req,res,next)=>{
    let input;try{input=validateEnquiry(req.body)}catch(error){return res.status(400).json({message:error.message})}
    try{
      const client=getClient();const{data,error}=await client.rpc('submit_contact_enquiry',{_id:input.id,_first_name:input.firstName,_last_name:input.lastName,_email:input.email,_category:input.category,_message:input.message});if(error)throw error;
      if(data.created){try{
        const contact=await getContact(client);
        const delivered=await deliver({name:`${input.firstName} ${input.lastName}`,email:input.email,topic:'Other',message:`Website enquiry · ${input.category}\nReference: ${data.id}\n\n${input.message}`},{recipient:contact.email,siteSubject:`[AeroGen Enquiry] ${input.category}`,title:'Website enquiry'});
        if(delivered.status!==202)console.error('Enquiry saved; email notification could not be delivered.');
      }catch{console.error('Enquiry saved; email notification is unavailable.')}}
      return res.status(202).json({reference:data.id,message:'Your enquiry has been received by AeroGen Tutoring. We will reply by email. Keep this reference: '+data.id});
    }catch(error){if(!siteError(res,error))return next(error)}
  };
}
export const receiveEnquiry=createEnquiryHandler();
export const adminContact=async(req,res,next)=>{try{return res.json({contact:await contactFrom(req.supabase)})}catch(error){if(!siteError(res,error))next(error)}};
function expected(body){if(!Number.isSafeInteger(body?.expectedVersion)||body.expectedVersion<1)throw new Error('Reload this record before saving.');return body.expectedVersion}
export const saveContact=async(req,res,next)=>{
  let clean,version;try{clean=validateContact(req.body?.contact);version=expected(req.body)}catch(error){return res.status(400).json({message:error.message})}
  try{const{data,error}=await req.supabase.from('site_contact_settings').update(clean).eq('id',true).eq('version',version).select().maybeSingle().abortSignal(timeout());if(error)throw error;if(!data)return res.status(409).json({message:'Contact details changed. Reload before saving.'});return res.json({contact:data})}catch(error){if(!siteError(res,error))next(error)}
};
export const listOpenings=async(req,res,next)=>{try{
  const openings=[];for(let offset=0;;offset+=500){const{data,error}=await req.supabase.from('career_openings').select('*').order('created_at',{ascending:false}).order('id').range(offset,offset+499).abortSignal(timeout());if(error)throw error;openings.push(...data);if(data.length<500)break}return res.json({openings});
}catch(error){if(!siteError(res,error))next(error)}};
export const saveOpening=async(req,res,next)=>{
  let clean,version;try{clean=validateOpening(req.body?.opening);if(req.params.id){if(!uuid.test(req.params.id))throw new Error('Invalid opening.');version=expected(req.body)}}catch(error){return res.status(400).json({message:error.message})}
  try{const query=req.params.id?req.supabase.from('career_openings').update(clean).eq('id',req.params.id).eq('version',version):req.supabase.from('career_openings').insert(clean);const{data,error}=await query.select().maybeSingle().abortSignal(timeout());if(error)throw error;if(!data)return res.status(409).json({message:'This opening changed. Reload before saving.'});return res.status(req.params.id?200:201).json({opening:data})}catch(error){if(!siteError(res,error))next(error)}
};
export const deleteOpening=async(req,res,next)=>{
  let version;try{if(!uuid.test(req.params.id))throw new Error('Invalid opening.');version=expected(req.body)}catch(error){return res.status(400).json({message:error.message})}
  try{const{data,error}=await req.supabase.from('career_openings').delete().eq('id',req.params.id).eq('version',version).select('id').maybeSingle().abortSignal(timeout());if(error)throw error;if(!data)return res.status(409).json({message:'This opening changed. Reload before deleting.'});return res.json({deleted:true})}catch(error){if(!siteError(res,error))next(error)}
};
export const listEnquiries=async(req,res,next)=>{try{
  const page=Math.max(1,Number.parseInt(req.query.page,10)||1),limit=25;
  let query=req.supabase.from('contact_enquiries').select('id,first_name,last_name,email,category,status,version,created_at,updated_at',{count:'exact'});
  if(req.query.status){if(!['new','in_progress','resolved','spam'].includes(req.query.status))return res.status(400).json({message:'Choose a valid enquiry status.'});query=query.eq('status',req.query.status)}
  if(req.query.email){if(typeof req.query.email!=='string'||req.query.email.length>254)return res.status(400).json({message:'Enter a valid email search.'});query=query.ilike('email',`%${req.query.email.replaceAll('%','').replaceAll('_','')}%`)}
  const{data,count,error}=await query.order('created_at',{ascending:false}).order('id').range((page-1)*limit,page*limit-1).abortSignal(timeout());if(error)throw error;return res.json({enquiries:data,total:count,page,limit});
}catch(error){if(!siteError(res,error))next(error)}};
async function enquiryFrom(req){const{data,error}=await req.supabase.from('contact_enquiries').select('*,replies:enquiry_replies(*)').eq('id',req.params.id).maybeSingle().abortSignal(timeout());if(error)throw error;return data}
export const enquiryDetails=async(req,res,next)=>{if(!uuid.test(req.params.id))return res.status(400).json({message:'Invalid enquiry.'});try{const enquiry=await enquiryFrom(req);return enquiry?res.json({enquiry}):res.status(404).json({message:'Enquiry not found.'})}catch(error){if(!siteError(res,error))next(error)}};
export const updateEnquiry=async(req,res,next)=>{
  let clean,version;try{if(!uuid.test(req.params.id))throw new Error('Invalid enquiry.');version=expected(req.body);const changes=req.body.changes;if(!changes||!Object.keys(changes).length||Object.keys(changes).some(key=>!['status','internal_notes'].includes(key)))throw new Error('Edit only status and internal notes.');clean={};if(changes.status!==undefined){if(!['new','in_progress','resolved','spam'].includes(changes.status))throw new Error('Choose a valid status.');clean.status=changes.status}if(changes.internal_notes!==undefined)clean.internal_notes=text(changes.internal_notes,5000)}catch(error){return res.status(400).json({message:error.message})}
  try{const{data,error}=await req.supabase.from('contact_enquiries').update(clean).eq('id',req.params.id).eq('version',version).select().maybeSingle().abortSignal(timeout());if(error)throw error;if(!data)return res.status(409).json({message:'This enquiry changed. Reload before saving.'});return res.json({enquiry:data})}catch(error){if(!siteError(res,error))next(error)}
};
export const replyToEnquiry=async(req,res,next)=>{
  let message,version;try{if(!uuid.test(req.params.id)||!uuid.test(req.body?.id))throw new Error('Invalid reply reference.');message=text(req.body.message,4000,10);version=expected(req.body)}catch(error){return res.status(400).json({message:error.message})}
  try{
    const{data,error}=await req.supabase.rpc('begin_enquiry_reply',{_id:req.body.id,_enquiry_id:req.params.id,_message:message,_expected_version:version}).abortSignal(timeout());if(error)throw error;
    if(!data.created)return res.json({reply:data.reply,message:'This reply is already recorded. Check its delivery status before sending another.'});
    let delivered;
    try{const enquiry=await enquiryFrom(req),contact=await contactFrom(req.supabase);delivered=await deliverSupportEmail({name:'AeroGen Tutoring',email:contact.email,topic:'Other',message},{recipient:enquiry.email,recipientName:`${enquiry.first_name} ${enquiry.last_name}`,siteSubject:`AeroGen Tutoring: your ${enquiry.category} enquiry`,title:'A response to your enquiry',isReply:true});}catch{delivered={status:502,deliveryStatus:'unknown'}}
    const delivery_status=delivered.status===202?'sent':delivered.deliveryStatus||'failed';
    const{data:reply,error:saveError}=await req.supabase.from('enquiry_replies').update({delivery_status,provider_id:delivered.providerId||null}).eq('id',data.reply.id).eq('delivery_status','pending').select().maybeSingle().abortSignal(timeout());
    if(saveError)throw saveError;
    return res.json({reply:reply||data.reply,message:delivery_status==='sent'?'Reply accepted by the email provider.':delivery_status==='unknown'?'Delivery could not be confirmed. Check Brevo before sending again.':'Reply was not sent. Your message remains in the history.'});
  }catch(error){if(!siteError(res,error))next(error)}
};
