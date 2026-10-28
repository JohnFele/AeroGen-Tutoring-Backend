import { submitApplication, currentApplication } from '../controllers/application.controller.js';
import { authorize } from '../middleware/auth.middleware.js';
import { Router } from 'express';
import { sendEnquiry, sendSubjectRequest } from '../controllers/site.controller.js';
import { supportLimiter } from '../middleware/rateLimit.middleware.js';

const router = Router();
router.post('/enquiries', supportLimiter, sendEnquiry);
router.post('/subject-requests', supportLimiter, sendSubjectRequest);
// Authentication and the larger, rate-limited JSON parser are installed before the global parser in app.js.
router.post('/tutor-applications', submitApplication);
router.get('/tutor-applications/me', authorize, currentApplication);
export default router;
