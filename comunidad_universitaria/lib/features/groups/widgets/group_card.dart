import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:share_plus/share_plus.dart';
import '../../../core/constants/zanate_colors.dart';
import '../../../core/models/whatsapp_group.dart';
import '../../../core/utils/time_utils.dart';
import '../../../core/utils/url_utils.dart';
import '../../shared/widgets/image_viewer_dialog.dart';
import '../../shared/widgets/report_dialog.dart';
import '../../shared/widgets/user_avatar_circle.dart';

class GroupCard extends StatelessWidget {
  final WhatsAppGroup group;
  final VoidCallback onUpvote;
  final Function(String reason)? onReport;
  final VoidCallback? onDelete;
  final VoidCallback? onShare;

  const GroupCard({
    super.key,
    required this.group,
    required this.onUpvote,
    this.onReport,
    this.onDelete,
    this.onShare,
  });

  String _getPlatformLabel(GroupPlatform platform) {
    switch (platform) {
      case GroupPlatform.whatsApp:
        return 'WhatsApp';
      case GroupPlatform.telegram:
        return 'Telegram';
      case GroupPlatform.discord:
        return 'Discord';
    }
  }

  String? _validatedExternalUrl(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;

    final hasScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:').hasMatch(trimmed);
    final uri = Uri.tryParse(hasScheme ? trimmed : 'https://$trimmed');
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    return uri.toString();
  }

  Future<void> _openGroupLink(BuildContext context) async {
    final safeUrl = _validatedExternalUrl(group.link);
    if (safeUrl == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('El enlace del grupo no es válido.')),
      );
      return;
    }
    await UrlUtils.openUrl(context, safeUrl);
  }

  Future<void> _shareGroup(BuildContext context) async {
    final shareText = group.link.trim();
    if (shareText.isEmpty) return;
    try {
      final result = await SharePlus.instance.share(
        ShareParams(text: shareText, subject: group.title),
      );
      if (result.status == ShareResultStatus.unavailable) {
        await Clipboard.setData(ClipboardData(text: shareText));
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Enlace del grupo copiado al portapapeles'),
            backgroundColor: ZanateColors.zanateBlack,
          ),
        );
      }
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: shareText));
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enlace del grupo copiado al portapapeles'),
          backgroundColor: ZanateColors.zanateBlack,
        ),
      );
    }
  }

  Widget _buildReportMenu(
    BuildContext context,
    bool isDark, {
    bool onImage = false,
  }) {
    if (onReport == null && !(group.isMine && onDelete != null)) {
      return const SizedBox.shrink();
    }
    return PopupMenuButton<String>(
      tooltip: 'Más opciones',
      color: ZanateColors.card(isDark),
      surfaceTintColor: Colors.transparent,
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: ZanateColors.border(isDark),
        ),
      ),
      icon: PhosphorIcon(
        PhosphorIconsBold.dotsThreeVertical,
        size: 18,
        color: onImage
            ? Colors.white
            : (isDark ? Colors.white : ZanateColors.zanateBlack),
      ),
      onSelected: (val) {
        if (val == 'report' && onReport != null) {
          ReportDialog.show(
            context,
            title: 'Reportar Grupo',
            subtitle: group.title,
            reasonOptions: const [
              'El enlace de invitación está expirado o revocado',
              'El grupo es de otra sección o curso',
              'Grupo lleno / límite de participantes',
              'Spam, publicidad o cobros de dinero',
              'Otro motivo',
            ],
            onSubmitted: onReport!,
          );
        } else if (val == 'delete' && onDelete != null) {
          onDelete!();
        }
      },
      itemBuilder: (ctx) => [
        if (onReport != null)
          PopupMenuItem(
            value: 'report',
            height: 44,
            child: Row(
              children: [
                PhosphorIcon(
                  PhosphorIconsRegular.flag,
                  size: 17,
                  color: isDark ? Colors.white : ZanateColors.zanateBlack,
                ),
                const SizedBox(width: 10),
                const Text('Reportar'),
              ],
            ),
          ),
        if (group.isMine && onDelete != null)
          const PopupMenuItem(
            value: 'delete',
            height: 44,
            child: Row(
              children: [
                Icon(
                  PhosphorIconsRegular.trash,
                  size: 17,
                  color: Colors.red,
                ),
                SizedBox(width: 10),
                Text(
                  'Eliminar grupo',
                  style: TextStyle(
                    color: Colors.red,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final platform = group.platform;
    final hasImage = group.imageUrl != null && group.imageUrl!.isNotEmpty;
    final primaryTitle = group.curso.isNotEmpty ? group.curso : group.title;
    const joinGray = Color(0xFF94A3B8);
    final platformLabel = _getPlatformLabel(platform);
    final showSubtitle =
        group.title.trim().isNotEmpty &&
        group.title.trim() != group.curso.trim() &&
        group.title.trim().toLowerCase() !=
            '${group.curso.trim().toLowerCase()} - ${group.section.trim().toLowerCase()}';

    return Container(
      decoration: BoxDecoration(
        color: ZanateColors.bg(isDark),
        border: Border(
          bottom: BorderSide(
            color: ZanateColors.border(isDark),
            width: 0.8,
          ),
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: Padding(
          padding: EdgeInsets.only(top: hasImage ? 0 : 14, bottom: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (hasImage) ...[
                // Imagen edge-to-edge sin bordes redondeados con autor, 3 puntos y título superpuestos
                SizedBox(
                  width: double.infinity,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final availableW = constraints.maxWidth.isFinite
                          ? constraints.maxWidth
                          : 360.0;
                      final viewportCap =
                          (MediaQuery.sizeOf(context).height * 0.52).clamp(
                            180.0,
                            440.0,
                          );
                      final displayHeight = availableW.clamp(
                        180.0,
                        viewportCap,
                      );
                      return SizedBox(
                        width: double.infinity,
                        height: displayHeight,
                        child: InkWell(
                          onTap: () => ImageViewerDialog.show(
                            context,
                            imageUrl: group.imageUrl!,
                            title: group.title,
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.zero,
                            child: Container(
                              width: double.infinity,
                              height: displayHeight,
                              color: ZanateColors.surface(isDark),
                              child: Stack(
                                children: [
                                  Positioned.fill(
                                    child: Image.network(
                                      group.imageUrl!,
                                      width: double.infinity,
                                      height: displayHeight,
                                      fit: BoxFit.cover,
                                      errorBuilder: (ctx, err, stack) =>
                                          const SizedBox.shrink(),
                                    ),
                                  ),
                                  Positioned(
                                    top: 0,
                                    left: 0,
                                    right: 0,
                                    height: 76,
                                    child: IgnorePointer(
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(
                                            begin: Alignment.topCenter,
                                            end: Alignment.bottomCenter,
                                            colors: [
                                              Colors.black.withValues(alpha: 0.65),
                                              Colors.transparent,
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    bottom: 0,
                                    left: 0,
                                    right: 0,
                                    height: 96,
                                    child: IgnorePointer(
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(
                                            begin: Alignment.bottomCenter,
                                            end: Alignment.topCenter,
                                            colors: [
                                              Colors.black.withValues(alpha: 0.72),
                                              Colors.transparent,
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    top: 12,
                                    left: 14,
                                    right: 52,
                                    child: Row(
                                      children: [
                                        UserAvatarCircle(
                                          authorAlias: group.authorAlias,
                                          avatarColorIndex:
                                              group.avatarColorIndex,
                                          avatarIconIndex:
                                              group.avatarIconIndex,
                                          isMine: group.isMine,
                                          size: 32,
                                          iconSize: 15,
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            group.authorAlias,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                              fontSize: 13,
                                              color: Colors.white,
                                              shadows: [
                                                Shadow(
                                                  color: Colors.black54,
                                                  blurRadius: 4,
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Positioned(
                                    top: 4,
                                    right: 4,
                                    child: _buildReportMenu(
                                      context,
                                      isDark,
                                      onImage: true,
                                    ),
                                  ),
                                  Positioned(
                                    bottom: 12,
                                    left: 14,
                                    right: 52,
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text.rich(
                                          TextSpan(
                                            text: primaryTitle,
                                            children: [
                                              const TextSpan(
                                                text: ' • ',
                                                style: TextStyle(
                                                  color: Colors.white,
                                                ),
                                              ),
                                              TextSpan(
                                                text: platformLabel,
                                                style: const TextStyle(
                                                  fontSize: 12.5,
                                                  fontWeight: FontWeight.w400,
                                                  color: joinGray,
                                                  shadows: [],
                                                ),
                                              ),
                                            ],
                                          ),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: GoogleFonts.outfit(
                                            fontWeight: FontWeight.w700,
                                            fontSize: 17,
                                            height: 1.2,
                                            color: Colors.white,
                                            shadows: const [
                                              Shadow(
                                                color: Colors.black54,
                                                blurRadius: 4,
                                              ),
                                            ],
                                          ),
                                        ),
                                        if (showSubtitle) ...[
                                          const SizedBox(height: 2),
                                          Text(
                                            group.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 12.5,
                                              fontWeight: FontWeight.w500,
                                              color: Colors.white70,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ] else ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          UserAvatarCircle(
                            authorAlias: group.authorAlias,
                            avatarColorIndex: group.avatarColorIndex,
                            avatarIconIndex: group.avatarIconIndex,
                            isMine: group.isMine,
                            size: 34,
                            iconSize: 16,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              group.authorAlias,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                                color: isDark
                                    ? Colors.white
                                    : ZanateColors.zanateDark,
                              ),
                            ),
                          ),
                          _buildReportMenu(context, isDark),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text.rich(
                        TextSpan(
                          text: primaryTitle,
                          children: [
                            TextSpan(
                              text: ' • ',
                              style: TextStyle(
                                color: isDark
                                    ? Colors.white
                                    : ZanateColors.zanateBlack,
                              ),
                            ),
                            TextSpan(
                              text: platformLabel,
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w400,
                                color: joinGray,
                              ),
                            ),
                          ],
                        ),
                        style: GoogleFonts.outfit(
                          fontWeight: FontWeight.w700,
                          fontSize: 16.5,
                          height: 1.25,
                          color: isDark
                              ? Colors.white
                              : ZanateColors.zanateBlack,
                        ),
                      ),
                      if (showSubtitle) ...[
                        const SizedBox(height: 2),
                        Text(
                          group.title,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w500,
                            color: theme.colorScheme.onSurfaceVariant,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],

              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (group.description.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                        group.description,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),

                    // Actions Row: Upvote, Copy link, Generic Join Button
                    Row(
                      children: [
                        // Simple upvote button (>=48px accessible hit target)
                        InkWell(
                          onTap: onUpvote,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                              minHeight: 48,
                              minWidth: 48,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  PhosphorIcon(
                                    group.isUpvotedByMe
                                        ? PhosphorIconsFill.arrowFatUp
                                        : PhosphorIconsRegular.arrowFatUp,
                                    size: 17,
                                    color: group.isUpvotedByMe
                                        ? (isDark
                                              ? ZanateColors.zanateEyeYellow
                                              : ZanateColors.zanateBlack)
                                        : (isDark
                                              ? const Color(0xFF94A3B8)
                                              : ZanateColors.mutedText),
                                  ),
                                  const SizedBox(width: 5),
                                  Text(
                                    '${group.upvotes}',
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w700,
                                      color: group.isUpvotedByMe
                                          ? (isDark
                                                ? ZanateColors.zanateEyeYellow
                                                : ZanateColors.zanateBlack)
                                          : (isDark
                                                ? const Color(0xFFE2E8F0)
                                                : ZanateColors.zanateBlack),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Share button matching forum PostCard
                        Tooltip(
                          message: 'Compartir',
                          child: InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: onShare ?? () => _shareGroup(context),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 4,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  PhosphorIcon(
                                    PhosphorIconsRegular.shareNetwork,
                                    size: 17,
                                    color: ZanateColors.textMuted(isDark),
                                  ),
                                  if (group.sharesCount > 0) ...[
                                    const SizedBox(width: 4),
                                    Text(
                                      '${group.sharesCount}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: ZanateColors.textMuted(isDark),
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                        const Spacer(),
                        // Join action button: soft yellow pill in light mode (matching bottom nav), solid Zanate yellow in dark mode
                        ElevatedButton.icon(
                          onPressed: () => _openGroupLink(context),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: isDark
                                ? ZanateColors.zanateEyeYellow
                                : ZanateColors.zanateEyeYellow.withValues(
                                    alpha: 0.28,
                                  ),
                            foregroundColor: ZanateColors.zanateBlack,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 9,
                            ),
                          ),
                          icon: const PhosphorIcon(
                            PhosphorIconsRegular.usersThree,
                            size: 16,
                          ),
                          label: const Text(
                            'Unirse',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 6),
                    Text(
                      TimeUtils.timeAgo(group.createdAt),
                      style: TextStyle(
                        fontSize: 11,
                        color: ZanateColors.textMuted(isDark),
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
