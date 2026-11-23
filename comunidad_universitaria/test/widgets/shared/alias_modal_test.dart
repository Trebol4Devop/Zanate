import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:comunidad_universitaria/core/config/app_theme.dart';
import 'package:comunidad_universitaria/core/constants/anonymous_aliases.dart';
import 'package:comunidad_universitaria/features/profile/widgets/alias_modal.dart';
import '../../helpers/test_setup.dart';

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  setupTestLifecycle();

  Widget buildTestModal({
    String currentAlias = 'Compilador Desvelado',
    Function(String)? onAliasSaved,
  }) {
    return MaterialApp(
      theme: AppTheme.lightTheme,
      home: Scaffold(
        body: AliasModal(
          currentAlias: currentAlias,
          onAliasSaved: onAliasSaved ?? (_) {},
        ),
      ),
    );
  }

  group('AliasModal Widget Tests', () {
    testWidgets('Renderiza campo editable y permite escribir alias libre', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      String? savedAlias;
      await tester.pumpWidget(
        buildTestModal(
          onAliasSaved: (val) => savedAlias = val,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Tu Seudónimo Estudiantil'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);

      await tester.enterText(find.byType(TextField), '  Anonymus  ');
      await tester.tap(find.text('Guardar Alias'));
      await tester.pumpAndSettle();

      expect(savedAlias, 'Anonymus');
    });

    testWidgets('Muestra error si el alias tiene menos de 2 caracteres', (
      tester,
    ) async {
      await tester.pumpWidget(buildTestModal());
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'A');
      await tester.tap(find.text('Guardar Alias'));
      await tester.pumpAndSettle();

      expect(
        find.text('El alias debe tener entre 2 y 32 caracteres.'),
        findsOneWidget,
      );
    });

    testWidgets(
      'Al pulsar el botón de dados, genera un alias aleatorio válido del catálogo',
      (tester) async {
        await tester.pumpWidget(
          buildTestModal(currentAlias: 'Anonymus'),
        );
        await tester.pumpAndSettle();

        final diceBtn = find.byTooltip('Generar alias anónimo');
        expect(diceBtn, findsOneWidget);

        await tester.tap(diceBtn);
        await tester.pumpAndSettle();

        final field = tester.widget<TextField>(find.byType(TextField));
        final generated = field.controller?.text ?? '';
        expect(AnonymousAliasGenerator.isValid(generated), isTrue);
      },
    );
  });
}
