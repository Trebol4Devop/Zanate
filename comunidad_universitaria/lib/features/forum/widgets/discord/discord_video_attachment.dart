import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:video_player/video_player.dart';
import '../../../../core/constants/zanate_colors.dart';

/// Reproductor para videos adjuntos en publicaciones del foro.
/// Ocupa el ancho disponible (salvo que se indique `maxWidth`) manteniendo relación de aspecto.
class DiscordVideoAttachment extends StatefulWidget {
  final String videoUrl;
  final double? maxWidth;
  final double maxHeight;
  final BorderRadius? borderRadius;
  final bool showBorder;

  const DiscordVideoAttachment({
    super.key,
    required this.videoUrl,
    this.maxWidth,
    this.maxHeight = 420,
    this.borderRadius,
    this.showBorder = true,
  });

  @override
  State<DiscordVideoAttachment> createState() => _DiscordVideoAttachmentState();
}

class _DiscordVideoAttachmentState extends State<DiscordVideoAttachment> {
  VideoPlayerController? _controller;
  bool _isInitialized = false;
  bool _hasError = false;
  bool _isMuted = false;

  @override
  void initState() {
    super.initState();
    _initController();
  }

  @override
  void didUpdateWidget(covariant DiscordVideoAttachment oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoUrl != widget.videoUrl) {
      _disposeController();
      _initController();
    }
  }

  Future<void> _initController() async {
    final url = widget.videoUrl.trim();
    if (url.isEmpty) {
      setState(() => _hasError = true);
      return;
    }

    setState(() {
      _isInitialized = false;
      _hasError = false;
    });

    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      setState(() => _hasError = true);
      return;
    }

    final controller = VideoPlayerController.networkUrl(uri);
    _controller = controller;

    try {
      await controller.initialize();
      await controller.setLooping(true);
      if (!mounted || _controller != controller) return;
      setState(() => _isInitialized = true);
    } catch (_) {
      if (!mounted || _controller != controller) return;
      setState(() => _hasError = true);
    }
  }

  void _disposeController() {
    _controller?.dispose();
    _controller = null;
  }

  @override
  void dispose() {
    _disposeController();
    super.dispose();
  }

  void _togglePlayPause() {
    final c = _controller;
    if (c == null || !_isInitialized) return;
    setState(() {
      if (c.value.isPlaying) {
        c.pause();
      } else {
        c.play();
      }
    });
  }

  Future<void> _toggleMute() async {
    final c = _controller;
    if (c == null || !_isInitialized) return;
    final nextMuted = !_isMuted;
    await c.setVolume(nextMuted ? 0.0 : 1.0);
    if (mounted) {
      setState(() => _isMuted = nextMuted);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.videoUrl.trim().isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final viewportMaxHeight = (MediaQuery.sizeOf(context).height * 0.56).clamp(
      200.0,
      widget.maxHeight,
    );
    final radius = widget.borderRadius ?? BorderRadius.circular(14);
    final containerBg = ZanateColors.surface(isDark);
    final borderColor = ZanateColors.border(isDark);

    final videoCard = ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: widget.maxWidth ?? double.infinity,
        maxHeight: viewportMaxHeight,
        minHeight: 160,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: radius,
            border: widget.showBorder
                ? Border.all(color: borderColor, width: 1)
                : null,
          ),
          child: _hasError
              ? Container(
                  width: double.infinity,
                  height: 160,
                  color: containerBg,
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        PhosphorIconsRegular.videoCameraSlash,
                        size: 20,
                        color: Colors.blueGrey.shade400,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          'No se pudo reproducir el video',
                          style: TextStyle(
                            fontSize: 12,
                            color: ZanateColors.textMuted(isDark),
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              : !_isInitialized || _controller == null
              ? Container(
                  width: double.infinity,
                  height: 180,
                  color: containerBg,
                  alignment: Alignment.center,
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final ar = _controller!.value.aspectRatio > 0
                        ? _controller!.value.aspectRatio
                        : 16 / 9;
                    final availableWidth = constraints.maxWidth.isFinite
                        ? constraints.maxWidth
                        : MediaQuery.sizeOf(context).width;
                    final targetHeight = (availableWidth / ar).clamp(
                      160.0,
                      viewportMaxHeight,
                    );
                    final videoSize = _controller!.value.size;
                    final childWidth = videoSize.width > 0
                        ? videoSize.width
                        : availableWidth;
                    final childHeight = videoSize.height > 0
                        ? videoSize.height
                        : availableWidth / ar;

                    return GestureDetector(
                      onTap: _togglePlayPause,
                      child: SizedBox(
                        width: availableWidth,
                        height: targetHeight,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Positioned.fill(
                              child: ClipRect(
                                child: FittedBox(
                                  fit: BoxFit.contain,
                                  child: SizedBox(
                                    width: childWidth,
                                    height: childHeight,
                                    child: VideoPlayer(_controller!),
                                  ),
                                ),
                              ),
                            ),
                      if (!_controller!.value.isPlaying)
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.6),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            PhosphorIconsFill.play,
                            color: Colors.white,
                            size: 26,
                          ),
                        ),
                      Positioned(
                        top: 8,
                        right: 8,
                        child: InkWell(
                          onTap: _toggleMute,
                          borderRadius: BorderRadius.circular(20),
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.65),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              _isMuted
                                  ? PhosphorIconsRegular.speakerSlash
                                  : PhosphorIconsRegular.speakerHigh,
                              color: Colors.white,
                              size: 16,
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: VideoProgressIndicator(
                          _controller!,
                          allowScrubbing: true,
                          padding: const EdgeInsets.symmetric(
                            vertical: 4,
                            horizontal: 8,
                          ),
                          colors: VideoProgressColors(
                            playedColor: ZanateColors.zanateEyeYellow,
                            bufferedColor: Colors.white38,
                            backgroundColor: Colors.white12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
                  },
                ),
        ),
      ),
    );

    if (widget.maxWidth != null) {
      return Align(alignment: Alignment.centerLeft, child: videoCard);
    }
    return SizedBox(width: double.infinity, child: videoCard);
  }
}
