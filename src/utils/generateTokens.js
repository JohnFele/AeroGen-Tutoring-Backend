import jwt from "jsonwebtoken";
import { ENV } from "../config/env.js";

export const generateTokens = (userId) => {
  const accessToken = jwt.sign({ id: userId }, ENV.JWT_ACCESS_SECRET, {
    expiresIn: "15m",
  });

  const refreshToken = jwt.sign({ id: userId }, ENV.JWT_REFRESH_SECRET, {
    expiresIn: "7d",
  });

  if (!accessToken || !refreshToken) {
    throw new Error("Token generation failed");
  }

  return { accessToken, refreshToken };
};
