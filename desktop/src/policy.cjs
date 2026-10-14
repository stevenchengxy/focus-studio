'use strict';

const SITE_ORIGIN = 'https://focus-studio.stevenchengxy19.chatgpt.site';
const STUDIO_URL = `${SITE_ORIGIN}/studio`;
const TOKEN_PATTERN = /^fs_[0-9a-f]{64}$/;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function trustedURL(raw, studioOnly = false) {
  try {
    const url = new URL(raw);
    return url.origin === SITE_ORIGIN && !url.username && !url.password &&
      (!studioOnly || url.pathname === '/studio' || url.pathname === '/studio/');
  } catch { return false; }
}

function externalURL(raw) {
  try {
    const url = new URL(raw);
    // Authentication and billing stay in the user's normal browser. No arbitrary
    // protocols, hosts, userinfo, or local files may reach shell.openExternal.
    return trustedURL(raw) && ['/account', '/account/', '/community', '/community/', '/help', '/', '/downloads', '/privacy', '/terms'].includes(url.pathname);
  } catch { return false; }
}

function trustedIPC(event, contents) {
  return Boolean(contents && !contents.isDestroyed() && event.sender === contents &&
    event.senderFrame && event.senderFrame === contents.mainFrame && trustedURL(event.senderFrame.url, true));
}

function requestSpec(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) throw new Error('Invalid request.');
  const {path, method, body} = input;
  if (Object.keys(input).some(key => !['path', 'method', 'body'].includes(key))) throw new Error('Unsupported request.');
  if (path === '/api/account' && method === 'GET' && body == null) return {path, method};
  if (method !== 'POST' || !body || typeof body !== 'object' || Array.isArray(body)) throw new Error('Unsupported request.');
  if (path === '/api/exports/reserve') {
    if (Object.keys(body).some(key => !['idempotencyKey', 'projectId'].includes(key)) ||
      !UUID_PATTERN.test(body.idempotencyKey) || typeof body.projectId !== 'string' ||
      !body.projectId.trim() || body.projectId.length > 200) throw new Error('Invalid export request.');
    return {path, method, body: {idempotencyKey: body.idempotencyKey, projectId: body.projectId}};
  }
  if (typeof path === 'string' && /^\/api\/exports\/[0-9a-f-]{36}\/(commit|renew|release)$/.test(path) &&
    UUID_PATTERN.test(path.split('/')[3]) && Object.keys(body).length === 0) return {path, method, body: {}};
  throw new Error('Unsupported request.');
}

function capabilities(platform) {
  return {platform, systemAudio: platform === 'win32' ? 'loopback' : 'unavailable', microphone: true};
}

function validatePairing(data) {
  if (!data || !/^[0-9a-f]{64}$/.test(data.deviceCode) || !/^[A-Z0-9]{6}-[A-Z0-9]{6}$/.test(data.userCode) ||
    !Number.isFinite(data.expiresIn) || data.expiresIn < 30 || data.expiresIn > 900 ||
    !Number.isFinite(data.interval) || data.interval < 1 || data.interval > 30 ||
    !externalURL(data.verificationUriComplete)) throw new Error('Invalid pairing response.');
  const url = new URL(data.verificationUriComplete);
  if (url.pathname !== '/account' || url.searchParams.get('code') !== data.userCode || [...url.searchParams.keys()].some(key => key !== 'code')) {
    throw new Error('Invalid pairing link.');
  }
  return data;
}

function validDisplayRequest(request, contents) {
  return Boolean(contents && !contents.isDestroyed() && request.userGesture && request.videoRequested &&
    request.securityOrigin === SITE_ORIGIN && request.frame && request.frame === contents.mainFrame &&
    trustedURL(request.frame.url, true));
}

function selectionFor(sources, selected, audioRequested, platform) {
  if (!selected || typeof selected.id !== 'string') return null;
  const source = sources.find(item => item.id === selected.id);
  if (!source) return null;
  return {video: source, ...(platform === 'win32' && audioRequested && selected.audio === true ? {audio: 'loopback'} : {})};
}

module.exports = {SITE_ORIGIN, STUDIO_URL, TOKEN_PATTERN, trustedURL, externalURL, trustedIPC, requestSpec,
  capabilities, validatePairing, validDisplayRequest, selectionFor};
