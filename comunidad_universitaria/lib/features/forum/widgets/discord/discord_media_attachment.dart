import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import '../../../../core/constants/zanate_colors.dart';
import '../../../shared/widgets/image_viewer_dialog.dart';

/// Un componente de medios con estilo Discord para adjuntos de imagen y GIF.
/// Ocupa el 100% del ancho disponible (salvo que se indique `maxWidth`),
/// escalando la imagen para aprovechar todo el espacio horizontal sin recortar.
class DiscordMediaAttachment extends StatelessWidget {
  final String imageUrl;
  final String? title;
  final bool isGif;
  final double? maxWidth;
  final double maxHeight;
  final double minHeight;
  final BorderRadius? borderRadius;
  final bool showBorder;
  final bool showZoomBadge;
  final VoidCallback? onTap;

  const DiscordMediaAttachment({
    super.key,
    required this.imageUrl,
    this.title,
    this.isGif = false,
    this.maxWidth,
    this.maxHeight = 560,
    this.minHeight = 120,
    this.borderRadius,
    this.showBorder = true,
    this.showZoomBadge = true,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (imageUrl.trim().isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final radius = borderRadius ?? BorderRadius.circular(14);

    final containerBg = ZanateColors.surface(isDark);
    final borderColor = ZanateColors.border(isDark);

    final mediaCard = ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: maxWidth ?? double.infinity,
        maxHeight: maxHeight,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: containerBg,
            borderRadius: radius,
            border: showBorder ? Border.all(color: borderColor, width: 1) : null,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap:
                  onTap ??
                  () => ImageViewerDialog.show(
                    context,
                    imageUrl: imageUrl,
                    title: title,
                  ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: Image.network(
                      imageUrl,
                      width: double.infinity,
                      fit: BoxFit.fitWidth,
                    loadingBuilder: (context, child, loadingProgress) {
                      if (loadingProgress == null) return child;
                      return Container(
                        width: double.infinity,
                        height: minHeight,
                        color: containerBg,
                        alignment: Alignment.center,
                        child: SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            value: loadingProgress.expectedTotalBytes != null
                                ? loadingProgress.cumulativeBytesLoaded /
                                      loadingProgress.expectedTotalBytes!
                                : null,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      );
                    },
                    errorBuilder: (context, error, stackTrace) {
                      return Container(
                        width: double.infinity,
                        height: minHeight,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        color: containerBg,
                        alignment: Alignment.center,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              PhosphorIconsRegular.imageBroken,
                              size: 20,
                              color: Colors.blueGrey.shade400,
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                'No se pudo cargar la imagen',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: ZanateColors.textMuted(isDark),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                  ),

                  // Badge GIF or Zoom Pill
                  if (isGif || showZoomBadge)
                    Positioned(
                      bottom: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.72),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (isGif) ...[
                              const Text(
                                'GIF',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ] else ...[
                              const Icon(
                                PhosphorIconsRegular.magnifyingGlassPlus,
                                color: Colors.white,
                                size: 13,
                              ),
                              const SizedBox(width: 4),
                              const Text(
                                'Ampliar',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    if (maxWidth != null) {
      return Align(alignment: Alignment.centerLeft, child: mediaCard);
    }
    return SizedBox(width: double.infinity, child: mediaCard);
  }
}
