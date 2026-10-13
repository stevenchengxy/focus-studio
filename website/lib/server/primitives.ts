/** Pure helpers, shared with the executable backend regression suite. */
export class APIError extends Error {
  constructor(public status: number, public code: string, message: string) { super(message); }
}
export const nowSeconds = () => Math.floor(Date.now() / 1000);
export const randomSecret = () => Array.from(crypto.getRandomValues(new Uint8Array(32)), b => b.toString(16).padStart(2, '0')).join('');
export async function sha256(value: string) {
  const data = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  return Array.from(new Uint8Array(data), b => b.toString(16).padStart(2, '0')).join('');
}
export function requireText(value: unknown, name: string, max = 128) {
  if (typeof value !== 'string' || !value.trim() || value.length > max) throw new APIError(400, 'invalid_input', `Invalid ${name}.`);
  return value.trim();
}
export function checkOrigin(request: Request, siteOrigin: string, allowNative = false) {
  const origin = request.headers.get('origin');
  const bearer = /^Bearer fs_[a-f0-9]{64}$/.test(request.headers.get('authorization') ?? '');
  if (allowNative && bearer && !origin) return;
  if (origin !== siteOrigin || request.headers.get('sec-fetch-site') === 'cross-site') {
    throw new APIError(403, 'origin_rejected', 'Open this action from Focus Studio.');
  }
}
export async function readBody(request: Request, max = 4096) {
  if (!(request.headers.get('content-type') ?? '').toLowerCase().startsWith('application/json')) throw new APIError(415, 'json_required', 'Send application/json.');
  const text = await boundedText(request, max);
  try {
    const body = JSON.parse(text);
    if (!body || typeof body !== 'object' || Array.isArray(body)) throw new Error();
    return body as Record<string, unknown>;
  } catch { throw new APIError(400, 'invalid_json', 'Invalid JSON object.'); }
}
export async function boundedText(request: Request, max: number) {
  if (Number(request.headers.get('content-length') || 0) > max) throw new APIError(413, 'body_too_large', 'Request is too large.');
  const reader = request.body?.getReader();
  if (!reader) return '';
  const chunks: Uint8Array[] = []; let size = 0;
  for (;;) {
    const { done, value } = await reader.read(); if (done) break;
    size += value.length;
    if (size > max) { await reader.cancel(); throw new APIError(413, 'body_too_large', 'Request is too large.'); }
    chunks.push(value);
  }
  const all = new Uint8Array(size); let offset = 0;
  for (const chunk of chunks) { all.set(chunk, offset); offset += chunk.length; }
  return new TextDecoder().decode(all);
}
export async function verifyStripeSignature(raw: string, header: string | null, secret: string, now = nowSeconds()) {
  if (!header || header.length > 2048) throw new APIError(400, 'invalid_signature', 'Invalid webhook signature.');
  const parts = header.split(',').map(p => p.split('='));
  const timestamps = parts.filter(p => p[0] === 't');
  const stamp = Number(timestamps[0]?.[1]);
  if (timestamps.length !== 1 || !Number.isInteger(stamp) || Math.abs(now - stamp) > 300) throw new APIError(400, 'invalid_signature', 'Invalid webhook signature.');
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['verify']);
  for (const [, signature] of parts.filter(p => p[0] === 'v1')) {
    if (!/^[a-f0-9]{64}$/.test(signature)) continue;
    const bytes = new Uint8Array(signature.match(/../g)!.map(h => parseInt(h, 16)));
    if (await crypto.subtle.verify('HMAC', key, bytes, new TextEncoder().encode(`${stamp}.${raw}`))) return;
  }
  throw new APIError(400, 'invalid_signature', 'Invalid webhook signature.');
}
export function subscriptionIsActive(status: string, periodEnd: number, now = nowSeconds()) {
  return status === 'active' && periodEnd > now;
}
export function safePublicUrl(value: unknown): string | null {
  if (typeof value !== 'string' || !value) return null;
  try { const url = new URL(value); return url.protocol === 'https:' ? url.href : null; } catch { return null; }
}
