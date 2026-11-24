import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image/image.dart' as img;
import 'package:comunidad_universitaria/core/config/app_theme.dart';
import 'package:comunidad_universitaria/core/config/supabase_config.dart';
import 'package:comunidad_universitaria/core/constants/anonymous_aliases.dart';
import 'package:comunidad_universitaria/core/models/post.dart';
import 'package:comunidad_universitaria/core/services/profile_service.dart';
import 'package:comunidad_universitaria/core/services/publish_cooldown_service.dart';
import 'package:comunidad_universitaria/core/services/storage_service.dart';
import 'package:comunidad_universitaria/core/services/supabase_service.dart';
import 'package:comunidad_universitaria/core/utils/input_sanitizer.dart';
import 'package:comunidad_universitaria/core/utils/square_image_crop.dart';
import 'package:comunidad_universitaria/features/forum/widgets/discord/discord_media_attachment.dart';
import 'package:comunidad_universitaria/features/forum/widgets/discord/discord_video_attachment.dart';
import 'package:comunidad_universitaria/features/forum/widgets/post_card.dart';
import 'package:comunidad_universitaria/features/groups/widgets/group_card.dart';
import 'package:comunidad_universitaria/features/shared/widgets/square_image_crop_dialog.dart';
import 'helpers/fake_postgrest.dart';
import 'helpers/fixtures.dart';
import 'helpers/test_setup.dart';

void main() {
  setUp(() async {
    await resetTestState();
  });

  tearDown(() async {
    await resetTestState();
  });

  group('StorageService.compressImageBytes', () {
    test('redimensiona a <= 1280px y comprime a JPEG más liviano', () {
      final large = img.Image(width: 2000, height: 1500);
      img.fill(large, color: img.ColorRgb8(40, 120, 200));
      final rawPng = Uint8List.fromList(img.encodePng(large));

      final compressed = StorageService.compressImageBytes(rawPng);
      final decoded = img.decodeImage(compressed);

      expect(decoded, isNotNull);
      expect(decoded!.width, lessThanOrEqualTo(1280));
      expect(decoded.height, lessThanOrEqualTo(1280));
      expect(compressed.length, lessThanOrEqualTo(StorageService.maxCompressedImageBytes));
    });

    test('rechaza imágenes que exceden el límite de 10 MB', () {
      final oversized = Uint8List(StorageService.maxRawImageBytes + 1);
      expect(
        () => StorageService.compressImageBytes(oversized),
        throwsA(isA<StorageUploadException>()),
      );
    });
  });

  group('InputSanitizer.sanitizePostgrestSearch', () {
    test('elimina caracteres de control de filtros PostgREST y recorta longitud', () {
      const malicious =
          'calc,title.ilike.%admin%(or);drop table posts;--\'"_*\\';
      final sanitized = InputSanitizer.sanitizePostgrestSearch(malicious);

      expect(sanitized.contains(','), isFalse);
      expect(sanitized.contains('('), isFalse);
      expect(sanitized.contains(')'), isFalse);
      expect(sanitized.contains('*'), isFalse);
      expect(sanitized.contains(';'), isFalse);
      expect(sanitized.contains("'"), isFalse);
      expect(sanitized.contains('"'), isFalse);
      expect(sanitized.contains('%'), isFalse);
      expect(sanitized.contains('_'), isFalse);
      expect(sanitized.contains('\\'), isFalse);
      expect(sanitized, contains('calc'));

      final longInput = 'a' * 150;
      expect(InputSanitizer.sanitizePostgrestSearch(longInput).length, 100);
    });
  });

  group('PublishCooldownService', () {
    test('permite la primera publicación, bloquea por 30s y libera después', () async {
      final t0 = DateTime.utc(2026, 11, 23, 10, 0, 0);

      expect(
        await PublishCooldownService.remainingCooldown('post', now: t0),
        isNull,
      );

      await PublishCooldownService.recordPublish('post', now: t0);

      final blocked = await PublishCooldownService.remainingCooldown(
        'post',
        now: t0.add(const Duration(seconds: 10)),
      );
      expect(blocked, isNotNull);
      expect(blocked!.inSeconds, 20);

      final allowed = await PublishCooldownService.remainingCooldown(
        'post',
        now: t0.add(const Duration(seconds: 30)),
      );
      expect(allowed, isNull);
    });
  });

  group('Post.videoUrl', () {
    test('fromMap y toInsertMap manejan video_url correctamente', () {
      final post = Post.fromMap({
        'id': 'p-1',
        'title': 'Demo',
        'category': 'general',
        'content': 'Video de prueba',
        'author_alias': 'Estudiante',
        'likes': 0,
        'created_at': '2026-11-23T10:00:00.000Z',
        'video_url': 'https://example.com/images/forum_videos/demo.mp4',
      });

      expect(post.videoUrl, 'https://example.com/images/forum_videos/demo.mp4');
      expect(post.toInsertMap()['video_url'], post.videoUrl);

      final noVideo = post.copyWith(videoUrl: '');
      expect(noVideo.toInsertMap().containsKey('video_url'), isFalse);
    });
  });

  group('Alias único libre por cuenta', () {
    test('ensureValidForBackend conserva alias libres como Anonymus', () {
      expect(
        AnonymousAliasGenerator.ensureValidForBackend('  Anonymus  '),
        'Anonymus',
      );
      expect(
        AnonymousAliasGenerator.ensureValidForBackend('Usac_Dev-99'),
        'Usac_Dev-99',
      );
    });

    test('ProfileService.saveAccountAlias reclama alias vía RPC y rechaza duplicados', () async {
      final fakeServer = FakePostgrestServer();
      SupabaseConfig.debugOverrideConfigured = true;
      SupabaseService.debugClient = fakeServer.buildClient();
      fakeServer.onPost(
        '/auth/v1/token',
        (_) => {
          'access_token': 'alias-token',
          'token_type': 'bearer',
          'expires_in': 3600,
          'refresh_token': 'refresh-token',
          'user': {
            'id': 'user-alias-1',
            'aud': 'authenticated',
            'role': 'authenticated',
            'email': 'u@usac.edu.gt',
            'created_at': '2026-10-03T00:00:00.000Z',
          },
        },
      );
      await SupabaseService.client.auth.signInWithPassword(
        email: 'u@usac.edu.gt',
        password: 'password123',
      );

      fakeServer.onPost('/rest/v1/rpc/claim_unique_alias', (req) {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        if (body['p_alias'] == 'Ocupado') {
          return {'ok': false, 'code': 'alias_taken'};
        }
        return {'ok': true, 'alias': body['p_alias']};
      });

      final claimed = await ProfileService.saveAccountAlias('  Anonymus ');
      expect(claimed, 'Anonymus');

      expect(
        () => ProfileService.saveAccountAlias('Ocupado'),
        throwsA(
          isA<AliasException>().having((e) => e.code, 'code', 'alias_taken'),
        ),
      );
    });
  });

  group('Recorte manual 1:1 para imágenes de grupos', () {
    test('computeCropRect calcula región exacta en horizontal, vertical y zoom', () {
      final centered = SquareImageCrop.computeCropRect(
        imageWidth: 600,
        imageHeight: 300,
        viewportSize: 300,
        scale: 1.0,
        translateX: -150,
        translateY: 0,
      );
      expect(centered.x, 150);
      expect(centered.y, 0);
      expect(centered.size, 300);

      final leftEdge = SquareImageCrop.computeCropRect(
        imageWidth: 600,
        imageHeight: 300,
        viewportSize: 300,
        scale: 1.0,
        translateX: 0,
        translateY: 0,
      );
      expect(leftEdge.x, 0);
      expect(leftEdge.y, 0);
      expect(leftEdge.size, 300);

      final zoomed = SquareImageCrop.computeCropRect(
        imageWidth: 600,
        imageHeight: 300,
        viewportSize: 300,
        scale: 2.0,
        translateX: -300,
        translateY: -150,
      );
      expect(zoomed.x, 150);
      expect(zoomed.y, 75);
      expect(zoomed.size, 150);

      final portraitCentered = SquareImageCrop.computeCropRect(
        imageWidth: 300,
        imageHeight: 600,
        viewportSize: 300,
        scale: 1.0,
        translateX: 0,
        translateY: -150,
      );
      expect(portraitCentered.x, 0);
      expect(portraitCentered.y, 150);
      expect(portraitCentered.size, 300);
    });

    test('cropSquareJpeg respeta la zona elegida manualmente y comprime a <= 1280px 1:1', () {
      final wide = img.Image(width: 2000, height: 1000);
      for (int y = 0; y < 1000; y++) {
        for (int x = 0; x < 2000; x++) {
          if (x < 1000) {
            wide.setPixelRgb(x, y, 220, 20, 20);
          } else {
            wide.setPixelRgb(x, y, 20, 40, 220);
          }
        }
      }
      final rawPng = Uint8List.fromList(img.encodePng(wide));

      final croppedBytes = SquareImageCrop.cropSquareJpeg(
        rawPng,
        const SquareCropRect(x: 0, y: 0, size: 1000),
      );
      final decoded = img.decodeImage(croppedBytes);

      expect(decoded, isNotNull);
      expect(decoded!.width, decoded.height);
      expect(decoded.width, 1000);
      final center = decoded.getPixel(500, 500);
      expect(center.r, greaterThan(150));
      expect(center.b, lessThan(80));
    });

    testWidgets('SquareImageCropDialog devuelve imagen 1:1 al confirmar recorte', (
      tester,
    ) async {
      GoogleFonts.config.allowRuntimeFetching = false;
      final sample = img.Image(width: 400, height: 200);
      img.fill(sample, color: img.ColorRgb8(30, 160, 90));
      final pngBytes = Uint8List.fromList(img.encodePng(sample));

      Uint8List? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () async {
                  result = await SquareImageCropDialog.show(
                    context,
                    imageBytes: pngBytes,
                    imageWidth: 400,
                    imageHeight: 200,
                  );
                },
                child: const Text('Abrir recorte'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Abrir recorte'));
      await tester.pumpAndSettle();

      expect(find.text('Recortar imagen'), findsOneWidget);
      await tester.tap(find.text('Aplicar recorte'));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      final decoded = img.decodeImage(result!);
      expect(decoded, isNotNull);
      expect(decoded!.width, decoded.height);
    });
  });

  group('Imágenes a ancho completo disponible en Foro y Grupos', () {
    testWidgets(
      'DiscordMediaAttachment sin maxWidth ocupa todo el ancho y usa fitWidth',
      (tester) async {
        tester.view.physicalSize = const Size(400, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() => tester.view.resetPhysicalSize());
        GoogleFonts.config.allowRuntimeFetching = false;

        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.lightTheme,
            home: const Scaffold(
              body: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DiscordMediaAttachment(
                      imageUrl: 'https://example.com/foto.jpg',
                      title: 'Prueba foro',
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final boxSize = tester.getSize(find.byType(DiscordMediaAttachment));
        expect(boxSize.width, 368.0);

        final imageSize = tester.getSize(find.byType(Image));
        expect(imageSize.width, 366.0);

        final imageWidget = tester.widget<Image>(find.byType(Image));
        expect(imageWidget.width, double.infinity);
        expect(imageWidget.fit, BoxFit.contain);
      },
    );

    testWidgets(
      'GroupCard con imagen ocupa todo el ancho disponible en relación 1:1',
      (tester) async {
        tester.view.physicalSize = const Size(400, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() => tester.view.resetPhysicalSize());
        GoogleFonts.config.allowRuntimeFetching = false;

        final group = TestFixtures.whatsAppGroup(
          id: 'grp-img-1',
          title: 'Sistemas 1 - Sección A',
          curso: 'Sistemas 1',
          section: 'Sección A',
          imageUrl: 'https://example.com/grupo.jpg',
        );

        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.lightTheme,
            home: Scaffold(
              body: SingleChildScrollView(
                child: GroupCard(group: group, onUpvote: () {}),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final imageClip = find.descendant(
          of: find.byType(GroupCard),
          matching: find.byType(ClipRRect),
        );
        expect(imageClip, findsOneWidget);
        final renderedSize = tester.getSize(imageClip);
        expect(renderedSize.width, 400.0);
        expect(renderedSize.height, 400.0);

        final imageWidget = tester.widget<Image>(
          find.descendant(
            of: find.byType(GroupCard),
            matching: find.byType(Image),
          ),
        );
        expect(imageWidget.width, double.infinity);
        expect(imageWidget.fit, BoxFit.cover);
      },
    );

    testWidgets(
      'PostCard renderiza fotos, GIFs y videos al ancho exacto sin bordes ni esquinas redondeadas',
      (tester) async {
        tester.view.physicalSize = const Size(400, 1200);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() => tester.view.resetPhysicalSize());
        GoogleFonts.config.allowRuntimeFetching = false;

        final post = Post(
          id: 'post-media-1',
          title: 'Media full width',
          content: 'Contenido de prueba',
          category: 'general',
          authorAlias: 'Zanate #01',
          authorHash: 'hash-1',
          createdAt: DateTime(2026, 11, 23),
          likes: 0,
          imageUrl: 'https://example.com/foto.jpg',
          gifUrl: 'https://example.com/clip.gif',
          videoUrl: 'https://example.com/video.mp4',
        );

        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.lightTheme,
            home: Scaffold(
              body: SingleChildScrollView(
                child: PostCard(
                  post: post,
                  onTap: () {},
                  onLike: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final mediaWidgets = tester
            .widgetList<DiscordMediaAttachment>(
              find.byType(DiscordMediaAttachment),
            )
            .toList();
        expect(mediaWidgets.length, 2);
        for (final media in mediaWidgets) {
          expect(media.borderRadius, BorderRadius.zero);
          expect(media.showBorder, isFalse);
        }

        for (final finder in [
          find.byType(DiscordMediaAttachment).at(0),
          find.byType(DiscordMediaAttachment).at(1),
          find.byType(DiscordVideoAttachment),
        ]) {
          expect(tester.getSize(finder).width, 400.0);
        }

        final videoWidget = tester.widget<DiscordVideoAttachment>(
          find.byType(DiscordVideoAttachment),
        );
        expect(videoWidget.borderRadius, BorderRadius.zero);
        expect(videoWidget.showBorder, isFalse);
      },
    );

    testWidgets(
      'Tocar la imagen en PostCard abre la publicación en lugar del zoom',
      (tester) async {
        tester.view.physicalSize = const Size(400, 1200);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() => tester.view.resetPhysicalSize());
        GoogleFonts.config.allowRuntimeFetching = false;

        var opened = false;
        final post = Post(
          id: 'post-tap-1',
          title: 'Post con imagen',
          content: 'Descripción corta',
          category: 'general',
          authorAlias: 'Zanate #03',
          authorHash: 'hash-3',
          createdAt: DateTime(2026, 11, 23),
          likes: 0,
          imageUrl: 'https://example.com/foto.jpg',
        );

        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.lightTheme,
            home: Scaffold(
              body: SingleChildScrollView(
                child: PostCard(
                  post: post,
                  onTap: () => opened = true,
                  onLike: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(find.text('Ampliar'), findsNothing);
        await tester.tap(find.byType(DiscordMediaAttachment));
        await tester.pump();
        expect(opened, isTrue);
      },
    );

    testWidgets(
      'PostCard sigue el orden Header -> Media -> Encuesta -> Acciones -> Título -> Descripción (Ver más/Ver menos) -> Fecha',
      (tester) async {
        tester.view.physicalSize = const Size(400, 1400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() => tester.view.resetPhysicalSize());
        GoogleFonts.config.allowRuntimeFetching = false;

        final longDescription = List.filled(
          15,
          'Descripción extensa de prueba para verificar que el texto se contraiga.',
        ).join(' ');

        final post = Post(
          id: 'post-order-1',
          title: 'Título de la publicación',
          content: longDescription,
          category: 'general',
          authorAlias: 'Zanate #02',
          authorHash: 'hash-2',
          createdAt: DateTime.now().subtract(const Duration(hours: 2)),
          likes: 3,
          imageUrl: 'https://example.com/foto.jpg',
          poll: TestFixtures.postPoll(
            id: 'poll-order-1',
            postId: 'post-order-1',
            question: '¿Te gusta el nuevo orden?',
          ),
        );

        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.lightTheme,
            home: Scaffold(
              body: SingleChildScrollView(
                child: PostCard(
                  post: post,
                  onTap: () {},
                  onLike: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final headerY = tester.getTopLeft(find.text('Zanate #02')).dy;
        final mediaY = tester.getTopLeft(find.byType(DiscordMediaAttachment)).dy;
        final pollY = tester.getTopLeft(find.text('¿Te gusta el nuevo orden?')).dy;
        final likeY = tester.getTopLeft(find.byTooltip('Me gusta')).dy;
        final titleY = tester.getTopLeft(find.text('Título de la publicación')).dy;
        final descY = tester.getTopLeft(find.text(longDescription)).dy;
        final timeY = tester.getTopLeft(find.text('Hace 2 horas')).dy;

        expect(headerY, lessThan(mediaY));
        expect(mediaY, lessThan(pollY));
        expect(pollY, lessThan(likeY));
        expect(likeY, lessThan(titleY));
        expect(titleY, lessThan(descY));
        expect(descY, lessThan(timeY));

        expect(find.text('Ver más'), findsOneWidget);
        expect(find.text('Ver menos'), findsNothing);

        await tester.tap(find.text('Ver más'));
        await tester.pump();

        expect(find.text('Ver menos'), findsOneWidget);
        expect(find.text('Ver más'), findsNothing);

        await tester.tap(find.text('Ver menos'));
        await tester.pump();

        expect(find.text('Ver más'), findsOneWidget);
      },
    );
  });
}
