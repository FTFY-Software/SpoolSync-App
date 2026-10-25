import express from 'express';
import helmet from 'helmet';
import morgan from 'morgan';
import passport from 'passport';
import cookieParser from 'cookie-parser';

import { configurePassport } from './middleware/auth.js';
import { errorHandler, notFoundHandler } from './middleware/errorHandler.js';
import apiRoutes from './routes/index.js';

const app = express();

// Trust the ingress reverse-proxy so req.protocol / req.hostname reflect
// the external X-Forwarded-Proto / X-Forwarded-Host headers.
app.set('trust proxy', true);

app.use(helmet());
app.use(express.json());
app.use(express.urlencoded({ extended: true }));
app.use(cookieParser());
app.use(morgan('dev'));

configurePassport(passport);
app.use(passport.initialize());

app.use('/api/v1', apiRoutes);

app.get('/health', (_req, res) => res.json({ status: 'ok' }));
app.get('/api/version', (_req, res) => res.json({ version: process.env.APP_VERSION || 'dev' }));
app.get('/api/client-config', (_req, res) => res.json({ esp32ServerHost: process.env.ESP32_SERVER_HOST || null }));

app.use(notFoundHandler);
app.use(errorHandler);

export default app;
