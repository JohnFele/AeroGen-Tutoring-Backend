import { User } from '../models/User.js';
import { RefreshToken } from '../models/RefreshToken.js';
import { PasswordResetToken } from '../models/PasswordResetToken.js';
import { hash, compare } from '../utils/hash.js';
import { generateTokenId, signAccessToken, signRefreshToken, decodeRefresh } from './token.service.js';
import { ENV } from '../config/env.js';

export const createUser = async ({ role, firstName, lastName, email, phone, city, password }) => {
  const passwordHash = await hash(password, 12);
  const user = await User.create({ role, firstName, lastName, email: email.toLowerCase(), phone, city, passwordHash });
  return user;
};

export const findUserByEmail = async (email) => {
  return User.findOne({ email: String(email).toLowerCase() });
};

export const verifyPassword = async (user, password) => {
  return compare(password, user.passwordHash);
};

export const createRefreshForUser = async (user, rawRefreshToken, deviceId, deviceInfo) => {
  const decoded = decodeRefresh(rawRefreshToken);
  const expiresAt = decoded && decoded.exp ? new Date(decoded.exp * 1000) : null;
  const tokenId = decoded.tokenId;
  const tokenHash = await hash(rawRefreshToken, 12);
  return RefreshToken.create({ tokenId, tokenHash, user: user._id, deviceId, deviceInfo, expiresAt });
};

export const revokeRefreshById = async (tokenId) => RefreshToken.deleteOne({ tokenId });

export const revokeAllUserRefreshes = async (userId) => RefreshToken.deleteMany({ user: userId });

export const findRefreshRecord = async (tokenId) => RefreshToken.findOne({ tokenId });

export const savePasswordResetToken = async (userId, rawToken, ttlMinutes = 15) => {
  const tokenHash = await hash(rawToken, 12);
  const expiresAt = new Date(Date.now() + ttlMinutes * 60 * 1000);
  return PasswordResetToken.create({ tokenHash, user: userId, expiresAt });
};

export const findValidPasswordReset = async (token) => {
  // scan token collection for un-used, not expired token by comparing hashes
  const list = await PasswordResetToken.find({ used: false, expiresAt: { $gt: new Date() } }).limit(50);
  for (const rec of list) {
    const matches = await compare(token, rec.tokenHash);
    if (matches) return rec;
  }
  return null;
};

export const markResetUsed = async (id) => PasswordResetToken.findByIdAndUpdate(id, { used: true });

export const incrementLoginAttempt = async (user) => {
  user.loginAttempts.count = (user.loginAttempts.count || 0) + 1;
  user.loginAttempts.lastAttempt = new Date();
  if (user.loginAttempts.count >= ENV.MAX_LOGIN_ATTEMPTS) {
    user.loginAttempts.lockedUntil = new Date(Date.now() + ENV.LOGIN_LOCK_TIME_MINUTES * 60 * 1000);
  }
  await user.save();
};

export const resetLoginAttempts = async (user) => {
  user.loginAttempts = { count: 0 };
  await user.save();
};

export const isAccountLocked = (user) => {
  if (!user.loginAttempts || !user.loginAttempts.lockedUntil) return false;
  return new Date() < new Date(user.loginAttempts.lockedUntil);
};
