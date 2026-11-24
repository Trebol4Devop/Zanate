const ALLOWED_FOLDERS = {
  forum: {
    kind: 'image',
    mimes: new Set(['image/jpeg', 'image/png', 'image/webp']),
    maxBytes: 2 * 1024 * 1024,
  },
  groups: {
    kind: 'image',
    mimes: new Set(['image/jpeg', 'image/png', 'image/webp']),
    maxBytes: 2 * 1024 * 1024,
  },
  listings: {
    kind: 'image',
    mimes: new Set(['image/jpeg', 'image/png', 'image/webp']),
    maxBytes: 2 * 1024 * 1024,
  },
  forum_videos: {
    kind: 'video',
    mimes: new Set(['video/mp4', 'video/webm', 'video/quicktime']),
    maxBytes: 50 * 1024 * 1024,
  },
};

const RATE_LIMIT_WINDOWS = {
  image: { maxRequests: 6, windowMs: 60 * 1000 },
  video: { maxRequests: 2, windowMs: 300 * 1000 },
};

const SIGNED_URL_TTL_SECONDS = 120;
const ORPHAN_GRACE_PERIOD_MS = 2 * 60 * 60 * 1000;
const CLEANUP_BATCH_LIMIT = 500;

const uploadHistoryByUserKind = new Map();
const encoder = new TextEncoder();

export function resetRateLimitsForTest() {
  uploadHistoryByUserKind.clear();
}

export function getCorsHeaders(request, env) {
  const origin = request.headers.get('Origin');
  const rawAllowed = (env?.ALLOWED_ORIGINS || '*').trim();
  const allowed = rawAllowed
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);

  let allowOrigin = '';
  if (allowed.includes('*')) {
    allowOrigin = origin || '*';
  } else if (origin && allowed.includes(origin)) {
    allowOrigin = origin;
  }

  if (!allowOrigin) {
    return {};
  }

  return {
    'Access-Control-Allow-Origin': allowOrigin,
    'Access-Control-Allow-Methods': 'GET, HEAD, POST, PUT, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization, Range',
    'Access-Control-Expose-Headers': 'Content-Length, Content-Range, Accept-Ranges, ETag',
    'Access-Control-Max-Age': '86400',
    ...(allowOrigin !== '*' ? { Vary: 'Origin' } : {}),
  };
}

function jsonResponse(data, status, corsHeaders, extraHeaders = {}) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      'Content-Type': 'application/json',
      ...corsHeaders,
      ...extraHeaders,
    },
  });
}

function hasPathTraversal(value) {
  if (typeof value !== 'string') return true;
  return (
    value.includes('..') ||
    value.includes('/') ||
    value.includes('\\') ||
    value.includes('\0')
  );
}

function sanitizeFilename(rawName, userId, nowMs) {
  const cleaned = rawName
    .replace(/[^a-zA-Z0-9._-]/g, '_')
    .replace(/^\.+/, '');
  if (!cleaned) {
    return `${userId}_${nowMs}_file`;
  }
  const base = cleaned.startsWith(`${userId}_`)
    ? cleaned
    : `${userId}_${nowMs}_${cleaned}`;
  return base.slice(0, 160);
}

export function matchesMagicBytes(bytes, contentType) {
  if (!(bytes instanceof Uint8Array) || bytes.length < 4) {
    return false;
  }

  switch (contentType) {
    case 'image/jpeg':
      return bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;

    case 'image/png':
      return (
        bytes.length >= 8 &&
        bytes[0] === 0x89 &&
        bytes[1] === 0x50 &&
        bytes[2] === 0x4e &&
        bytes[3] === 0x47 &&
        bytes[4] === 0x0d &&
        bytes[5] === 0x0a &&
        bytes[6] === 0x1a &&
        bytes[7] === 0x0a
      );

    case 'image/webp':
      return (
        bytes.length >= 12 &&
        bytes[0] === 0x52 && // R
        bytes[1] === 0x49 && // I
        bytes[2] === 0x46 && // F
        bytes[3] === 0x46 && // F
        bytes[8] === 0x57 && // W
        bytes[9] === 0x45 && // E
        bytes[10] === 0x42 && // B
        bytes[11] === 0x50 // P
      );

    case 'video/webm':
      return (
        bytes[0] === 0x1a &&
        bytes[1] === 0x45 &&
        bytes[2] === 0xdf &&
        bytes[3] === 0xa3
      );

    case 'video/mp4':
      return (
        bytes.length >= 12 &&
        bytes[4] === 0x66 && // f
        bytes[5] === 0x74 && // t
        bytes[6] === 0x79 && // y
        bytes[7] === 0x70 // p
      );

    case 'video/quicktime': {
      if (bytes.length < 12) return false;
      const box = String.fromCharCode(bytes[4], bytes[5], bytes[6], bytes[7]);
      return (
        box === 'ftyp' ||
        box === 'moov' ||
        box === 'mdat' ||
        box === 'wide' ||
        box === 'free'
      );
    }

    default:
      return false;
  }
}

async function importSigningKey(secret) {
  return globalThis.crypto.subtle.importKey(
    'raw',
    encoder.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign', 'verify']
  );
}

function toHex(buffer) {
  return Array.from(new Uint8Array(buffer))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

function constantTimeEqualHex(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string' || a.length !== b.length) {
    return false;
  }
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

async function signUploadToken(secret, payload) {
  const key = await importSigningKey(secret);
  const sigBuffer = await globalThis.crypto.subtle.sign(
    'HMAC',
    key,
    encoder.encode(payload)
  );
  return toHex(sigBuffer);
}

async function verifySupabaseUser(request, env, fetchImpl) {
  const authHeader = request.headers.get('Authorization') || '';
  const match = authHeader.match(/^Bearer\s+(.+)$/i);
  if (!match || !match[1].trim()) {
    return { ok: false, status: 401, code: 'missing_token', message: 'Token de sesión requerido.' };
  }

  if (!env?.SUPABASE_URL || !env?.SUPABASE_ANON_KEY) {
    return {
      ok: false,
      status: 500,
      code: 'misconfigured',
      message: 'Falta configuración de autenticación en el servicio.',
    };
  }

  const supabaseUrl = env.SUPABASE_URL.replace(/\/+$/, '');
  const token = match[1].trim();

  let res;
  try {
    res = await fetchImpl(`${supabaseUrl}/auth/v1/user`, {
      method: 'GET',
      headers: {
        apikey: env.SUPABASE_ANON_KEY,
        Authorization: `Bearer ${token}`,
      },
    });
  } catch {
    return {
      ok: false,
      status: 502,
      code: 'auth_unreachable',
      message: 'No se pudo verificar la sesión con el servidor.',
    };
  }

  if (!res.ok) {
    return {
      ok: false,
      status: 401,
      code: 'invalid_token',
      message: 'Sesión inválida o expirada.',
    };
  }

  let user;
  try {
    user = await res.json();
  } catch {
    return {
      ok: false,
      status: 401,
      code: 'invalid_user',
      message: 'Respuesta de sesión inválida.',
    };
  }

  if (!user?.id || user.is_anonymous === true) {
    return {
      ok: false,
      status: 401,
      code: 'anonymous_not_allowed',
      message: 'Debes iniciar sesión con una cuenta registrada para subir archivos.',
    };
  }

  return { ok: true, userId: String(user.id) };
}

function checkRateLimit(userId, kind, nowMs) {
  const rule = RATE_LIMIT_WINDOWS[kind] || RATE_LIMIT_WINDOWS.image;
  const bucketKey = `${userId}:${kind}`;
  const cutoff = nowMs - rule.windowMs;
  const recent = (uploadHistoryByUserKind.get(bucketKey) || []).filter(
    (ts) => ts > cutoff
  );

  if (recent.length >= rule.maxRequests) {
    const oldest = recent[0];
    const retryAfterSec = Math.max(1, Math.ceil((oldest + rule.windowMs - nowMs) / 1000));
    uploadHistoryByUserKind.set(bucketKey, recent);
    return { allowed: false, retryAfterSec };
  }

  recent.push(nowMs);
  uploadHistoryByUserKind.set(bucketKey, recent);
  return { allowed: true, retryAfterSec: 0 };
}

function parseRangeHeader(rangeHeader, totalSize) {
  if (!rangeHeader || !rangeHeader.startsWith('bytes=')) {
    return null;
  }
  const spec = rangeHeader.slice('bytes='.length).split(',')[0].trim();
  const parts = spec.split('-');
  if (parts.length !== 2) return null;

  const [startStr, endStr] = parts;
  if (startStr === '' && endStr === '') return null;

  if (startStr === '') {
    const suffix = Number.parseInt(endStr, 10);
    if (!Number.isFinite(suffix) || suffix <= 0) return null;
    if (totalSize != null) {
      const start = Math.max(0, totalSize - suffix);
      return { offset: start, length: totalSize - start };
    }
    return { suffix };
  }

  const start = Number.parseInt(startStr, 10);
  if (!Number.isFinite(start) || start < 0) return null;

  if (endStr === '') {
    if (totalSize != null) {
      if (start >= totalSize) return { invalid: true };
      return { offset: start, length: totalSize - start };
    }
    return { offset: start };
  }

  const end = Number.parseInt(endStr, 10);
  if (!Number.isFinite(end) || end < start) return null;

  const clampedEnd = totalSize != null ? Math.min(end, totalSize - 1) : end;
  if (totalSize != null && start >= totalSize) return { invalid: true };

  return { offset: start, length: clampedEnd - start + 1 };
}

function extractKeyFromMediaUrl(rawUrl) {
  if (typeof rawUrl !== 'string' || !rawUrl.trim()) return null;
  try {
    const parsed = new URL(rawUrl.trim());
    const idx = parsed.pathname.indexOf('/images/');
    if (idx === -1) return null;
    const key = decodeURIComponent(parsed.pathname.slice(idx + '/images/'.length));
    return key || null;
  } catch {
    return null;
  }
}

async function fetchSupabaseJson(supabaseUrl, serviceRoleKey, path, fetchImpl) {
  const res = await fetchImpl(`${supabaseUrl}/rest/v1/${path}`, {
    method: 'GET',
    headers: {
      apikey: serviceRoleKey,
      Authorization: `Bearer ${serviceRoleKey}`,
      Accept: 'application/json',
    },
  });
  return res;
}

export async function cleanupOrphanObjects(env, fetchImpl = fetch, nowMs = Date.now()) {
  if (!env?.R2_BUCKET || !env?.SUPABASE_URL || !env?.SUPABASE_SERVICE_ROLE_KEY) {
    return { skipped: true, deletedCount: 0, scannedCount: 0 };
  }

  const supabaseUrl = env.SUPABASE_URL.replace(/\/+$/, '');
  const serviceKey = env.SUPABASE_SERVICE_ROLE_KEY;
  const referencedKeys = new Set();

  let postsRes = await fetchSupabaseJson(
    supabaseUrl,
    serviceKey,
    'posts?select=image_url,video_url&limit=1000',
    fetchImpl
  );
  if (!postsRes.ok) {
    postsRes = await fetchSupabaseJson(
      supabaseUrl,
      serviceKey,
      'posts?select=image_url&limit=1000',
      fetchImpl
    );
  }
  if (postsRes.ok) {
    const posts = await postsRes.json();
    for (const row of posts) {
      const imgKey = extractKeyFromMediaUrl(row?.image_url);
      if (imgKey) referencedKeys.add(imgKey);
      const vidKey = extractKeyFromMediaUrl(row?.video_url);
      if (vidKey) referencedKeys.add(vidKey);
    }
  }

  const groupsRes = await fetchSupabaseJson(
    supabaseUrl,
    serviceKey,
    'student_groups?select=image_url&limit=1000',
    fetchImpl
  );
  if (groupsRes.ok) {
    const groups = await groupsRes.json();
    for (const row of groups) {
      const key = extractKeyFromMediaUrl(row?.image_url);
      if (key) referencedKeys.add(key);
    }
  }

  const marketRes = await fetchSupabaseJson(
    supabaseUrl,
    serviceKey,
    'marketplace_items?select=image_urls&limit=1000',
    fetchImpl
  );
  if (marketRes.ok) {
    const items = await marketRes.json();
    for (const row of items) {
      const urls = Array.isArray(row?.image_urls) ? row.image_urls : [];
      for (const u of urls) {
        const key = extractKeyFromMediaUrl(u);
        if (key) referencedKeys.add(key);
      }
    }
  }

  const keysToDelete = [];
  let scannedCount = 0;

  for (const folder of Object.keys(ALLOWED_FOLDERS)) {
    if (scannedCount >= CLEANUP_BATCH_LIMIT) break;
    const listed = await env.R2_BUCKET.list({
      prefix: `${folder}/`,
      limit: CLEANUP_BATCH_LIMIT - scannedCount,
    });
    const objects = listed?.objects || [];
    scannedCount += objects.length;

    for (const obj of objects) {
      const uploadedMs = obj.uploaded ? new Date(obj.uploaded).getTime() : 0;
      const ageMs = nowMs - uploadedMs;
      if (ageMs > ORPHAN_GRACE_PERIOD_MS && !referencedKeys.has(obj.key)) {
        keysToDelete.push(obj.key);
      }
    }
  }

  if (keysToDelete.length > 0) {
    await env.R2_BUCKET.delete(keysToDelete);
  }

  return {
    skipped: false,
    scannedCount,
    deletedCount: keysToDelete.length,
    deletedKeys: keysToDelete,
  };
}

export function createWorker(options = {}) {
  const fetchImpl = options.fetchImpl || ((...args) => fetch(...args));
  const nowProvider = options.nowProvider || (() => Date.now());

  return {
    async fetch(request, env) {
      const corsHeaders = getCorsHeaders(request, env);

      if (request.method === 'OPTIONS') {
        return new Response(null, { status: 204, headers: corsHeaders });
      }

      const url = new URL(request.url);
      const pathname = url.pathname;

      if (pathname === '/health' && request.method === 'GET') {
        return jsonResponse(
          { status: 'ok', service: 'comunidad-usac-storage' },
          200,
          corsHeaders
        );
      }

      // 1. Solicitud de URL firmada para subida directa al Worker
      if (pathname === '/upload' && request.method === 'POST') {
        if (!env?.UPLOAD_SIGNING_SECRET) {
          return jsonResponse(
            { error: 'Servicio de subida sin secreto de firma configurado.' },
            500,
            corsHeaders
          );
        }

        const auth = await verifySupabaseUser(request, env, fetchImpl);
        if (!auth.ok) {
          return jsonResponse({ error: auth.message, code: auth.code }, auth.status, corsHeaders);
        }

        let body;
        try {
          body = await request.json();
        } catch {
          return jsonResponse({ error: 'Cuerpo JSON inválido.' }, 400, corsHeaders);
        }

        const folder = typeof body?.folder === 'string' ? body.folder.trim() : '';
        const filename = typeof body?.filename === 'string' ? body.filename.trim() : '';
        const contentType =
          typeof body?.contentType === 'string' ? body.contentType.trim().toLowerCase() : '';
        const size = body?.size;

        if (!folder || !filename || !contentType) {
          return jsonResponse(
            { error: 'Faltan parámetros obligatorios para la subida.' },
            400,
            corsHeaders
          );
        }

        if (hasPathTraversal(folder) || hasPathTraversal(filename)) {
          return jsonResponse({ error: 'Ruta o nombre de archivo inválido.' }, 400, corsHeaders);
        }

        const folderRule = ALLOWED_FOLDERS[folder];
        if (!folderRule) {
          return jsonResponse({ error: 'Carpeta de destino no permitida.' }, 400, corsHeaders);
        }

        if (!folderRule.mimes.has(contentType)) {
          return jsonResponse(
            { error: 'Tipo de archivo no permitido para esta sección.' },
            400,
            corsHeaders
          );
        }

        if (size !== undefined && (typeof size !== 'number' || !Number.isFinite(size) || size <= 0)) {
          return jsonResponse({ error: 'Tamaño de archivo inválido.' }, 400, corsHeaders);
        }

        if (typeof size === 'number' && size > folderRule.maxBytes) {
          return jsonResponse(
            { error: 'El archivo supera el tamaño máximo permitido.' },
            413,
            corsHeaders
          );
        }

        const nowMs = nowProvider();
        const rate = checkRateLimit(auth.userId, folderRule.kind, nowMs);
        if (!rate.allowed) {
          return jsonResponse(
            { error: 'Demasiadas subidas seguidas. Intenta de nuevo en unos segundos.' },
            429,
            corsHeaders,
            { 'Retry-After': String(rate.retryAfterSec) }
          );
        }

        const safeFilename = sanitizeFilename(filename, auth.userId, nowMs);
        const key = `${folder}/${safeFilename}`;
        const exp = Math.floor(nowMs / 1000) + SIGNED_URL_TTL_SECONDS;
        const payload = `${key}|${contentType}|${folderRule.maxBytes}|${auth.userId}|${exp}`;
        const sig = await signUploadToken(env.UPLOAD_SIGNING_SECRET, payload);

        const origin = url.origin;
        const signedPath =
          `${origin}/upload-direct/${key}` +
          `?exp=${exp}&max=${folderRule.maxBytes}&ct=${encodeURIComponent(contentType)}&sig=${sig}`;
        const publicUrl = `${origin}/images/${key}`;

        return jsonResponse(
          {
            uploadUrl: signedPath,
            directUploadUrl: signedPath,
            publicUrl,
            key,
            expiresIn: SIGNED_URL_TTL_SECONDS,
          },
          200,
          corsHeaders
        );
      }

      // 2. Subida directa autenticada y firmada hacia R2
      if (pathname.startsWith('/upload-direct/') && request.method === 'PUT') {
        if (!env?.UPLOAD_SIGNING_SECRET || !env?.R2_BUCKET) {
          return jsonResponse(
            { error: 'Almacenamiento o secreto no configurado.' },
            500,
            corsHeaders
          );
        }

        const auth = await verifySupabaseUser(request, env, fetchImpl);
        if (!auth.ok) {
          return jsonResponse({ error: auth.message, code: auth.code }, auth.status, corsHeaders);
        }

        const key = decodeURIComponent(pathname.slice('/upload-direct/'.length));
        const segments = key.split('/');
        if (
          segments.length !== 2 ||
          hasPathTraversal(segments[0]) ||
          hasPathTraversal(segments[1])
        ) {
          return jsonResponse({ error: 'Clave de objeto inválida.' }, 400, corsHeaders);
        }

        const [folder, filename] = segments;
        const folderRule = ALLOWED_FOLDERS[folder];
        if (!folderRule || !filename.startsWith(`${auth.userId}_`)) {
          return jsonResponse({ error: 'No autorizado para esta ruta.' }, 403, corsHeaders);
        }

        const expParam = Number.parseInt(url.searchParams.get('exp') || '', 10);
        const maxParam = Number.parseInt(url.searchParams.get('max') || '', 10);
        const ctParam = (url.searchParams.get('ct') || '').trim().toLowerCase();
        const sigParam = (url.searchParams.get('sig') || '').trim().toLowerCase();

        const nowSec = Math.floor(nowProvider() / 1000);
        if (!Number.isFinite(expParam) || expParam < nowSec) {
          return jsonResponse({ error: 'La autorización de subida expiró.' }, 403, corsHeaders);
        }

        if (
          !Number.isFinite(maxParam) ||
          maxParam <= 0 ||
          maxParam > folderRule.maxBytes ||
          !folderRule.mimes.has(ctParam)
        ) {
          return jsonResponse({ error: 'Parámetros de firma inválidos.' }, 403, corsHeaders);
        }

        const expectedPayload = `${key}|${ctParam}|${maxParam}|${auth.userId}|${expParam}`;
        const expectedSig = await signUploadToken(env.UPLOAD_SIGNING_SECRET, expectedPayload);
        if (!constantTimeEqualHex(sigParam, expectedSig)) {
          return jsonResponse({ error: 'Firma de subida inválida.' }, 403, corsHeaders);
        }

        const contentLengthHeader = request.headers.get('Content-Length');
        if (contentLengthHeader) {
          const declaredSize = Number.parseInt(contentLengthHeader, 10);
          if (Number.isFinite(declaredSize) && declaredSize > maxParam) {
            return jsonResponse(
              { error: 'El archivo supera el tamaño máximo permitido.' },
              413,
              corsHeaders
            );
          }
        }

        const buffer = await request.arrayBuffer();
        if (buffer.byteLength === 0) {
          return jsonResponse({ error: 'El archivo está vacío.' }, 400, corsHeaders);
        }
        if (buffer.byteLength > maxParam) {
          return jsonResponse(
            { error: 'El archivo supera el tamaño máximo permitido.' },
            413,
            corsHeaders
          );
        }

        const bytes = new Uint8Array(buffer);
        if (!matchesMagicBytes(bytes, ctParam)) {
          return jsonResponse(
            { error: 'El contenido del archivo no coincide con el formato declarado.' },
            415,
            corsHeaders
          );
        }

        await env.R2_BUCKET.put(key, buffer, {
          httpMetadata: {
            contentType: ctParam,
            cacheControl: 'public, max-age=31536000, immutable',
          },
          customMetadata: {
            uploadedBy: auth.userId,
            folder,
          },
        });

        const publicUrl = `${url.origin}/images/${key}`;
        return jsonResponse({ ok: true, key, publicUrl }, 200, corsHeaders);
      }

      // 3. Lectura pública de medios con caché CDN y soporte Range para video
      if (
        pathname.startsWith('/images/') &&
        (request.method === 'GET' || request.method === 'HEAD')
      ) {
        if (!env?.R2_BUCKET) {
          return new Response('Storage not configured', { status: 500, headers: corsHeaders });
        }

        const key = decodeURIComponent(pathname.slice('/images/'.length));
        const segments = key.split('/');
        if (
          segments.length !== 2 ||
          hasPathTraversal(segments[0]) ||
          hasPathTraversal(segments[1]) ||
          !ALLOWED_FOLDERS[segments[0]]
        ) {
          return new Response('Not Found', { status: 404, headers: corsHeaders });
        }

        const rangeHeader = request.headers.get('Range');
        if (rangeHeader) {
          const headObj = await env.R2_BUCKET.head(key);
          if (!headObj) {
            return new Response('Not Found', { status: 404, headers: corsHeaders });
          }

          const parsedRange = parseRangeHeader(rangeHeader, headObj.size);
          if (!parsedRange || parsedRange.invalid) {
            return new Response('Range Not Satisfiable', {
              status: 416,
              headers: {
                'Content-Range': `bytes */${headObj.size}`,
                ...corsHeaders,
              },
            });
          }

          const obj =
            request.method === 'HEAD'
              ? headObj
              : await env.R2_BUCKET.get(key, { range: parsedRange });
          if (!obj) {
            return new Response('Not Found', { status: 404, headers: corsHeaders });
          }

          const start = parsedRange.offset ?? 0;
          const length = parsedRange.length ?? headObj.size - start;
          const end = start + length - 1;

          const headers = new Headers();
          if (typeof obj.writeHttpMetadata === 'function') {
            obj.writeHttpMetadata(headers);
          } else if (obj.httpMetadata?.contentType) {
            headers.set('Content-Type', obj.httpMetadata.contentType);
          }
          if (obj.httpEtag) headers.set('ETag', obj.httpEtag);
          headers.set('Accept-Ranges', 'bytes');
          headers.set('Content-Range', `bytes ${start}-${end}/${headObj.size}`);
          headers.set('Content-Length', String(length));
          headers.set('Cache-Control', 'public, max-age=31536000, immutable');
          headers.set('X-Content-Type-Options', 'nosniff');
          headers.set('Content-Disposition', 'inline');
          for (const [k, v] of Object.entries(corsHeaders)) {
            headers.set(k, v);
          }

          return new Response(request.method === 'HEAD' ? null : obj.body, {
            status: 206,
            headers,
          });
        }

        const object =
          request.method === 'HEAD'
            ? await env.R2_BUCKET.head(key)
            : await env.R2_BUCKET.get(key);
        if (!object) {
          return new Response('Not Found', { status: 404, headers: corsHeaders });
        }

        const headers = new Headers();
        if (typeof object.writeHttpMetadata === 'function') {
          object.writeHttpMetadata(headers);
        } else if (object.httpMetadata?.contentType) {
          headers.set('Content-Type', object.httpMetadata.contentType);
        }
        if (object.httpEtag) headers.set('ETag', object.httpEtag);
        if (typeof object.size === 'number') {
          headers.set('Content-Length', String(object.size));
        }
        headers.set('Accept-Ranges', 'bytes');
        headers.set('Cache-Control', 'public, max-age=31536000, immutable');
        headers.set('X-Content-Type-Options', 'nosniff');
        headers.set('Content-Disposition', 'inline');
        for (const [k, v] of Object.entries(corsHeaders)) {
          headers.set(k, v);
        }

        return new Response(request.method === 'HEAD' ? null : object.body, {
          status: 200,
          headers,
        });
      }

      return jsonResponse({ error: 'Endpoint no encontrado.' }, 404, corsHeaders);
    },

    async scheduled(_controller, env, ctx) {
      ctx.waitUntil(cleanupOrphanObjects(env, fetchImpl, nowProvider()));
    },
  };
}

export default createWorker();
