import { Router } from "express";
import userRoutes from "./user.routes.js";
import siteRoutes from './site.routes.js';

const router = Router();

router.use("/users", userRoutes);
router.use('/site', siteRoutes);

export default router;
