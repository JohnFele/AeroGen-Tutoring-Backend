import { ENV } from './env.config.js';

export function normalizeOrigins(value, { production = false } = {}) {
  const values = Array.isArray(value) ? value : String(value || '').split(',');
  return [...new Set(values.map(value => String(value || '').trim()).filter(Boolean).map(value => {
    // Accept a hostname in deployment configuration, but compare full origins.
    const url = new URL(value.includes('://') ? value : `https://${value}`);
    if (!['http:', 'https:'].includes(url.protocol) || (production && url.protocol !== 'https:') ||
      url.username || url.password || url.pathname !== '/' || url.search || url.hash || url.hostname.includes('*')) {
      throw new Error('Frontend origins must be exact HTTP(S) origins; production origins must use HTTPS.');
    }
    return url.origin;
  }))];
}

export function createCorsOptions(config = ENV) {
  const production = config.NODE_ENV === 'production';
  const allowed = new Set(normalizeOrigins(production ? config.FRONTEND_ORIGINS_PROD : config.FRONTEND_ORIGINS_DEV, { production }));
  return {
    origin(origin, callback) {
      // Non-browser clients still pass through authentication and authorization.
      if (!origin || allowed.has(origin)) return callback(null, true);
      const error = new Error('This browser origin is not permitted.');
      error.code = 'CORS_FORBIDDEN';
      return callback(error);
    },
    methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'],
    allowedHeaders: ['Content-Type', 'Authorization'],
    maxAge: 600,
  };
}

export const corsOptions = createCorsOptions();
