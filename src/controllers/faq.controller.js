import {createPublicSupabaseClient} from '../config/supabase.js';

const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const limits={category:[2,80],question:[5,250],answer:[10,8000]};
export function validateFaq(input){
  if(!input||typeof input!=='object'||Array.isArray(input)||Object.keys(input).some(key=>!Object.hasOwn(limits,key)&&!['sort_order','status'].includes(key)))throw new Error('Send only category, question, answer, display order and publication status.');
  const faq={};
  for(const[key,[min,max]]of Object.entries(limits)){
    const value=input[key];if(typeof value!=='string'||value.trim().length<min||value.length>max||(key!=='answer'&&/[\x00-\x1f\x7f]/.test(value)))throw new Error(`Enter a ${key} between ${min} and ${max} characters${key==='answer'?'':' on one line'}.`);
    faq[key]=value.trim();
  }
  if(faq.category.toLowerCase()==='all categories')throw new Error('Choose a specific category name, rather than All categories.');
  if(!Number.isSafeInteger(input.sort_order)||input.sort_order<0||input.sort_order>10000)throw new Error('Display order must be a whole number from 0 to 10000.');
  if(!['draft','published'].includes(input.status))throw new Error('Choose Draft or Published.');
  return{...faq,sort_order:input.sort_order,status:input.status};
}
function version(body){if(!Number.isSafeInteger(body?.expectedVersion)||body.expectedVersion<1)throw new Error('Reload this FAQ before saving.');return body.expectedVersion;}
function databaseError(res,error){
  const code={PGRST202:503,PGRST204:503,'42P01':503,'42501':403,'23514':400,'22023':400,'22P02':400,'23505':409}[error?.code];if(!code)return false;
  res.status(code).json({message:code===503?'FAQs are temporarily unavailable. Please try again later.':code===403?'Administrator access required.':code===409?'That question already exists in this category. Edit the existing FAQ or change the question.':'Check the FAQ fields and try again.'});return true;
}
const signal=()=>AbortSignal.timeout(15000);
async function rows(client,publishedOnly){
  const faqs=[];
  for(let offset=0;;offset+=500){
    let query=client.from('site_faqs').select(publishedOnly?'id,category,question,answer,sort_order':'*');
    if(publishedOnly)query=query.eq('status','published');
    const{data,error}=await query.order('sort_order').order('id').range(offset,offset+499).abortSignal(signal());if(error)throw error;
    faqs.push(...data);if(data.length<500)return faqs;
  }
}
export function createFaqHandlers({getPublicClient=createPublicSupabaseClient}={}){
  const publicList=async(req,res,next)=>{try{res.set('Cache-Control','no-store');return res.json({faqs:await rows(getPublicClient(),true)})}catch(error){if(!databaseError(res,error))next(error)}};
  const list=async(req,res,next)=>{try{return res.json({faqs:await rows(req.supabase,false)})}catch(error){if(!databaseError(res,error))next(error)}};
  const save=async(req,res,next)=>{
    let faq,expected;try{faq=validateFaq(req.body?.faq);if(req.params.id){if(!uuid.test(req.params.id))throw new Error('Invalid FAQ reference.');expected=version(req.body)}}catch(error){return res.status(400).json({message:error.message})}
    try{
      const query=req.params.id?req.supabase.from('site_faqs').update(faq).eq('id',req.params.id).eq('version',expected):req.supabase.from('site_faqs').insert(faq);
      const{data,error}=await query.select().maybeSingle().abortSignal(signal());if(error)throw error;
      if(!data)return res.status(409).json({message:'This FAQ changed. Reload it before saving; your entries have been kept.'});
      return res.status(req.params.id?200:201).json({faq:data});
    }catch(error){if(!databaseError(res,error))next(error)}
  };
  const remove=async(req,res,next)=>{
    let expected;try{if(!uuid.test(req.params.id))throw new Error('Invalid FAQ reference.');expected=version(req.body)}catch(error){return res.status(400).json({message:error.message})}
    try{const{data,error}=await req.supabase.from('site_faqs').delete().eq('id',req.params.id).eq('version',expected).select('id').maybeSingle().abortSignal(signal());if(error)throw error;if(!data)return res.status(409).json({message:'This FAQ changed. Reload it before deleting.'});return res.json({deleted:true})}catch(error){if(!databaseError(res,error))next(error)}
  };
  return{publicList,list,save,remove};
}
export const{publicList:publicFaqs,list:listFaqs,save:saveFaq,remove:deleteFaq}=createFaqHandlers();
