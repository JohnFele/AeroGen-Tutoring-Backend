import jwt from 'jsonwebtoken';
import crypto from 'crypto';
import { ENV } from '../config/env.js';

export const signAccessToken = (user) => {
  const payload = { sub: String(user._id), role: user.role };
  return jwt.sign(payload, ENV.JWT_ACCESS_SECRET, {
    expiresIn: ENV.ACCESS_TOKEN_EXPIRES_IN,
    issuer: 'your-app-name',
    audience: 'your-app-users',
  });
};

export const signRefreshToken = (user, tokenId) => {
  const payload = { sub: String(user._id), tokenId };
  return jwt.sign(payload, ENV.JWT_REFRESH_SECRET, {
    expiresIn: ENV.REFRESH_TOKEN_EXPIRES_IN,
    issuer: 'your-app-name',
    audience: 'your-app-users',
  });
};

export const generateTokenId = () => crypto.randomUUID();

export const decodeRefresh = (token) => jwt.decode(token);

export const verifyRefresh = (token) => jwt.verify(token, ENV.JWT_REFRESH_SECRET);

export const verifyAccess = (token) => jwt.verify(token, ENV.JWT_ACCESS_SECRET);
