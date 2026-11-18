import {isBookingSchemaUnavailable} from '../utils/bookingSchema.js';
const uuid=value=>typeof value==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
const bad=res=>res.status(400).json({message:'Check the conversation, message and required fields.'});
async function invoke(req,res,next,name,args,status=200){
 try{const{data,error}=await req.supabase.rpc(name,args).abortSignal(AbortSignal.timeout(15000));
  if(error){if(isBookingSchemaUnavailable(error))return res.status(503).json({message:'Messaging is waiting for its database migration.'});
   const code={'42501':403,'22023':400,PT403:403,PT404:404,PT409:409,PT429:429,PT503:503}[error.code];
   return code?res.status(code).json({message:error.message}):next(error)}
  res.set('Cache-Control','no-store');return res.status(status).json(data);
 }catch(error){next(error)}
}
export function conversations(req,res,next){
 const page=Number(req.query.page||1),query=req.query.q||'';
 if((req.query.page!==undefined&&typeof req.query.page!=='string')||!Number.isSafeInteger(page)||page<1||page>10000||typeof query!=='string'||query.length>120)return bad(res);
 return invoke(req,res,next,'my_conversations',{_page:page,_query:query.trim()});
}
export function conversation(req,res,next){return uuid(req.params.id)?invoke(req,res,next,'resolve_my_conversation',{_id:req.params.id}):bad(res)}
export const notificationSummary=(req,res,next)=>invoke(req,res,next,'my_notification_summary',{});
export function messageHistory(req,res,next){
 const{before,beforeId}=req.query;
 if(!uuid(req.params.id)||((before!==undefined)!==(beforeId!==undefined))||(before!==undefined&&
  (typeof before!=='string'||!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|\+00:00)$/.test(before)||!Number.isFinite(Date.parse(before))||new Date(before).toISOString().slice(0,19)!==before.slice(0,19)||!uuid(beforeId))))return bad(res);
 return invoke(req,res,next,'my_conversation_messages',{_id:req.params.id,_before:before||null,_before_id:beforeId||null});
}
export function sendMessage(req,res,next){
 if(!uuid(req.params.id)||!uuid(req.body?.requestId)||typeof req.body?.body!=='string'||!req.body.body.trim()||req.body.body.length>10000)return bad(res);
 return invoke(req,res,next,'send_tutoring_message',{_conversation_id:req.params.id,_body:req.body.body.trim(),_request:req.body.requestId},201);
}
export function blockConversation(req,res,next){return uuid(req.params.id)&&typeof req.body?.blocked==='boolean'
 ?invoke(req,res,next,'set_conversation_block',{_id:req.params.id,_blocked:req.body.blocked}):bad(res)}
export function reportMessage(req,res,next){
 const{description,requestId}=req.body||{};
 return uuid(req.params.id)&&uuid(requestId)&&typeof description==='string'&&description.trim().length>=20&&description.length<=1800
 ?invoke(req,res,next,'report_conversation_message',{_message:req.params.id,_description:description.trim(),_request:requestId},201):bad(res);
}
