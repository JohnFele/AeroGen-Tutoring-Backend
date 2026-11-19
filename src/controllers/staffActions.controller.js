const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
export function ownRpc(name,args){return async(req,res,next)=>{try{const {data,error}=await req.supabase.rpc(name,args(req)).abortSignal(AbortSignal.timeout(10000));if(error){const code={PT404:404,PT409:409,'42501':403,'22023':400}[error.code];if(code)return res.status(code).json({message:error.message});throw error;}return res.json(data);}catch(error){return next(error);}};}
export const logoutSummary=ownRpc('my_logout_summary',()=>({}));
export const staffList=async(req,res,next)=>{try{const {data,error}=await req.supabase.from('profiles').select('id,first_name,last_name,email,role').in('role',['admin','superUser']).is('demo_dataset',null).order('first_name').abortSignal(AbortSignal.timeout(10000));if(error)throw error;return res.json({staff:data});}catch(error){return next(error);}};
export const promoteAdmin=async(req,res,next)=>{
 if(!uuid.test(req.params.id)||typeof req.body?.expectedUpdatedAt!=='string'||!Number.isFinite(Date.parse(req.body.expectedUpdatedAt)))return res.status(400).json({message:'Reload the account before changing access.'});
 return ownRpc('promote_platform_admin',r=>({_user:r.params.id,_expected:r.body.expectedUpdatedAt}))(req,res,next);
};
export const bookingActionFailure=async(req,res,next)=>{
 if(!uuid.test(req.params.id)||!uuid.test(req.body?.requestId)||!['accept','decline','cancel'].includes(req.body?.action))return res.status(400).json({message:'Invalid booking action reference.'});
 return ownRpc('record_booking_action_failure',r=>({_booking:r.params.id,_action:r.body.action,_request:r.body.requestId}))(req,res,next);
};
