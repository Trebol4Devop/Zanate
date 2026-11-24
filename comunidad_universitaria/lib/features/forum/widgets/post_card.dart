import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import '../../../core/constants/categories.dart';
import '../../../core/constants/zanate_colors.dart';
import '../../../core/models/post.dart';
import '../../../core/utils/time_utils.dart';
import '../../shared/widgets/report_dialog.dart';
import '../../shared/widgets/user_avatar_circle.dart';
import 'discord/discord_media_attachment.dart';
import 'discord/discord_video_attachment.dart';

class PostCard extends StatelessWidget {
  final Post post;
  final VoidCallback onTap;
  final VoidCallback onLike;
  final VoidCallback? onBookmark;
  final VoidCallback? onRepost;
  final VoidCallback? onShare;
  final Function(String pollId, String optionId)? onVotePoll;
  final Function(String reason)? onReport;
  final VoidCallback? onDelete;
  final bool isModerator;

  const PostCard({
    super.key,
    required this.post,
    required this.onTap,
    required this.onLike,
    this.onBookmark,
    this.onRepost,
    this.onShare,
    this.onVotePoll,
    this.onReport,
    this.onDelete,
    this.isModerator = false,
  });

  String _getCategoryLabel(String catId) {
    final match = USACConstants.forumCategories.where((c) => c.id == catId);
    return match.isNotEmpty ? match.first.label : 'General';
  }

  Widget _buildAction(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    int? count,
    bool isActive = false,
    Color? activeColor,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final defaultColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    final color = isActive
        ? (activeColor ??
            (isDark ? ZanateColors.zanateEyeYellow : ZanateColors.zanateBlack))
        : defaultColor;

    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: label,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 19, color: color),
                if (count != null && count > 0) ...[
                  const SizedBox(width: 5),
                  Text(
                    '$count',
                    style: TextStyle(
                      fontSize: 12,
                      color: color,
                      fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final modStatus = post.moderationStatus;
    final showModBanner = isModerator && modStatus > 0;
    final modColor = modStatus == 1 ? const Color(0xFFEAB308) : const Color(0xFFEF4444);

    final cardBg = ZanateColors.bg(isDark);
    final cardBorder = showModBanner
        ? modColor
        : ZanateColors.border(isDark);

    return Container(
      decoration: BoxDecoration(
        color: cardBg,
        border: Border(
          bottom: BorderSide(
            color: cardBorder,
            width: showModBanner ? 2.0 : 0.8,
          ),
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          hoverColor: (isDark ? ZanateColors.zanateEyeYellow : ZanateColors.zanateBlack)
              .withValues(alpha: 0.03),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 15),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
              if (showModBanner) ...[
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: modColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: modColor.withValues(alpha: 0.4)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        modStatus == 1 ? PhosphorIconsRegular.hourglass : PhosphorIconsRegular.eyeSlash,
                        size: 13,
                        color: modColor,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        modStatus == 1 ? 'Pendiente de revisión' : 'Ocultado por reportes',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: modColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              // Pinned badge if applicable
              if (post.isPinned) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: ZanateColors.zanateEyeYellow.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PhosphorIcon(
                        PhosphorIconsFill.pushPin,
                        size: 13,
                        color: isDark
                            ? ZanateColors.zanateEyeYellow
                            : ZanateColors.zanateBlack,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        'Publicación Fijada',
                        style: GoogleFonts.outfit(
                          color: isDark
                              ? ZanateColors.zanateEyeYellow
                              : ZanateColors.zanateBlack,
                          fontWeight: FontWeight.w700,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
              ],

              // Header: Author alias, Carrera/Faculty badge, Time ago
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  UserAvatarCircle(
                    authorAlias: post.authorAlias,
                    authorHash: post.authorHash,
                    avatarColorIndex: post.avatarColorIndex,
                    avatarIconIndex: post.avatarIconIndex,
                    isMine: post.isMine,
                    size: 34,
                    iconSize: 16,
                  ),
                  const SizedBox(width: 10),
                    Expanded(
                      child: Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 6,
                        runSpacing: 2,
                        children: [
                          Text(
                            post.authorAlias,
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                              color: isDark ? Colors.white : ZanateColors.zanateDark,
                            ),
                          ),
                          Text(
                            _getCategoryLabel(post.category),
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w500,
                              color: ZanateColors.textMuted(isDark),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (onReport != null || (post.isMine && onDelete != null))
                    PopupMenuButton<String>(
                    tooltip: 'Más opciones',
                    color: ZanateColors.card(isDark),
                    surfaceTintColor: Colors.transparent,
                    elevation: 3,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                      side: BorderSide(color: ZanateColors.border(isDark)),
                    ),
                    icon: Icon(
                      PhosphorIconsRegular.dotsThreeVertical,
                      size: 18,
                      color: isDark ? Colors.white70 : ZanateColors.zanateDark,
                    ),
                    onSelected: (val) {
                      if (val == 'report' && onReport != null) {
                        ReportDialog.show(
                          context,
                          title: 'Reportar Publicación',
                          subtitle: 'Publicación de ${post.authorAlias}',
                          onSubmitted: onReport!,
                        );
                      } else if (val == 'delete' && onDelete != null) {
                        onDelete!();
                      }
                    },
                    itemBuilder: (ctx) => [
                      if (post.isMine && onDelete != null)
                        PopupMenuItem(
                          value: 'delete',
                          height: 44,
                          child: Row(
                            children: [
                              Icon(
                                PhosphorIconsRegular.trash,
                                size: 17,
                                color: Colors.red,
                              ),
                              const SizedBox(width: 10),
                              const Text(
                                'Eliminar publicación',
                                style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                        ),
                      if (onReport != null)
                        PopupMenuItem(
                          value: 'report',
                          height: 44,
                          child: Row(
                            children: [
                              Icon(
                                PhosphorIconsRegular.flag,
                                size: 17,
                                color: isDark ? Colors.white : ZanateColors.zanateDark,
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
                  ],
                ),
              ),

              // GIF Preview if available
              if (post.gifUrl != null && post.gifUrl!.isNotEmpty) ...[
                const SizedBox(height: 10),
                DiscordMediaAttachment(
                  imageUrl: post.gifUrl!,
                  title: post.title,
                  isGif: true,
                  maxHeight: 420,
                  borderRadius: BorderRadius.zero,
                  showBorder: false,
                  showZoomBadge: false,
                  onTap: onTap,
                ),
              ],

              // Image Preview if available
              if (post.imageUrl != null && post.imageUrl!.isNotEmpty) ...[
                const SizedBox(height: 10),
                DiscordMediaAttachment(
                  imageUrl: post.imageUrl!,
                  title: post.title,
                  isGif: false,
                  maxHeight: 560,
                  borderRadius: BorderRadius.zero,
                  showBorder: false,
                  showZoomBadge: false,
                  onTap: onTap,
                ),
              ],

              // Video Preview if available
              if (post.videoUrl != null && post.videoUrl!.isNotEmpty) ...[
                const SizedBox(height: 10),
                DiscordVideoAttachment(
                  videoUrl: post.videoUrl!,
                  maxHeight: 420,
                  borderRadius: BorderRadius.zero,
                  showBorder: false,
                ),
              ],

              const SizedBox(height: 12),

              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
              // Interactive Poll Widget if available (above interaction buttons)
              if (post.poll != null) ...[
                _buildPollCard(isDark),
                const SizedBox(height: 12),
              ],

              // Acciones en el orden de la interfaz de referencia.
              Row(
                children: [
                  _buildAction(
                    context,
                    icon: post.isLikedByMe
                        ? PhosphorIconsFill.thumbsUp
                        : PhosphorIconsRegular.thumbsUp,
                    label: 'Me gusta',
                    onTap: onLike,
                    count: post.likes,
                    isActive: post.isLikedByMe,
                    activeColor: isDark
                        ? ZanateColors.zanateEyeYellow
                        : ZanateColors.zanateBlack,
                  ),
                  const SizedBox(width: 14),
                  _buildAction(
                    context,
                    icon: PhosphorIconsRegular.chatCircle,
                    label: 'Comentar',
                    onTap: onTap,
                    count: post.commentCount,
                  ),
                  const SizedBox(width: 14),
                  if (onRepost != null) ...[
                    _buildAction(
                      context,
                      icon: PhosphorIconsRegular.repeat,
                      label: 'Republicar',
                      onTap: onRepost,
                      count: post.repostsCount,
                    ),
                    const SizedBox(width: 14),
                  ],
                  if (onShare != null) ...[
                    _buildAction(
                      context,
                      icon: PhosphorIconsRegular.shareNetwork,
                      label: 'Compartir',
                      onTap: onShare,
                      count: post.sharesCount,
                    ),
                    const SizedBox(width: 14),
                  ],
                  if (onBookmark != null)
                    _buildAction(
                      context,
                      icon: post.isBookmarkedByMe
                          ? PhosphorIconsFill.bookmarkSimple
                          : PhosphorIconsRegular.bookmarkSimple,
                      label: post.isBookmarkedByMe
                          ? 'Quitar de guardados'
                          : 'Guardar',
                      onTap: onBookmark,
                      isActive: post.isBookmarkedByMe,
                      activeColor: ZanateColors.zanateEyeYellow,
                    ),
                ],
              ),

              const SizedBox(height: 10),

              // Post Title (below interaction buttons)
              Text(
                post.title,
                style: GoogleFonts.outfit(
                  fontWeight: FontWeight.w700,
                  fontSize: 16.5,
                  height: 1.25,
                  color: isDark ? Colors.white : ZanateColors.zanateBlack,
                ),
              ),

              if (post.content.trim().isNotEmpty) ...[
                const SizedBox(height: 6),
                _ExpandableDescription(
                  text: post.content,
                  style: theme.textTheme.bodyMedium?.copyWith(
                        fontSize: 13.5,
                        color: ZanateColors.textSecondary(isDark),
                        height: 1.45,
                      ) ??
                      TextStyle(
                        fontSize: 13.5,
                        color: ZanateColors.textSecondary(isDark),
                        height: 1.45,
                      ),
                  toggleColor: ZanateColors.textMuted(isDark),
                ),
              ],

              // Quoted Post Card (Quote Tweet style)
              if (post.quotedPost != null) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: ZanateColors.surface(isDark),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: ZanateColors.border(isDark),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          PhosphorIcon(
                            PhosphorIconsRegular.quotes,
                            size: 14,
                            color: isDark
                                ? ZanateColors.zanateEyeYellow
                                : ZanateColors.zanateBlack,
                          ),
                          const SizedBox(width: 5),
                          Expanded(
                            child: Text(
                              post.quotedPost!.authorAlias,
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 12,
                                color: isDark
                                    ? Colors.white
                                    : ZanateColors.zanateBlack,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            TimeUtils.timeAgo(post.quotedPost!.createdAt),
                            style: const TextStyle(
                              color: ZanateColors.mutedText,
                              fontSize: 10.5,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        post.quotedPost!.title,
                        style: GoogleFonts.outfit(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: isDark
                              ? Colors.white
                              : ZanateColors.zanateBlack,
                        ),
                      ),
                      Text(
                        post.quotedPost!.content,
                        style: TextStyle(
                          color: isDark
                              ? const Color(0xFF94A3B8)
                              : ZanateColors.subtleText,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 8),
              Text(
                TimeUtils.timeAgo(post.createdAt),
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
    ),
  );
}

  Widget _buildPollCard(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ZanateColors.surface(isDark),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: ZanateColors.border(isDark),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              PhosphorIcon(
                PhosphorIconsRegular.chartBar,
                size: 16,
                color: isDark
                    ? ZanateColors.zanateEyeYellow
                    : ZanateColors.zanateBlack,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  post.poll!.question,
                  style: GoogleFonts.outfit(
                    fontWeight: FontWeight.w700,
                    fontSize: 13.5,
                    color: isDark
                        ? Colors.white
                        : ZanateColors.zanateBlack,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...post.poll!.options.map((opt) {
            final total = post.poll!.totalVotes;
            final rawPercent = total > 0 ? (opt.votesCount / total) : 0.0;
            final percent = (rawPercent.isNaN || rawPercent.isInfinite) ? 0.0 : rawPercent.clamp(0.0, 1.0);
            final hasVoted = post.poll!.myVotedOptionId != null;
            final isMyVote = post.poll!.myVotedOptionId == opt.id;

            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: InkWell(
                onTap: onVotePoll != null
                    ? () => onVotePoll!(post.poll!.id, opt.id)
                    : null,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 36),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isMyVote
                          ? ZanateColors.focusBorder(isDark)
                          : ZanateColors.border(isDark),
                      width: isMyVote ? 1.5 : 1.0,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(7),
                    child: Stack(
                      alignment: Alignment.centerLeft,
                      children: [
                        if (hasVoted)
                          Positioned.fill(
                            child: FractionallySizedBox(
                              alignment: Alignment.centerLeft,
                              widthFactor: percent,
                              child: Container(
                                color: isMyVote
                                    ? ZanateColors.zanateEyeYellow
                                        .withValues(
                                          alpha: isDark ? 0.25 : 0.34,
                                        )
                                    : (isDark
                                        ? Colors.white.withValues(alpha: 0.08)
                                        : ZanateColors.pillBg),
                              ),
                            ),
                          ),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 7,
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Row(
                                  children: [
                                    if (isMyVote) ...[
                                      PhosphorIcon(
                                        PhosphorIconsFill.checkCircle,
                                        size: 15,
                                        color: isDark
                                            ? ZanateColors.zanateEyeYellow
                                            : ZanateColors.zanateBlack,
                                      ),
                                      const SizedBox(width: 6),
                                    ],
                                    Flexible(
                                      child: Text(
                                        opt.optionText,
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: isMyVote ? FontWeight.bold : FontWeight.normal,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (hasVoted) ...[
                                const SizedBox(width: 8),
                                Text(
                                  '${(percent * 100).toStringAsFixed(0)}% · ${opt.votesCount} votos',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: isMyVote
                                        ? (isDark
                                            ? ZanateColors.zanateEyeYellow
                                            : ZanateColors.zanateBlack)
                                        : (isDark
                                            ? const Color(0xFF94A3B8)
                                            : ZanateColors.subtleText),
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
          }),
          Text(
            '${post.poll!.totalVotes} votos registrados',
            style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
          ),
        ],
      ),
    );
  }
}

class _ExpandableDescription extends StatefulWidget {
  final String text;
  final TextStyle style;
  final Color toggleColor;

  const _ExpandableDescription({
    required this.text,
    required this.style,
    required this.toggleColor,
  });

  @override
  State<_ExpandableDescription> createState() => _ExpandableDescriptionState();
}

class _ExpandableDescriptionState extends State<_ExpandableDescription> {
  static const int _collapsedMaxLines = 3;
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          maxLines: _collapsedMaxLines,
          textDirection: Directionality.of(context),
        )..layout(maxWidth: constraints.maxWidth);

        final isOverflowing = painter.didExceedMaxLines;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.text,
              style: widget.style,
              maxLines: _isExpanded ? null : _collapsedMaxLines,
              overflow: _isExpanded ? TextOverflow.visible : TextOverflow.ellipsis,
            ),
            if (isOverflowing) ...[
              const SizedBox(height: 4),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _isExpanded = !_isExpanded),
                child: Text(
                  _isExpanded ? 'Ver menos' : 'Ver más',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: widget.toggleColor,
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
