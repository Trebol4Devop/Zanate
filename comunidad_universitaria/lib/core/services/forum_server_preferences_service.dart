import 'package:flutter/foundation.dart';

import '../../features/forum/models/discord_forum_models.dart';
import '../config/supabase_config.dart';
import 'supabase_service.dart';

/// Servicio para persistir los servidores del foro del usuario directamente en
/// Supabase (`public.user_forum_servers`), sin almacenamiento local.
class ForumServerPreferencesService {
  static Future<List<String>> loadServerIds() async {
    if (!SupabaseConfig.isConfigured || !SupabaseService.isAuthenticated) {
      return const [];
    }
    final uid = SupabaseService.currentUserId;
    if (uid == null) return const [];

    try {
      final res = await SupabaseService.client
          .from('user_forum_servers')
          .select('server_id, sort_order')
          .eq('user_id', uid)
          .order('sort_order', ascending: true)
          .order('created_at', ascending: true);

      return (res as List<dynamic>)
          .map((row) => row['server_id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('Error cargando servidores del usuario desde Supabase: $e');
      return const [];
    }
  }

  static Future<void> addServer(String serverId, {int sortOrder = 0}) async {
    if (serverId.trim().isEmpty) return;
    if (!SupabaseConfig.isConfigured || !SupabaseService.isAuthenticated) {
      return;
    }
    final uid = SupabaseService.currentUserId;
    if (uid == null) return;

    try {
      await SupabaseService.client.from('user_forum_servers').upsert({
        'user_id': uid,
        'server_id': serverId.trim(),
        'sort_order': sortOrder,
      });
    } catch (e) {
      debugPrint('Error guardando servidor $serverId en Supabase: $e');
    }
  }

  static Future<void> removeServer(String serverId) async {
    if (serverId.trim().isEmpty) return;
    if (!SupabaseConfig.isConfigured || !SupabaseService.isAuthenticated) {
      return;
    }
    final uid = SupabaseService.currentUserId;
    if (uid == null) return;

    try {
      await SupabaseService.client
          .from('user_forum_servers')
          .delete()
          .eq('user_id', uid)
          .eq('server_id', serverId.trim());
    } catch (e) {
      debugPrint('Error eliminando servidor $serverId en Supabase: $e');
    }
  }

  static Future<List<ForumServer>> load() async {
    final ids = await loadServerIds();
    if (ids.isEmpty) return const [];

    try {
      final res = await SupabaseService.client
          .from('forum_servers')
          .select(
            'id, nombre, short_code, descripcion, icon, color_hex, facultad_id, '
            'facultad_nombre, carrera_id, is_groups, show_in_rail, is_active, '
            'is_system, sort_order, logo_asset, parent_id, server_kind, scope_key',
          )
          .inFilter('id', ids)
          .eq('is_active', true)
          .eq('is_groups', false);

      final byId = <String, ForumServer>{};
      for (final row in res as List<dynamic>) {
        final server = ForumServer.fromDbServer(
          Map<String, dynamic>.from(row as Map),
        );
        if (server.id.isNotEmpty) {
          byId[server.id] = server;
        }
      }
      return [
        for (final id in ids)
          if (byId.containsKey(id)) byId[id]!,
      ];
    } catch (e) {
      debugPrint('Error resolviendo servidores del usuario desde Supabase: $e');
      return const [];
    }
  }

  static Future<void> save(List<ForumServer> servers) async {
    if (!SupabaseConfig.isConfigured || !SupabaseService.isAuthenticated) {
      return;
    }
    final uid = SupabaseService.currentUserId;
    if (uid == null) return;

    final userServers = servers
        .where((s) => !s.isGroups && !s.isSystem && !s.showInRail && s.id != 'todas')
        .toList();

    try {
      await SupabaseService.client
          .from('user_forum_servers')
          .delete()
          .eq('user_id', uid);

      if (userServers.isEmpty) return;

      await SupabaseService.client.from('user_forum_servers').upsert([
        for (int i = 0; i < userServers.length; i++)
          {
            'user_id': uid,
            'server_id': userServers[i].id,
            'sort_order': i,
          },
      ]);
    } catch (e) {
      debugPrint('Error sincronizando servidores del usuario en Supabase: $e');
    }
  }
}
