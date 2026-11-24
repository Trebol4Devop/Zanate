import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:comunidad_universitaria/core/services/forum_server_preferences_service.dart';
import 'package:comunidad_universitaria/features/forum/models/discord_forum_models.dart';
import 'package:comunidad_universitaria/features/forum/screens/forum_screen.dart';
import 'package:comunidad_universitaria/features/forum/widgets/discord/forum_channel_sidebar.dart';
import 'package:comunidad_universitaria/features/forum/widgets/discord/forum_server_rail.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'usac_forum_alias': 'EstudianteTest',
    });
  });

  group('Discord Forum Models & Architecture', () {
    test(
      'Los servidores predeterminados incluyen comunidades generales y por carrera',
      () {
        final servers = ForumServer.defaultServers;
        expect(servers.any((server) => server.id == 'todas'), isTrue);
        expect(servers.any((server) => server.carreraId == 'sistemas'), isTrue);
        expect(
          servers.any(
            (server) =>
                server.id == 'medicina' && server.carreraId == '05-00-01',
          ),
          isTrue,
        );
        expect(
          servers.any(
            (server) =>
                server.id == 'derecho' && server.carreraId == '04-00-01',
          ),
          isTrue,
        );
      },
    );

    test(
      'Los canales del foro están alineados con las categorías disponibles',
      () {
        final channels = ForumChannel.defaultChannels;
        expect(channels.length, 8);
        expect(
          channels.any((channel) => channel.name == 'todos-los-temas'),
          isTrue,
        );
        expect(channels.any((channel) => channel.id == 'general'), isTrue);
        expect(channels.any((channel) => channel.id == 'desahogo'), isTrue);
        expect(channels.any((channel) => channel.id == 'desmadre'), isTrue);
        expect(
          channels.any((channel) => channel.name == 'dudas-y-pensum'),
          isTrue,
        );
        expect(
          channels.any((channel) => channel.name == 'catedraticos-opiniones'),
          isTrue,
        );
        expect(
          channels.any((channel) => channel.name == 'apuntes-y-recursos'),
          isTrue,
        );
        expect(
          channels.any((channel) => channel.name == 'horarios-y-secciones'),
          isTrue,
        );
      },
    );

    test('Los servidores y canales no dependen de conteos simulados', () {
      for (final server in ForumServer.defaultServers) {
        expect(server.memberCount, isNull);
      }
      final areaComun = ForumServer.defaultServers.firstWhere(
        (server) => server.id == 'area_comun',
      );
      expect(areaComun.facultadId, '08');

      final channel = ForumChannel.fromDbCategory(
        id: 'prerrequisitos',
        nombre: 'Prerrequisitos & Pensum',
      );
      expect(channel.name, 'dudas-y-pensum');
      expect(channel.label, 'Prerrequisitos & Pensum');

      // El backend manda: nombre visible, descripción, slug e icono desde DB.
      final adminChannel = ForumChannel.fromDbCategory(
        id: 'becas',
        nombre: 'Becas y Financiamiento',
        descripcion: 'Convocatorias y apoyo económico.',
        slug: 'becas-y-financiamiento',
        icon: 'campaign_outlined',
      );
      expect(adminChannel.id, 'becas');
      expect(adminChannel.name, 'becas-y-financiamiento');
      expect(adminChannel.description, 'Convocatorias y apoyo económico.');
      expect(adminChannel.icon, Icons.campaign_outlined);
    });

    test(
      'Los servidores de grupos conservan su catálogo fuera del rail del foro',
      () {
        final channels = ForumChannel.groupsChannels;
        expect(channels.length, 11);
        expect(channels.first.name, 'todos-los-grupos');
        expect(
          channels.any(
            (channel) => channel.id == '08' && channel.name == 'ingenieria',
          ),
          isTrue,
        );
        expect(channels.any((channel) => channel.id == 'area_comun'), isFalse);
        final engineering = ForumFaculty.defaultFaculties.firstWhere(
          (faculty) => faculty.id == '08',
        );
        expect(
          engineering.careers.any((career) => career.id == 'area_comun'),
          isTrue,
        );
      },
    );
  });

  group('Discord Forum UI', () {
    testWidgets(
      'Inicia con el servidor general y muestra configuración en el menú lateral',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);

        await tester.pumpWidget(
          const MaterialApp(
            home: ForumScreen(
              activeAlias: 'Alias oculto',
              onAliasChanged: _ignoreAlias,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(ForumServerRail), findsOneWidget);
        expect(find.byType(ForumChannelSidebar), findsOneWidget);
        expect(find.byTooltip('Todas las Facultades'), findsOneWidget);
        expect(find.byTooltip('Grupos de Estudio'), findsNothing);
        expect(find.byTooltip('Agregar servidor'), findsOneWidget);
        expect(find.byIcon(PhosphorIconsRegular.gear), findsOneWidget);
        expect(find.text('Alias oculto'), findsNothing);
        expect(find.text('CANALES'), findsOneWidget);
      },
    );

    testWidgets('El botón más agrega un servidor y persiste la preferencia', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        const MaterialApp(
          home: ForumScreen(
            activeAlias: 'Estudiante',
            onAliasChanged: _ignoreAlias,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Agregar servidor'));
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byType(Dialog), matching: find.text('Agregar servidor')), findsOneWidget);

      final search = find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(search, 'Médico y Cirujano');
      await tester.pumpAndSettle();
      await tester.tap(
        find
            .descendant(
              of: find.byType(Dialog),
              matching: find.byType(ListTile),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);

      final savedServers = await ForumServerPreferencesService.load();
      expect(savedServers, isEmpty);
      expect(
        find.descendant(
          of: find.byType(ForumChannelSidebar),
          matching: find.text('Médico y Cirujano'),
        ),
        findsOneWidget,
      );
    });

    testWidgets(
      'Los títulos de canales y el estado vacío no incluyen hashtag ni CTA duplicado',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);

        await tester.pumpWidget(
          const MaterialApp(
            home: ForumScreen(
              activeAlias: 'Estudiante',
              onAliasChanged: _ignoreAlias,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Título en doble línea igual que en móvil: servidor arriba, canal abajo.
        expect(find.text('TODAS LAS FACULTADES'), findsOneWidget);
        expect(find.text('todos-los-temas'), findsWidgets);
        expect(find.textContaining('#todos-los-temas'), findsNothing);
        expect(find.text('Crear Primera Publicación'), findsNothing);

        await tester.tap(find.text('catedraticos-opiniones').first);
        await tester.pumpAndSettle();
        expect(find.text('TODAS LAS FACULTADES'), findsOneWidget);
        expect(find.text('catedraticos-opiniones'), findsWidgets);
        expect(find.textContaining('#catedraticos-opiniones'), findsNothing);
      },
    );

    testWidgets(
      'En móvil el buscador está en el menú desplegable entre Agregar servidor y Configuración',
      (tester) async {
        tester.view.physicalSize = const Size(400, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);

        await tester.pumpWidget(
          const MaterialApp(
            home: ForumScreen(
              activeAlias: 'Estudiante',
              onAliasChanged: _ignoreAlias,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.widgetWithText(TextField, 'Buscar publicaciones...'),
          findsNothing,
        );

        await tester.tap(find.byIcon(PhosphorIconsRegular.list));
        await tester.pumpAndSettle();

        final addServerFinder = find.byTooltip('Agregar servidor');
        final searchButtonFinder = find.byTooltip('Buscar en el foro');
        final settingsFinder = find.byTooltip('Configuración y Perfil');

        expect(addServerFinder, findsOneWidget);
        expect(searchButtonFinder, findsOneWidget);
        expect(settingsFinder, findsOneWidget);

        final addServerX = tester.getCenter(addServerFinder).dx;
        final searchX = tester.getCenter(searchButtonFinder).dx;
        final settingsX = tester.getCenter(settingsFinder).dx;
        expect(addServerX, lessThan(searchX));
        expect(searchX, lessThan(settingsX));

        await tester.tap(searchButtonFinder);
        await tester.pumpAndSettle();

        expect(find.byType(AlertDialog), findsOneWidget);
        await tester.enterText(
          find.widgetWithText(TextField, 'Buscar publicaciones...'),
          'parcial',
        );
        await tester.tap(find.text('Buscar'));
        await tester.pumpAndSettle();

        expect(find.byType(AlertDialog), findsNothing);
      },
    );

    testWidgets(
      'En móvil se conservan rail de servidores y canales dentro del drawer',
      (tester) async {
        tester.view.physicalSize = const Size(400, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);

        await tester.pumpWidget(
          const MaterialApp(
            home: ForumScreen(
              activeAlias: 'Estudiante',
              onAliasChanged: _ignoreAlias,
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byIcon(PhosphorIconsRegular.list));
        await tester.pumpAndSettle();
        expect(find.byType(ForumServerRail), findsOneWidget);
        expect(find.byType(ForumChannelSidebar), findsOneWidget);
        expect(find.byTooltip('Agregar servidor'), findsOneWidget);
        expect(find.byTooltip('Grupos de Estudio'), findsNothing);

        await tester.tap(find.byTooltip('Agregar servidor'));
        await tester.pumpAndSettle();
        final search = find.descendant(
          of: find.byType(Dialog),
          matching: find.byType(TextField),
        );
        await tester.enterText(search, 'Médico y Cirujano');
        await tester.pumpAndSettle();
        await tester.tap(
          find
              .descendant(
                of: find.byType(Dialog),
                matching: find.byType(ListTile),
              )
              .first,
        );
        await tester.pumpAndSettle();
        expect(find.byType(ForumServerRail), findsNothing);
      },
    );

    testWidgets('El rail ignora servidores de grupos recibidos en la lista', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ForumServerRail(
              servers: ForumServer.defaultServers,
              activeServer: ForumServer.defaultServers.first,
              onSelectServer: (_) {},
              onAddServer: (_) {},
            ),
          ),
        ),
      );

      expect(find.byTooltip('Todas las Facultades'), findsOneWidget);
      expect(find.byTooltip('Grupos de Estudio'), findsNothing);
      expect(find.byTooltip('Agregar servidor'), findsOneWidget);
    });
  });
}

void _ignoreAlias(String _) {}
