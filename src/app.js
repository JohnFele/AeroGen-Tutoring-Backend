import express from 'express';
import helmet from 'helmet';
import cors from 'cors';
import routes from './routes/router.js';
// import { ENV } from './config/env.config.js';
import { generalLimiter } from './middleware/rateLimit.middleware.js';
import { corsOptions } from './config/cors.config.js';

const app = express();

app.use(helmet());
app.use(express.json({ limit: '10mb' }));
app.use(express.urlencoded({ extended: false }));
app.use(cors(corsOptions));
app.use(generalLimiter);

app.use('/api/v1/', routes);

app.use((err, req, res, next) => {
  console.error('Unhandled', err);
  if (err.type === 'entity.parse.failed') return res.status(400).json({ error: 'Invalid JSON' });
  res.status(500).json({ error: 'Internal server error' });
});

export default app;
