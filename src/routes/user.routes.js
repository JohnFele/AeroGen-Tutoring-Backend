import express from "express";
import {
  me,
  updateMe,
  getTeachingSubjects,
  saveTeachingSubjects,
  getTutorListing,
  saveTutorListing,
  getNotificationPreferences,
  updateNotificationPreferences,
} from "../controllers/user.controller.js";
import { authorize } from "../middleware/auth.middleware.js";
import { sendSupportRequest } from "../controllers/support.controller.js";
import { supportLimiter } from "../middleware/rateLimit.middleware.js";
import { learnerAgeProfile } from "../controllers/learning.controller.js";

const router = express.Router();

router.use(authorize);

router.get("/me", me);
router.patch("/me", updateMe);
router.get("/me/learner-age", learnerAgeProfile);
router.patch("/me/learner-age", learnerAgeProfile);
router.get("/me/teaching", getTeachingSubjects);
router.patch("/me/teaching", saveTeachingSubjects);
router.get("/me/tutor-listing", getTutorListing);
router.patch("/me/tutor-listing", saveTutorListing);
router.get("/me/notification-preferences", getNotificationPreferences);
router.patch("/me/notification-preferences", updateNotificationPreferences);
router.post("/me/support-requests", supportLimiter, sendSupportRequest);

export default router;
