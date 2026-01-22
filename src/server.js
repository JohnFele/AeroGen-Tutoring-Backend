import mongoose from 'mongoose';
import app from './app.js';
import { ENV } from './config/env.config.js';
import { log, error } from './utils/logger.js';

const start = async () => {
  try {
    await mongoose.connect(ENV.MONGO_URI, { autoIndex: true });
    log('Connected to MongoDB');

    const server = app.listen(ENV.PORT, () => {
      log(`Server listening on ${ENV.PORT} (${ENV.NODE_ENV})`);
    });

    process.on('SIGTERM', () => {
      log('SIGTERM, closing');
      server.close(() => process.exit(0));
    });
    process.on('SIGINT', () => {
      log('SIGINT, closing');
      server.close(() => process.exit(0));
    });
  } catch (err) {
    error('Failed to start', err);
    process.exit(1);
  }
};

start();
