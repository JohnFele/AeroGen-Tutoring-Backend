import express from 'express';
import helmet from 'helmet';
import cors from 'cors';
import routes from './routes/router.js';
// import { ENV } from './config/env.config.js';
import { applicationLimiter, generalLimiter } from './middleware/rateLimit.middleware.js';
import { corsOptions } from './config/cors.config.js';
import { authorize } from './middleware/auth.middleware.js';

const app = express();

app.use(helmet());
app.use(cors(corsOptions));
app.post('/api/v1/site/tutor-applications', applicationLimiter, authorize, express.json({ limit: '28mb' }));
app.put('/api/v1/site/tutor-application-draft', authorize, express.json({ limit: '28mb' }));
app.use(express.json({ limit: '10mb' }));
app.use(express.urlencoded({ extended: false }));
app.use(generalLimiter);

app.use('/api/v1/', routes);

app.use((err, req, res, next) => {
  if (err.type === 'entity.parse.failed') return res.status(400).json({ error: 'Invalid JSON' });
  if (err.type === 'entity.too.large') return res.status(413).json({ message: 'The submitted files are too large. Check each document size and try again.' });
  console.error('Unhandled server error:', err.message);
  res.status(500).json({ error: 'Internal server error' });
});

export default app;
