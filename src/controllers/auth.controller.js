import User from "../models/User.model.js";
// import { sendEmail } from "../utils/sendEmail.js";
import { RefreshToken } from "../models/RefreshToken.model.js";
import {
  signAccessToken,
  // signRefreshToken,
  hashToken,
  generateRandomToken,
  // verifyRefreshToken
} from "../utils/jwt.util.js";
import { ENV } from "../config/env.config.js";
import { OAuth2Client } from "google-auth-library";


const GOOGLE_CLIENT_ID = ENV.GOOGLE_CLIENT_ID;
const isProduction = ENV.NODE_ENV === 'production';

const client = new OAuth2Client(GOOGLE_CLIENT_ID);

const REFRESH_COOKIE_OPTIONS = {
  httpOnly: true,
  secure: isProduction,
  sameSite: isProduction ? 'none' : 'lax',
  path: "/api/v1/auth/refresh",
};

const setRefreshTokenCookie = (res, rawToken, expiresInMs) => {
  res.cookie("refreshToken", rawToken, {
    ...REFRESH_COOKIE_OPTIONS,
    maxAge: expiresInMs,
  });
}

const clearRefreshTokenCookie = (res) => {
  res.clearCookie("refreshToken", { ...REFRESH_COOKIE_OPTIONS, maxAge: 0 });
}

const createAndStoreRefreshToken = async ({ userId, rawToken, userAgent="", ipAddress="", isLongLived=false }) => {
  const lifetimeMs = isLongLived ? ENV.REMEMBER_ME_EXPIRES_MS : ENV.REFRESH_TOKEN_EXPIRES_MS;
  const expiresAt = new Date(Date.now() + lifetimeMs);
  const tokenHash = hashToken(rawToken);

  await RefreshToken.create({
    user: userId,
    tokenHash,
    expiresAt,
    userAgent,
    ipAddress,
    isLongLived,
    revoked:false,
  });

  return { lifetimeMs, expiresAt };
}

export const register = async (req, res, next) => {
  try {
    const { firstName, lastName, email, password, role, location, phone } = req.body;

    if (!firstName || !lastName || !email || !password || !role || !location || !phone) {
      return res.status(400).json({ message: "All fields are required." });
    }

    const existingUser = await User.findOne({ email });
    if (existingUser) {
      return res.status(409).json({ message: "Email is already in use." });
    }

    const newUser = new User({ firstName, lastName, email, password, role, location, phone });
    await newUser.save();

    const accessToken = signAccessToken({ userId: newUser._id, role: newUser.role });
    const rawRefreshToken = generateRandomToken();
    const { lifetimeMs } = await createAndStoreRefreshToken({
      userId: newUser._id,
      rawToken: rawRefreshToken,
      userAgent: req.get('User-Agent') || '',
      ipAddress: req.ip,
      isLongLived: false,
    });

    setRefreshTokenCookie(res, rawRefreshToken, lifetimeMs);

    return res.status(201).json({
      message: "User registered successfully.",
      user: newUser.toJSON(),
      accessToken,
    });
  } catch (error) {
    next(error);
  }
}

export const login = async (req, res, next) => {
  try {
    const { email, password, rememberMe } = req.body;

    if (!email || !password) {
      return res.status(400).json({ message: "Email and password are required." });
    }

    const user = await User.findOne({ email }).select("+password");
    if (!user || !(await user.comparePassword(password))) {
      return res.status(401).json({ message: "Invalid email or password." });
    }

    const accessToken = signAccessToken({ userId: user._id, role: user.role });
    const rawRefreshToken = generateRandomToken();

    const isLongLived = rememberMe === 'on';

    await RefreshToken.deleteMany({ user: user._id });

    const { lifetimeMs } = await createAndStoreRefreshToken({
      userId: user._id,
      rawToken: rawRefreshToken,
      userAgent: req.get('User-Agent') || '',
      ipAddress: req.ip,
      isLongLived,
    });

    setRefreshTokenCookie(res, rawRefreshToken, lifetimeMs);

    return res.status(200).json({
      message: "Login successful.",
      user: user.toJSON(),
      accessToken,
    });
  } catch (error) {
    next(error);
  }
}

export const googleLogin = async (req, res, next) => {
  const { credential } = req.body;

  try {
    if (!credential) {
      return res.status(400).json({ message: "ID token is required." });
    }

    const ticket = await client.verifyIdToken({
      idToken: credential,
      audience: GOOGLE_CLIENT_ID,
    });

    if (!ticket) {
      return res.status(401).json({ message: "Failed to verify ID token." });
    }

    const payload = ticket.getPayload();

    if (!payload?.email) {
      return res.status(400).json({ message: "User email not found in token." });
    }

    if (!payload.email_verified) {
      return res.status(400).json({ message: "User email is not verified." });
    }

    if (payload.aud !== GOOGLE_CLIENT_ID) {
      return res.status(400).json({ message: "Invalid token audience." });
    }

    const validIssuers = ["accounts.google.com", "https://accounts.google.com"];

    if (!validIssuers.includes(payload.iss)) {
      return res.status(400).json({ message: "Invalid token issuer." });
    }

    let user = await User.findOne({ email: payload.email });

    if (user && user.password && user.authProvider !== 'google') {
      return res.status(400).json({ message: "Email is already registered. Please login using email and password." });
    }

    if (!user) {
      user = new User({
        firstName: payload.given_name || "Google",
        lastName: payload.family_name || "User",
        email: payload.email,
        role: "student",
        location: payload.locale || "Unknown",
        phone: "Unknown",
        password: null,
        authProvider: 'google',
        isVerified: true,
      });

      await user.save();
    } else {
      if (user.authProvider !== 'google') {
        user.authProvider = 'google';
        user.isVerified = true;
        await user.save();
      }
    }

    await RefreshToken.deleteMany({ user: user._id });

    const tokenPayload = { userId: user._id, role: user.role };
    const accessToken = signAccessToken(tokenPayload);
    const rawRefreshToken = generateRandomToken();
    
    const { lifetimeMs } = await createAndStoreRefreshToken({
      userId: user._id,
      rawToken: rawRefreshToken,
      userAgent: req.get('User-Agent') || '',
      ipAddress: req.ip,
      isLongLived: false,
    });

    setRefreshTokenCookie(res, rawRefreshToken, lifetimeMs);

    return res.status(200).json({
      message: "Login successful.",
      user: user.toJSON(),
      accessToken,
    });
  } catch (error) {
    next(error);
  }
}

export const logout = async (req, res, next) => {
  try {
    const rawRefreshToken = req.cookies?.refreshToken;
    if (rawRefreshToken) {
      const refreshTokenHash = hashToken(rawRefreshToken);
      await RefreshToken.findOneAndUpdate(
        { tokenHash: refreshTokenHash, revoked: false },
        { revoked: true }
      ).exec();
    }

    clearRefreshTokenCookie(res);

    return res.status(200).json({ message: "Logout successful." });
  } catch (error) {
    next(error);
  }
}

export const refreshToken = async (req, res, next) => {
  try {
    const rawRefreshToken = req.cookies?.refreshToken;
    if (!rawRefreshToken) {
      return res.status(401).json({ message: "Refresh token missing." });
    }

    const refreshTokenHash = hashToken(rawRefreshToken);
    const storedToken = await RefreshToken.findOne({ tokenHash: refreshTokenHash, revoked: false }).populate('user');
    
    if (!storedToken || storedToken.revoked) {
      clearRefreshTokenCookie(res);
      return res.status(401).json({ message: "Invalid refresh token." });
    }

    if (storedToken.expiresAt < new Date()) {
      await storedToken.remove();
      clearRefreshTokenCookie(res);
      return res.status(401).json({ message: "Refresh token expired." });
    }

    const currentUserAgent = req.get('User-Agent') || '';
    const currentIpAddress = req.ip;

    if (storedToken.userAgent !== currentUserAgent || storedToken.ipAddress !== currentIpAddress) {
      clearRefreshTokenCookie(res);
      return res.status(401).json({ message: "Refresh token context mismatch." });
    }

    storedToken.revoked = true;
    await storedToken.save();

    const newRawRefreshToken = generateRandomToken();
    const isLongLived = storedToken.isLongLived === true;
    const lifetimeMs = isLongLived ? ENV.REMEMBER_ME_EXPIRES_MS : ENV.REFRESH_TOKEN_EXPIRES_MS;
    const newExpiresAt = new Date(Date.now() + lifetimeMs);
    const newRefreshTokenHash = hashToken(newRawRefreshToken);
    
    await RefreshToken.create({
      user: storedToken.user._id,
      tokenHash: newRefreshTokenHash,
      expiresAt: newExpiresAt,
      userAgent: req.get('User-Agent') || '',
      ipAddress: req.ip,
      isLongLived,
      revoked: false,
    });

    const accessToken = signAccessToken({ userId: storedToken.user._id, role: storedToken.user.role });

    setRefreshTokenCookie(res, newRawRefreshToken, lifetimeMs);

    return res.status(200).json({
      message: "Token refreshed successfully.",
      accessToken,
    });
  } catch (error) {
    next(error);
  }
}