import test from 'node:test';
import assert from 'node:assert/strict';
import {
  cleanupOrphanObjects,
  createWorker,
  resetRateLimitsForTest,
} from '../src/index.js';

function createMemoryR2() {
  const store = new Map();
  return {
    store,
    async put(key, value, options = {}) {
      const bytes =
        value instanceof Uint8Array
          ? value
          : new Uint8Array(value);
      store.set(key, {
        key,
        bytes,
        size: bytes.byteLength,
        httpMetadata: options.httpMetadata || {},
        customMetadata: options.customMetadata || {},
        httpEtag: `"etag-${key}"`,
        uploaded: options.uploaded || new Date(),
      });
    },
    async head(key) {
      const item = store.get(key);
      if (!item) return null;
      return {
        key: item.key,
        size: item.size,
        httpMetadata: item.httpMetadata,
        httpEtag: item.httpEtag,
        writeHttpMetadata(headers) {
          if (item.httpMetadata.contentType) {
            headers.set('Content-Type', item.httpMetadata.contentType);
          }
        },
      };
    },
    async get(key, options = {}) {
      const item = store.get(key);
      if (!item) return null;
      let slice = item.bytes;
      if (options.range && typeof options.range.offset === 'number') {
        const start = options.range.offset;
        const end =
          typeof options.range.length === 'number'
            ? start + options.range.length
            : item.bytes.byteLength;
        slice = item.bytes.slice(start, end);
      }
      return {
        key: item.key,
        size: item.size,
        httpMetadata: item.httpMetadata,
        httpEtag: item.httpEtag,
        body: slice,
        writeHttpMetadata(headers) {
          if (item.httpMetadata.contentType) {
            headers.set('Content-Type', item.httpMetadata.contentType);
          }
        },
      };
    },
    async list({ prefix = '', limit = 1000 } = {}) {
      const objects = [];
      for (const item of store.values()) {
        if (item.key.startsWith(prefix)) {
          objects.push({
            key: item.key,
            size: item.size,
            uploaded: item.uploaded,
          });
          if (objects.length >= limit) break;
        }
      }
      return { objects, truncated: false };
    },
    async delete(keys) {
      const list = Array.isArray(keys) ? keys : [keys];
      for (const k of list) {
        store.delete(k);
      }
    },
  };
}

function makeFakeFetch(userByToken = { 'valid-token': { id: 'user-1', is_anonymous: false } }) {
  return async (url, init = {}) => {
    const strUrl = String(url);
    if (strUrl.endsWith('/auth/v1/user')) {
      const auth = init.headers?.Authorization || init.headers?.authorization || '';
      const token = auth.replace(/^Bearer\s+/i, '').trim();
      const user = userByToken[token];
      if (!user) {
        return new Response(JSON.stringify({ error: 'unauthorized' }), { status: 401 });
      }
      return new Response(JSON.stringify(user), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      });
    }
    return new Response('Not Found', { status: 404 });
  };
}

function makeEnv(bucket) {
  return {
    R2_BUCKET: bucket,
    SUPABASE_URL: 'https://hfvsstkfqszpjrsrwhql.supabase.co',
    SUPABASE_ANON_KEY: 'anon-key-test',
    UPLOAD_SIGNING_SECRET: 'super-secret-signing-key-2026',
    ALLOWED_ORIGINS: 'https://zanate.pages.dev',
  };
}

const VALID_JPEG = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46]);
const VALID_MP4 = new Uint8Array([
  0x00, 0x00, 0x00, 0x18,
  0x66, 0x74, 0x79, 0x70, // ftyp
  0x6d, 0x70, 0x34, 0x32,
  0x00, 0x00, 0x00, 0x00,
]);

test('OPTIONS preflight incluye PUT, Authorization y Origin permitido', async () => {
  resetRateLimitsForTest();
  const bucket = createMemoryR2();
  const worker = createWorker({ fetchImpl: makeFakeFetch() });
  const env = makeEnv(bucket);

  const res = await worker.fetch(
    new Request('https://worker.test/upload', {
      method: 'OPTIONS',
      headers: { Origin: 'https://zanate.pages.dev' },
    }),
    env
  );

  assert.equal(res.status, 204);
  assert.equal(res.headers.get('Access-Control-Allow-Origin'), 'https://zanate.pages.dev');
  assert.match(res.headers.get('Access-Control-Allow-Methods') || '', /PUT/);
});

test('POST /upload rechaza peticiones sin token o de usuarios anónimos (401)', async () => {
  resetRateLimitsForTest();
  const bucket = createMemoryR2();
  const worker = createWorker({
    fetchImpl: makeFakeFetch({
      'anon-token': { id: 'anon-1', is_anonymous: true },
    }),
  });
  const env = makeEnv(bucket);

  const noAuthRes = await worker.fetch(
    new Request('https://worker.test/upload', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ folder: 'forum', filename: 'a.jpg', contentType: 'image/jpeg', size: 100 }),
    }),
    env
  );
  assert.equal(noAuthRes.status, 401);

  const anonRes = await worker.fetch(
    new Request('https://worker.test/upload', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: 'Bearer anon-token',
      },
      body: JSON.stringify({ folder: 'forum', filename: 'a.jpg', contentType: 'image/jpeg', size: 100 }),
    }),
    env
  );
  assert.equal(anonRes.status, 401);
});

test('POST /upload bloquea videos fuera de forum_videos, path traversal y exceso de tamaño', async () => {
  resetRateLimitsForTest();
  const bucket = createMemoryR2();
  const worker = createWorker({ fetchImpl: makeFakeFetch() });
  const env = makeEnv(bucket);

  const videoInGroups = await worker.fetch(
    new Request('https://worker.test/upload', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer valid-token' },
      body: JSON.stringify({ folder: 'groups', filename: 'clip.mp4', contentType: 'video/mp4', size: 1024 }),
    }),
    env
  );
  assert.equal(videoInGroups.status, 400);

  const traversal = await worker.fetch(
    new Request('https://worker.test/upload', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer valid-token' },
      body: JSON.stringify({ folder: 'forum', filename: '../evil.jpg', contentType: 'image/jpeg', size: 100 }),
    }),
    env
  );
  assert.equal(traversal.status, 400);

  const tooBigImg = await worker.fetch(
    new Request('https://worker.test/upload', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer valid-token' },
      body: JSON.stringify({
        folder: 'forum',
        filename: 'big.jpg',
        contentType: 'image/jpeg',
        size: 3 * 1024 * 1024,
      }),
    }),
    env
  );
  assert.equal(tooBigImg.status, 413);
});

test('Flujo completo de imagen: /upload -> PUT /upload-direct -> GET /images con caché inmutable', async () => {
  resetRateLimitsForTest();
  const bucket = createMemoryR2();
  const worker = createWorker({
    fetchImpl: makeFakeFetch(),
    nowProvider: () => 1700000000000,
  });
  const env = makeEnv(bucket);

  const signRes = await worker.fetch(
    new Request('https://worker.test/upload', {
      method: 'POST',
      headers: {
        Origin: 'https://zanate.pages.dev',
        'Content-Type': 'application/json',
        Authorization: 'Bearer valid-token',
      },
      body: JSON.stringify({
        folder: 'forum',
        filename: 'foto.jpg',
        contentType: 'image/jpeg',
        size: VALID_JPEG.byteLength,
      }),
    }),
    env
  );
  assert.equal(signRes.status, 200);
  const signJson = await signRes.json();
  assert.ok(signJson.directUploadUrl.includes('/upload-direct/forum/user-1_'));
  assert.ok(signJson.publicUrl.includes('/images/forum/user-1_'));

  const putRes = await worker.fetch(
    new Request(signJson.directUploadUrl, {
      method: 'PUT',
      headers: {
        Origin: 'https://zanate.pages.dev',
        'Content-Type': 'image/jpeg',
        Authorization: 'Bearer valid-token',
      },
      body: VALID_JPEG,
    }),
    env
  );
  assert.equal(putRes.status, 200);

  const getRes = await worker.fetch(
    new Request(signJson.publicUrl, {
      method: 'GET',
      headers: { Origin: 'https://zanate.pages.dev' },
    }),
    env
  );
  assert.equal(getRes.status, 200);
  assert.equal(getRes.headers.get('Cache-Control'), 'public, max-age=31536000, immutable');
  assert.equal(getRes.headers.get('X-Content-Type-Options'), 'nosniff');
  assert.equal(getRes.headers.get('Content-Type'), 'image/jpeg');
  const gotBytes = new Uint8Array(await getRes.arrayBuffer());
  assert.deepEqual(gotBytes, VALID_JPEG);
});

test('PUT /upload-direct rechaza magic bytes falsificados (415) y firmas adulteradas o usuario distinto (403)', async () => {
  resetRateLimitsForTest();
  const bucket = createMemoryR2();
  const worker = createWorker({
    fetchImpl: makeFakeFetch({
      'valid-token': { id: 'user-1', is_anonymous: false },
      'other-token': { id: 'user-2', is_anonymous: false },
    }),
    nowProvider: () => 1700000000000,
  });
  const env = makeEnv(bucket);

  const signRes = await worker.fetch(
    new Request('https://worker.test/upload', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer valid-token' },
      body: JSON.stringify({
        folder: 'forum',
        filename: 'fake.jpg',
        contentType: 'image/jpeg',
        size: 16,
      }),
    }),
    env
  );
  const { directUploadUrl } = await signRes.json();

  const spoofRes = await worker.fetch(
    new Request(directUploadUrl, {
      method: 'PUT',
      headers: { 'Content-Type': 'image/jpeg', Authorization: 'Bearer valid-token' },
      body: new TextEncoder().encode('not-actually-jpeg'),
    }),
    env
  );
  assert.equal(spoofRes.status, 415);

  const otherUserRes = await worker.fetch(
    new Request(directUploadUrl, {
      method: 'PUT',
      headers: { 'Content-Type': 'image/jpeg', Authorization: 'Bearer other-token' },
      body: VALID_JPEG,
    }),
    env
  );
  assert.equal(otherUserRes.status, 403);

  const tamperedUrl = directUploadUrl.replace(/sig=[a-f0-9]+/, 'sig=' + '0'.repeat(64));
  const tamperedRes = await worker.fetch(
    new Request(tamperedUrl, {
      method: 'PUT',
      headers: { 'Content-Type': 'image/jpeg', Authorization: 'Bearer valid-token' },
      body: VALID_JPEG,
    }),
    env
  );
  assert.equal(tamperedRes.status, 403);
});

test('Flujo de video en forum_videos soporta Range 206 Partial Content', async () => {
  resetRateLimitsForTest();
  const bucket = createMemoryR2();
  const worker = createWorker({
    fetchImpl: makeFakeFetch(),
    nowProvider: () => 1700000000000,
  });
  const env = makeEnv(bucket);

  const signRes = await worker.fetch(
    new Request('https://worker.test/upload', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer valid-token' },
      body: JSON.stringify({
        folder: 'forum_videos',
        filename: 'demo.mp4',
        contentType: 'video/mp4',
        size: VALID_MP4.byteLength,
      }),
    }),
    env
  );
  assert.equal(signRes.status, 200);
  const { directUploadUrl, publicUrl } = await signRes.json();

  const putRes = await worker.fetch(
    new Request(directUploadUrl, {
      method: 'PUT',
      headers: { 'Content-Type': 'video/mp4', Authorization: 'Bearer valid-token' },
      body: VALID_MP4,
    }),
    env
  );
  assert.equal(putRes.status, 200);

  const rangeRes = await worker.fetch(
    new Request(publicUrl, {
      method: 'GET',
      headers: { Range: 'bytes=0-7' },
    }),
    env
  );
  assert.equal(rangeRes.status, 206);
  assert.equal(rangeRes.headers.get('Content-Range'), `bytes 0-7/${VALID_MP4.byteLength}`);
  assert.equal(rangeRes.headers.get('Content-Length'), '8');
  const chunk = new Uint8Array(await rangeRes.arrayBuffer());
  assert.deepEqual(chunk, VALID_MP4.slice(0, 8));
});

test('Rate limiter bloquea con 429 al exceder 6 imágenes en 60 segundos', async () => {
  resetRateLimitsForTest();
  const bucket = createMemoryR2();
  const worker = createWorker({
    fetchImpl: makeFakeFetch(),
    nowProvider: () => 1700000000000,
  });
  const env = makeEnv(bucket);

  for (let i = 0; i < 6; i++) {
    const res = await worker.fetch(
      new Request('https://worker.test/upload', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: 'Bearer valid-token' },
        body: JSON.stringify({
          folder: 'listings',
          filename: `img_${i}.jpg`,
          contentType: 'image/jpeg',
          size: 100,
        }),
      }),
      env
    );
    assert.equal(res.status, 200);
  }

  const blocked = await worker.fetch(
    new Request('https://worker.test/upload', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer valid-token' },
      body: JSON.stringify({
        folder: 'listings',
        filename: 'img_7.jpg',
        contentType: 'image/jpeg',
        size: 100,
      }),
    }),
    env
  );
  assert.equal(blocked.status, 429);
  assert.ok(blocked.headers.get('Retry-After'));
});

test('cleanupOrphanObjects elimina objetos viejos sin referencia y conserva los referenciados o recientes', async () => {
  const bucket = createMemoryR2();
  const now = 1700000000000;
  const oldDate = new Date(now - 3 * 60 * 60 * 1000);
  const recentDate = new Date(now - 10 * 60 * 1000);

  await bucket.put('forum/user-1_keep.jpg', VALID_JPEG, { uploaded: oldDate });
  await bucket.put('forum/user-1_orphan.jpg', VALID_JPEG, { uploaded: oldDate });
  await bucket.put('forum_videos/user-1_market.mp4', VALID_MP4, { uploaded: oldDate });
  await bucket.put('groups/user-1_recent.jpg', VALID_JPEG, { uploaded: recentDate });

  const env = {
    ...makeEnv(bucket),
    SUPABASE_SERVICE_ROLE_KEY: 'service-role-key',
  };

  const mockSupabaseFetch = async (url) => {
    const u = String(url);
    if (u.includes('/rest/v1/posts')) {
      return new Response(
        JSON.stringify([
          { image_url: 'https://worker.test/images/forum/user-1_keep.jpg', video_url: null },
        ]),
        { status: 200, headers: { 'Content-Type': 'application/json' } }
      );
    }
    if (u.includes('/rest/v1/marketplace_items')) {
      return new Response(
        JSON.stringify([
          {
            image_urls: [],
            video_url: 'https://worker.test/images/forum_videos/user-1_market.mp4',
          },
        ]),
        { status: 200, headers: { 'Content-Type': 'application/json' } }
      );
    }
    return new Response(JSON.stringify([]), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  };

  const result = await cleanupOrphanObjects(env, mockSupabaseFetch, now);
  assert.equal(result.deletedCount, 1);
  assert.deepEqual(result.deletedKeys, ['forum/user-1_orphan.jpg']);
  assert.ok(bucket.store.has('forum/user-1_keep.jpg'));
  assert.ok(bucket.store.has('forum_videos/user-1_market.mp4'));
  assert.ok(bucket.store.has('groups/user-1_recent.jpg'));
  assert.ok(!bucket.store.has('forum/user-1_orphan.jpg'));
});
