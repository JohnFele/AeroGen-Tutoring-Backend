import{readPlatformSettings}from'../services/platformSettings.js';
import{createUserSupabaseClient}from'../config/supabase.js';
async function verifyAdmin(req){
  try{const[scheme,token,...extra]=(req.headers.authorization||'').split(' ');if(scheme!=='Bearer'||!token||extra.length)return false;const client=createUserSupabaseClient(token);const{data,error}=await client.auth.getUser(token);if(error||!data.user)return false;const role=await client.from('profiles').select('role').eq('id',data.user.id).single().abortSignal(AbortSignal.timeout(10000));if(role.error||!['admin','superUser'].includes(role.data?.role))return false;req.supabase=client;req.userId=data.user.id;req.userRole=role.data.role;return true}catch{return false}
}
export function createPlatformGate({load=readPlatformSettings,verifyAdmin:checkAdmin=verifyAdmin}={}){
  return async(req,res,next)=>{
    const path=(req.originalUrl||'').split('?')[0].replace(/^\/api\/v1/,'');
    if(path==='/admin'||path.startsWith('/admin/')||(['GET','HEAD'].includes(req.method)&&['/site/platform-settings','/site/contact-details','/users/me','/health'].includes(path)))return next();
    try{req.platformSettings??=await load();if(!req.platformSettings.maintenance||await checkAdmin(req))return next();res.set('Retry-After','60');return res.status(503).json({code:'MAINTENANCE_MODE',message:'AeroGen Tutoring is temporarily undergoing maintenance. Please try again shortly.'})}
    catch{return res.status(503).json({code:'PLATFORM_UNAVAILABLE',message:'Platform status is temporarily unavailable. Please try again.'})}
  };
}
export const platformGate=createPlatformGate();
export function requireApplicationsOpen(req,res,next){
  if(!req.platformSettings)return res.status(503).json({code:'PLATFORM_UNAVAILABLE',message:'Application availability could not be checked. Please retry.'});
  if(!req.platformSettings.applications)return res.status(403).json({code:'APPLICATIONS_PAUSED',message:'New tutor applications are temporarily paused. Your saved draft is still available.'});return next();
}
