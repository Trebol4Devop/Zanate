import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart' hide DistanceCalculator;
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:usac_campus_map/usac_campus_map.dart';

import '../../../core/constants/categories.dart';
import '../../../core/constants/zanate_colors.dart';
import '../../../core/utils/responsive.dart';
import '../../map/services/map_sync_service.dart';

/// Resultado devuelto al elegir una ubicación en el mapa para filtrar o publicar.
class MarketplaceLocationSelection {
  final String sedeId;
  final String facultadId;
  final String buildingCode;
  final String label;

  const MarketplaceLocationSelection({
    required this.sedeId,
    required this.facultadId,
    required this.buildingCode,
    required this.label,
  });

  static const MarketplaceLocationSelection all = MarketplaceLocationSelection(
    sedeId: 'todas',
    facultadId: 'todas',
    buildingCode: 'todos',
    label: 'Todas las ubicaciones',
  );
}

/// Diálogo interactivo que permite elegir un edificio en el mapa del campus
/// (o una sede departamental) para filtrar o fijar el punto de entrega.
class MarketplaceLocationPickerDialog extends StatefulWidget {
  final String initialSedeId;
  final String initialFacultadId;
  final String initialBuildingCode;
  final bool allowClearAll;

  const MarketplaceLocationPickerDialog({
    super.key,
    required this.initialSedeId,
    required this.initialFacultadId,
    required this.initialBuildingCode,
    this.allowClearAll = true,
  });

  static Future<MarketplaceLocationSelection?> show(
    BuildContext context, {
    required String initialSedeId,
    required String initialFacultadId,
    required String initialBuildingCode,
    bool allowClearAll = true,
  }) {
    return showDialog<MarketplaceLocationSelection>(
      context: context,
      builder: (ctx) => MarketplaceLocationPickerDialog(
        initialSedeId: initialSedeId,
        initialFacultadId: initialFacultadId,
        initialBuildingCode: initialBuildingCode,
        allowClearAll: allowClearAll,
      ),
    );
  }

  @override
  State<MarketplaceLocationPickerDialog> createState() =>
      _MarketplaceLocationPickerDialogState();
}

class _MarketplaceLocationPickerDialogState
    extends State<MarketplaceLocationPickerDialog> {
  late final UsacCampusMapController _mapController;
  final TextEditingController _searchController = TextEditingController();

  late String _sedeId;
  late String _facultadId;
  late String _buildingCode;
  String _selectedLabel = '';
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _sedeId = widget.initialSedeId;
    _facultadId = widget.initialFacultadId;
    _buildingCode = widget.initialBuildingCode;
    _selectedLabel = _buildLabel(_sedeId, _buildingCode);
    _mapController = UsacCampusMapController();
    _initMapData();
  }

  Future<void> _initMapData() async {
    try {
      await MapSyncService.loadRepositoryData(_mapController.repository);
      if (mounted) {
        setState(() {});
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _searchController.dispose();
    _mapController.dispose();
    super.dispose();
  }

  String _buildLabel(String sedeId, String buildingCode) {
    if (sedeId == 'todas' && buildingCode == 'todos') {
      return 'Todas las ubicaciones';
    }
    if (buildingCode != 'todos' && buildingCode.isNotEmpty) {
      final match = USACConstants.campusBuildings.where(
        (b) => b['building_code']?.toString() == buildingCode,
      );
      if (match.isNotEmpty) {
        return '${match.first['building_code']} · ${match.first['nombre']}';
      }
      return buildingCode;
    }
    final sedeMatch = USACConstants.sedes.where((s) => s['id'] == sedeId);
    if (sedeMatch.isNotEmpty) {
      return sedeMatch.first['nombre'] ?? sedeId;
    }
    return 'Campus Central';
  }

  void _selectCampusBuilding(CampusBuilding building) {
    final code = building.code.isNotEmpty ? building.code : building.name;
    setState(() {
      _sedeId = 'central';
      _facultadId = 'todas';
      _buildingCode = code;
      _selectedLabel = '$code · ${building.name}';
    });
  }

  void _selectCatalogLocation(Map<String, dynamic> b) {
    final code = b['building_code']?.toString() ?? 'T-3';
    final sede = b['sede_id']?.toString() ?? 'central';
    final name = b['nombre']?.toString() ?? code;
    final lat = b['latitude'];
    final lng = b['longitude'];

    setState(() {
      _sedeId = sede;
      _facultadId = 'todas';
      _buildingCode = code;
      _selectedLabel = '$code · $name';
    });

    if (lat is num && lng is num) {
      try {
        _mapController.mapController.move(
          LatLng(lat.toDouble(), lng.toDouble()),
          17.5,
        );
      } catch (_) {}
    }
  }

  void _selectSede(Map<String, String> sede) {
    final id = sede['id'] ?? 'central';
    setState(() {
      _sedeId = id;
      _facultadId = 'todas';
      _buildingCode = 'todos';
      _selectedLabel = sede['nombre'] ?? id;
    });
  }

  void _confirmSelection() {
    Navigator.of(context).pop(
      MarketplaceLocationSelection(
        sedeId: _sedeId,
        facultadId: _facultadId,
        buildingCode: _buildingCode,
        label: _selectedLabel.isNotEmpty
            ? _selectedLabel
            : _buildLabel(_sedeId, _buildingCode),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isMobile = Responsive.isMobile(context);
    final textPrimary = ZanateColors.textPrimary(isDark);
    final textMuted = ZanateColors.textMuted(isDark);
    final borderColor = ZanateColors.border(isDark);
    final screenSize = MediaQuery.of(context).size;

    final q = _searchQuery.trim().toLowerCase();
    final filteredBuildings = USACConstants.campusBuildings.where((b) {
      if (q.isEmpty) return true;
      final code = (b['building_code']?.toString() ?? '').toLowerCase();
      final name = (b['nombre']?.toString() ?? '').toLowerCase();
      return code.contains(q) || name.contains(q);
    }).toList();

    final filteredSedes = USACConstants.sedes
        .where((s) => s['id'] != 'todas')
        .where((s) {
          if (q.isEmpty) return true;
          final name = (s['nombre'] ?? '').toLowerCase();
          final dept = (s['departamento'] ?? '').toLowerCase();
          return name.contains(q) || dept.contains(q);
        })
        .toList();

    final mapWidget = ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: borderColor),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Stack(
          children: [
            UsacCampusMap(
              controller: _mapController,
              theme: UsacMapTheme(
                primaryColor: isDark
                    ? ZanateColors.zanateEyeYellow
                    : ZanateColors.zanateBlack,
                accentColor: ZanateColors.zanateEyeYellow,
              ),
              showControls: true,
              onBuildingSelected: (building) {
                if (building != null) {
                  _selectCampusBuilding(building);
                }
              },
            ),
            Positioned(
              left: 10,
              right: 10,
              top: 10,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: ZanateColors.card(isDark).withValues(alpha: 0.94),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: borderColor),
                ),
                child: Row(
                  children: [
                    Icon(
                      PhosphorIconsFill.mapPin,
                      size: 16,
                      color: isDark
                          ? ZanateColors.zanateEyeYellow
                          : ZanateColors.zanateBlack,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _selectedLabel.isNotEmpty
                            ? _selectedLabel
                            : 'Toca un edificio en el mapa o elige en la lista',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );

    final listWidget = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _searchController,
          onChanged: (val) => setState(() => _searchQuery = val),
          style: TextStyle(fontSize: 13, color: textPrimary),
          decoration: InputDecoration(
            hintText: 'Buscar edificio o sede...',
            hintStyle: TextStyle(fontSize: 12.5, color: textMuted),
            prefixIcon: Icon(
              PhosphorIconsRegular.magnifyingGlass,
              size: 17,
              color: textMuted,
            ),
            filled: true,
            fillColor: ZanateColors.surface(isDark),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: borderColor),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: borderColor),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: ListView(
            children: [
              if (widget.allowClearAll)
                ListTile(
                  dense: true,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  selected: _sedeId == 'todas' && _buildingCode == 'todos',
                  selectedTileColor: ZanateColors.zanateEyeYellow
                      .withValues(alpha: 0.22),
                  leading: const Icon(PhosphorIconsRegular.globe, size: 18),
                  title: const Text(
                    'Todas las ubicaciones',
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
                  ),
                  onTap: () {
                    Navigator.of(context).pop(MarketplaceLocationSelection.all);
                  },
                ),
              if (filteredBuildings.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                  child: Text(
                    'EDIFICIOS Y PUNTOS DEL CAMPUS',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.6,
                      color: textMuted,
                    ),
                  ),
                ),
                for (final b in filteredBuildings)
                  ListTile(
                    dense: true,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    selected:
                        _buildingCode == b['building_code']?.toString(),
                    selectedTileColor: ZanateColors.zanateEyeYellow
                        .withValues(alpha: 0.22),
                    leading: const Icon(
                      PhosphorIconsRegular.buildings,
                      size: 17,
                    ),
                    title: Text(
                      '${b['building_code']} · ${b['nombre']}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: textPrimary,
                      ),
                    ),
                    onTap: () => _selectCatalogLocation(b),
                  ),
              ],
              if (filteredSedes.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
                  child: Text(
                    'SEDES Y CENTROS UNIVERSITARIOS',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.6,
                      color: textMuted,
                    ),
                  ),
                ),
                for (final s in filteredSedes)
                  ListTile(
                    dense: true,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    selected: _sedeId == s['id'] && _buildingCode == 'todos',
                    selectedTileColor: ZanateColors.zanateEyeYellow
                        .withValues(alpha: 0.22),
                    leading: const Icon(PhosphorIconsRegular.mapPin, size: 17),
                    title: Text(
                      s['nombre'] ?? '',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: textPrimary,
                      ),
                    ),
                    onTap: () => _selectSede(s),
                  ),
              ],
            ],
          ),
        ),
      ],
    );

    return Dialog(
      insetPadding: EdgeInsets.symmetric(
        horizontal: isMobile ? 12 : 28,
        vertical: isMobile ? 16 : 24,
      ),
      backgroundColor: ZanateColors.bg(isDark),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: borderColor),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 920,
          maxHeight: screenSize.height * 0.86,
        ),
        child: Padding(
          padding: EdgeInsets.all(isMobile ? 14 : 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    PhosphorIconsFill.mapTrifold,
                    size: 22,
                    color: isDark
                        ? ZanateColors.zanateEyeYellow
                        : ZanateColors.zanateBlack,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Elegir ubicación en el mapa',
                          style: GoogleFonts.outfit(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: textPrimary,
                          ),
                        ),
                        Text(
                          widget.allowClearAll
                              ? 'Selecciona un edificio o sede para filtrar publicaciones'
                              : 'Toca un edificio en el mapa o selecciona una sede de entrega',
                          style: TextStyle(fontSize: 12, color: textMuted),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(PhosphorIconsRegular.x, color: textMuted),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Expanded(
                child: isMobile
                    ? Column(
                        children: [
                          SizedBox(height: 240, child: mapWidget),
                          const SizedBox(height: 12),
                          Expanded(child: listWidget),
                        ],
                      )
                    : Row(
                        children: [
                          Expanded(flex: 3, child: mapWidget),
                          const SizedBox(width: 14),
                          Expanded(flex: 2, child: listWidget),
                        ],
                      ),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(
                      'Cancelar',
                      style: TextStyle(color: textMuted),
                    ),
                  ),
                  const SizedBox(width: 10),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: ZanateColors.ctaBg(isDark),
                      foregroundColor: ZanateColors.ctaFg(isDark),
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 12,
                      ),
                    ),
                    onPressed: _confirmSelection,
                    icon: const Icon(PhosphorIconsBold.check, size: 16),
                    label: const Text(
                      'Confirmar ubicación',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
