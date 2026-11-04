import { Router } from 'express';
import { authorize } from '../middleware/auth.middleware.js';
import {listNotifications,markNotificationRead,deleteNotification,readConversation} from '../controllers/notification.controller.js';
const router=Router();
router.use(authorize);
const idPattern=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
router.get('/',async(req,res,next)=>{
  try{const {data,error}=await req.supabase.rpc('my_tutoring_workspace');if(error)throw error;res.set('Cache-Control','no-store');return res.json(data);}catch(error){return next(error);}
});
router.post('/conversations/:id/messages',async(req,res,next)=>{
  if(!idPattern.test(req.params.id)||typeof req.body?.body!=='string'||!req.body.body.trim()||req.body.body.length>10000)return res.status(400).json({message:'Choose a conversation and enter a message of 1 to 10,000 characters.'});
  try{const {data,error}=await req.supabase.rpc('send_tutoring_message',{_conversation_id:req.params.id,_body:req.body.body});if(error?.code==='42501')return res.status(403).json({message:'You cannot access this conversation.'});if(error)throw error;return res.status(201).json({id:data});}catch(error){return next(error);}
});
router.patch('/conversations/:id/read',readConversation);
router.get('/notifications',listNotifications);
router.patch('/notifications/read',markNotificationRead);
router.delete('/notifications/:id',deleteNotification);
export default router;
