import express from "express";
import {
  register,
  login,
  googleLogin,
  logout,
  refreshToken
} from "../controllers/auth.controller.js";

const router = express.Router();

router.post("/register", register);
// router.post("/verify", verifyAccount);
router.post("/login", login);
router.post("/google-auth", googleLogin);
router.post("/refresh", refreshToken);
// router.post("/request-reset", requestPasswordReset);
// router.post("/reset-password", resetPassword);
router.post("/logout", logout);

export default router;
