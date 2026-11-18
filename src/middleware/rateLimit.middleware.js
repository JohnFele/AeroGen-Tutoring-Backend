import rateLimit from 'express-rate-limit';

const isProfileRead = req => ['GET', 'HEAD'].includes(req.method) && /^\/api\/v1\/users\/me\/?$/i.test(req.path);
export const isMessagingActivity=req=>/^\/api\/v1\/workspace\/(?:notification-summary|conversations(?:\/[a-f0-9-]{36}(?:\/(?:messages|read|block))?)?)\/?$/i.test((req.originalUrl||req.path||'').split('?')[0]);
export const messagingIpLimiter=rateLimit({windowMs:60000,max:1200,skip:req=>!isMessagingActivity(req),standardHeaders:true,legacyHeaders:false});
export const messagingAccountLimiter=rateLimit({windowMs:60000,max:600,skip:req=>!isMessagingActivity(req),keyGenerator:req=>req.userId||req.ip,
 standardHeaders:true,legacyHeaders:false,message:{message:'Messaging is busy. Please wait a moment before retrying.'}});

export const applicationLimiter = rateLimit({ windowMs: 60 * 60 * 1000, max: 3, standardHeaders: true, legacyHeaders: false, message: { message: 'Too many application attempts. Please try again later.' } });

export const authLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 10,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Too many auth requests, try again later' },
});

export const generalLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 200,
  standardHeaders: true,
  legacyHeaders: false,
  skip: req=>isProfileRead(req)||isMessagingActivity(req),
});

export const profileReadLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 60,
  standardHeaders: true,
  legacyHeaders: false,
  skip: req => !isProfileRead(req),
  message: { code: 'PROFILE_RATE_LIMITED', message: 'Too many profile requests. Please wait a moment and retry.' },
});

export const supportLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 5,
  standardHeaders: true,
  legacyHeaders: false,
  message: { message: 'Too many support requests. Please try again later.' },
});

export const billingLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 20,
  keyGenerator: req => req.userId || req.ip,
  standardHeaders: true,
  legacyHeaders: false,
  message: { message: 'Too many billing attempts. Please try again later.' },
});

export const bookingRequestLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 30,
  keyGenerator: req => req.userId || req.ip,
  standardHeaders: true,
  legacyHeaders: false,
  message: { message: 'Too many booking requests. Please try again later.' },
});
export const courseAnswerLimiter=rateLimit({windowMs:60*1000,max:30,keyGenerator:req=>req.userId||req.ip,
 standardHeaders:true,legacyHeaders:false,message:{message:'Please wait a minute before checking more course answers.'}});
