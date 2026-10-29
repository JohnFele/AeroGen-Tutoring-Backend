import { getDraft,saveDraft,resolveSavedDocuments } from '../controllers/applicationDraft.controller.js';
import { submitApplication, currentApplication } from '../controllers/application.controller.js';
import { authorize } from '../middleware/auth.middleware.js';
import { Router } from 'express';
import { sendEnquiry, sendSubjectRequest } from '../controllers/site.controller.js';
import { supportLimiter } from '../middleware/rateLimit.middleware.js';
import { publicContact,publicOpenings } from '../controllers/siteAdmin.controller.js';

const router = Router();
router.get('/contact-details', publicContact);
router.get('/openings', publicOpenings);
router.post('/enquiries', supportLimiter, sendEnquiry);
router.post('/subject-requests', supportLimiter, sendSubjectRequest);
// Authentication and the larger, rate-limited JSON parser are installed before the global parser in app.js.
router.post('/tutor-applications', resolveSavedDocuments, submitApplication);
router.get('/tutor-application-draft', authorize, getDraft);
router.put('/tutor-application-draft', saveDraft);
router.get('/tutor-applications/me', authorize, currentApplication);
export default router;
