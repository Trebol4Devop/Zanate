import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:share_plus/share_plus.dart';
import '../../../core/config/supabase_config.dart';
import '../../../core/constants/categories.dart';
import '../../../core/constants/zanate_colors.dart';
import '../../../core/models/whatsapp_group.dart';
import '../../../core/services/groups_service.dart';
import '../../../core/services/local_storage_service.dart';
import '../../../core/services/profile_service.dart';
import '../../../core/services/supabase_service.dart';
import '../../../core/utils/responsive.dart';
import '../widgets/create_group_dialog.dart';
import '../widgets/group_card.dart';
import '../../shared/widgets/auth_modal.dart';
import '../../shared/widgets/empty_state_widget.dart';
import '../../shared/screens/settings_screen.dart';

class GroupsScreen extends StatefulWidget {
  final String activeAlias;
  final Function(String newAlias) onAliasChanged;
  final VoidCallback? onToggleTheme;
  final String? activeServerName;
  final String? activeFacultadId;
  final String? activeCarreraId;
  final String? activeChannelName;
  final String? activeChannelDescription;
  final IconData? activeChannelIcon;
  final bool showFloatingActionButton;
  final Object floatingActionButtonHeroTag;

  const GroupsScreen({
    super.key,
    required this.activeAlias,
    required this.onAliasChanged,
    this.onToggleTheme,
    this.activeServerName,
    this.activeFacultadId,
    this.activeCarreraId,
    this.activeChannelName,
    this.activeChannelDescription,
    this.activeChannelIcon,
    this.showFloatingActionButton = true,
    this.floatingActionButtonHeroTag = 'groups_fab',
  });

  @override
  GroupsScreenState createState() => GroupsScreenState();
}

class GroupsScreenState extends State<GroupsScreen> {
  List<WhatsAppGroup> _groups = [];
  bool _isLoading = true;
  String? _loadError;
  String _selectedFacultad = 'todas';
  String _selectedCarrera = 'todas';
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;
  int _loadRequestId = 0;
  final Set<String> _votingGroupIds = {};
  bool _isDesktopFilterExpanded = false;
  bool _isDesktopSidebarCollapsed = false;

  @override
  void initState() {
    super.initState();
    if (widget.activeFacultadId != null) {
      _selectedFacultad = widget.activeFacultadId!;
    }
    if (widget.activeCarreraId != null) {
      _selectedCarrera = widget.activeCarreraId!;
    }
    ProfileService.profileRevision.addListener(_onProfileRevisionChanged);
    _loadGroups();
  }

  Future<void> _onProfileRevisionChanged() async {
    try {
      final profile = await LocalStorageService.getUserProfile();
      if (!mounted) return;
      setState(() {
        _groups = _groups.map((g) {
          if (!g.isMine) return g;
          return g.copyWith(
            avatarColorIndex: profile.avatarColorIndex,
            avatarIconIndex: profile.avatarIconIndex,
          );
        }).toList();
      });
    } catch (_) {}
    if (mounted) {
      _loadGroups(forceRefresh: true);
    }
  }

  @override
  void didUpdateWidget(covariant GroupsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    bool shouldReload = false;
    if (widget.activeFacultadId != null &&
        widget.activeFacultadId != _selectedFacultad) {
      _selectedFacultad = widget.activeFacultadId!;
      shouldReload = true;
    }
    if (widget.activeCarreraId != null &&
        widget.activeCarreraId != _selectedCarrera) {
      _selectedCarrera = widget.activeCarreraId!;
      shouldReload = true;
    }
    if (shouldReload) {
      _loadGroups();
    }
  }

  @override
  void dispose() {
    ProfileService.profileRevision.removeListener(_onProfileRevisionChanged);
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String val) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() => _searchQuery = val.trim());
      _loadGroups();
    });
  }

  void _submitSearch(String val) {
    _searchDebounce?.cancel();
    setState(() => _searchQuery = val.trim());
    _loadGroups();
  }

  Future<void> _loadGroups({bool forceRefresh = false}) async {
    final currentRequestId = ++_loadRequestId;
    setState(() {
      _isLoading = true;
      _loadError = null;
    });

    try {
      final groups = await GroupsService.fetchGroups(
        facultad: _selectedFacultad,
        carrera: _selectedCarrera,
        searchQuery: _searchQuery,
        forceRefresh: forceRefresh,
      );
      if (mounted && currentRequestId == _loadRequestId) {
        setState(() {
          _groups = groups;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted && currentRequestId == _loadRequestId) {
        setState(() {
          _loadError = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _handleToggleUpvote(WhatsAppGroup group) async {
    if (_votingGroupIds.contains(group.id)) return;
    _votingGroupIds.add(group.id);

    if (SupabaseConfig.isConfigured && !SupabaseService.isAuthenticated) {
      _votingGroupIds.remove(group.id);
      AuthModal.show(
        context,
        title: 'Inicia sesión para votar',
        subtitle:
            'Para apoyar un enlace de grupo necesitas autenticar tu cuenta.',
        onAuthenticated: () => _handleToggleUpvote(group),
      );
      return;
    }

    final prevUpvoted = group.isUpvotedByMe;
    final prevUpvotes = group.upvotes;

    setState(() {
      final idx = _groups.indexWhere((g) => g.id == group.id);
      if (idx != -1) {
        _groups[idx] = group.copyWith(
          isUpvotedByMe: !prevUpvoted,
          upvotes: prevUpvoted
              ? (prevUpvotes - 1).clamp(0, 999999)
              : prevUpvotes + 1,
        );
      }
    });

    bool? persistedUpvoteState;
    try {
      persistedUpvoteState = await GroupsService.toggleUpvote(group);
    } catch (_) {
      persistedUpvoteState = null;
    }

    final succeeded = persistedUpvoteState == !prevUpvoted;
    if (mounted) {
      if (!succeeded) {
        setState(() {
          final idx = _groups.indexWhere((g) => g.id == group.id);
          if (idx != -1) {
            _groups[idx] = group.copyWith(
              isUpvotedByMe: prevUpvoted,
              upvotes: prevUpvotes,
            );
          }
        });
      }
      _votingGroupIds.remove(group.id);
    } else {
      _votingGroupIds.remove(group.id);
    }
  }

  Future<void> _handleReportGroup(WhatsAppGroup group, String reason) async {
    if (SupabaseConfig.isConfigured && !SupabaseService.isAuthenticated) {
      AuthModal.show(
        context,
        title: 'Inicia sesión para reportar',
        subtitle:
            'Para enviar un reporte sobre un grupo necesitas iniciar sesión.',
        onAuthenticated: () => _handleReportGroup(group, reason),
      );
      return;
    }

    final submitted = await GroupsService.reportGroup(
      groupId: group.id,
      reason: reason,
    );
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          submitted
              ? 'Gracias. Hemos recibido tu reporte sobre el enlace.'
              : 'No se pudo enviar el reporte. Inténtalo de nuevo.',
        ),
      ),
    );
  }

  Future<void> _handleDeleteGroup(WhatsAppGroup group) async {
    final ok = await ProfileService.deleteGroup(group.id);
    if (!mounted) return;
    if (ok) {
      setState(() {
        _groups.removeWhere((g) => g.id == group.id);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Grupo eliminado.'),
          backgroundColor: ZanateColors.zanateBlack,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No se pudo eliminar el grupo.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _handleShareGroup(WhatsAppGroup group) async {
    final shareText = group.link.trim();
    if (shareText.isEmpty) return;

    final optimistic = group.sharesCount + 1;
    setState(() {
      final idx = _groups.indexWhere((g) => g.id == group.id);
      if (idx != -1) {
        _groups[idx] = _groups[idx].copyWith(sharesCount: optimistic);
      }
    });

    final updatedCount = await GroupsService.incrementShareCount(group.id);
    if (mounted && updatedCount != null) {
      setState(() {
        final idx = _groups.indexWhere((g) => g.id == group.id);
        if (idx != -1) {
          _groups[idx] = _groups[idx].copyWith(sharesCount: updatedCount);
        }
      });
    }

    try {
      final result = await SharePlus.instance.share(
        ShareParams(text: shareText, subject: group.title),
      );
      if (result.status == ShareResultStatus.unavailable) {
        await Clipboard.setData(ClipboardData(text: shareText));
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Enlace del grupo copiado al portapapeles'),
            backgroundColor: ZanateColors.zanateBlack,
          ),
        );
      }
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: shareText));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enlace del grupo copiado al portapapeles'),
          backgroundColor: ZanateColors.zanateBlack,
        ),
      );
    }
  }

  Widget _buildGroupCard(WhatsAppGroup group) => GroupCard(
    key: ValueKey(group.id),
    group: group,
    onUpvote: () => _handleToggleUpvote(group),
    onReport: (reason) => _handleReportGroup(group, reason),
    onDelete: group.isMine ? () => _handleDeleteGroup(group) : null,
    onShare: () => _handleShareGroup(group),
  );

  void openCreateGroupDialog() => _openCreateGroupDialog();

  void _openCreateGroupDialog() {
    if (SupabaseConfig.isConfigured && !SupabaseService.isAuthenticated) {
      AuthModal.show(
        context,
        title: 'Inicia Sesión para Compartir',
        subtitle:
            'Para compartir enlaces de grupos estudiantiles, debes iniciar sesión.',
        onAuthenticated: () {
          _showCreateGroupDialog();
        },
      );
      return;
    }
    _showCreateGroupDialog();
  }

  void _showCreateGroupDialog() {
    CreateGroupDialog.show(
      context,
      activeAlias: widget.activeAlias,
      onAliasChanged: widget.onAliasChanged,
      initialFacultad: _selectedFacultad != 'todas' ? _selectedFacultad : null,
      initialCarrera: _selectedCarrera != 'todas' ? _selectedCarrera : null,
      onGroupCreated: (newGroup) {
        _loadGroups(forceRefresh: true);
      },
    );
  }

  bool get _hasActivePreferences => _selectedFacultad != 'todas';

  String _getActivePreferencesLabel() {
    if (_selectedFacultad != 'todas') {
      final fac = USACConstants.facultades.firstWhere(
        (f) => f['id'].toString() == _selectedFacultad,
        orElse: () => {'nombre': 'Facultad'},
      );
      return fac['nombre']?.toString() ?? 'Facultad';
    }
    return 'Facultad';
  }

  void _showPreferencesSheet(BuildContext context, bool isDark) {
    String tempFacultad = _selectedFacultad;
    final textPrimary = ZanateColors.textPrimary(isDark);
    final textSecondary = ZanateColors.textSecondary(isDark);
    final borderColor = ZanateColors.border(isDark);

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: ZanateColors.bg(isDark),
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        side: BorderSide(color: borderColor, width: 1),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  left: 20,
                  right: 20,
                  top: 12,
                  bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 20,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 16),
                        decoration: BoxDecoration(
                          color: borderColor,
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        Icon(
                          PhosphorIconsRegular.slidersHorizontal,
                          size: 20,
                          color: textPrimary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Filtrar por Facultad',
                          style: GoogleFonts.outfit(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: textPrimary,
                          ),
                        ),
                        const Spacer(),
                        if (tempFacultad != 'todas')
                          TextButton(
                            onPressed: () {
                              setSheetState(() => tempFacultad = 'todas');
                            },
                            child: Text(
                              'Restablecer',
                              style: TextStyle(
                                fontSize: 13,
                                color: isDark
                                    ? const Color(0xFFF87171)
                                    : const Color(0xFFEF4444),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 14),

                    Text(
                      'Selecciona tu facultad o unidad académica',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: textSecondary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      decoration: BoxDecoration(
                        color: ZanateColors.surface(isDark),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: borderColor,
                          width: 1.2,
                        ),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: tempFacultad,
                          isExpanded: true,
                          itemHeight: null,
                          dropdownColor: ZanateColors.card(isDark),
                          borderRadius: BorderRadius.circular(14),
                          icon: Icon(
                            PhosphorIconsRegular.caretDown,
                            size: 16,
                            color: textPrimary,
                          ),
                          items: USACConstants.facultades
                              .map(
                                (f) => DropdownMenuItem<String>(
                                  value: f['id'].toString(),
                                  child: Text(
                                    f['nombre'].toString(),
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: textPrimary,
                                    ),
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (val) {
                            if (val != null) {
                              setSheetState(() => tempFacultad = val);
                            }
                          },
                        ),
                      ),
                    ),

                    const SizedBox(height: 20),

                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton(
                        onPressed: () {
                          Navigator.of(sheetContext).pop();
                          setState(() => _selectedFacultad = tempFacultad);
                          _loadGroups();
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: ZanateColors.ctaBg(isDark),
                          foregroundColor: ZanateColors.ctaFg(isDark),
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: const Text(
                          'Aplicar Filtro',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // 1. Zanate Header: Centered Title, Gear for Settings on Left
  Widget _buildSquaredHeader(bool isDark, String titleText) {
    final textPrimary = ZanateColors.textPrimary(isDark);
    return Container(
      constraints: const BoxConstraints(minHeight: 58),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: ZanateColors.card(isDark),
        border: Border(
          bottom: BorderSide(color: ZanateColors.border(isDark)),
        ),
      ),
      child: Row(
        children: [
          // Left: Settings Button (Configuración y Perfil)
          IconButton(
            tooltip: 'Configuración y Perfil',
            onPressed: () => SettingsScreen.show(
              context,
              activeAlias: widget.activeAlias,
              onAliasChanged: widget.onAliasChanged,
              onToggleTheme: widget.onToggleTheme,
            ),
            icon: Icon(
              PhosphorIconsRegular.gear,
              size: 22,
              color: textPrimary,
            ),
            splashRadius: 22,
          ),

          // Center: Clean, simple, centered title
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  'DIRECTORIO ESTUDIANTIL',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: ZanateColors.textMuted(isDark),
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  titleText,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.outfit(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: textPrimary,
                  ),
                ),
              ],
            ),
          ),

          // Right: Minimalist + button to share group
          IconButton(
            tooltip: 'Compartir Grupo',
            onPressed: _openCreateGroupDialog,
            icon: Icon(
              PhosphorIconsBold.plus,
              size: 22,
              color: textPrimary,
            ),
            splashRadius: 22,
          ),
        ],
      ),
    );
  }

  Widget _buildSearchInput(bool isDark) {
    final textPrimary = ZanateColors.textPrimary(isDark);
    final textSecondary = ZanateColors.textSecondary(isDark);
    final borderColor = ZanateColors.border(isDark);

    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: ZanateColors.surface(isDark),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: borderColor,
          width: 1.2,
        ),
      ),
      child: Row(
        children: [
          Icon(
            PhosphorIconsRegular.magnifyingGlass,
            size: 17,
            color: textSecondary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              onSubmitted: _submitSearch,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                filled: false,
                hintText: 'Buscar cursos, secciones o palabras clave...',
                hintStyle: TextStyle(
                  fontSize: 13,
                  color: ZanateColors.textMuted(isDark),
                  fontWeight: FontWeight.w400,
                ),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
              style: TextStyle(
                fontSize: 13.5,
                color: textPrimary,
              ),
            ),
          ),
          if (_searchQuery.isNotEmpty)
            InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: () {
                _searchController.clear();
                _onSearchChanged('');
              },
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  PhosphorIconsRegular.x,
                  size: 15,
                  color: textSecondary,
                ),
              ),
            ),
        ],
      ),
    );
  }

  // 2. Zanate Search & Preferences Bar (móvil / tableta)
  Widget _buildSquaredSearchBar(bool isDark) {
    final textPrimary = ZanateColors.textPrimary(isDark);
    final borderColor = ZanateColors.border(isDark);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: ZanateColors.card(isDark),
        border: Border(
          bottom: BorderSide(color: borderColor),
        ),
      ),
      child: Row(
        children: [
          Expanded(child: _buildSearchInput(isDark)),
          const SizedBox(width: 8),

          // Discrete Zanate Preferences Pill
          Flexible(
            flex: 0,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 185),
              child: InkWell(
                onTap: () => _showPreferencesSheet(context, isDark),
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 40),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: _hasActivePreferences
                        ? ZanateColors.zanateEyeYellow
                        : ZanateColors.pill(isDark),
                    borderRadius: BorderRadius.circular(12),
                    border: _hasActivePreferences
                        ? null
                        : Border.all(color: borderColor, width: 1),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _hasActivePreferences
                            ? PhosphorIconsFill.slidersHorizontal
                            : PhosphorIconsRegular.slidersHorizontal,
                        size: 15,
                        color: _hasActivePreferences
                            ? ZanateColors.zanateBlack
                            : textPrimary,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          _getActivePreferencesLabel(),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: _hasActivePreferences
                                ? FontWeight.w700
                                : FontWeight.w600,
                            color: _hasActivePreferences
                                ? ZanateColors.zanateBlack
                                : textPrimary,
                          ),
                        ),
                      ),
                      if (_hasActivePreferences) ...[
                        const SizedBox(width: 2),
                        InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () {
                            setState(() => _selectedFacultad = 'todas');
                            _loadGroups();
                          },
                          child: const Padding(
                            padding: EdgeInsets.all(6),
                            child: Icon(
                              PhosphorIconsBold.x,
                              size: 13,
                              color: ZanateColors.zanateBlack,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadError() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFEF4444).withValues(alpha: 0.1),
        border: const Border(
          bottom: BorderSide(
            color: Color(0xFFEF4444),
            width: 0.8,
          ),
        ),
      ),
      child: Row(
        children: [
          const Icon(PhosphorIconsRegular.warningCircle, color: Color(0xFFEF4444), size: 18),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'No se pudieron cargar los grupos. Revisa tu conexión.',
              style: TextStyle(fontSize: 12, color: Color(0xFFEF4444)),
            ),
          ),
          TextButton(
            onPressed: _loadGroups,
            child: const Text('Reintentar', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupsFeed(bool isDark) {
    if (_isLoading && _groups.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: CircularProgressIndicator(
            color: ZanateColors.focusBorder(isDark),
          ),
        ),
      );
    }

    if (_loadError != null && _groups.isEmpty) {
      return _buildLoadError();
    }

    final isDesktop = Responsive.isDesktop(context);

    if (_groups.isEmpty) {
      final empty = const EmptyStateWidget(
        icon: PhosphorIconsRegular.usersThree,
        title: 'No se encontraron grupos para este filtro',
        description:
            'Prueba ajustando tus preferencias o usa el botón + superior para compartir un enlace con tus compañeros.',
      );
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
        children: [
          if (isDesktop)
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 600),
                child: empty,
              ),
            )
          else
            empty,
        ],
      );
    }

    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      itemCount: _groups.length,
      itemBuilder: (ctx, i) {
        final card = _buildGroupCard(_groups[i]);
        if (!isDesktop) return card;
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: card,
          ),
        );
      },
    );
  }

  Widget _buildDesktopHeader(bool isDark, String titleText) {
    final textPrimary = ZanateColors.textPrimary(isDark);
    return Container(
      constraints: const BoxConstraints(minHeight: 58),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: ZanateColors.card(isDark),
        border: Border(
          bottom: BorderSide(color: ZanateColors.border(isDark)),
        ),
      ),
      child: Row(
        children: [
          const SizedBox(width: 48),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  'DIRECTORIO ESTUDIANTIL',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: ZanateColors.textMuted(isDark),
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  titleText,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.outfit(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: textPrimary,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Compartir Grupo',
            onPressed: _openCreateGroupDialog,
            icon: Icon(
              PhosphorIconsBold.plus,
              size: 22,
              color: textPrimary,
            ),
            splashRadius: 22,
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopSidebar(bool isDark) {
    final textPrimary = ZanateColors.textPrimary(isDark);
    final textSecondary = ZanateColors.textSecondary(isDark);
    final borderColor = ZanateColors.border(isDark);

    if (_isDesktopSidebarCollapsed) {
      return Container(
        width: 56,
        decoration: BoxDecoration(
          color: ZanateColors.card(isDark),
          border: Border(
            right: BorderSide(color: borderColor, width: 1),
          ),
        ),
        child: Column(
          children: [
            const SizedBox(height: 10),
            IconButton(
              tooltip: 'Expandir barra lateral',
              onPressed: () =>
                  setState(() => _isDesktopSidebarCollapsed = false),
              icon: Icon(
                PhosphorIconsRegular.sidebarSimple,
                size: 20,
                color: textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            IconButton(
              tooltip: 'Buscar grupos',
              onPressed: () =>
                  setState(() => _isDesktopSidebarCollapsed = false),
              icon: Icon(
                PhosphorIconsRegular.magnifyingGlass,
                size: 20,
                color: _searchQuery.isNotEmpty
                    ? ZanateColors.focusBorder(isDark)
                    : textSecondary,
              ),
            ),
            IconButton(
              tooltip: 'Filtrar por Facultad',
              onPressed: () {
                setState(() {
                  _isDesktopSidebarCollapsed = false;
                  _isDesktopFilterExpanded = true;
                });
              },
              icon: Icon(
                _hasActivePreferences
                    ? PhosphorIconsFill.slidersHorizontal
                    : PhosphorIconsRegular.slidersHorizontal,
                size: 20,
                color: _hasActivePreferences
                    ? ZanateColors.focusBorder(isDark)
                    : textSecondary,
              ),
            ),
            const Spacer(),
            Container(
              decoration: BoxDecoration(
                color: ZanateColors.bg(isDark),
                border: Border(top: BorderSide(color: borderColor, width: 0.8)),
              ),
              padding: const EdgeInsets.symmetric(vertical: 8),
              width: double.infinity,
              child: IconButton(
                tooltip: 'Configuración y Perfil',
                onPressed: () => SettingsScreen.show(
                  context,
                  activeAlias: widget.activeAlias,
                  onAliasChanged: widget.onAliasChanged,
                  onToggleTheme: widget.onToggleTheme,
                ),
                icon: Icon(
                  PhosphorIconsRegular.gear,
                  size: 20,
                  color: textPrimary,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: 272,
      decoration: BoxDecoration(
        color: ZanateColors.card(isDark),
        border: Border(
          right: BorderSide(color: borderColor, width: 1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Búsqueda y filtros',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: textSecondary,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Contraer barra lateral',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 30,
                        height: 30,
                      ),
                      onPressed: () =>
                          setState(() => _isDesktopSidebarCollapsed = true),
                      icon: Icon(
                        PhosphorIconsRegular.sidebarSimple,
                        size: 18,
                        color: textSecondary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                _buildSearchInput(isDark),
                const SizedBox(height: 10),
                InkWell(
                  onTap: () {
                    setState(() {
                      _isDesktopFilterExpanded = !_isDesktopFilterExpanded;
                    });
                  },
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 40),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: _hasActivePreferences
                          ? ZanateColors.zanateEyeYellow
                          : ZanateColors.pill(isDark),
                      borderRadius: BorderRadius.circular(12),
                      border: _hasActivePreferences
                          ? null
                          : Border.all(color: borderColor, width: 1),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _hasActivePreferences
                              ? PhosphorIconsFill.slidersHorizontal
                              : PhosphorIconsRegular.slidersHorizontal,
                          size: 16,
                          color: _hasActivePreferences
                              ? ZanateColors.zanateBlack
                              : textPrimary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _getActivePreferencesLabel(),
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: _hasActivePreferences
                                  ? FontWeight.w700
                                  : FontWeight.w600,
                              color: _hasActivePreferences
                                  ? ZanateColors.zanateBlack
                                  : textPrimary,
                            ),
                          ),
                        ),
                        if (_hasActivePreferences)
                          InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () {
                              setState(() => _selectedFacultad = 'todas');
                              _loadGroups();
                            },
                            child: const Padding(
                              padding: EdgeInsets.all(4),
                              child: Icon(
                                PhosphorIconsBold.x,
                                size: 13,
                                color: ZanateColors.zanateBlack,
                              ),
                            ),
                          ),
                        const SizedBox(width: 2),
                        Icon(
                          _isDesktopFilterExpanded
                              ? PhosphorIconsRegular.caretUp
                              : PhosphorIconsRegular.caretDown,
                          size: 15,
                          color: _hasActivePreferences
                              ? ZanateColors.zanateBlack
                              : textSecondary,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: _isDesktopFilterExpanded
                  ? Column(
                      key: const ValueKey('desktop_filter_list'),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 4, 10, 6),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Filtrar por Facultad',
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w700,
                                    color: textSecondary,
                                  ),
                                ),
                              ),
                              if (_hasActivePreferences) ...[
                                const SizedBox(width: 6),
                                TextButton(
                                  style: TextButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 2,
                                    ),
                                    minimumSize: Size.zero,
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  onPressed: () {
                                    setState(() => _selectedFacultad = 'todas');
                                    _loadGroups();
                                  },
                                  child: Text(
                                    'Restablecer',
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      color: isDark
                                          ? const Color(0xFFF87171)
                                          : const Color(0xFFEF4444),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        Expanded(
                          child: ListView.builder(
                            padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                            itemCount: USACConstants.facultades.length,
                            itemBuilder: (ctx, i) {
                              final fac = USACConstants.facultades[i];
                              final facId = fac['id'].toString();
                              final facName = fac['nombre'].toString();
                              final isSelected = _selectedFacultad == facId;
                              final activeBg = isDark
                                  ? ZanateColors.zanateEyeYellow
                                      .withValues(alpha: 0.20)
                                  : ZanateColors.zanateEyeYellow
                                      .withValues(alpha: 0.28);

                              return Padding(
                                padding: const EdgeInsets.only(bottom: 3),
                                child: Material(
                                  color: isSelected
                                      ? activeBg
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(10),
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(10),
                                    onTap: () {
                                      setState(() => _selectedFacultad = facId);
                                      _loadGroups();
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 8,
                                      ),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              facName,
                                              style: TextStyle(
                                                fontSize: 12.5,
                                                fontWeight: isSelected
                                                    ? FontWeight.w700
                                                    : FontWeight.w500,
                                                color: isSelected
                                                    ? textPrimary
                                                    : textSecondary,
                                              ),
                                            ),
                                          ),
                                          if (isSelected) ...[
                                            const SizedBox(width: 6),
                                            Icon(
                                              PhosphorIconsBold.check,
                                              size: 14,
                                              color: isDark
                                                  ? ZanateColors.zanateEyeYellow
                                                  : ZanateColors.zanateBlack,
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    )
                  : const SizedBox.shrink(key: ValueKey('desktop_filter_empty')),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: ZanateColors.bg(isDark),
              border: Border(top: BorderSide(color: borderColor, width: 0.8)),
            ),
            padding: const EdgeInsets.all(10),
            child: Tooltip(
              message: 'Configuración y Perfil',
              child: Material(
                color: ZanateColors.surface(isDark),
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => SettingsScreen.show(
                    context,
                    activeAlias: widget.activeAlias,
                    onAliasChanged: widget.onAliasChanged,
                    onToggleTheme: widget.onToggleTheme,
                  ),
                  child: Container(
                    height: 40,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: borderColor, width: 0.9),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          PhosphorIconsRegular.gear,
                          size: 18,
                          color: textPrimary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Configuración',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: textPrimary,
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
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isDesktop = Responsive.isDesktop(context);
    final titleText = widget.activeChannelName != null
        ? '#${widget.activeChannelName}'
        : 'Grupos de Estudio';

    if (isDesktop) {
      return Scaffold(
        backgroundColor: ZanateColors.bg(isDark),
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildDesktopSidebar(isDark),
            Expanded(
              child: Column(
                children: [
                  _buildDesktopHeader(isDark, titleText),
                  if (_loadError != null && _groups.isNotEmpty) ...[
                    _buildLoadError(),
                  ],
                  Expanded(
                    child: RefreshIndicator(
                      color: ZanateColors.focusBorder(isDark),
                      backgroundColor: ZanateColors.card(isDark),
                      onRefresh: () => _loadGroups(forceRefresh: true),
                      child: _buildGroupsFeed(isDark),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        floatingActionButton: null,
      );
    }

    return Scaffold(
      backgroundColor: ZanateColors.bg(isDark),
      body: Column(
        children: [
          // 1. Zanate Top Header
          _buildSquaredHeader(isDark, titleText),

          // 2. Zanate Search & Preference Bar
          _buildSquaredSearchBar(isDark),

          if (_loadError != null && _groups.isNotEmpty) ...[
            _buildLoadError(),
          ],

          // 3. Feed
          Expanded(
            child: RefreshIndicator(
              color: ZanateColors.focusBorder(isDark),
              backgroundColor: ZanateColors.card(isDark),
              onRefresh: () => _loadGroups(forceRefresh: true),
              child: _buildGroupsFeed(isDark),
            ),
          ),
        ],
      ),
      floatingActionButton: null,
    );
  }
}
