# Worker de medios R2 (`comunidad-usac-storage`)

Código fuente del Worker desplegable en [src/index.js](src/index.js) con configuración en [wrangler.toml](wrangler.toml).

## Seguridad y funcionamiento

1. **Autenticación JWT obligatoria (`POST /upload` y `PUT /upload-direct/*`):**
   Valida el token Bearer contra `${SUPABASE_URL}/auth/v1/user` y rechaza sesiones anónimas o ausentes (`401`).
2. **Subida directa vía Worker (sin bloqueo CORS en R2):**
   `POST /upload` devuelve `directUploadUrl` y `uploadUrl` firmadas con HMAC-SHA256 (`exp` de 120 s) hacia el propio Worker, evitando el `PUT` directo al dominio `r2.cloudflarestorage.com` sin CORS.
3. **Validación estricta de carpetas, tamaños y magic bytes:**
   - Imágenes (`forum`, `groups`, `listings`): `image/jpeg`, `image/png`, `image/webp` hasta **2 MB**.
   - Videos (`forum_videos` únicamente): `video/mp4`, `video/webm`, `video/quicktime` hasta **50 MB**.
   - Verifica firma binaria real (magic bytes) antes de guardar en R2 (`415` si no coincide) y fuerza el prefijo `<userId>_` en la clave.
4. **Rate limit por usuario:**
   Máximo 6 imágenes por minuto y 2 videos cada 5 minutos (`429` con `Retry-After`).
5. **Lectura CDN y streaming (`GET /images/<folder>/<filename>`):**
   Incluye `Cache-Control: public, max-age=31536000, immutable`, `X-Content-Type-Options: nosniff` y soporte `Range` (`206 Partial Content`) para videos.
6. **Limpieza automática de huérfanos (cron cada 6 h):**
   Si está configurado `SUPABASE_SERVICE_ROLE_KEY`, elimina objetos de R2 con más de 2 horas de antigüedad no referenciados en `posts`, `student_groups` o `marketplace_items`.

## Secretos y despliegue

Configura los secretos en Cloudflare (o vía `npx wrangler secret put`):

```bash
cd worker
npx wrangler secret put SUPABASE_ANON_KEY
npx wrangler secret put UPLOAD_SIGNING_SECRET
npx wrangler secret put SUPABASE_SERVICE_ROLE_KEY   # opcional para limpieza cron
npx wrangler deploy
```

Para pruebas locales:

```bash
cd worker
npm test
```

*(Nota: [storage_service.dart](../comunidad_universitaria/lib/core/services/storage_service.dart) conserva `convertSupabaseUrlToR2` sin uso activo por compatibilidad con URLs legadas).*
