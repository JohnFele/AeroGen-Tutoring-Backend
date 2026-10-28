import { Router } from 'express';
import { authorize } from '../middleware/auth.middleware.js';
const router=Router();
router.use(authorize);
const idPattern=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
router.get('/',async(req,res,next)=>{
  try{const {data,error}=await req.supabase.rpc('my_tutoring_workspace');if(error)throw error;return res.json(data);}catch(error){return next(error);}
});
router.post('/conversations/:id/messages',async(req,res,next)=>{
  if(!idPattern.test(req.params.id)||typeof req.body?.body!=='string'||!req.body.body.trim()||req.body.body.length>10000)return res.status(400).json({message:'Choose a conversation and enter a message of 1 to 10,000 characters.'});
  try{const {data,error}=await req.supabase.rpc('send_tutoring_message',{_conversation_id:req.params.id,_body:req.body.body});if(error?.code==='42501')return res.status(403).json({message:'You cannot access this conversation.'});if(error)throw error;return res.status(201).json({id:data});}catch(error){return next(error);}
});
router.patch('/conversations/:id/read',async(req,res,next)=>{
  if(!idPattern.test(req.params.id))return res.status(400).json({message:'Invalid conversation ID.'});
  try{const {data,error}=await req.supabase.from('conversation_members').update({last_read_at:new Date().toISOString()}).eq('conversation_id',req.params.id).eq('user_id',req.userId).select('conversation_id');if(error)throw error;if(!data.length)return res.status(404).json({message:'Conversation not found.'});return res.json({message:'Conversation marked read.'});}catch(error){return next(error);}
});
router.patch('/notifications/read',async(req,res,next)=>{
  const ids=req.body?.ids;
  if(!Array.isArray(ids)||ids.length>500||ids.some(id=>typeof id!=='string'||!idPattern.test(id)))return res.status(400).json({message:'Choose valid notifications.'});
  try{const {error}=await req.supabase.from('notifications').update({read_at:new Date().toISOString()}).eq('user_id',req.userId).in('id',ids);if(error)throw error;return res.json({message:'Notifications marked read.'});}catch(error){return next(error);}
});
router.delete('/notifications/:id',async(req,res,next)=>{
  if(!idPattern.test(req.params.id))return res.status(400).json({message:'Invalid notification ID.'});
  try{const {error}=await req.supabase.from('notifications').delete().eq('user_id',req.userId).eq('id',req.params.id);if(error)throw error;return res.json({message:'Notification deleted.'});}catch(error){return next(error);}
});
export default router;
