import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
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

  const GroupCard({
    super.key,
    required this.group,
    required this.onUpvote,
    this.onReport,
  });

  IconData _getPlatformIcon(GroupPlatform platform) {
    switch (platform) {
      case GroupPlatform.whatsApp:
        return PhosphorIconsFill.whatsappLogo;
      case GroupPlatform.telegram:
        return PhosphorIconsFill.telegramLogo;
      case GroupPlatform.discord:
        return PhosphorIconsFill.discordLogo;
      case GroupPlatform.drive:
        return PhosphorIconsRegular.folder;
      case GroupPlatform.other:
        return PhosphorIconsRegular.link;
    }
  }

  Color _getPlatformColor(GroupPlatform platform) {
    switch (platform) {
      case GroupPlatform.whatsApp:
        return const Color(0xFF25D366);
      case GroupPlatform.telegram:
        return const Color(0xFF0088CC);
      case GroupPlatform.discord:
        return const Color(0xFF5865F2);
      case GroupPlatform.drive:
        return const Color(0xFF0F9D58);
      case GroupPlatform.other:
        return ZanateColors.zanateBlack;
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final platform = group.platform;
    final platformColor = _getPlatformColor(platform);

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
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Cabecera en una sola línea: avatar circular, nombre y fecha
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                UserAvatarCircle(
                  authorAlias: group.authorAlias,
                  isMine: group.isMine,
                  size: 34,
                  iconSize: 16,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
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
                      Text(
                        ' · ${TimeUtils.timeAgo(group.createdAt)}',
                        style: TextStyle(
                          fontSize: 11,
                          color: ZanateColors.textMuted(isDark),
                        ),
                      ),
                    ],
                  ),
                ),

                if (onReport != null)
                  PopupMenuButton<String>(
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
                      color: isDark ? Colors.white : ZanateColors.zanateBlack,
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
                      }
                    },
                    itemBuilder: (ctx) => [
                      PopupMenuItem(
                        value: 'report',
                        height: 44,
                        child: Row(
                          children: [
                            PhosphorIcon(
                              PhosphorIconsRegular.flag,
                              size: 17,
                              color: isDark
                                  ? Colors.white
                                  : ZanateColors.zanateBlack,
                            ),
                            const SizedBox(width: 10),
                            const Text('Reportar'),
                          ],
                        ),
                      ),
                    ],
                  ),
              ],
            ),

            // Sección debajo del nombre del autor
            if (group.section.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 2.5,
                ),
                decoration: BoxDecoration(
                  color: ZanateColors.surface(isDark),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: ZanateColors.border(isDark),
                    width: 0.8,
                  ),
                ),
                child: Text(
                  group.section.trim(),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: ZanateColors.textMuted(isDark),
                  ),
                ),
              ),
            ],

            const SizedBox(height: 8),

            // Nombre del curso debajo de la sección (sin duplicar curso - sección)
            Text(
              group.curso.isNotEmpty ? group.curso : group.title,
              style: GoogleFonts.outfit(
                fontWeight: FontWeight.w700,
                fontSize: 16.5,
                height: 1.25,
                color: isDark ? Colors.white : ZanateColors.zanateBlack,
              ),
            ),

            // Subtítulo solo cuando aporta nombre distinto a "curso - sección"
            if (group.title.trim().isNotEmpty &&
                group.title.trim() != group.curso.trim() &&
                group.title.trim().toLowerCase() !=
                    '${group.curso.trim().toLowerCase()} - ${group.section.trim().toLowerCase()}') ...[
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

            if (group.description.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                group.description,
                style: theme.textTheme.bodySmall?.copyWith(fontSize: 12),
              ),
            ],

            // Imagen de grupo en proporción cuadrada 1:1
            if (group.imageUrl != null && group.imageUrl!.isNotEmpty) ...[
              const SizedBox(height: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 260,
                  maxHeight: 260,
                ),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: InkWell(
                    onTap: () => ImageViewerDialog.show(
                      context,
                      imageUrl: group.imageUrl!,
                      title: group.title,
                    ),
                    borderRadius: BorderRadius.circular(10),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        color: ZanateColors.surface(isDark),
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: Image.network(
                                group.imageUrl!,
                                fit: BoxFit.contain,
                                errorBuilder: (ctx, err, stack) =>
                                    const SizedBox.shrink(),
                              ),
                            ),
                            Positioned(
                              bottom: 6,
                              right: 6,
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.6),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const PhosphorIcon(
                                  PhosphorIconsRegular.magnifyingGlassPlus,
                                  color: Colors.white,
                                  size: 16,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],

            const SizedBox(height: 12),
            Container(
              height: 1.0,
              color: ZanateColors.border(isDark),
            ),
            const SizedBox(height: 10),

            // Actions Row: Upvote, Copy link, Join Button
            LayoutBuilder(
              builder: (context, constraints) {
                final compactJoinAction = constraints.maxWidth < 360;
                return Row(
                  children: [
                    // Upvote pill button (>=48px accessible hit target)
                    InkWell(
                      onTap: onUpvote,
                      borderRadius: BorderRadius.circular(12),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          minHeight: 48,
                          minWidth: 48,
                        ),
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 7,
                            ),
                            decoration: BoxDecoration(
                              color: group.isUpvotedByMe
                                  ? ZanateColors.zanateEyeYellow.withValues(
                                      alpha: isDark ? 0.24 : 0.32,
                                    )
                                  : ZanateColors.surface(isDark),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: group.isUpvotedByMe
                                    ? ZanateColors.focusBorder(isDark)
                                    : ZanateColors.border(isDark),
                                width: group.isUpvotedByMe ? 1.2 : 1.0,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                PhosphorIcon(
                                  group.isUpvotedByMe
                                      ? PhosphorIconsFill.arrowFatUp
                                      : PhosphorIconsRegular.arrowFatUp,
                                  size: 15,
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
                                    fontSize: 12,
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
                    ),
                    const SizedBox(width: 8),
                    // Minimalist copy button
                    IconButton(
                      icon: PhosphorIcon(
                        PhosphorIconsRegular.copy,
                        size: 17,
                        color: isDark
                            ? const Color(0xFF94A3B8)
                            : ZanateColors.mutedText,
                      ),
                      tooltip: 'Copiar enlace',
                      onPressed: () => UrlUtils.copyToClipboard(
                        context,
                        group.link,
                        message: 'Enlace del grupo copiado al portapapeles',
                      ),
                    ),
                    const Spacer(),
                    // Join action button
                    ElevatedButton.icon(
                      onPressed: () => _openGroupLink(context),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: platformColor,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 9,
                        ),
                      ),
                      icon: Icon(_getPlatformIcon(platform), size: 15),
                      label: Text(
                        compactJoinAction ? 'Unirse' : 'Unirse al Grupo',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    ),
  );
  }
}
