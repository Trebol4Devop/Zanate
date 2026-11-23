import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import '../../../core/constants/anonymous_aliases.dart';
import '../../../core/constants/zanate_colors.dart';
import '../../../core/services/profile_service.dart';

class AliasModal extends StatefulWidget {
  final String currentAlias;
  final Function(String newAlias) onAliasSaved;

  const AliasModal({
    super.key,
    required this.currentAlias,
    required this.onAliasSaved,
  });

  static Future<void> show(
    BuildContext context, {
    required String currentAlias,
    required Function(String) onSaved,
  }) {
    return showDialog(
      context: context,
      builder: (ctx) =>
          AliasModal(currentAlias: currentAlias, onAliasSaved: onSaved),
    );
  }

  @override
  State<AliasModal> createState() => _AliasModalState();
}

class _AliasModalState extends State<AliasModal> {
  late final TextEditingController _controller;
  bool _isSaving = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.currentAlias);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _generateRandomAlias() {
    setState(() {
      _controller.text = AnonymousAliasGenerator.generate();
      _errorText = null;
    });
  }

  Future<void> _save() async {
    if (_isSaving) return;

    setState(() {
      _isSaving = true;
      _errorText = null;
    });

    try {
      final saved = await ProfileService.saveAccountAlias(_controller.text);
      widget.onAliasSaved(saved);
      if (mounted) Navigator.of(context).pop();
    } on AliasException catch (e) {
      if (mounted) {
        setState(() {
          _isSaving = false;
          _errorText = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isSaving = false;
          _errorText = 'No se pudo guardar el alias en este momento.';
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
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: ZanateColors.zanateEyeYellow.withValues(
                        alpha: 0.22,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      PhosphorIconsBold.userCircle,
                      color: isDark
                          ? ZanateColors.zanateEyeYellow
                          : ZanateColors.zanateBlack,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Tu Seudónimo Estudiantil',
                          style: GoogleFonts.outfit(
                            fontWeight: FontWeight.w700,
                            fontSize: 18,
                            letterSpacing: -0.2,
                            color: titleColor,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Aparece al publicar en el foro y compartir grupos',
                          style: TextStyle(fontSize: 12, color: subtleColor),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: ZanateColors.zanateEyeYellow,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(height: 18),
              TextField(
                controller: _controller,
                enabled: !_isSaving,
                maxLength: AnonymousAliasGenerator.maxAliasLength,
                textInputAction: TextInputAction.done,
                onChanged: (_) {
                  if (_errorText != null) {
                    setState(() => _errorText = null);
                  }
                },
                onSubmitted: (_) => _save(),
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: titleColor,
                ),
                decoration: InputDecoration(
                  labelText: 'Alias único',
                  hintText: 'Ej. Anonymus',
                  errorText: _errorText,
                  labelStyle: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: ZanateColors.mutedText,
                  ),
                  floatingLabelStyle: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: titleColor,
                  ),
                  filled: true,
                  fillColor: ZanateColors.surface(isDark),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: borderColor, width: 1.2),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: borderColor, width: 1.2),
                  ),
                  prefixIcon: Icon(
                    PhosphorIconsRegular.user,
                    size: 20,
                    color: subtleColor,
                  ),
                  suffixIcon: IconButton(
                    icon: Icon(
                      PhosphorIconsRegular.diceFive,
                      size: 20,
                      color: titleColor,
                    ),
                    tooltip: 'Generar alias anónimo',
                    onPressed: _isSaving ? null : _generateRandomAlias,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Elige cualquier nombre único para tu cuenta. Nadie más podrá usar el mismo alias.',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 11.5,
                  height: 1.35,
                  color: subtleColor,
                ),
              ),
              const SizedBox(height: 20),
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
                      onPressed: _isSaving
                          ? null
                          : () => Navigator.of(context).pop(),
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
                      onPressed: _isSaving ? null : _save,
                      child: _isSaving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text(
                              'Guardar Alias',
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
