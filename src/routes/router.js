import { Router } from "express";
import userRoutes from "./user.routes.js";
import siteRoutes from './site.routes.js';
import adminRoutes from './admin.routes.js';
import workspaceRoutes from './workspace.routes.js';

const router = Router();

router.use("/users", userRoutes);
router.use('/site', siteRoutes);
router.use('/admin',adminRoutes);
router.use('/workspace',workspaceRoutes);

export default router;
