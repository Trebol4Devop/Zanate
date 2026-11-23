# Fase 1: Medios, Vistas Previas, Compresión y Video en Flutter

Documentación técnica detallada de los cambios realizados en `comunidad_universitaria/` para corregir la visualización y subida de imágenes, implementar compresión real y habilitar videos exclusivamente en publicaciones del foro.

---

## 1. Dependencias añadidas

Archivo: [pubspec.yaml](../../comunidad_universitaria/pubspec.yaml)

| Paquete | Versión | Propósito |
| :--- | :--- | :--- |
| `image` | `^4.5.4` | Decodificación, redimensionamiento proporcional y codificación JPEG en Dart puro (funciona en Web, Android, iOS y escritorio sin plugins nativos). |
| `video_player` | `^2.9.2` | Reproducción en red de videos adjuntos en publicaciones del foro mediante `VideoPlayerController.networkUrl`. |

---

## 2. Servicio central de almacenamiento (`StorageService`)

Archivo: [storage_service.dart](../../comunidad_universitaria/lib/core/services/storage_service.dart)

### 2.1 Constantes y límites vigentes

| Constante | Valor | Uso |
| :--- | :--- | :--- |
| `maxRawImageBytes` | `10 * 1024 * 1024` (10 MB) | Tamaño máximo de archivo de imagen aceptado desde el selector antes de comprimir. |
| `maxCompressedImageBytes` | `2 * 1024 * 1024` (2 MB) | Tamaño máximo final permitido tras la compresión (alineado con el límite del Worker R2). |
| `maxImageDimension` | `1280` px | Lado mayor máximo en la primera pasada de redimensionado. |
| `jpegQuality` | `78` | Calidad JPEG en la primera pasada. |
| `maxVideoBytes` | `15 * 1024 * 1024` (15 MB) | Tamaño máximo permitido para videos del foro. |
| `maxVideoDuration` | `Duration(seconds: 45)` | Duración sugerida al selector nativo `pickVideo`. |
| `allowedVideoExtensions` | `{'mp4', 'webm', 'mov', 'm4v'}` | Extensiones aceptadas para video en el foro. |

### 2.2 Tipos públicos exportados

- `StorageUploadException(String message)`: excepción controlada con mensajes amigables en español (sin jerga técnica).
- `PickedImageData({required XFile file, required Uint8List bytes, required String name})`: contenedor con los bytes en memoria para mostrar `Image.memory` de forma inmediata antes de subir.
- `PickedVideoData({required XFile file, required String name, required int sizeBytes})`: metadatos del video seleccionado para tarjeta previa.

### 2.3 Algoritmo de compresión de imágenes (`compressImageBytes`)

Ejecutado por `_compressImageIsolate(Uint8List rawBytes)` (en `compute()` para archivos `>= 256 KB` fuera de Web, o directo en Web/archivos pequeños):

1. Si `rawBytes.length > maxRawImageBytes` (10 MB) -> lanza `StorageUploadException`.
2. Intenta decodificar con `img.decodeImage(rawBytes)`.
   - **Si `decoded == null`** (caso de blobs de prueba sintéticos como cabeceras mínimas):
     - Si `rawBytes.length <= maxCompressedImageBytes`, conserva los bytes y el `contentType` original (`image/png`, `image/webp` o `image/jpeg`), preservando compatibilidad con `test/services/storage_service_test.dart`.
     - Si supera `2 MB`, lanza `StorageUploadException`.
   - **Si decodifica correctamente:**
     - Redimensiona proporcionalmente si `width > 1280` o `height > 1280` usando `img.copyResize`.
     - Codifica a JPEG con `quality: 78` (`reencodedAsJpeg = true`, extensión final `.jpg`, `contentType = 'image/jpeg'`).
     - **Segunda pasada automática:** si el resultado supera `2 MB`, reescala a lado máximo `1024 px` y re-codifica con `quality: 60`.
     - Si aun así supera `2 MB`, lanza `StorageUploadException`.

### 2.4 Protocolo de subida (`_uploadBytes`)

1. Obtiene el token de sesión actual: `SupabaseService.client.auth.currentSession?.accessToken`.
2. Envía `POST ${_workerUrl}/upload` con cabecera `Authorization: Bearer <accessToken>` y cuerpo JSON:
   ```json
   {
     "folder": "<forum|groups|listings|forum_videos>",
     "filename": "<userId>_<timestamp>_<safeName>",
     "contentType": "<mime>",
     "size": 123456
   }
   ```
3. Lee la respuesta del Worker:
   - Si el Worker responde `401`/`403`/`413`/`429`/`5xx` y `throwOnError == true`, lanza `StorageUploadException` con mensaje específico.
   - Si `throwOnError == false` (contrato por defecto para compatibilidad legada), registra por `debugPrint` y retorna `null`.
4. **Paso 2 (subida binaria):**
   - Si el JSON incluye `directUploadUrl` (entregado por el Worker de Fase 2), ejecuta `PUT` contra `directUploadUrl` con `Content-Type` y `Authorization: Bearer <accessToken>`. Esto evita cualquier llamada directa a `r2.cloudflarestorage.com` desde el navegador.
   - Si solo viene `uploadUrl` (compatibilidad con tests existentes), ejecuta `PUT` contra `uploadUrl`.
5. Retorna `publicUrl` del JSON o fallback `${_workerUrl}/images/$folder/$filename`.

*(Nota: `pickSingleImage()`, `pickMultipleImages()` y `convertSupabaseUrlToR2()` se mantienen intactos por compatibilidad).*

---

## 3. Flujo por módulo en la aplicación

### 3.1 Foro (`posts`) — Fotos y Videos

| Archivo | Responsabilidad y cambios |
| :--- | :--- |
| [create_post_dialog.dart](../../comunidad_universitaria/lib/features/forum/widgets/create_post_dialog.dart) | Reemplaza la subida inmediata al elegir archivo por estado pendiente local (`_pendingImage`, `_pendingVideo`). Los botones `Foto`, `Video` y `GIF` son mutuamente excluyentes. En el foro se acepta cualquier tamaño y proporción de fotografía sin recorte forzado (`Image.memory(..., fit: BoxFit.contain)`), comprimiendo solo al publicar si es necesario. Para video, `image_picker` sugiere un tope móvil de `45 s`, mientras que el límite estricto garantizado en todas las plataformas es de `15 MB` sin recompresión en cliente. |
| [post.dart](../../comunidad_universitaria/lib/core/models/post.dart) | Agrega propiedad `final String? videoUrl`, parámetro en constructor y `copyWith`, lectura `map['video_url']?.toString()` en `fromMap` e inclusión condicional en `toInsertMap` cuando no es vacío. |
| [discord_video_attachment.dart](../../comunidad_universitaria/lib/features/forum/widgets/discord/discord_video_attachment.dart) | Widget `StatefulWidget` (`maxWidth: 480`, `maxHeight: 300`, `minHeight: 160`) que inicializa `VideoPlayerController.networkUrl` en bucle, centra `VideoPlayer` dentro de `AspectRatio`, ofrece toque para play/pausa, botón superior de silencio, `VideoProgressIndicator` interactivo y estado de error limpio `'No se pudo reproducir el video'`. |
| [post_card.dart](../../comunidad_universitaria/lib/features/forum/widgets/post_card.dart) | Renderiza `DiscordVideoAttachment(videoUrl: post.videoUrl!, maxHeight: 280, maxWidth: 480)` debajo del bloque de imagen. |
| [post_detail_screen.dart](../../comunidad_universitaria/lib/features/forum/screens/post_detail_screen.dart) | Renderiza `DiscordVideoAttachment(videoUrl: _post.videoUrl!, maxHeight: 360, maxWidth: 620)` en la vista detallada del hilo. |
| [forum_service.dart](../../comunidad_universitaria/lib/core/services/forum_service.dart) | `createPost` acepta `String? videoUrl`, lo inserta solo si no es nulo/vacío, lo persiste en `_postToCacheMap` y maneja fallback automático si Postgres devuelve código `42703` (columna `video_url` aún no creada antes de la Fase 3). |

### 3.2 Grupos estudiantiles (`student_groups`) — Solo imagen (recorte 1:1)

| Archivo | Responsabilidad y cambios |
| :--- | :--- |
| [create_group_dialog.dart](../../comunidad_universitaria/lib/features/groups/widgets/create_group_dialog.dart) | Almacena `PickedImageData? _pendingImage` al seleccionar y, si la imagen no es cuadrada `1:1`, abre automáticamente [square_image_crop_dialog.dart](../../comunidad_universitaria/lib/features/shared/widgets/square_image_crop_dialog.dart) (respaldado por [square_image_crop.dart](../../comunidad_universitaria/lib/core/utils/square_image_crop.dart)) para encuadrarla manualmente. Muestra vista previa cuadrada `1:1` (`Image.memory(..., fit: BoxFit.contain)`) con botón `'Recortar'` sobre la vista previa, valida cooldown `'group'` antes de subir y ejecuta `uploadImageFile(..., folder: 'groups', throwOnError: true)` al enviar. |

### 3.3 Marketplace (`marketplace_items`) — Solo imágenes

| Archivo | Responsabilidad y cambios |
| :--- | :--- |
| [create_listing_dialog.dart](../../comunidad_universitaria/lib/features/marketplace/widgets/create_listing_dialog.dart) | Mantiene `List<PickedImageData> _pendingImages` respetando `_maxImages`, muestra miniaturas `70x70` con `Image.memory(..., fit: BoxFit.cover)` y botón eliminar. En `_submit()` valida cooldown `'listing'` antes de subir cada foto a `folder: 'listings'` con `throwOnError: true`. **No** permite subir archivos de video (solo conserva el campo de enlace externo para vendedores habilitados). |

---

## 4. Verificación ejecutada

Comando ejecutado desde `comunidad_universitaria/`:

```bash
flutter analyze --no-fatal-infos \
  lib/core/services/storage_service.dart \
  lib/core/utils/input_sanitizer.dart \
  lib/core/services/publish_cooldown_service.dart \
  lib/core/models/post.dart \
  lib/core/services/forum_service.dart \
  lib/core/services/groups_service.dart \
  lib/core/services/marketplace_service.dart \
  lib/features/forum/widgets/discord/discord_video_attachment.dart \
  lib/features/forum/widgets/create_post_dialog.dart \
  lib/features/forum/widgets/post_card.dart \
  lib/features/forum/screens/post_detail_screen.dart \
  lib/features/groups/widgets/create_group_dialog.dart \
  lib/features/marketplace/widgets/create_listing_dialog.dart \
  test/media_and_security_test.dart && \
flutter test \
  test/media_and_security_test.dart \
  test/services/storage_service_test.dart \
  test/services/forum_service_test.dart \
  test/services/groups_service_test.dart \
  test/services/marketplace_service_test.dart \
  test/services/marketplace_ux_service_test.dart \
  test/widgets/create_listing_alias_privacy_test.dart
```

- **`flutter analyze --no-fatal-infos`:** `0` errores, `0` advertencias (solo `info` por deprecación de `material.dart` en Flutter 3.47+).
- **`flutter test`:** **66 de 66 pruebas aprobadas**, incluyendo:
  - Compresión de imagen sintética `2000x1500` a JPEG `<= 1280 px` y `<= 2 MB`.
  - Rechazo de buffers `> 10 MB` con `StorageUploadException`.
  - Preservación total del contrato existente de `storage_service_test.dart`.
  - Serialización/deserialización de `Post.videoUrl`.
