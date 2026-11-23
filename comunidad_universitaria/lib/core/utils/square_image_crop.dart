import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import '../services/storage_service.dart';

/// Región cuadrada en píxeles de la imagen original seleccionada por el usuario.
class SquareCropRect {
  final int x;
  final int y;
  final int size;

  const SquareCropRect({
    required this.x,
    required this.y,
    required this.size,
  });
}

class _CropRequest {
  final Uint8List rawBytes;
  final SquareCropRect rect;
  final int maxDimension;
  final int quality;

  const _CropRequest({
    required this.rawBytes,
    required this.rect,
    required this.maxDimension,
    required this.quality,
  });
}

Uint8List _runCropInIsolate(_CropRequest req) {
  return SquareImageCrop.cropSquareJpeg(
    req.rawBytes,
    req.rect,
    maxDimension: req.maxDimension,
    quality: req.quality,
  );
}

/// Utilidades puras para validar proporciones 1:1 y recortar imágenes en cuadrado.
class SquareImageCrop {
  SquareImageCrop._();

  /// Lee las dimensiones en píxeles de una imagen codificada, o `null` si no es decodificable.
  static ({int width, int height})? readImageDimensions(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;
    return (width: decoded.width, height: decoded.height);
  }

  /// Convierte el estado del visor (`scale`, `translateX`, `translateY`) en un
  /// rectángulo cuadrado exacto sobre las coordenadas de la imagen original.
  static SquareCropRect computeCropRect({
    required int imageWidth,
    required int imageHeight,
    required double viewportSize,
    required double scale,
    required double translateX,
    required double translateY,
  }) {
    final safeW = math.max(1, imageWidth);
    final safeH = math.max(1, imageHeight);
    final safeViewport = viewportSize <= 0 ? 1.0 : viewportSize;
    final baseScale = math.max(safeViewport / safeW, safeViewport / safeH);
    final safeScale = scale <= 0 ? 1.0 : scale;

    final minSide = math.min(safeW, safeH);
    final rawSide = (safeViewport / safeScale) / baseScale;
    final side = rawSide.round().clamp(1, minSide);

    final cx0 = -translateX / safeScale;
    final cy0 = -translateY / safeScale;
    final maxX = math.max(0, safeW - side);
    final maxY = math.max(0, safeH - side);

    final x = (cx0 / baseScale).round().clamp(0, maxX);
    final y = (cy0 / baseScale).round().clamp(0, maxY);

    return SquareCropRect(x: x, y: y, size: side);
  }

  /// Recorta la imagen al rectángulo cuadrado [rect], redimensiona hasta
  /// [maxDimension] y codifica en JPEG respetando el límite de 2 MB.
  static Uint8List cropSquareJpeg(
    Uint8List rawBytes,
    SquareCropRect rect, {
    int maxDimension = StorageService.maxImageDimension,
    int quality = StorageService.jpegQuality,
  }) {
    final decoded = img.decodeImage(rawBytes);
    if (decoded == null) {
      throw const StorageUploadException(
        'No se pudo procesar la imagen seleccionada. Intenta con otra foto.',
      );
    }

    final int minSide = math.min(decoded.width, decoded.height);
    final int clampedSize = rect.size.clamp(1, minSide).toInt();
    final int maxX = math.max(0, decoded.width - clampedSize);
    final int maxY = math.max(0, decoded.height - clampedSize);
    final int clampedX = rect.x.clamp(0, maxX).toInt();
    final int clampedY = rect.y.clamp(0, maxY).toInt();

    img.Image working = img.copyCrop(
      decoded,
      x: clampedX,
      y: clampedY,
      width: clampedSize,
      height: clampedSize,
    );

    if (working.width > maxDimension) {
      working = img.copyResize(
        working,
        width: maxDimension,
        height: maxDimension,
      );
    }

    Uint8List encoded = Uint8List.fromList(
      img.encodeJpg(working, quality: quality),
    );

    if (encoded.length > StorageService.maxCompressedImageBytes) {
      img.Image smaller = working;
      if (smaller.width > 1024) {
        smaller = img.copyResize(smaller, width: 1024, height: 1024);
      }
      encoded = Uint8List.fromList(img.encodeJpg(smaller, quality: 60));
    }

    if (encoded.length > StorageService.maxCompressedImageBytes) {
      throw const StorageUploadException(
        'La imagen sigue siendo demasiado pesada después de recortarla.',
      );
    }

    return encoded;
  }

  /// Ejecuta el recorte fuera del hilo de UI cuando la plataforma y el tamaño lo ameritan.
  static Future<Uint8List> cropSquareJpegAsync(
    Uint8List rawBytes,
    SquareCropRect rect, {
    int maxDimension = StorageService.maxImageDimension,
    int quality = StorageService.jpegQuality,
  }) async {
    final req = _CropRequest(
      rawBytes: rawBytes,
      rect: rect,
      maxDimension: maxDimension,
      quality: quality,
    );
    if (kIsWeb || rawBytes.length < 256 * 1024) {
      return _runCropInIsolate(req);
    }
    return compute(_runCropInIsolate, req);
  }
}
