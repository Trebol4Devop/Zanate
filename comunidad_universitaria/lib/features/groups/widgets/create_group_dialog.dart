import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import '../../../core/constants/zanate_colors.dart';
import '../../../core/config/supabase_config.dart';
import '../../../core/constants/categories.dart';
import '../../../core/models/whatsapp_group.dart';
import '../../../core/services/groups_service.dart';
import '../../../core/services/publish_cooldown_service.dart';
import '../../../core/services/storage_service.dart';
import '../../../core/services/supabase_service.dart';
import '../../../core/utils/responsive.dart';
import '../../../core/utils/square_image_crop.dart';
import '../../shared/widgets/auth_modal.dart';
import '../../shared/widgets/square_image_crop_dialog.dart';

class CreateGroupDialog extends StatefulWidget {
  final String activeAlias;
  final Function(String newAlias) onAliasChanged;
  final Function(WhatsAppGroup newGroup) onGroupCreated;
  final String? initialFacultad;
  final String? initialCarrera;

  const CreateGroupDialog({
    super.key,
    required this.activeAlias,
    required this.onAliasChanged,
    required this.onGroupCreated,
    this.initialFacultad,
    this.initialCarrera,
  });

  static Future<void> show(
    BuildContext context, {
    required String activeAlias,
    required Function(String) onAliasChanged,
    required Function(WhatsAppGroup) onGroupCreated,
    String? initialFacultad,
    String? initialCarrera,
  }) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (ctx) => CreateGroupDialog(
          activeAlias: activeAlias,
          onAliasChanged: onAliasChanged,
          onGroupCreated: onGroupCreated,
          initialFacultad: initialFacultad,
          initialCarrera: initialCarrera,
        ),
      ),
    );
  }

  @override
  State<CreateGroupDialog> createState() => _CreateGroupDialogState();
}

class _CreateGroupDialogState extends State<CreateGroupDialog> {
  final _formKey = GlobalKey<FormState>();
  final _cursoController = TextEditingController();
  final _generalTitleController = TextEditingController();
  final _linkController = TextEditingController();
  final _descriptionController = TextEditingController();

  PickedImageData? _originalPendingImage;
  PickedImageData? _pendingImage;
  bool _isPickingImage = false;

  String _groupType =
      'curso'; // 'curso', 'objetos_perdidos', 'comunidad', 'deportes', 'avisos', 'otro'
  String _selectedFacultad = '08';
  String _selectedCarrera = 'todas';
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialFacultad != null && widget.initialFacultad!.isNotEmpty) {
      final validFacultad = USACConstants.facultades.any(
        (f) => f['id']?.toString() == widget.initialFacultad,
      );
      if (validFacultad) {
        _selectedFacultad = widget.initialFacultad!;
      }
    }
    if (widget.initialCarrera != null && widget.initialCarrera!.isNotEmpty) {
      final validCarrera = _availableCarreras.any(
        (c) => c['id']?.toString() == widget.initialCarrera,
      );
      if (validCarrera) {
        _selectedCarrera = widget.initialCarrera!;
      }
    }
  }

  @override
  void dispose() {
    _cursoController.dispose();
    _generalTitleController.dispose();
    _linkController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> get _availableCarreras {
    final fac = USACConstants.facultades.firstWhere(
      (f) => f['id'] == _selectedFacultad,
      orElse: () => USACConstants.facultades.first,
    );
    final list = fac['carreras'] as List<dynamic>? ?? [];
    return list.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  Future<void> _pickImage() async {
    setState(() => _isPickingImage = true);

    try {
      final picked = await StorageService.pickSingleImageWithPreview();
      if (picked == null || !mounted) return;

      final dims = SquareImageCrop.readImageDimensions(picked.bytes);
      PickedImageData finalImage = picked;

      if (dims != null && dims.width != dims.height) {
        final croppedBytes = await SquareImageCropDialog.show(
          context,
          imageBytes: picked.bytes,
          imageWidth: dims.width,
          imageHeight: dims.height,
        );
        if (croppedBytes == null || !mounted) return;
        finalImage = PickedImageData(
          file: picked.file,
          bytes: croppedBytes,
          name: picked.name,
        );
      }

      if (mounted) {
        setState(() {
          _originalPendingImage = picked;
          _pendingImage = finalImage;
        });
      }
    } on StorageUploadException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No se pudo cargar la imagen.')),
        );
      }
    } finally {
      if (mounted) setState(() => _isPickingImage = false);
    }
  }

  Future<void> _recropPendingImage() async {
    final source = _originalPendingImage ?? _pendingImage;
    if (source == null || _isSubmitting) return;

    final dims = SquareImageCrop.readImageDimensions(source.bytes);
    if (dims == null) return;

    final croppedBytes = await SquareImageCropDialog.show(
      context,
      imageBytes: source.bytes,
      imageWidth: dims.width,
      imageHeight: dims.height,
    );
    if (croppedBytes == null || !mounted) return;

    setState(() {
      _pendingImage = PickedImageData(
        file: source.file,
        bytes: croppedBytes,
        name: source.name,
      );
    });
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    if (SupabaseConfig.isConfigured && !SupabaseService.isAuthenticated) {
      AuthModal.show(
        context,
        title: 'Inicia Sesión para Compartir',
        subtitle:
            'Para compartir enlaces de grupos estudiantiles, debes iniciar sesión.',
        onAuthenticated: () => _submit(),
      );
      return;
    }

    final cooldownRemaining = await PublishCooldownService.remainingCooldown(
      'group',
    );
    if (cooldownRemaining != null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              PublishCooldownService.formatCooldownMessage(cooldownRemaining),
            ),
          ),
        );
      }
      return;
    }

    setState(() => _isSubmitting = true);

    String title;
    String cursoName;
    String sectionName;

    if (_groupType == 'curso') {
      cursoName = _cursoController.text.trim();
      sectionName = 'General';
      title = cursoName;
    } else {
      title = _generalTitleController.text.trim();
      switch (_groupType) {
        case 'objetos_perdidos':
          cursoName = 'Objetos Perdidos & Hallazgos';
          break;
        case 'comunidad':
          cursoName = 'Comunidad de Facultad / Sede';
          break;
        case 'deportes':
          cursoName = 'Deportes & Actividades';
          break;
        case 'avisos':
          cursoName = 'Avisos & Organización';
          break;
        default:
          cursoName = 'Interés General';
      }
      sectionName = 'Comunidad Abierta';
    }

    final carreraToSave =
        (_selectedCarrera == 'todas' && _selectedFacultad != 'todas')
        ? '${_selectedFacultad}_todas'
        : _selectedCarrera;

    try {
      String? uploadedImageUrl;
      if (_pendingImage != null) {
        uploadedImageUrl = await StorageService.uploadImageFile(
          _pendingImage!.file,
          folder: 'groups',
          preloadedBytes: _pendingImage!.bytes,
          throwOnError: true,
        );
      }

      final created = await GroupsService.createGroup(
        title: title,
        carrera: carreraToSave,
        curso: cursoName,
        section: sectionName,
        link: _linkController.text.trim(),
        description: _descriptionController.text.trim(),
        authorAlias: widget.activeAlias,
        imageUrl: uploadedImageUrl,
      );

      if (mounted) {
        setState(() => _isSubmitting = false);
        if (created != null) {
          widget.onGroupCreated(created);
          Navigator.of(context).pop();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Grupo estudiantil compartido con éxito.'),
              backgroundColor: ZanateColors.zanateBlack,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSubmitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e
                  .toString()
                  .replaceAll('Exception: ', '')
                  .replaceAll('AuthException: ', ''),
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  InputDecoration _zanateInput(
    bool isDark, {
    required String labelText,
    String? hintText,
    Widget? prefixIcon,
  }) {
    final borderColor = ZanateColors.border(isDark);
    final focusColor = ZanateColors.focusBorder(isDark);
    return InputDecoration(
      labelText: labelText,
      hintText: hintText,
      prefixIcon: prefixIcon,
      filled: true,
      fillColor: ZanateColors.surface(isDark),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: borderColor, width: 1.2),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: borderColor, width: 1.2),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: focusColor, width: 1.6),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final isMobile = Responsive.isMobile(context);
    final primaryTextColor = ZanateColors.textPrimary(isDark);
    final secondaryTextColor = ZanateColors.textMuted(isDark);
    final borderColor = ZanateColors.border(isDark);

    final scaffoldBg = ZanateColors.bg(isDark);

    Widget content = Form(
      key: _formKey,
      child: SingleChildScrollView(
        padding: EdgeInsets.symmetric(
          horizontal: isMobile ? 18 : 28,
          vertical: isMobile ? 16 : 24,
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
              // Group Type Selector
              DropdownButtonFormField<String>(
                initialValue: _groupType,
                isExpanded: true,
                itemHeight: null,
                dropdownColor: ZanateColors.card(isDark),
                decoration: _zanateInput(
                  isDark,
                  labelText: 'Tipo de Grupo / Propósito',
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'curso',
                    child: Text(
                      'Curso Académico',
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'objetos_perdidos',
                    child: Text(
                      'Objetos Perdidos & Hallazgos',
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'comunidad',
                    child: Text(
                      'Comunidad de Facultad / Sede',
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'deportes',
                    child: Text(
                      'Deportes & Actividades Extracurriculares',
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'avisos',
                    child: Text(
                      'Avisos & Organización Estudiantil',
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'otro',
                    child: Text(
                      'Interés General / Otro',
                    ),
                  ),
                ],
                onChanged: (val) => setState(() => _groupType = val ?? 'curso'),
              ),

              const SizedBox(height: 12),

              // Faculty and Career (Always helpful for contextualizing)
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  SizedBox(
                    width: isMobile ? double.infinity : 240,
                    child: DropdownButtonFormField<String>(
                      initialValue: _selectedFacultad,
                      isExpanded: true,
                      itemHeight: null,
                      dropdownColor: ZanateColors.card(isDark),
                      decoration: _zanateInput(
                        isDark,
                        labelText: 'Facultad / Unidad',
                      ),
                      items: USACConstants.facultades
                          .map(
                            (f) => DropdownMenuItem<String>(
                              value: f['id'].toString(),
                              child: Text(
                                f['nombre'].toString(),
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (val) {
                        setState(() {
                          _selectedFacultad = val ?? '08';
                          _selectedCarrera = 'todas';
                        });
                      },
                    ),
                  ),
                  SizedBox(
                    width: isMobile ? double.infinity : 240,
                    child: DropdownButtonFormField<String>(
                      key: ValueKey('carrera_$_selectedFacultad'),
                      initialValue: _selectedCarrera,
                      isExpanded: true,
                      itemHeight: null,
                      dropdownColor: ZanateColors.card(isDark),
                      decoration: _zanateInput(
                        isDark,
                        labelText: 'Carrera',
                      ),
                      items: _availableCarreras
                          .map(
                            (c) => DropdownMenuItem<String>(
                              value: c['id'].toString(),
                              child: Text(
                                c['nombre'].toString(),
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (val) =>
                          setState(() => _selectedCarrera = val ?? 'todas'),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              // Dynamic fields based on group type
              if (_groupType == 'curso') ...[
                // Course Name (no section field)
                TextFormField(
                  controller: _cursoController,
                  decoration: _zanateInput(
                    isDark,
                    labelText: 'Nombre del Curso',
                    hintText: 'Ej. Matemática Básica 1',
                  ),
                  validator: (val) => (val == null || val.trim().isEmpty)
                      ? 'Ingresa el nombre del curso'
                      : null,
                ),
              ] else ...[
                // General purpose title
                TextFormField(
                  controller: _generalTitleController,
                  decoration: _zanateInput(
                    isDark,
                    labelText: _groupType == 'objetos_perdidos'
                        ? 'Título del Grupo de Objetos Perdidos'
                        : 'Nombre o Propósito del Grupo',
                    hintText: _groupType == 'objetos_perdidos'
                        ? 'Ej. Objetos Perdidos Campus Central / CUM'
                        : 'Ej. Club de Ajedrez USAC / Comunidad Primer Ingreso',
                  ),
                  validator: (val) => (val == null || val.trim().length < 4)
                      ? 'Ingresa un nombre claro para el grupo'
                      : null,
                ),
              ],

              const SizedBox(height: 12),

              // Invitation Link
              TextFormField(
                controller: _linkController,
                decoration: _zanateInput(
                  isDark,
                  labelText: 'Enlace de Invitación',
                  hintText:
                      'https://chat.whatsapp.com/..., https://t.me/..., https://discord.gg/...',
                  prefixIcon: const Padding(
                    padding: EdgeInsets.all(12),
                    child: PhosphorIcon(PhosphorIconsRegular.link, size: 20),
                  ),
                ),
                validator: (val) {
                  if (val == null || val.trim().isEmpty) {
                    return 'Pega el enlace de invitación del grupo.';
                  }
                  final trimmed = val.trim();
                  final lower = trimmed.toLowerCase();
                  if (!lower.startsWith('http://') &&
                      !lower.startsWith('https://')) {
                    return 'El enlace debe comenzar con https://';
                  }
                  if (WhatsAppGroup.detectPlatformFromLink(trimmed) == null) {
                    return 'Solo se permiten enlaces de WhatsApp, Telegram o Discord.';
                  }
                  return null;
                },
              ),

              const SizedBox(height: 12),

              // Description
              TextFormField(
                controller: _descriptionController,
                maxLines: 2,
                decoration: _zanateInput(
                  isDark,
                  labelText: 'Descripción, reglas o notas',
                  hintText:
                      'Ej. Grupo para compartir reportes de objetos extraviados / tareas con el Ing. Morales.',
                ),
              ),

              const SizedBox(height: 14),

              // Image Upload to Supabase Storage
              Text(
                'Imagen o Logotipo del Grupo',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 6),

              if (_pendingImage != null) ...[
                SizedBox(
                  width: double.infinity,
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(14),
                            child: Container(
                              width: double.infinity,
                              height: double.infinity,
                              color: ZanateColors.surface(isDark),
                              child: Image.memory(
                                _pendingImage!.bytes,
                                width: double.infinity,
                                height: double.infinity,
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          bottom: 8,
                          left: 8,
                          child: InkWell(
                            onTap: _isSubmitting ? null : _recropPendingImage,
                            borderRadius: BorderRadius.circular(10),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.72),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  PhosphorIcon(
                                    PhosphorIconsRegular.crop,
                                    size: 14,
                                    color: Colors.white,
                                  ),
                                  SizedBox(width: 5),
                                  Text(
                                    'Recortar',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          top: 8,
                          right: 8,
                          child: InkWell(
                            onTap: _isSubmitting
                                ? null
                                : () => setState(() {
                                    _originalPendingImage = null;
                                    _pendingImage = null;
                                  }),
                            child: Container(
                              padding: const EdgeInsets.all(5),
                              decoration: const BoxDecoration(
                                color: Colors.black54,
                                shape: BoxShape.circle,
                              ),
                              child: const PhosphorIcon(
                                PhosphorIconsRegular.x,
                                size: 16,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ] else ...[
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: primaryTextColor,
                    backgroundColor: ZanateColors.surface(isDark),
                    side: BorderSide(color: borderColor, width: 1.2),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                  ),
                  onPressed: (_isPickingImage || _isSubmitting)
                      ? null
                      : _pickImage,
                  icon: _isPickingImage
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : PhosphorIcon(
                          PhosphorIconsRegular.image,
                          size: 18,
                          color: primaryTextColor,
                        ),
                  label: Text(
                    _isPickingImage ? 'Cargando imagen...' : 'Elegir Imagen',
                  ),
                ),
              ],

              const SizedBox(height: 18),

              // Submit Buttons
              Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    TextButton(
                      onPressed: _isSubmitting
                          ? null
                          : () => Navigator.of(context).pop(),
                      style: TextButton.styleFrom(
                        foregroundColor: secondaryTextColor,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        'Cancelar',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isDark
                            ? ZanateColors.zanateEyeYellow
                            : ZanateColors.zanateBlack,
                        foregroundColor: isDark
                            ? ZanateColors.zanateBlack
                            : Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 13,
                        ),
                      ),
                      onPressed: _isSubmitting ? null : _submit,
                      icon: _isSubmitting
                          ? SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: isDark
                                    ? ZanateColors.zanateBlack
                                    : Colors.white,
                              ),
                            )
                          : const PhosphorIcon(
                              PhosphorIconsBold.paperPlaneTilt,
                              size: 16,
                            ),
                      label: Text(
                        _isSubmitting ? 'Guardando...' : 'Compartir Grupo',
                        style: const TextStyle(fontWeight: FontWeight.w700),
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

    return Scaffold(
      backgroundColor: scaffoldBg,
      appBar: AppBar(
        backgroundColor: scaffoldBg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: PhosphorIcon(
            PhosphorIconsBold.caretLeft,
            color: primaryTextColor,
            size: 22,
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          'Compartir Enlace de Grupo',
          style: GoogleFonts.outfit(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: primaryTextColor,
          ),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, color: borderColor),
        ),
      ),
      body: SafeArea(child: content),
    );
  }
}
