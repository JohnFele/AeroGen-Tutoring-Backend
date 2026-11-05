import rateLimit from 'express-rate-limit';

const isProfileRead = req => ['GET', 'HEAD'].includes(req.method) && /^\/api\/v1\/users\/me\/?$/i.test(req.path);

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
  skip: isProfileRead,
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
