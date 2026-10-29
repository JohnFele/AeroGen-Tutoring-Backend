import { randomUUID } from 'node:crypto';
import { applicationBucket,decodeApplicationFile,documentKinds } from './applicationFiles.js';

const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const arrays=['subjects','studentAgeGroups','availability','teachingMode'];
const limits={firstName:60,lastName:60,email:254,phone:22,idNumber:100,address:1000,city:160,province:40,highestQualification:250,institution:250,yearCompleted:4,certifications:1000,yearsExperience:10,previousPlatforms:1000,teachingStyle:1000,hourlyRate:10,studentsPerSession:20};
export function validateDraft(body) {
  if(!body||!uuid.test(body.id)||!uuid.test(body.saveId)||!Number.isInteger(body.step)||body.step<1||body.step>5||!Number.isInteger(body.furthestStep)||body.furthestStep<body.step||body.furthestStep>5
    ||(body.expectedVersion!==null&&(!Number.isSafeInteger(body.expectedVersion)||body.expectedVersion<1)))throw new Error('Reload the application before saving this draft.');
  if(!body.application||typeof body.application!=='object'||Array.isArray(body.application)||Buffer.byteLength(JSON.stringify(body.application))>30000)throw new Error('Invalid draft details.');
  for(const [key,value] of Object.entries(body.application)){
    if(arrays.includes(key)){if(!Array.isArray(value)||value.length>30||value.some(item=>typeof item!=='string'||item.length>100))throw new Error(`Invalid ${key} choices.`);}
    else if(!Object.hasOwn(limits,key)||typeof value!=='string'||value.length>limits[key])throw new Error(`Invalid draft field: ${key}.`);
  }
  if(!Array.isArray(body.documents)||body.documents.length>3||new Set(body.documents.map(file=>file?.kind)).size!==body.documents.length)throw new Error('Choose one file per document type.');
  for(const file of body.documents){if(!documentKinds.includes(file?.kind))throw new Error('Invalid document type.');if(file.savedId){if(!uuid.test(file.savedId)||file.content!==undefined)throw new Error('Invalid saved document.');}else decodeApplicationFile(file);}
  return body;
}
export const draftSelect='id,user_id,application,documents,step,furthest_step,version,save_id,updated_at';
export async function readOwnDraft(req) {
  const {data,error}=await req.supabase.from('tutor_application_drafts').select(draftSelect).eq('user_id',req.userId).maybeSingle().abortSignal(AbortSignal.timeout(15000));
  if(error)throw error;return data;
}
const publicDraft=row=>row?{id:row.id,application:row.application,documents:row.documents.map(({id,kind,name,size})=>({id,kind,name,size})),step:row.step,furthestStep:row.furthest_step,version:row.version,updatedAt:row.updated_at}:null;
export function draftError(res,error){
  const status={PT409:409,'23505':409,'42501':403,'22023':400,'22P02':400,'23514':400,PGRST202:503,PGRST204:503,'42P01':503}[error?.code];
  if(!status)return false;
  res.status(status).json({message:status===503?'Account drafts are temporarily unavailable. Please try again later.':status===409?'A newer draft exists. Reload the saved draft before saving or submitting again.':error.message});return true;
}
export const getDraft=async(req,res,next)=>{
  res.set('Cache-Control','no-store');
  try{return res.json({draft:publicDraft(await readOwnDraft(req))});}catch(error){if(!draftError(res,error))return next(error);}
};
async function removeFiles(req,paths){
  if(!paths.length)return;
  try{const {error}=await req.supabase.storage.from(applicationBucket).remove(paths);if(error)console.error('Could not clean up unattached draft files:',error.message);}catch(error){console.error('Could not clean up unattached draft files:',error.message);}
}
export const saveDraft=async(req,res,next)=>{
  if(req.body?.accountId&&req.body.accountId!==req.userId)return res.status(403).json({message:'Your signed-in account changed. Reload the application before saving.'});
  res.set('Cache-Control','no-store');
  let body;
  try{body=validateDraft(req.body);}catch(error){return res.status(400).json({message:error.message});}
  const uploaded=[];let committed=false,rpcAttempted=false,safeToClean=true;
  try{
    const previous=await readOwnDraft(req);
    if(previous?.save_id===body.saveId)return res.json({draft:publicDraft(previous)});
    if((previous?.version??null)!==body.expectedVersion||(previous&&previous.id!==body.id))return res.status(409).json({message:'A newer draft exists. Reload the saved draft before saving again.'});
    const docs=[];
    for(const file of body.documents){
      if(file.savedId){const saved=previous?.documents.find(item=>item.id===file.savedId&&item.kind===file.kind);if(!saved)return res.status(409).json({message:'This saved document changed. Reload your draft.'});docs.push(saved);}
      else{
        const decoded=decodeApplicationFile(file),id=randomUUID(),path=`${req.userId}/${body.id}/${id}-${decoded.name}`;
        const {error}=await req.supabase.storage.from(applicationBucket).upload(path,decoded.bytes,{contentType:decoded.mime,upsert:false});if(error)throw error;
        uploaded.push(path);docs.push({id,path,kind:file.kind,name:decoded.name,size:decoded.bytes.length,mime:decoded.mime});
      }
    }
    rpcAttempted=true;
    const {data,error}=await req.supabase.rpc('save_tutor_application_draft',{_id:body.id,_application:body.application,_documents:docs,_step:body.step,_furthest_step:body.furthestStep,_expected_version:body.expectedVersion,_save_id:body.saveId}).abortSignal(AbortSignal.timeout(15000));
    if(error)throw error;committed=true;
    await removeFiles(req,(previous?.documents||[]).filter(file=>!docs.some(item=>item.path===file.path)).map(file=>file.path));
    return res.json({draft:publicDraft(data)});
  }catch(error){
    safeToClean=!rpcAttempted||['PT409','42501','22023','22P02','23505','23514','PGRST202','PGRST204','42P01'].includes(error.code);
    // A response can be lost after commit: retain files referenced by the saved row.
    try{const saved=await readOwnDraft(req);if(saved?.save_id===body.saveId){committed=true;return res.json({draft:publicDraft(saved)});}}catch{/* Preserve the original provider error. */}
    if(!draftError(res,error))return next(error);
  }finally{if(!committed&&safeToClean)await removeFiles(req,uploaded);}
};
export const resolveSavedDocuments=async(req,res,next)=>{
  if(req.body?.accountId&&req.body.accountId!==req.userId)return res.status(403).json({message:'Your signed-in account changed. Reload the application before submitting.'});
  const inputs=req.body?.documents;
  if(req.body?.draftVersion===undefined&&!(Array.isArray(inputs)&&inputs.some(file=>file?.savedId)))return next();
  if(!Number.isSafeInteger(req.body?.draftVersion)||req.body.draftVersion<1||!uuid.test(req.body.submissionId))return res.status(400).json({message:'Reload the saved application draft before submitting.'});
  try{
    const draft=await readOwnDraft(req);
    if(!draft){
      const {data,error}=await req.supabase.from('tutor_applications').select('id,status').eq('id',req.body.submissionId).eq('user_id',req.userId).maybeSingle();if(error)throw error;
      if(data)return res.json({applicationId:data.id,status:data.status,message:'Your application is already saved in the review portal.'});
    }
    if(!draft||draft.id!==req.body.submissionId||draft.version!==req.body.draftVersion)return res.status(409).json({message:'A newer draft exists. Reload the saved draft before submitting.'});
    req.applicationDraft=draft;
    if(!Array.isArray(req.body.documents)||req.body.documents.length>3)return res.status(400).json({message:'Invalid application documents.'});
    const expanded=[];
    for(const file of req.body.documents){
      if(!file||typeof file!=='object')return res.status(400).json({message:'Invalid application document.'});
      if(!file.savedId){expanded.push(file);continue;}
      const saved=draft.documents.find(item=>item.id===file.savedId&&item.kind===file.kind);
      if(!saved)return res.status(409).json({message:'This saved document changed. Reload your draft.'});
      const {data,error}=await req.supabase.storage.from(applicationBucket).download(saved.path);if(error)throw error;
      if(data.size!==saved.size)return res.status(400).json({message:'A saved document changed. Upload it again.'});
      expanded.push({kind:saved.kind,name:saved.name,content:Buffer.from(await data.arrayBuffer()).toString('base64')});
    }
    req.body.documents=expanded;return next();
  }catch(error){if(!draftError(res,error))return next(error);}
};
export const cleanSubmittedDraftFiles=async(req)=>{if(req.applicationDraft)await removeFiles(req,req.applicationDraft.documents.map(file=>file.path));};
