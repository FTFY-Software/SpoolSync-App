import { Router } from 'express';
import { randomUUID } from 'crypto';
import jwt from 'jsonwebtoken';
import fetch from 'node-fetch';
import * as oidcConfigService from '../services/oidcConfigService.js';
import * as userService from '../services/userService.js';
import { authenticate, requirePermission } from '../middleware/auth.js';

const router = Router();

// Use PUBLIC_URL when set; otherwise derive the callback URL from the live
// request so it matches the external hostname (uses X-Forwarded-Host /
// X-Forwarded-Proto via trust proxy).
function callbackUrlFor(req) {
  const base = process.env.PUBLIC_URL?.replace(/\/+$/, '') || `${req.protocol}://${req.hostname}`;
  return `${base}/api/v1/auth/oidc/callback`;
}

// ── Public: OIDC status ────────────────────────────────────────────────────
router.get('/oidc-status', async (_req, res, next) => {
  try {
    const enabled = await oidcConfigService.isEnabled();
    res.json({ enabled });
  } catch (err) {
    next(err);
  }
});

// ── Public: Initiate OIDC flow ─────────────────────────────────────────────
router.get('/oidc', async (req, res, next) => {
  try {
    const config = await oidcConfigService.getConfig();
    if (!config?.enabled) {
      return res.redirect('/login?error=oidc_disabled');
    }

    const discovery = await oidcConfigService.getDiscovery(config.issuer);
    const state = randomUUID();
    const nonce = randomUUID();

    // Sign state + nonce into a short-lived cookie so we can verify the callback
    const stateCookie = jwt.sign({ state, nonce }, process.env.JWT_SECRET, { expiresIn: '5m' });
    res.cookie('oidc_state', stateCookie, {
      httpOnly: true,
      sameSite: 'lax',
      secure: process.env.NODE_ENV === 'production',
      maxAge: 5 * 60 * 1000,
    });

    const params = new URLSearchParams({
      response_type: 'code',
      client_id: config.clientId,
      redirect_uri: callbackUrlFor(req),
      scope: 'openid email profile',
      state,
      nonce,
    });

    res.redirect(`${discovery.authorization_endpoint}?${params}`);
  } catch (err) {
    next(err);
  }
});

// ── Public: OIDC callback ──────────────────────────────────────────────────
router.get('/oidc/callback', async (req, res, next) => {
  try {
    const { code, state: queryState, error } = req.query;

    if (error) {
      res.clearCookie('oidc_state');
      return res.redirect('/login?error=oidc_failed');
    }

    const stateCookieToken = req.cookies?.oidc_state;
    if (!stateCookieToken || !code || !queryState) {
      res.clearCookie('oidc_state');
      return res.redirect('/login?error=oidc_failed');
    }

    let cookieState, nonce;
    try {
      ({ state: cookieState, nonce } = jwt.verify(stateCookieToken, process.env.JWT_SECRET));
    } catch {
      res.clearCookie('oidc_state');
      return res.redirect('/login?error=oidc_failed');
    }

    if (queryState !== cookieState) {
      res.clearCookie('oidc_state');
      return res.redirect('/login?error=oidc_failed');
    }

    const config = await oidcConfigService.getConfig();
    const discovery = await oidcConfigService.getDiscovery(config.issuer);

    // Exchange authorization code for tokens
    const tokenResponse = await fetch(discovery.token_endpoint, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'authorization_code',
        code,
        redirect_uri: callbackUrlFor(req),
        client_id: config.clientId,
        client_secret: config.clientSecret,
      }),
    });

    if (!tokenResponse.ok) {
      res.clearCookie('oidc_state');
      return res.redirect('/login?error=oidc_failed');
    }

    const tokens = await tokenResponse.json();

    // Decode id_token — issuer already proved identity via code exchange
    const claims = jwt.decode(tokens.id_token);
    if (!claims || !claims.sub || claims.nonce !== nonce) {
      res.clearCookie('oidc_state');
      return res.redirect('/login?error=oidc_failed');
    }

    // Extract SSO group/role claims (support both 'roles' and 'groups')
    const ssoRoles = [
      ...(Array.isArray(claims.roles) ? claims.roles : []),
      ...(Array.isArray(claims.groups) ? claims.groups : []),
    ].filter((r) => typeof r === 'string' && r.length > 0);

    const user = await userService.findOrCreateOidcUser({
      provider: config.issuer,
      providerId: claims.sub,
      email: claims.email,
      displayName: claims.name,
      ssoRoles,
    });

    const appToken = jwt.sign(
      { sub: user.userId },
      process.env.JWT_SECRET,
      { expiresIn: '7d' }
    );

    res.clearCookie('oidc_state');
    res.redirect(`/auth/callback?token=${encodeURIComponent(appToken)}`);
  } catch (err) {
    res.clearCookie('oidc_state');
    res.redirect('/login?error=oidc_failed');
  }
});

// ── Admin: Get OIDC config ────────────────────────────────────────────────
router.get('/oidc-config', authenticate, requirePermission('settings:view'), async (_req, res, next) => {
  try {
    const config = await oidcConfigService.getConfig();
    if (!config) return res.json(null);
    const { clientSecret, ...rest } = config;
    res.json({ ...rest, clientSecret: clientSecret ? '••••••' : '' });
  } catch (err) {
    next(err);
  }
});

// ── Admin: Upsert OIDC config ─────────────────────────────────────────────
router.put('/oidc-config', authenticate, requirePermission('settings:edit'), async (req, res, next) => {
  try {
    const { issuer, clientId, clientSecret, callbackUrl, enabled } = req.body;
    const config = await oidcConfigService.upsertConfig({ issuer, clientId, clientSecret, callbackUrl, enabled });
    const { clientSecret: _, ...rest } = config;
    res.json({ ...rest, clientSecret: '••••••' });
  } catch (err) {
    next(err);
  }
});

export default router;
