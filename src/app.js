import express from 'express';
import helmet from 'helmet';
import cors from 'cors';
import routes from './routes/router.js';
// import { ENV } from './config/env.config.js';
import { applicationLimiter, generalLimiter, messagingIpLimiter, profileReadLimiter } from './middleware/rateLimit.middleware.js';
import { corsOptions } from './config/cors.config.js';
import { preventPrivateCaching } from './middleware/security.middleware.js';
import { authorize } from './middleware/auth.middleware.js';
import {platformGate as defaultPlatformGate,requireApplicationsOpen} from './middleware/platform.middleware.js';

export function createApp({platformGate=defaultPlatformGate,corsConfig=corsOptions}={}) {
const app = express();

app.use(helmet());
app.use(preventPrivateCaching);
app.use(cors(corsConfig));
// Reject excessive traffic before parsing potentially large upload bodies.
app.use(profileReadLimiter);
app.use(messagingIpLimiter);
app.use(generalLimiter);
app.post('/api/v1/site/tutor-applications', applicationLimiter, authorize, platformGate, requireApplicationsOpen, express.json({ limit: '28mb' }));
app.put('/api/v1/site/tutor-application-draft', authorize, platformGate, express.json({ limit: '28mb' }));
app.post(['/api/v1/site/bug-reports', '/api/v1/workspace/bug-reports'], express.json({ limit: '3mb' }));
app.use(express.json({ limit: '10mb' }));
app.use(express.urlencoded({ extended: false }));

app.use('/api/v1',platformGate);
app.get('/api/v1/health',(req,res)=>res.json({status:'ok'}));
app.use('/api/v1/', routes);

app.use((err, req, res, next) => {
  if(err.code==='CORS_FORBIDDEN')return res.status(403).json({code:'CORS_FORBIDDEN',message:'This browser origin is not permitted.'});
  if(err.code==='PT503')return res.status(503).json({code:'MAINTENANCE_MODE',message:'AeroGen Tutoring is temporarily undergoing maintenance.'});
  if(err.code==='PT403')return res.status(403).json({code:'APPLICATIONS_PAUSED',message:'New tutor applications are temporarily paused.'});
  if (err.type === 'entity.parse.failed') return res.status(400).json({ error: 'Invalid JSON' });
  if (err.type === 'entity.too.large') return res.status(413).json({ message: 'The submitted files are too large. Check each document size and try again.' });
  console.error('Unhandled server error:', err.message);
  res.status(500).json({ error: 'Internal server error' });
});

return app;
}
export default createApp();
