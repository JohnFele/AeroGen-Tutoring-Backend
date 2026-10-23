import express from "express";
import {
  me,
  updateMe,
  getNotificationPreferences,
  updateNotificationPreferences,
} from "../controllers/user.controller.js";
import { authorize } from "../middleware/auth.middleware.js";
import { sendSupportRequest } from "../controllers/support.controller.js";
import { supportLimiter } from "../middleware/rateLimit.middleware.js";

const router = express.Router();

router.use(authorize);

router.get("/me", me);
router.patch("/me", updateMe);
router.get("/me/notification-preferences", getNotificationPreferences);
router.patch("/me/notification-preferences", updateNotificationPreferences);
router.post("/me/support-requests", supportLimiter, sendSupportRequest);

export default router;
