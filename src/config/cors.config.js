import { ENV } from "./env.config.js";

const normalizeOrigins = (origins) => {
  if (!origins) return [];

  if (Array.isArray(origins)) return origins.filter(Boolean);

  return String(origins)
    .split(",")
    .map((origin) => origin.trim())
    .filter(Boolean);
};

const devOrigins = normalizeOrigins(ENV.FRONTEND_ORIGINS_DEV);
const prodOrigins = normalizeOrigins(ENV.FRONTEND_ORIGINS_PROD);

const allowedOrigins = ENV.NODE_ENV === "production" ? prodOrigins : devOrigins;

export const corsOptions = {
  origin: (origin, callback) => {
    // Allow requests with no origin (like mobile apps or curl requests)
    if (!origin) return callback(null, true);

    if (allowedOrigins.includes(origin) || allowedOrigins.length === 0) return callback(null, true);
    
    return callback(new Error(`CORS policy: This origin - ${origin} is not allowed`));
  },
  methods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
  allowedHeaders: ["Content-Type", "Authorization"],
  maxAge: 600,
};
