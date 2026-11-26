import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import '../../../../core/constants/zanate_colors.dart';
import '../../../shared/screens/settings_screen.dart';
import '../../models/discord_forum_models.dart';

class ForumChannelSidebar extends StatelessWidget {
  final ForumServer activeServer;
  final ForumChannel activeChannel;
  final List<ForumChannel>? channels;
  final List<ForumServer> subservers;
  final ForumServer? activeSubserver;
  final Function(ForumServer)? onSelectSubserver;
  final Function(ForumChannel) onSelectChannel;
  final VoidCallback? onAddServer;
  final VoidCallback? onSearch;
  final bool hasActiveSearch;
  final String? activeAlias;
  final Function(String)? onAliasChanged;
  final VoidCallback? onToggleTheme;

  const ForumChannelSidebar({
    super.key,
    required this.activeServer,
    required this.activeChannel,
    this.channels,
    this.subservers = const [],
    this.activeSubserver,
    this.onSelectSubserver,
    required this.onSelectChannel,
    this.onAddServer,
    this.onSearch,
    this.hasActiveSearch = false,
    this.activeAlias,
    this.onAliasChanged,
    this.onToggleTheme,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final background = ZanateColors.card(isDark);
    final borderColor = ZanateColors.border(isDark);

    final channelList =
        channels ??
        (activeServer.isGroups
            ? ForumChannel.groupsChannels
            : ForumChannel.defaultChannels);

    return Container(
      width: 244,
      color: background,
      child: Column(
        children: [
          // Cabecera del servidor activo
          Container(
            constraints: const BoxConstraints(minHeight: 62),
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            alignment: Alignment.centerLeft,
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: borderColor, width: 0.8),
              ),
            ),
            child: Row(
              children: [
                if (activeServer.resolvedLogoAsset != null) ...[
                  Container(
                    width: 28,
                    height: 28,
                    margin: const EdgeInsets.only(right: 10),
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: ZanateColors.surface(isDark),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: ZanateColors.border(isDark),
                        width: 1,
                      ),
                    ),
                    child: Image.asset(
                      activeServer.resolvedLogoAsset!,
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) => Icon(
                        activeServer.icon,
                        size: 16,
                        color: activeServer.color,
                      ),
                    ),
                  ),
                ],
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        activeServer.name
                            .replaceAll(RegExp(r'\s*\([^)]*\)'), '')
                            .trim(),
                        style: GoogleFonts.outfit(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.2,
                          color: isDark ? Colors.white : ZanateColors.zanateBlack,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        activeServer.isGroups
                            ? 'Grupos de estudio'
                            : 'Comunidad universitaria',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: isDark
                              ? const Color(0xFF94A3B8)
                              : ZanateColors.mutedText,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Lista de canales
          Expanded(
            child: ListView(
              primary: false,
              padding: const EdgeInsets.fromLTRB(10, 14, 10, 12),
              children: [
                if (subservers.isNotEmpty) ...[
                  _sectionLabel(
                    activeServer.serverKind == 'general' ? 'TEMAS' : 'CARRERAS',
                    isDark,
                  ),
                  const SizedBox(height: 6),
                  for (final subserver in subservers)
                    _subserverTile(
                      subserver,
                      activeSubserver?.id == subserver.id,
                      isDark,
                    ),
                  const SizedBox(height: 18),
                ],
                _sectionLabel(
                  activeServer.isGroups
                      ? 'GRUPOS'
                      : (subservers.isEmpty ? 'CANALES' : 'CANALES DE LA CARRERA'),
                  isDark,
                ),
                const SizedBox(height: 6),
                for (final channel in channelList)
                  _channelTile(
                    channel,
                    activeChannel.id == channel.id,
                    theme,
                    isDark,
                  ),
                if (!activeServer.isGroups) ...[
                  const SizedBox(height: 18),
                  _sectionLabel('PERSONAL', isDark),
                  const SizedBox(height: 6),
                  _channelTile(
                    ForumChannel.bookmarksChannel,
                    activeChannel.id == ForumChannel.bookmarksChannel.id,
                    theme,
                    isDark,
                  ),
                ],
              ],
            ),
          ),

          // Sección inferior con botones modernos
          _buildBottomConfigSection(context, theme, isDark, borderColor),
        ],
      ),
    );
  }

  Widget _buildBottomConfigSection(
    BuildContext context,
    ThemeData theme,
    bool isDark,
    Color borderColor,
  ) {
    final muted = ZanateColors.textMuted(isDark);

    return Container(
      decoration: BoxDecoration(
        color: ZanateColors.bg(isDark),
        border: Border(top: BorderSide(color: borderColor, width: 0.8)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Tooltip(
              message: 'Agregar servidor',
              child: Material(
                color: ZanateColors.zanateEyeYellow,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  onTap: onAddServer,
                  borderRadius: BorderRadius.circular(12),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 40),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          PhosphorIcon(
                            PhosphorIconsBold.plus,
                            size: 16,
                            color: ZanateColors.zanateBlack,
                          ),
                          SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              'Agregar servidor',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: ZanateColors.zanateBlack,
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
          ),
          const SizedBox(width: 4),
          if (onSearch != null) ...[
            IconButton(
              tooltip: 'Buscar en el foro',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 38, height: 38),
              onPressed: onSearch,
              icon: PhosphorIcon(
                PhosphorIconsRegular.magnifyingGlass,
                size: 20,
                color: hasActiveSearch
                    ? (isDark
                          ? ZanateColors.zanateEyeYellow
                          : ZanateColors.zanateBlack)
                    : muted,
              ),
            ),
            const SizedBox(width: 2),
          ],
          IconButton(
            tooltip: 'Configuración y Perfil',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 38, height: 38),
            onPressed: () => SettingsScreen.show(
              context,
              activeAlias: activeAlias ?? 'Estudiante',
              onAliasChanged: onAliasChanged ?? (_) {},
              onToggleTheme: onToggleTheme,
            ),
            icon: PhosphorIcon(
              PhosphorIconsRegular.gear,
              size: 20,
              color: muted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String label, bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.9,
          color: isDark ? const Color(0xFF64748B) : Colors.blueGrey.shade400,
        ),
      ),
    );
  }

  Widget _subserverTile(ForumServer server, bool isActive, bool isDark) {
    final activeBg = isDark
        ? ZanateColors.zanateEyeYellow.withValues(alpha: 0.20)
        : ZanateColors.zanateEyeYellow.withValues(alpha: 0.28);
    final activeTextColor = isDark ? Colors.white : ZanateColors.zanateBlack;

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: isActive ? activeBg : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onSelectSubserver == null
              ? null
              : () => onSelectSubserver!(server),
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(
              children: [
                Icon(
                  server.icon,
                  size: 16,
                  color: isActive ? activeTextColor : server.color,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    server.name,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                      color: isActive
                          ? activeTextColor
                          : (isDark
                                ? const Color(0xFFCBD5E1)
                                : ZanateColors.subtleText),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _channelTile(
    ForumChannel channel,
    bool isActive,
    ThemeData theme,
    bool isDark,
  ) {
    final activeBg = isDark
        ? ZanateColors.zanateEyeYellow.withValues(alpha: 0.20)
        : ZanateColors.zanateEyeYellow.withValues(alpha: 0.28);
    final activeTextColor = isDark ? Colors.white : ZanateColors.zanateBlack;
    final inactiveTextColor =
        isDark ? const Color(0xFF94A3B8) : ZanateColors.subtleText;

    final iconColor = isActive
        ? (isDark ? ZanateColors.zanateEyeYellow : ZanateColors.zanateBlack)
        : (isDark ? const Color(0xFF64748B) : ZanateColors.mutedText);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: isActive ? activeBg : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: () => onSelectChannel(channel),
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(
                  channel.icon,
                  size: 18,
                  color: iconColor,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    channel.label.isNotEmpty ? channel.label : channel.name,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight:
                          isActive ? FontWeight.w700 : FontWeight.w500,
                      color: isActive ? activeTextColor : inactiveTextColor,
                    ),
                  ),
                ),
                if (channel.isSpecial)
                  PhosphorIcon(
                    PhosphorIconsFill.bookmarkSimple,
                    size: 13,
                    color: iconColor,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
