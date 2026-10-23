import dotenv from 'dotenv';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

dotenv.config({ path: path.join(__dirname, '../../.env') });

export const ENV = {
  PORT: process.env.PORT || 4000,
  NODE_ENV: process.env.NODE_ENV || 'development',
  FRONTEND_ORIGINS_DEV: process.env.FRONTEND_ORIGINS_DEV || 'http://localhost:5173',
  FRONTEND_ORIGINS_PROD: process.env.FRONTEND_ORIGINS_PROD || '',
  SUPABASE_URL: process.env.SUPABASE_URL || '',
  SUPABASE_PUBLISHABLE_KEY: process.env.SUPABASE_PUBLISHABLE_KEY || process.env.SUPABASE_ANON_KEY || '',
  BREVO_API_KEY: process.env.BREVO_API_KEY || '',
  BREVO_SENDER_EMAIL: process.env.BREVO_SENDER_EMAIL || '',
  BREVO_SENDER_NAME: process.env.BREVO_SENDER_NAME || 'AeroGen Tutoring',
};
