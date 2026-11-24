import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import '../config/supabase_config.dart';
import 'supabase_service.dart';

/// Excepción controlada para errores de validación, compresión o subida de archivos.
class StorageUploadException implements Exception {
  final String message;

  const StorageUploadException(this.message);

  @override
  String toString() => message;
}

/// Resultado de seleccionar una imagen junto con sus bytes para vista previa local.
class PickedImageData {
  final XFile file;
  final Uint8List bytes;
  final String name;

  const PickedImageData({
    required this.file,
    required this.bytes,
    required this.name,
  });
}

/// Resultado de seleccionar un video junto con sus metadatos básicos.
class PickedVideoData {
  final XFile file;
  final String name;
  final int sizeBytes;

  const PickedVideoData({
    required this.file,
    required this.name,
    required this.sizeBytes,
  });
}

class _CompressedImageResult {
  final Uint8List bytes;
  final bool reencodedAsJpeg;

  const _CompressedImageResult({
    required this.bytes,
    required this.reencodedAsJpeg,
  });
}

_CompressedImageResult _compressImageIsolate(Uint8List rawBytes) {
  if (rawBytes.length > StorageService.maxRawImageBytes) {
    throw const StorageUploadException(
      'La imagen supera el tamaño máximo permitido de 10 MB.',
    );
  }

  final decoded = img.decodeImage(rawBytes);
  if (decoded == null) {
    if (rawBytes.length <= StorageService.maxCompressedImageBytes) {
      return _CompressedImageResult(bytes: rawBytes, reencodedAsJpeg: false);
    }
    throw const StorageUploadException(
      'No se pudo procesar la imagen seleccionada. Intenta con otra foto.',
    );
  }

  img.Image working = decoded;
  if (working.width > StorageService.maxImageDimension ||
      working.height > StorageService.maxImageDimension) {
    if (working.width >= working.height) {
      working = img.copyResize(working, width: StorageService.maxImageDimension);
    } else {
      working = img.copyResize(working, height: StorageService.maxImageDimension);
    }
  }

  Uint8List encoded = Uint8List.fromList(
    img.encodeJpg(working, quality: StorageService.jpegQuality),
  );

  if (encoded.length > StorageService.maxCompressedImageBytes) {
    img.Image smaller = working;
    if (smaller.width > 1024 || smaller.height > 1024) {
      if (smaller.width >= smaller.height) {
        smaller = img.copyResize(smaller, width: 1024);
      } else {
        smaller = img.copyResize(smaller, height: 1024);
      }
    }
    encoded = Uint8List.fromList(img.encodeJpg(smaller, quality: 60));
  }

  if (encoded.length > StorageService.maxCompressedImageBytes) {
    throw const StorageUploadException(
      'La imagen sigue siendo demasiado pesada después de comprimirla.',
    );
  }

  return _CompressedImageResult(bytes: encoded, reencodedAsJpeg: true);
}

class StorageService {
  static final ImagePicker _picker = ImagePicker();

  static const int maxRawImageBytes = 10 * 1024 * 1024;
  static const int maxCompressedImageBytes = 2 * 1024 * 1024;
  static const int maxImageDimension = 1280;
  static const int jpegQuality = 78;
  static const int maxVideoBytes = 50 * 1024 * 1024;
  static const Duration maxVideoDuration = Duration(seconds: 45);
  static const Set<String> allowedVideoExtensions = {'mp4', 'webm', 'mov', 'm4v'};

  /// Cloudflare Worker URL for R2 storage operations.
  /// Replace with your deployed Worker URL.
  static const String _workerUrl = String.fromEnvironment(
    'R2_WORKER_URL',
    defaultValue:
        'https://comunidad-usac-storage.carlosdelcidramirez.workers.dev',
  );

  /// Comprime y redimensiona una imagen manteniendo su proporción.
  /// Lanza [StorageUploadException] si supera los límites permitidos.
  static Uint8List compressImageBytes(Uint8List rawBytes) {
    return _compressImageIsolate(rawBytes).bytes;
  }

  static Future<XFile?> pickSingleImage() async {
    try {
      return await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 85,
      );
    } catch (e) {
      debugPrint('Error seleccionando imagen: $e');
      return null;
    }
  }

  /// Selecciona una imagen y lee sus bytes para mostrar vista previa local inmediata.
  static Future<PickedImageData?> pickSingleImageWithPreview() async {
    final file = await pickSingleImage();
    if (file == null) return null;

    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      throw const StorageUploadException('La imagen seleccionada está vacía.');
    }
    if (bytes.length > maxRawImageBytes) {
      throw const StorageUploadException(
        'La imagen supera el máximo de 10 MB. Elige una más liviana.',
      );
    }

    return PickedImageData(
      file: file,
      bytes: bytes,
      name: file.name,
    );
  }

  static Future<List<XFile>> pickMultipleImages({int maxImages = 3}) async {
    try {
      final picked = await _picker.pickMultiImage(
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 85,
      );
      if (picked.length > maxImages) {
        return picked.sublist(0, maxImages);
      }
      return picked;
    } catch (e) {
      debugPrint('Error seleccionando múltiples imágenes: $e');
      return [];
    }
  }

  /// Selecciona un video corto para publicaciones del foro y valida formato y tamaño.
  static Future<PickedVideoData?> pickSingleVideo() async {
    final XFile? file;
    try {
      file = await _picker.pickVideo(
        source: ImageSource.gallery,
        maxDuration: maxVideoDuration,
      );
    } catch (e) {
      debugPrint('Error seleccionando video: $e');
      throw const StorageUploadException(
        'No se pudo abrir el selector de video.',
      );
    }

    if (file == null) return null;

    final ext = _extractExtension(file.name);
    if (!allowedVideoExtensions.contains(ext)) {
      throw const StorageUploadException(
        'Formato no compatible. Usa videos MP4, WebM o MOV.',
      );
    }

    final sizeBytes = await file.length();
    if (sizeBytes <= 0) {
      throw const StorageUploadException('El video seleccionado está vacío.');
    }
    if (sizeBytes > maxVideoBytes) {
      throw const StorageUploadException(
        'El video supera el máximo permitido de 50 MB.',
      );
    }

    return PickedVideoData(
      file: file,
      name: file.name,
      sizeBytes: sizeBytes,
    );
  }

  /// Sube una imagen comprimida a Cloudflare R2 vía Worker autenticado.
  ///
  /// Cuando [throwOnError] es `true`, lanza [StorageUploadException] con un
  /// mensaje claro si algo falla en vez de devolver `null`.
  static Future<String?> uploadImageFile(
    XFile file, {
    String folder = 'listings',
    Uint8List? preloadedBytes,
    bool throwOnError = false,
  }) async {
    if (!SupabaseConfig.isConfigured || !SupabaseService.isAuthenticated) {
      if (throwOnError) {
        throw const StorageUploadException(
          'Debes iniciar sesión para subir imágenes.',
        );
      }
      return null;
    }

    try {
      final rawBytes = preloadedBytes ?? await file.readAsBytes();
      final _CompressedImageResult compressed;
      if (kIsWeb || rawBytes.length < 256 * 1024) {
        compressed = _compressImageIsolate(rawBytes);
      } else {
        compressed = await compute(_compressImageIsolate, rawBytes);
      }

      final originalExt = _extractExtension(file.name);
      final userId = SupabaseService.currentUserId ?? 'anon';
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final safeName = file.name.replaceAll(RegExp(r'[^a-zA-Z0-9.]'), '_');

      final String filename;
      final String contentType;
      if (compressed.reencodedAsJpeg) {
        final dotIndex = safeName.lastIndexOf('.');
        final baseName = dotIndex > 0 ? safeName.substring(0, dotIndex) : safeName;
        filename = '${userId}_${timestamp}_$baseName.jpg';
        contentType = 'image/jpeg';
      } else {
        filename = '${userId}_${timestamp}_$safeName';
        contentType = originalExt == 'png'
            ? 'image/png'
            : (originalExt == 'webp' ? 'image/webp' : 'image/jpeg');
      }

      return await _uploadBytes(
        bytes: compressed.bytes,
        folder: folder,
        filename: filename,
        contentType: contentType,
        throwOnError: throwOnError,
      );
    } on StorageUploadException catch (e) {
      if (throwOnError) rethrow;
      debugPrint('Error validando/comprimiendo imagen: ${e.message}');
      return null;
    } catch (e) {
      debugPrint('Error subiendo imagen a R2: $e');
      if (throwOnError) {
        throw const StorageUploadException(
          'No se pudo subir la imagen en este momento. Intenta de nuevo.',
        );
      }
      return null;
    }
  }

  /// Sube un video validado para publicaciones del foro.
  static Future<String> uploadVideoFile(
    XFile file, {
    String folder = 'forum_videos',
  }) async {
    if (!SupabaseConfig.isConfigured || !SupabaseService.isAuthenticated) {
      throw const StorageUploadException(
        'Debes iniciar sesión para subir videos.',
      );
    }

    final ext = _extractExtension(file.name);
    if (!allowedVideoExtensions.contains(ext)) {
      throw const StorageUploadException(
        'Formato no compatible. Usa videos MP4, WebM o MOV.',
      );
    }

    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      throw const StorageUploadException('El video seleccionado está vacío.');
    }
    if (bytes.length > maxVideoBytes) {
      throw const StorageUploadException(
        'El video supera el máximo permitido de 50 MB.',
      );
    }

    final userId = SupabaseService.currentUserId ?? 'anon';
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final safeName = file.name.replaceAll(RegExp(r'[^a-zA-Z0-9.]'), '_');
    final filename = '${userId}_${timestamp}_$safeName';

    final String contentType;
    switch (ext) {
      case 'webm':
        contentType = 'video/webm';
        break;
      case 'mov':
        contentType = 'video/quicktime';
        break;
      default:
        contentType = 'video/mp4';
    }

    final url = await _uploadBytes(
      bytes: bytes,
      folder: folder,
      filename: filename,
      contentType: contentType,
      throwOnError: true,
    );

    if (url == null || url.isEmpty) {
      throw const StorageUploadException('No se pudo completar la subida del video.');
    }
    return url;
  }

  static Future<String?> _uploadBytes({
    required Uint8List bytes,
    required String folder,
    required String filename,
    required String contentType,
    required bool throwOnError,
  }) async {
    final accessToken = SupabaseService.client.auth.currentSession?.accessToken;
    final authHeaders = <String, String>{
      'Content-Type': 'application/json',
      if (accessToken != null && accessToken.isNotEmpty)
        'Authorization': 'Bearer $accessToken',
    };

    // Paso 1: Solicitar permiso y URL de subida al Worker
    final uploadResponse = await http.post(
      Uri.parse('$_workerUrl/upload'),
      headers: authHeaders,
      body: jsonEncode({
        'folder': folder,
        'filename': filename,
        'contentType': contentType,
        'size': bytes.length,
      }),
    );

    if (uploadResponse.statusCode != 200) {
      debugPrint('Error getting upload URL: ${uploadResponse.statusCode}');
      if (throwOnError) {
        if (uploadResponse.statusCode == 401 || uploadResponse.statusCode == 403) {
          throw const StorageUploadException(
            'Tu sesión no tiene autorización para subir archivos.',
          );
        }
        if (uploadResponse.statusCode == 413) {
          throw const StorageUploadException(
            'El archivo supera el tamaño máximo permitido.',
          );
        }
        if (uploadResponse.statusCode == 429) {
          throw const StorageUploadException(
            'Demasiados envíos seguidos. Espera unos segundos e intenta de nuevo.',
          );
        }
        throw const StorageUploadException(
          'No se pudo preparar la subida del archivo.',
        );
      }
      return null;
    }

    final uploadData = jsonDecode(uploadResponse.body) as Map<String, dynamic>;
    final directUploadUrl = uploadData['directUploadUrl'] as String?;
    final presignedUploadUrl = uploadData['uploadUrl'] as String?;
    final returnedPublicUrl = uploadData['publicUrl'] as String?;

    // Paso 2: Subir archivo (preferir directUploadUrl del Worker si existe para evitar bloqueo CORS en Web)
    http.Response? putResponse;
    if (directUploadUrl != null && directUploadUrl.isNotEmpty) {
      putResponse = await http.put(
        Uri.parse(directUploadUrl),
        headers: {
          'Content-Type': contentType,
          if (accessToken != null && accessToken.isNotEmpty)
            'Authorization': 'Bearer $accessToken',
        },
        body: bytes,
      );
    } else if (presignedUploadUrl != null && presignedUploadUrl.isNotEmpty) {
      try {
        putResponse = await http.put(
          Uri.parse(presignedUploadUrl),
          headers: {'Content-Type': contentType},
          body: bytes,
        );
      } catch (e) {
        debugPrint('Error en PUT directo a R2: $e');
        if (throwOnError) {
          throw const StorageUploadException(
            'No se pudo guardar el archivo. Verifica tu conexión o intenta más tarde.',
          );
        }
        return null;
      }
    }

    if (putResponse == null || (putResponse.statusCode != 200 && putResponse.statusCode != 201)) {
      debugPrint('Error uploading to R2: ${putResponse?.statusCode}');
      if (throwOnError) {
        throw const StorageUploadException(
          'No se pudo completar la subida del archivo.',
        );
      }
      return null;
    }

    // Paso 3: Retornar URL pública
    return (returnedPublicUrl != null && returnedPublicUrl.isNotEmpty)
        ? returnedPublicUrl
        : '$_workerUrl/images/$folder/$filename';
  }

  static String _extractExtension(String name) {
    final idx = name.lastIndexOf('.');
    if (idx < 0 || idx + 1 >= name.length) return '';
    return name.substring(idx + 1).toLowerCase().trim();
  }

  /// Converts a Supabase Storage URL to an R2 Worker URL.
  ///
  /// Supabase URL format:
  ///   https://hfvsstkfqszpjrsrwhql.supabase.co/storage/v1/object/public/marketplace/forum/file.jpg
  ///   or: https://hfvsstkfqszpjrsrwhql.supabase.co/storage/v1/object/sign/marketplace/forum/file.jpg?token=...
  ///
  /// R2 URL format:
  ///   https://worker-url/images/forum/file.jpg
  static String? convertSupabaseUrlToR2(String? supabaseUrl) {
    if (supabaseUrl == null || supabaseUrl.isEmpty) return null;

    // If already an R2 URL, return as-is
    if (supabaseUrl.contains('.workers.dev') ||
        supabaseUrl.contains('r2.cloudflarestorage.com')) {
      return supabaseUrl;
    }

    try {
      final uri = Uri.parse(supabaseUrl);

      // Extract path after 'marketplace/' or 'images/' or 'PEMTREE/'
      final pathSegments = uri.pathSegments;
      int bucketIndex = -1;

      for (int i = 0; i < pathSegments.length; i++) {
        final seg = pathSegments[i];
        if (seg == 'marketplace' || seg == 'images' || seg == 'PEMTREE') {
          bucketIndex = i;
          break;
        }
      }

      if (bucketIndex == -1 || bucketIndex + 1 >= pathSegments.length) {
        return null;
      }

      // Get the relative path after the bucket name
      final relativePath = pathSegments.sublist(bucketIndex + 1).join('/');
      return '$_workerUrl/images/$relativePath';
    } catch (e) {
      debugPrint('Error converting Supabase URL to R2: $e');
      return null;
    }
  }
}
