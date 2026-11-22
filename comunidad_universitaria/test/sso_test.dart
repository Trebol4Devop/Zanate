import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:comunidad_universitaria/features/sso/sso_security_validator.dart';
import 'package:comunidad_universitaria/features/sso/sso_service.dart';
import 'package:comunidad_universitaria/features/sso/screens/sso_authorize_screen.dart';

/// Fake para pruebas unitarias y de widgets que simula el servicio SSO desacoplado.
class FakeSsoService implements SsoService {
  final SsoSessionData? sessionToReturn;
  final bool configured;
  final bool authenticated;
  final String? emailToReturn;
  bool getCurrentSessionCalled = false;

  FakeSsoService({
    this.sessionToReturn,
    this.configured = true,
    this.authenticated = true,
    this.emailToReturn = 'estudiante@usac.edu.gt',
  });

  @override
  bool get isConfigured => configured;

  @override
  bool get isAuthenticated => authenticated;

  @override
  String? get currentUserEmail => emailToReturn;

  @override
  Future<SsoSessionData?> getCurrentSession() async {
    getCurrentSessionCalled = true;
    return sessionToReturn;
  }
}

void main() {
  group('SSO Security Validator - Open Redirect Protection', () {
    test('Permite localhost:5173 para desarrollo local de PEMTREE', () {
      expect(
        SsoSecurityValidator.isValidRedirectUri('http://localhost:5173/auth/callback'),
        isTrue,
      );
      expect(
        SsoSecurityValidator.isValidRedirectUri('http://127.0.0.1:5173/auth/callback'),
        isTrue,
      );
    });

    test('Permite solo los dominios de PEMTREE en Netlify', () {
      expect(
        SsoSecurityValidator.isValidRedirectUri('https://pemtree.netlify.app/auth/callback'),
        isTrue,
      );
      expect(
        SsoSecurityValidator.isValidRedirectUri('https://deploy-preview-42--pemtree.netlify.app/auth/callback'),
        isTrue,
      );
      // Un sitio ajeno en Netlify no debe recibir tokens.
      expect(
        SsoSecurityValidator.isValidRedirectUri('https://evil.netlify.app/auth/callback'),
        isFalse,
      );
      expect(
        SsoSecurityValidator.isValidRedirectUri('https://otro-sitio.netlify.app/auth/callback'),
        isFalse,
      );
    });

    test('Permite dominios oficiales de producción de PEMTREE', () {
      expect(
        SsoSecurityValidator.isValidRedirectUri('https://pemtree.com/auth/callback'),
        isTrue,
      );
      expect(
        SsoSecurityValidator.isValidRedirectUri('https://app.pemtree.com/auth/callback'),
        isTrue,
      );
      expect(
        SsoSecurityValidator.isValidRedirectUri('https://pemtree.app/auth/callback'),
        isTrue,
      );
      // La ruta del callback es obligatoria.
      expect(
        SsoSecurityValidator.isValidRedirectUri('https://pemtree.netlify.app/robar'),
        isFalse,
      );
    });

    test('Bloquea orígenes no autorizados o maliciosos (Open Redirect Attacks)', () {
      // Dominio atacante externo
      expect(
        SsoSecurityValidator.isValidRedirectUri('http://malicious-site.com/steal-token'),
        isFalse,
      );
      expect(
        SsoSecurityValidator.isValidRedirectUri('https://evil.com/callback'),
        isFalse,
      );

      // Suplantación de subdominio
      expect(
        SsoSecurityValidator.isValidRedirectUri('https://evil-netlify.app.attacker.com/callback'),
        isFalse,
      );
      expect(
        SsoSecurityValidator.isValidRedirectUri('https://pemtree.com.fake.org/callback'),
        isFalse,
      );

      // Esquema inseguro para dominios remotos
      expect(
        SsoSecurityValidator.isValidRedirectUri('http://pemtree.com/callback'),
        isFalse,
      );

      // User info spoofing
      expect(
        SsoSecurityValidator.isValidRedirectUri('https://localhost:5173@evil.com/callback'),
        isFalse,
      );

      // Wildcards o asteriscos (deben ser rechazados rotundamente)
      expect(
        SsoSecurityValidator.isValidRedirectUri('http://localhost:5173/**'),
        isFalse,
      );
      expect(
        SsoSecurityValidator.isValidRedirectUri('http://localhost:5173/*'),
        isFalse,
      );
      expect(
        SsoSecurityValidator.isValidRedirectUri('https://*.netlify.app/auth/callback'),
        isFalse,
      );

      // Esquemas peligrosos
      expect(
        SsoSecurityValidator.isValidRedirectUri('javascript:alert("hacked")'),
        isFalse,
      );
      expect(
        SsoSecurityValidator.isValidRedirectUri('data:text/html,<script>alert(1)</script>'),
        isFalse,
      );
      expect(
        SsoSecurityValidator.isValidRedirectUri('ftp://pemtree.com/auth/callback'),
        isFalse,
      );
      expect(
        SsoSecurityValidator.isValidRedirectUri('file:///etc/passwd'),
        isFalse,
      );
      expect(
        SsoSecurityValidator.isValidRedirectUri('ws://pemtree.com/socket'),
        isFalse,
      );
      expect(
        SsoSecurityValidator.isValidRedirectUri('ftp://localhost:5173/auth/callback'),
        isFalse,
      );

      // Engaños de prefijo o nombres de dominio similares
      expect(
        SsoSecurityValidator.isValidRedirectUri('https://evilpemtree.com/auth/callback'),
        isFalse,
      );
      expect(
        SsoSecurityValidator.isValidRedirectUri('https://not-netlify.app/callback'),
        isFalse,
      );
      expect(
        SsoSecurityValidator.isValidRedirectUri('https://fakepemtree.org/callback'),
        isFalse,
      );

      // UserInfo con contraseñas o tokens embebidos
      expect(
        SsoSecurityValidator.isValidRedirectUri('https://victim:secret@pemtree.com/callback'),
        isFalse,
      );

      // Comodines o asteriscos en la URL
      expect(
        SsoSecurityValidator.isValidRedirectUri('https://pemtree.com/auth/*'),
        isFalse,
      );
      expect(
        SsoSecurityValidator.isValidRedirectUri('https://pemtree.com/auth?token=*'),
        isFalse,
      );

      // Fragmentos en la URI base de retorno
      expect(
        SsoSecurityValidator.isValidRedirectUri('https://pemtree.com/auth/callback#token=123'),
        isFalse,
      );

      // Caracteres de control o escape
      expect(
        SsoSecurityValidator.isValidRedirectUri('https://pemtree.com/auth/callback\\test'),
        isFalse,
      );

      // Puertos no estándar en dominios remotos HTTPS
      expect(
        SsoSecurityValidator.isValidRedirectUri('https://pemtree.com:8080/auth/callback'),
        isFalse,
      );
    });

    test('Usa por defecto exactamente http://localhost:5173/auth/callback si redirect_uri es nula o vacía', () {
      expect(SsoSecurityValidator.isValidRedirectUri(null), isTrue);
      expect(SsoSecurityValidator.isValidRedirectUri(''), isTrue);

      final successUrl = SsoSecurityValidator.buildSuccessRedirectUrl(
        redirectUri: '',
        accessToken: 'tok_1',
        refreshToken: 'tok_2',
        state: 'st_3',
      );
      expect(successUrl.startsWith('http://localhost:5173/auth/callback#'), isTrue);
      expect(successUrl.contains('*'), isFalse);
    });
  });

  group('SSO Security Validator - State CSRF Protection', () {
    test('isValidState rechaza valores nulos, vacíos o solo espacios', () {
      expect(SsoSecurityValidator.isValidState(null), isFalse);
      expect(SsoSecurityValidator.isValidState(''), isFalse);
      expect(SsoSecurityValidator.isValidState('   '), isFalse);
      expect(SsoSecurityValidator.isValidState('\t\n'), isFalse);
    });

    test('isValidState acepta valores no vacíos legítimos', () {
      expect(SsoSecurityValidator.isValidState('csrf_state_xyz123'), isTrue);
      expect(SsoSecurityValidator.isValidState('a'), isTrue);
      expect(SsoSecurityValidator.isValidState('  valid_state  '), isTrue);
    });

    test('buildSuccessRedirectUrl lanza ArgumentError si state es nulo o vacío', () {
      expect(
        () => SsoSecurityValidator.buildSuccessRedirectUrl(
          redirectUri: 'http://localhost:5173/auth/callback',
          accessToken: 'tok',
          refreshToken: 'ref',
          state: null,
        ),
        throwsArgumentError,
      );
      expect(
        () => SsoSecurityValidator.buildSuccessRedirectUrl(
          redirectUri: 'http://localhost:5173/auth/callback',
          accessToken: 'tok',
          refreshToken: 'ref',
          state: '  ',
        ),
        throwsArgumentError,
      );
    });

    test('buildCancelRedirectUrl lanza ArgumentError si state es nulo o vacío', () {
      expect(
        () => SsoSecurityValidator.buildCancelRedirectUrl(
          redirectUri: 'http://localhost:5173/auth/callback',
          state: null,
        ),
        throwsArgumentError,
      );
      expect(
        () => SsoSecurityValidator.buildCancelRedirectUrl(
          redirectUri: 'http://localhost:5173/auth/callback',
          state: '',
        ),
        throwsArgumentError,
      );
    });
  });

  group('SSO Hash Fragment URL Builder', () {
    test('Construye URL de éxito con tokens en el fragmento hash (#) y preserva el state', () {
      final url = SsoSecurityValidator.buildSuccessRedirectUrl(
        redirectUri: 'http://localhost:5173/auth/callback',
        accessToken: 'access_tok_123',
        refreshToken: 'refresh_tok_456',
        state: 'csrf_state_xyz789',
        expiresIn: 3600,
      );

      final uri = Uri.parse(url);

      // No debe contener tokens en los query parameters
      expect(uri.queryParameters.containsKey('access_token'), isFalse);
      expect(uri.queryParameters.containsKey('refresh_token'), isFalse);

      // Debe contener fragmento hash
      expect(uri.fragment.isNotEmpty, isTrue);
      expect(uri.fragment.contains('access_token=access_tok_123'), isTrue);
      expect(uri.fragment.contains('refresh_token=refresh_tok_456'), isTrue);
      expect(uri.fragment.contains('state=csrf_state_xyz789'), isTrue);
      expect(uri.fragment.contains('token_type=bearer'), isTrue);
      expect(uri.fragment.contains('expires_in=3600'), isTrue);
    });

    test('Construye URL de cancelación con error_description en el hash (#) y preserva el state', () {
      final url = SsoSecurityValidator.buildCancelRedirectUrl(
        redirectUri: 'https://pemtree.netlify.app/auth/callback',
        state: 'csrf_state_abc',
        errorDescription: 'El usuario canceló la autorización',
      );

      final uri = Uri.parse(url);

      expect(uri.queryParameters.containsKey('error'), isFalse);
      expect(uri.fragment.contains('error=access_denied'), isTrue);
      expect(uri.fragment.contains('state=csrf_state_abc'), isTrue);
      expect(uri.fragment.contains('error_description='), isTrue);
    });
  });

  group('SsoAuthorizeScreen UI & Injection Tests', () {
    testWidgets('Muestra error de seguridad si el redirect_uri no está en whitelist', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: SsoAuthorizeScreen(
            clientId: 'pemtree',
            redirectUri: 'http://evil-site.com/callback',
            state: 'test_state',
            activeAlias: 'Estudiante USAC #100',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('URL de Redirección No Autorizada'), findsOneWidget);
      expect(find.text('Conectar con PEMTREE'), findsNothing);
      expect(find.text('Autorizar / Continuar'), findsNothing);
    });

    testWidgets('Muestra error si el client_id no es pemtree', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: SsoAuthorizeScreen(
            clientId: 'cliente_desconocido',
            redirectUri: 'http://localhost:5173/auth/callback',
            state: 'test_state',
            activeAlias: 'Estudiante USAC #100',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Cliente SSO Desconocido'), findsOneWidget);
      expect(find.text('Conectar con PEMTREE'), findsNothing);
    });

    testWidgets('Muestra error de seguridad si el state es nulo o vacío (protección CSRF)', (tester) async {
      // Caso 1: state nulo
      await tester.pumpWidget(
        const MaterialApp(
          home: SsoAuthorizeScreen(
            clientId: 'pemtree',
            redirectUri: 'http://localhost:5173/auth/callback',
            state: null,
            activeAlias: 'Estudiante USAC #100',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Parámetro State Requerido'), findsOneWidget);
      expect(find.text('Conectar con PEMTREE'), findsNothing);

      // Caso 2: state con solo espacios en blanco
      await tester.pumpWidget(
        const MaterialApp(
          home: SsoAuthorizeScreen(
            clientId: 'pemtree',
            redirectUri: 'http://localhost:5173/auth/callback',
            state: '   ',
            activeAlias: 'Estudiante USAC #100',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Parámetro State Requerido'), findsOneWidget);
      expect(find.text('Conectar con PEMTREE'), findsNothing);
    });

    testWidgets('Renderiza pantalla de consentimiento con parámetros legítimos y SsoService inyectado', (tester) async {
      final fakeService = FakeSsoService(
        emailToReturn: 'test.alumno@ingenieria.usac.edu.gt',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: SsoAuthorizeScreen(
            clientId: 'pemtree',
            redirectUri: 'http://localhost:5173/auth/callback',
            state: 'valid_csrf_state',
            activeAlias: 'Estudiante USAC #404',
            ssoService: fakeService,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Conectar con PEMTREE'), findsOneWidget);
      expect(
        find.text('PEMTREE solicita autorización para consultar tu perfil de estudiante y permitirte calificar secciones.'),
        findsOneWidget,
      );
      expect(find.text('test.alumno@ingenieria.usac.edu.gt'), findsOneWidget);
      expect(find.text('Autorizar / Continuar'), findsOneWidget);
      expect(find.text('Cancelar / Rechazar'), findsOneWidget);
    });

    testWidgets('Al pulsar Cancelar / Rechazar muestra estado de redirección', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: SsoAuthorizeScreen(
            clientId: 'pemtree',
            redirectUri: 'http://localhost:5173/auth/callback',
            state: 'cancel_csrf_state',
            activeAlias: 'Estudiante USAC #404',
          ),
        ),
      );
      await tester.pumpAndSettle();

      final cancelBtn = find.text('Cancelar / Rechazar');
      expect(cancelBtn, findsOneWidget);
      await tester.tap(cancelBtn);
      await tester.pump();

      expect(find.text('Redirigiendo a PEMTREE...'), findsOneWidget);
      expect(find.text('Conectando de forma segura con tu cuenta de estudiante...'), findsOneWidget);
      expect(find.text('Si no eres redirigido automáticamente, haz clic aquí'), findsOneWidget);
    });

    testWidgets('Al pulsar Autorizar / Continuar invoca SsoService inyectado e inicia redirección', (tester) async {
      final fakeService = FakeSsoService(
        sessionToReturn: const SsoSessionData(
          accessToken: 'fake_access_token_123',
          refreshToken: 'fake_refresh_token_456',
          expiresIn: 3600,
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: SsoAuthorizeScreen(
            clientId: 'pemtree',
            redirectUri: 'http://localhost:5173/auth/callback',
            state: 'auth_csrf_state',
            activeAlias: 'Estudiante USAC #404',
            ssoService: fakeService,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final authBtn = find.text('Autorizar / Continuar');
      expect(authBtn, findsOneWidget);
      await tester.tap(authBtn);
      await tester.pump();

      expect(fakeService.getCurrentSessionCalled, isTrue);
      expect(find.text('Redirigiendo a PEMTREE...'), findsOneWidget);
      expect(find.text('Conectando de forma segura con tu cuenta de estudiante...'), findsOneWidget);
      expect(find.text('Si no eres redirigido automáticamente, haz clic aquí'), findsOneWidget);
    });
  });
}
