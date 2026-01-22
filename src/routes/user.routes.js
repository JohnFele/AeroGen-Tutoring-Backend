import express from "express";
import {
  me,
} from "../controllers/user.controller.js";
import { authorize } from "../middleware/auth.middleware.js";

const router = express.Router();

router.use(authorize);

router.get("/me", me);

export default router;