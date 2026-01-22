import dotenv from 'dotenv';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

dotenv.config({ path: path.join(__dirname, '../../.env') });

const toBool = (v) => String(v) === 'true' || String(v) === '1';

const toMilliseconds = (timeString) => {
  const units = {
    s: 1000,         // seconds
    m: 1000 * 60,    // minutes
    h: 1000 * 60 * 60, // hours
    d: 1000 * 60 * 60 * 24, // days
    w: 1000 * 60 * 60 * 24 * 7, // weeks
  };

  const match = timeString.match(/^(\d+)([smhdw])$/);
  if (match) {
    const value = parseInt(match[1]);
    const unit = match[2];
    return value * units[unit];
  }
  
  // Fallback: try to parse as milliseconds
  return parseInt(timeString) || 7 * 24 * 60 * 60 * 1000; // Default 7 days
};

export const ENV = {
  PORT: process.env.PORT || 4000,
  NODE_ENV: process.env.NODE_ENV || 'development',
  // FRONTEND_ORIGIN: process.env.FRONTEND_ORIGIN || 'http://localhost:3000',
  FRONTEND_ORIGINS_DEV: process.env.FRONTEND_ORIGINS_DEV || 'http://localhost:5173',
  FRONTEND_ORIGINS_PROD: process.env.FRONTEND_ORIGINS_PROD || '',

  GOOGLE_CLIENT_ID: process.env.GOOGLE_CLIENT_ID || '',
  GOOGLE_CLIENT_SECRET: process.env.GOOGLE_CLIENT_SECRET || '',

  MONGO_URI: process.env.MONGO_URI || 'mongodb+srv://johnfele86_db_user:Vj7aUUtFexdty0GN@cluster-test-v1.ujdmy1t.mongodb.net',

  JWT_ACCESS_SECRET: process.env.JWT_ACCESS_SECRET || 'change_me_access',
  JWT_REFRESH_SECRET: process.env.JWT_REFRESH_SECRET || 'change_me_refresh',
  ACCESS_TOKEN_EXPIRES_IN: process.env.ACCESS_TOKEN_EXPIRES_IN || '15m',
  REFRESH_TOKEN_EXPIRES_IN: process.env.REFRESH_TOKEN_EXPIRES_IN || '7d',

  ACCESS_TOKEN_EXPIRES_MS: toMilliseconds(process.env.ACCESS_TOKEN_EXPIRES_IN || '15m'),
  REFRESH_TOKEN_EXPIRES_MS: toMilliseconds(process.env.REFRESH_TOKEN_EXPIRES_IN || '7d'),
  REMEMBER_ME_EXPIRES_MS: toMilliseconds(process.env.REMEMBER_ME_EXPIRES_IN || '30d'),

  COOKIE_SECURE: toBool(process.env.COOKIE_SECURE || 'false'),
  COOKIE_SAME_SITE: process.env.COOKIE_SAME_SITE || 'lax',

  SMTP_HOST: process.env.SMTP_HOST || '',
  SMTP_PORT: Number(process.env.SMTP_PORT || 587),
  SMTP_USER: process.env.SMTP_USER || '',
  SMTP_PASS: process.env.SMTP_PASS || '',
  EMAIL_FROM: process.env.EMAIL_FROM || 'no-reply@example.com',

  MAX_LOGIN_ATTEMPTS: Number(process.env.MAX_LOGIN_ATTEMPTS || 5),
  LOGIN_LOCK_TIME_MINUTES: Number(process.env.LOGIN_LOCK_TIME_MINUTES || 15),
};
