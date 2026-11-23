import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import '../../../core/constants/zanate_colors.dart';
import '../../../core/services/storage_service.dart';
import '../../../core/utils/square_image_crop.dart';

/// Diálogo interactivo para que el usuario encuadre manualmente una imagen
/// en proporción cuadrada 1:1 antes de adjuntarla.
class SquareImageCropDialog extends StatefulWidget {
  final Uint8List imageBytes;
  final int imageWidth;
  final int imageHeight;

  const SquareImageCropDialog({
    super.key,
    required this.imageBytes,
    required this.imageWidth,
    required this.imageHeight,
  });

  static Future<Uint8List?> show(
    BuildContext context, {
    required Uint8List imageBytes,
    required int imageWidth,
    required int imageHeight,
  }) {
    return showDialog<Uint8List>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => SquareImageCropDialog(
        imageBytes: imageBytes,
        imageWidth: imageWidth,
        imageHeight: imageHeight,
      ),
    );
  }

  @override
  State<SquareImageCropDialog> createState() => _SquareImageCropDialogState();
}

class _SquareImageCropDialogState extends State<SquareImageCropDialog> {
  final TransformationController _controller = TransformationController();
  double _zoom = 1.0;
  double? _lastViewportSize;
  bool _isCropping = false;
  String? _errorText;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _initCenteredIfNeeded(double viewportSize) {
    if (_lastViewportSize == viewportSize) return;
    _lastViewportSize = viewportSize;
    final baseScale = math.max(
      viewportSize / widget.imageWidth,
      viewportSize / widget.imageHeight,
    );
    final childW = widget.imageWidth * baseScale;
    final childH = widget.imageHeight * baseScale;
    final tx = -(childW - viewportSize) / 2.0;
    final ty = -(childH - viewportSize) / 2.0;

    final m = Matrix4.identity();
    m.storage[0] = 1.0;
    m.storage[5] = 1.0;
    m.storage[12] = tx;
    m.storage[13] = ty;
    _controller.value = m;
    _zoom = 1.0;
  }

  void _applyZoom(double nextZoom) {
    final viewportSize = _lastViewportSize;
    if (viewportSize == null) return;

    final clampedZoom = nextZoom.clamp(1.0, 4.0);
    final current = _controller.value;
    final currentScale = current.storage[0] <= 0 ? 1.0 : current.storage[0];
    final currentTx = current.storage[12];
    final currentTy = current.storage[13];

    final centerX = (viewportSize / 2.0 - currentTx) / currentScale;
    final centerY = (viewportSize / 2.0 - currentTy) / currentScale;

    final baseScale = math.max(
      viewportSize / widget.imageWidth,
      viewportSize / widget.imageHeight,
    );
    final childW = widget.imageWidth * baseScale;
    final childH = widget.imageHeight * baseScale;

    final rawTx = viewportSize / 2.0 - centerX * clampedZoom;
    final rawTy = viewportSize / 2.0 - centerY * clampedZoom;
    final minTx = math.min(0.0, viewportSize - childW * clampedZoom);
    final minTy = math.min(0.0, viewportSize - childH * clampedZoom);

    final m = Matrix4.identity();
    m.storage[0] = clampedZoom;
    m.storage[5] = clampedZoom;
    m.storage[12] = rawTx.clamp(minTx, 0.0);
    m.storage[13] = rawTy.clamp(minTy, 0.0);
    _controller.value = m;

    setState(() {
      _zoom = clampedZoom;
    });
  }

  Future<void> _confirmCrop() async {
    if (_isCropping) return;
    final viewportSize = _lastViewportSize ?? 300.0;
    final matrix = _controller.value;
    final scale = matrix.storage[0] <= 0 ? 1.0 : matrix.storage[0];
    final tx = matrix.storage[12];
    final ty = matrix.storage[13];

    final rect = SquareImageCrop.computeCropRect(
      imageWidth: widget.imageWidth,
      imageHeight: widget.imageHeight,
      viewportSize: viewportSize,
      scale: scale,
      translateX: tx,
      translateY: ty,
    );

    setState(() {
      _isCropping = true;
      _errorText = null;
    });

    try {
      final cropped = await SquareImageCrop.cropSquareJpegAsync(
        widget.imageBytes,
        rect,
      );
      if (mounted) {
        Navigator.of(context).pop(cropped);
      }
    } on StorageUploadException catch (e) {
      if (mounted) {
        setState(() {
          _isCropping = false;
          _errorText = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isCropping = false;
          _errorText = 'No se pudo aplicar el recorte a la imagen.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final titleColor = ZanateColors.textPrimary(isDark);
    final subtleColor = ZanateColors.textSecondary(isDark);
    final borderColor = ZanateColors.border(isDark);

    return Dialog(
      backgroundColor: ZanateColors.card(isDark),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: borderColor, width: 1.0),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Recortar imagen',
                style: GoogleFonts.outfit(
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
                  color: titleColor,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Mueve o acerca la foto para encuadrarla en formato cuadrado',
                style: TextStyle(
                  fontSize: 12.5,
                  color: subtleColor,
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: LayoutBuilder(
                  builder: (ctx, constraints) {
                    final maxW = constraints.maxWidth.isFinite
                        ? constraints.maxWidth
                        : 320.0;
                    final screenH = MediaQuery.sizeOf(context).height;
                    final maxH = math.max(160.0, screenH - 340.0);
                    final viewportSize = math.max(
                      160.0,
                      math.min(math.min(maxW, 340.0), maxH),
                    );
                    _initCenteredIfNeeded(viewportSize);

                    final baseScale = math.max(
                      viewportSize / widget.imageWidth,
                      viewportSize / widget.imageHeight,
                    );
                    final childW = widget.imageWidth * baseScale;
                    final childH = widget.imageHeight * baseScale;

                    return SizedBox.square(
                      dimension: viewportSize,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.black,
                            border: Border.all(
                              color: ZanateColors.zanateEyeYellow.withValues(
                                alpha: 0.75,
                              ),
                              width: 1.5,
                            ),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Stack(
                            children: [
                              InteractiveViewer(
                                transformationController: _controller,
                                constrained: false,
                                minScale: 1.0,
                                maxScale: 4.0,
                                boundaryMargin: EdgeInsets.zero,
                                onInteractionUpdate: (_) {
                                  final s = _controller.value.storage[0];
                                  if ((s - _zoom).abs() > 0.01 && mounted) {
                                    setState(() {
                                      _zoom = s.clamp(1.0, 4.0);
                                    });
                                  }
                                },
                                child: SizedBox(
                                  width: childW,
                                  height: childH,
                                  child: Image.memory(
                                    widget.imageBytes,
                                    fit: BoxFit.fill,
                                  ),
                                ),
                              ),
                              const Positioned.fill(
                                child: IgnorePointer(
                                  child: CustomPaint(
                                    painter: _CropGridPainter(),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(
                    PhosphorIconsRegular.magnifyingGlassMinus,
                    size: 18,
                    color: subtleColor,
                  ),
                  Expanded(
                    child: Slider(
                      min: 1.0,
                      max: 4.0,
                      value: _zoom,
                      activeColor: isDark
                          ? ZanateColors.zanateEyeYellow
                          : ZanateColors.zanateBlack,
                      onChanged: _isCropping ? null : _applyZoom,
                    ),
                  ),
                  Icon(
                    PhosphorIconsRegular.magnifyingGlassPlus,
                    size: 18,
                    color: subtleColor,
                  ),
                ],
              ),
              if (_errorText != null) ...[
                const SizedBox(height: 6),
                Text(
                  _errorText!,
                  style: const TextStyle(
                    color: Colors.redAccent,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: subtleColor,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: _isCropping
                          ? null
                          : () => Navigator.of(context).pop(null),
                      child: const Text(
                        'Cancelar',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: ZanateColors.ctaBg(isDark),
                        foregroundColor: ZanateColors.ctaFg(isDark),
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 12,
                        ),
                      ),
                      onPressed: _isCropping ? null : _confirmCrop,
                      child: _isCropping
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text(
                              'Aplicar recorte',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CropGridPainter extends CustomPainter {
  const _CropGridPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.32)
      ..strokeWidth = 1.0;

    final thirdW = size.width / 3.0;
    final thirdH = size.height / 3.0;

    canvas.drawLine(Offset(thirdW, 0), Offset(thirdW, size.height), paint);
    canvas.drawLine(
      Offset(thirdW * 2, 0),
      Offset(thirdW * 2, size.height),
      paint,
    );
    canvas.drawLine(Offset(0, thirdH), Offset(size.width, thirdH), paint);
    canvas.drawLine(
      Offset(0, thirdH * 2),
      Offset(size.width, thirdH * 2),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
