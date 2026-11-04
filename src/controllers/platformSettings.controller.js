import{readPlatformSettings,platformDto}from'../services/platformSettings.js';
const fields={applications:'applications',studentRegistration:'student_registration',maintenance:'maintenance',notifications:'admin_email_notifications'};
export function validatePlatformEdit(body){
  const values=body?.settings;
  if(!values||typeof values!=='object'||Array.isArray(values)||Object.keys(values).length!==4||Object.keys(values).some(key=>!Object.hasOwn(fields,key)||typeof values[key]!=='boolean'))throw Error('Choose a valid on/off value for all four platform settings.');
  if(!Number.isSafeInteger(body.expectedVersion)||body.expectedVersion<1)throw Error('Reload platform settings before saving.');
  return{patch:Object.fromEntries(Object.entries(fields).map(([key,column])=>[column,values[key]])),version:body.expectedVersion};
}
export const publicPlatformSettings=async(req,res,next)=>{res.set('Cache-Control','no-store');try{return res.json({settings:await readPlatformSettings()})}catch{return res.status(503).json({code:'PLATFORM_UNAVAILABLE',message:'Platform status is temporarily unavailable. Please try again.'})}};
export const adminPlatformSettings=async(req,res,next)=>{try{return res.json({settings:await readPlatformSettings(req.supabase)})}catch(error){next(error)}};
export const savePlatformSettings=async(req,res,next)=>{
  let input;try{input=validatePlatformEdit(req.body)}catch(error){return res.status(400).json({message:error.message})}
  try{const{data,error}=await req.supabase.rpc('update_platform_settings',{_patch:input.patch,_expected_version:input.version}).abortSignal(AbortSignal.timeout(15000));if(error){if(error.code==='PT409')return res.status(409).json({message:'Platform settings changed. Your choices are kept; reload the saved settings before saving again.'});throw error}return res.json({settings:platformDto(data)})}catch(error){next(error)}
};
