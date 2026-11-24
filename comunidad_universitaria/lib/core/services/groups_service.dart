import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../features/forum/models/discord_forum_models.dart';
import '../config/supabase_config.dart';
import '../models/whatsapp_group.dart';
import '../utils/input_sanitizer.dart';
import 'cache_service.dart';
import 'forum_service.dart';
import 'local_storage_service.dart';
import 'publish_cooldown_service.dart';
import 'supabase_service.dart';

class GroupsService {
  static const String _groupColumns =
      'id, title, carrera, curso, section, link, description, author_alias, '
      'upvotes, reported_count, shares_count, created_at, image_url, moderation_status, '
      'moderation_label, moderation_confidence, moderation_reason, moderated_at, '
      'moderated_by, platform, updated_at, deleted_at, is_legal_hold';

  static const String _safeGroupColumns = '$_groupColumns, is_mine';

  static const String _cacheNamespace = 'student_groups';

  static const Map<String, List<String>> _facultyAliases = {
    '08': [
      'sistemas',
      'civil',
      'industrial',
      'mecanica',
      'quimica',
      'electronica',
      'electrica',
      'ambiental',
      'ingenieria',
      'fi',
      'area_comun',
      'basicas',
    ],
    '05': ['medicina', 'salud', 'medicas', 'cirujano', 'cum'],
    '04': ['derecho', 'juridicas', 'leyes', 'sociales'],
    '03': ['economicas', 'auditoria', 'administracion', 'economia'],
    '02': ['arquitectura', 'diseno', 'farq'],
    '01': ['agronomia', 'agricola', 'fausac'],
    '06': ['farmacia', 'bioquimica', 'quimicas', 'farmaceutica'],
    '77': [
      'humanidades',
      'pedagogia',
      'profesorado',
      'filosofia',
      'letras',
      'fahusac',
    ],
    '07': [
      'humanidades',
      'pedagogia',
      'profesorado',
      'filosofia',
      'letras',
      'fahusac',
    ],
    '09': ['odontologia', 'dental', 'fousac'],
    '10': ['veterinaria', 'zootecnia', 'fmvz'],
    'area_comun': ['area_comun', 'basicas'],
  };

  static Future<List<WhatsAppGroup>> fetchGroups({
    String facultad = 'todas',
    String carrera = 'todas',
    String searchQuery = '',
    bool forceRefresh = false,
  }) async {
    final isDefaultQuery =
        facultad == 'todas' && carrera == 'todas' && searchQuery.trim().isEmpty;
    final cacheKey = CacheService.buildKey({
      'user': SupabaseService.currentUserId ?? 'anon',
      if (facultad != 'todas') 'facultad': facultad,
      'carrera': carrera,
      'search': searchQuery.trim().toLowerCase(),
    });

    final cached = forceRefresh
        ? null
        : CacheService.get<List<WhatsAppGroup>>(_cacheNamespace, cacheKey);
    if (cached != null) return List<WhatsAppGroup>.from(cached);

    if (!SupabaseConfig.isConfigured) {
      throw Exception('La aplicación no está conectada a la base de datos.');
    }

    if (isDefaultQuery && !forceRefresh) {
      final persisted = await _readPersistedGroups(cacheKey);
      if (persisted != null) return persisted;
    }

    try {
      Future<List<dynamic>> queryFromSource(
        String source,
        String columns,
      ) async {
        var query = SupabaseService.client
            .from(source)
            .select(columns)
            .neq('moderation_status', 2);

        if (carrera != 'todas') {
          query = query.eq('carrera', carrera);
        }

        if (searchQuery.trim().isNotEmpty) {
          final q = InputSanitizer.sanitizePostgrestSearch(searchQuery);
          if (q.isNotEmpty) {
            query = query.or(
              'title.ilike.%$q%,curso.ilike.%$q%,description.ilike.%$q%',
            );
          }
        }

        final response = await query
            .order('upvotes', ascending: false)
            .order('created_at', ascending: false);
        return response as List<dynamic>;
      }

      List<dynamic> data;
      try {
        data = await queryFromSource('safe_student_groups', _safeGroupColumns);
      } on PostgrestException catch (e) {
        if (e.code == '42P01' || e.code == '42501' || e.code == '42703') {
          data = await queryFromSource('student_groups', _groupColumns);
        } else {
          rethrow;
        }
      }

      // Get upvotes for current user
      final currentUserId = SupabaseService.currentUserId;
      final Set<String> upvotedGroupIds = {};

      if (currentUserId != null && data.isNotEmpty) {
        final groupIds = data.map((item) => item['id'].toString()).toList();
        final upvotesRes = await SupabaseService.client
            .from('student_group_upvotes')
            .select('group_id')
            .eq('user_id', currentUserId)
            .inFilter('group_id', groupIds);

        for (var item in upvotesRes) {
          upvotedGroupIds.add(item['group_id'].toString());
        }
      }

      // Avatares actuales de los autores desde Supabase (sin exponer user_id)
      final Map<String, ({int color, int icon})> avatarsByGroupId = {};
      if (data.isNotEmpty) {
        try {
          final groupIds = data.map((item) => item['id'].toString()).toList();
          final avatarsRes = await SupabaseService.client.rpc(
            'get_student_groups_avatars',
            params: {'p_group_ids': groupIds},
          );
          if (avatarsRes is List) {
            for (final item in avatarsRes) {
              if (item is! Map) continue;
              final gid = item['group_id']?.toString();
              final colorIdx = item['avatar_color_index'];
              final iconIdx = item['avatar_icon_index'];
              if (gid != null && colorIdx is int && iconIdx is int) {
                avatarsByGroupId[gid] = (color: colorIdx, icon: iconIdx);
              }
            }
          }
        } catch (e) {
          debugPrint('Aviso cargando avatares de grupos: $e');
        }
      }

      int? myColorIndex;
      int? myIconIndex;
      final hasMineGroup = data.any(
        (item) => item is Map && item['is_mine'] == true,
      );
      if (hasMineGroup) {
        try {
          final profile = await LocalStorageService.getUserProfile();
          myColorIndex = profile.avatarColorIndex;
          myIconIndex = profile.avatarIconIndex;
        } catch (_) {}
      }

      var groups = data.map((item) {
        final map = Map<String, dynamic>.from(item);
        final groupId = map['id'].toString();
        final parsed = WhatsAppGroup.fromMap(
          map,
          isUpvotedByMe: upvotedGroupIds.contains(groupId),
        );
        final av = avatarsByGroupId[groupId];
        if (av != null) {
          return parsed.copyWith(
            avatarColorIndex: av.color,
            avatarIconIndex: av.icon,
          );
        }
        if (parsed.isMine && myColorIndex != null && myIconIndex != null) {
          return parsed.copyWith(
            avatarColorIndex: parsed.avatarColorIndex ?? myColorIndex,
            avatarIconIndex: parsed.avatarIconIndex ?? myIconIndex,
          );
        }
        return parsed;
      }).toList();

      if (facultad != 'todas' && carrera == 'todas') {
        final facultyKeywords = _facultyAliases[facultad] ?? [];
        final Set<String> facultyCareerIds = {};
        try {
          final faculties = await ForumService.fetchForumFaculties();
          final matchedFac = faculties.cast<ForumFaculty?>().firstWhere(
            (f) => f?.id == facultad,
            orElse: () => null,
          );
          if (matchedFac != null) {
            for (final c in matchedFac.careers) {
              if (c.id.isNotEmpty && c.id != 'todas') {
                facultyCareerIds.add(c.id.toLowerCase());
              }
            }
          }
        } catch (_) {}

        groups = groups.where((g) {
          final carreraLower = g.carrera.toLowerCase().trim();

          // 1. Coincidencia exacta con los IDs oficiales de carreras de esta facultad
          if (facultyCareerIds.contains(carreraLower)) return true;

          // 2. La carrera inicia con el código de la facultad (ej. 08, 08-01-01, 08_todas, o 77- para Humanidades 07)
          if (g.carrera.startsWith(facultad)) return true;
          if (facultad == '07' && g.carrera.startsWith('77')) return true;

          // 3. Si la carrera coincide con algún alias de la facultad (ej. 'sistemas', 'civil', etc.)
          if (carreraLower.isNotEmpty &&
              carreraLower != 'todas' &&
              facultyKeywords.any(
                (kw) => carreraLower == kw || carreraLower.contains(kw),
              )) {
            return true;
          }

          // 4. Caso especial de Área Común (Ingeniería o general)
          if (carreraLower == 'area_comun' &&
              (facultad == '08' || facultad == 'area_comun')) {
            return true;
          }

          // 5. Si la carrera fue registrada como 'todas' o vacía, SOLO se incluye si su título, curso
          // o descripción menciona explícitamente palabras clave de esta facultad específica.
          if (carreraLower == 'todas' || carreraLower.isEmpty) {
            final searchable = '${g.title} ${g.curso} ${g.description}'
                .toLowerCase();
            return facultyKeywords.any((kw) => searchable.contains(kw));
          }

          return false;
        }).toList();
      }

      CacheService.set(
        _cacheNamespace,
        cacheKey,
        List<WhatsAppGroup>.from(groups),
      );
      if (isDefaultQuery) {
        await CacheService.setPersisted(
          _cacheNamespace,
          cacheKey,
          groups.map(_groupToCacheMap).toList(),
        );
      }
      return groups;
    } catch (e) {
      debugPrint('Error al obtener grupos estudiantiles: $e');
      if (isDefaultQuery) {
        final persisted = await _readPersistedGroups(
          cacheKey,
          allowStale: true,
        );
        if (persisted != null) return persisted;
      }
      rethrow;
    }
  }

  /// Lee la primera página persistida (solo consultas por defecto).
  static Future<List<WhatsAppGroup>?> _readPersistedGroups(
    String cacheKey, {
    bool allowStale = false,
  }) {
    return CacheService.getPersisted<List<WhatsAppGroup>>(
      _cacheNamespace,
      cacheKey,
      (data) {
        if (data is! List) {
          throw const FormatException('Caché de grupos inválida');
        }
        return data
            .whereType<Map>()
            .map((item) => _groupFromCacheMap(Map<String, dynamic>.from(item)))
            .toList();
      },
      allowStale: allowStale,
    );
  }

  static Map<String, dynamic> _groupToCacheMap(WhatsAppGroup group) {
    final map = group.toInsertMap();
    map.remove('user_id');
    map['id'] = group.id;
    map['created_at'] = group.createdAt.toIso8601String();
    map['cache_upvoted'] = group.isUpvotedByMe;
    map['is_mine'] = group.isMine;
    map['avatar_color_index'] = group.avatarColorIndex;
    map['avatar_icon_index'] = group.avatarIconIndex;
    return map;
  }

  static WhatsAppGroup _groupFromCacheMap(Map<String, dynamic> map) {
    return WhatsAppGroup.fromMap(
      map,
      isUpvotedByMe: map['cache_upvoted'] == true,
    );
  }

  static Future<bool> toggleUpvote(WhatsAppGroup group) async {
    if (!SupabaseConfig.isConfigured) {
      throw Exception('La aplicación no está conectada a la base de datos.');
    }
    final currentUserId = SupabaseService.currentUserId;
    if (currentUserId == null) return group.isUpvotedByMe;

    try {
      if (group.isUpvotedByMe) {
        // Remove upvote (PostgreSQL trigger automatically syncs counter)
        await SupabaseService.client
            .from('student_group_upvotes')
            .delete()
            .eq('group_id', group.id)
            .eq('user_id', currentUserId);

        await CacheService.invalidateAll(_cacheNamespace);
        return false;
      } else {
        // Add upvote (PostgreSQL trigger automatically syncs counter)
        await SupabaseService.client.from('student_group_upvotes').insert({
          'group_id': group.id,
          'user_id': currentUserId,
        });

        await CacheService.invalidateAll(_cacheNamespace);
        return true;
      }
    } catch (e) {
      debugPrint('Error procesando upvote de grupo: $e');
      return group.isUpvotedByMe;
    }
  }

  static Future<WhatsAppGroup?> createGroup({
    required String title,
    required String carrera,
    required String curso,
    required String section,
    required String link,
    required String description,
    required String authorAlias,
    String? imageUrl,
    GroupPlatform? platform,
  }) async {
    if (!SupabaseConfig.isConfigured) {
      throw Exception('La aplicación no está conectada a la base de datos.');
    }

    final userId = SupabaseService.currentUserId;
    if (userId == null) {
      throw Exception(
        'Debes iniciar sesión para compartir un grupo estudiantil.',
      );
    }

    final cooldownRemaining = await PublishCooldownService.remainingCooldown(
      'group',
    );
    if (cooldownRemaining != null) {
      throw Exception(
        PublishCooldownService.formatCooldownMessage(cooldownRemaining),
      );
    }

    try {
      final resolvedPlatform =
          platform ?? WhatsAppGroup.stringToPlatform(null, link);
      final groupMap = {
        'title': title.trim(),
        'carrera': carrera,
        'curso': curso.trim(),
        'section': section.trim().isEmpty ? 'Sección Única' : section.trim(),
        'link': link.trim(),
        'platform': WhatsAppGroup.platformToString(resolvedPlatform),
        'description': description.trim(),
        'author_alias': authorAlias.trim(),
        'user_id': userId,
        'image_url': imageUrl?.trim().isEmpty == true ? null : imageUrl?.trim(),
        'upvotes': 0,
        'reported_count': 0,
        'moderation_status': 0,
      };

      const explicitColumns =
          'id, title, carrera, curso, section, link, description, author_alias, '
          'upvotes, reported_count, shares_count, created_at, image_url, moderation_status, platform';

      final res = await SupabaseService.client
          .from('student_groups')
          .insert(groupMap)
          .select(explicitColumns)
          .single();

      int? avatarColorIndex;
      int? avatarIconIndex;
      try {
        final profile = await LocalStorageService.getUserProfile();
        avatarColorIndex = profile.avatarColorIndex;
        avatarIconIndex = profile.avatarIconIndex;
      } catch (_) {}

      final created = WhatsAppGroup.fromMap(
        Map<String, dynamic>.from(res),
        isUpvotedByMe: false,
      ).copyWith(
        isMine: true,
        avatarColorIndex: avatarColorIndex,
        avatarIconIndex: avatarIconIndex,
      );

      await PublishCooldownService.recordPublish('group');
      await CacheService.invalidateAll(_cacheNamespace);
      return created;
    } catch (e) {
      debugPrint('Error al crear grupo: $e');
      rethrow;
    }
  }

  static Future<int?> incrementShareCount(String groupId) async {
    if (!SupabaseConfig.isConfigured || groupId.trim().isEmpty) return null;
    try {
      final res = await SupabaseService.client.rpc(
        'increment_student_group_share',
        params: {'p_group_id': groupId},
      );
      await CacheService.invalidateAll(_cacheNamespace);
      if (res is int) return res;
      return int.tryParse(res?.toString() ?? '');
    } catch (e) {
      debugPrint('Error al incrementar shares_count del grupo: $e');
      return null;
    }
  }

  static Future<bool> reportGroup({
    required String groupId,
    required String reason,
  }) async {
    if (!SupabaseConfig.isConfigured) {
      throw Exception('La aplicación no está conectada a la base de datos.');
    }

    try {
      await SupabaseService.client.from('entity_reports').insert({
        'reporter_id': SupabaseService.currentUserId,
        'entity_type': 'group',
        'entity_id': groupId,
        'reason': reason.trim(),
        'moderation_status': 0,
      });

      return true;
    } catch (e) {
      debugPrint('Error al reportar grupo: $e');
      return false;
    }
  }
}
