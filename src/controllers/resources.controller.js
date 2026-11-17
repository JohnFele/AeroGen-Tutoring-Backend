import { isBookingSchemaUnavailable } from '../utils/bookingSchema.js';

const itemId=value=>typeof value==='string'&&/^[a-z0-9][a-z0-9-]{2,79}$/.test(value);
const version=value=>Number.isSafeInteger(value)&&value>0;
async function invoke(req,res,next,name,args){
  try{
    const{data,error}=await req.supabase.rpc(name,args).abortSignal(AbortSignal.timeout(15000));
    if(error){
      if(isBookingSchemaUnavailable(error))return res.status(503).json({message:'The resource library is waiting for its database migration.'});
      const status={'42501':403,'22023':400,PT404:404,PT409:409}[error.code];
      return status?res.status(status).json({message:error.message}):next(error);
    }
    res.set('Cache-Control','no-store');return res.json(data??{saved:true});
  }catch(error){next(error)}
}
const invalid=res=>res.status(400).json({message:'Check the library item and required fields.'});
export const tutorLibrary=(req,res,next)=>invoke(req,res,next,'my_tutor_resource_library',{});
export const adminLibrary=(req,res,next)=>invoke(req,res,next,'admin_tutor_library',{});
export function saveLibraryItem(req,res,next){
  const{item,expectedVersion=null}=req.body||{};
  if(!item||typeof item!=='object'||Array.isArray(item)||!itemId(item.id)||(expectedVersion!==null&&!version(expectedVersion)))return invalid(res);
  return invoke(req,res,next,'admin_save_tutor_library_item',{_item:item,_expected:expectedVersion});
}
export function archiveLibraryItem(req,res,next){
  if(!itemId(req.params.id)||!version(req.body?.expectedVersion))return invalid(res);
  return invoke(req,res,next,'admin_archive_tutor_library_item',{_id:req.params.id,_expected:req.body.expectedVersion});
}
export function saveLibraryBookmark(req,res,next){
  if(!itemId(req.params.id)||typeof req.body?.saved!=='boolean')return invalid(res);
  return invoke(req,res,next,'save_tutor_library_item',{_id:req.params.id,_saved:req.body.saved});
}
export function answerLibraryLesson(req,res,next){
  const{answer,contentVersion}=req.body||{};
  if(!itemId(req.params.id)||!itemId(req.params.lesson)||!Number.isInteger(answer)||answer<0||answer>5||!version(contentVersion))return invalid(res);
  return invoke(req,res,next,'answer_tutor_course_lesson',{_id:req.params.id,_lesson:req.params.lesson,_answer:answer,_version:contentVersion});
}
export function importLibraryProgress(req,res,next){
  const{saved=[],completed=[]}=req.body||{};
  if(!Array.isArray(saved)||saved.length>200||!saved.every(itemId)||!Array.isArray(completed)||completed.length>500||!completed.every(itemId))return invalid(res);
  return invoke(req,res,next,'import_tutor_library_progress',{_saved:saved,_completed:completed});
}

