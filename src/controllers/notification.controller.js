const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const instant=/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|\+00:00)$/;
const timeout=()=>AbortSignal.timeout(15000);
const pageSize=50;
export const notificationCursor=row=>Buffer.from(JSON.stringify([row.created_at,row.id])).toString('base64url');
export function parseNotificationQuery(query){
 const filter=query.filter||'all';if(!['all','unread'].includes(filter))throw Error('Choose all or unread notifications.');let before=null;
 if(query.cursor){if(typeof query.cursor!=='string'||query.cursor.length>512||!/^[A-Za-z0-9_-]+$/.test(query.cursor))throw Error('Invalid notification page.');try{before=JSON.parse(Buffer.from(query.cursor,'base64url').toString())}catch{throw Error('Invalid notification page.')}if(!Array.isArray(before)||before.length!==2||before.some(value=>typeof value!=='string')||!instant.test(before[0])||!Number.isFinite(Date.parse(before[0]))||!uuid.test(before[1]))throw Error('Invalid notification page.');}
 return{filter,before};
}
export async function listNotifications(req,res,next){
 let input;try{input=parseNotificationQuery(req.query)}catch(error){return res.status(400).json({message:error.message})}
 try{
  let query=req.supabase.from('notifications').select('id,kind,title,body,data,read_at,created_at').eq('user_id',req.userId).order('created_at',{ascending:false}).order('id',{ascending:false}).limit(pageSize+1);
  if(input.filter==='unread')query=query.is('read_at',null);
  if(input.before){const[time,id]=input.before;query=query.or(`created_at.lt.${time},and(created_at.eq.${time},id.lt.${id})`)}
  const{data,error}=await query.abortSignal(timeout());if(error)throw error;
  const items=data.slice(0,pageSize);res.set('Cache-Control','no-store');return res.json({notifications:items,nextCursor:data.length>pageSize?notificationCursor(items.at(-1)):null});
 }catch(error){next(error)}
}
export async function markNotificationRead(req,res,next){
 const{ids,all}=req.body||{};
 if(all===true?ids!==undefined:all!==undefined||!Array.isArray(ids)||ids.length>500||ids.some(id=>typeof id!=='string'||!uuid.test(id)))return res.status(400).json({message:'Choose valid notifications or mark all as read.'});
 if(all!==true&&!ids.length)return res.json({message:'No unread notifications selected.'});
 try{let query=req.supabase.from('notifications').update({read_at:new Date().toISOString()}).eq('user_id',req.userId).is('read_at',null);if(!all)query=query.in('id',[...new Set(ids)]);const{error}=await query.abortSignal(timeout());if(error)throw error;return res.json({message:'Notifications marked read.'})}catch(error){next(error)}
}
export async function deleteNotification(req,res,next){
 if(!uuid.test(req.params.id))return res.status(400).json({message:'Invalid notification ID.'});
 try{const{data,error}=await req.supabase.from('notifications').delete().eq('id',req.params.id).eq('user_id',req.userId).select('id').maybeSingle().abortSignal(timeout());if(error)throw error;return data?res.json({message:'Notification deleted.'}):res.status(404).json({message:'Notification not found.'})}catch(error){next(error)}
}
export async function readConversation(req,res,next){
 const messageId=req.body?.lastMessageId;
 if(!uuid.test(req.params.id)||messageId!==undefined&&!uuid.test(messageId))return res.status(400).json({message:'Choose a valid conversation and message.'});
 try{
  const{data:membership,error:memberError}=await req.supabase.from('conversation_members').select('conversation_id').eq('conversation_id',req.params.id).eq('user_id',req.userId).maybeSingle().abortSignal(timeout());if(memberError)throw memberError;if(!membership)return res.status(404).json({message:'Conversation not found.'});
  let query=req.supabase.from('messages').select('created_at').eq('conversation_id',req.params.id).is('deleted_at',null);if(messageId)query=query.eq('id',messageId);
  const{data:message,error:readError}=await query.order('created_at',{ascending:false}).limit(1).maybeSingle().abortSignal(timeout());if(readError)throw readError;if(!message&&messageId)return res.status(404).json({message:'Message not found.'});
  if(message){const{error}=await req.supabase.from('conversation_members').update({last_read_at:message.created_at}).eq('conversation_id',req.params.id).eq('user_id',req.userId).abortSignal(timeout());if(error)throw error;}
  return res.json({message:'Conversation marked read.'});
 }catch(error){next(error)}
}
