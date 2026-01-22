import jwt from 'jsonwebtoken';
import crypto from 'crypto';
import { ENV } from '../config/env.config.js';

const JWT_ACCESS_SECRET = ENV.JWT_ACCESS_SECRET;
const JWT_REFRESH_SECRET = ENV.JWT_REFRESH_SECRET;

export const signAccessToken = (payload, options = {}) => {
  const defaultOptions = { expiresIn: ENV.ACCESS_TOKEN_EXPIRES_IN || '15m' };
  return jwt.sign(payload, JWT_ACCESS_SECRET, defaultOptions);
}

export const signRefreshToken = (payload, options = {}) => {
  const defaultOptions = { expiresIn: ENV.REFRESH_TOKEN_EXPIRES_IN || '7d' };
  return jwt.sign(payload, JWT_REFRESH_SECRET, defaultOptions);
}

export const verifyAccessToken = (token) => jwt.verify(token, JWT_ACCESS_SECRET);

export const verifyRefreshToken = (token) => jwt.verify(token, JWT_REFRESH_SECRET);

export const generateRandomToken = (length = 48) => {
  return crypto.randomBytes(length).toString('hex');
}

export const hashToken = (token) => {
  return crypto.createHash('sha256').update(token).digest('hex');
}