import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:comunidad_universitaria/core/services/billing_service.dart';
import '../helpers/fake_postgrest.dart';

void main() {
  group('BillingService', () {
    test('createCheckoutSession envía JWT y devuelve checkout_url', () async {
      late http.Request captured;
      final mockHttp = MockClient((req) async {
        captured = req;
        return http.Response(
          jsonEncode({
            'checkout_id': 'chk_123',
            'checkout_url': 'https://app.recurrente.com/c/chk_123',
          }),
          201,
        );
      });

      final service = BillingService(
        httpClient: mockHttp,
        workerUrl: 'https://billing.example.workers.dev/',
        accessTokenProvider: () => 'jwt-token-test',
      );

      final url = await service.createCheckoutSession('pro_student');

      expect(url, 'https://app.recurrente.com/c/chk_123');
      expect(captured.method, 'POST');
      expect(
        captured.url.toString(),
        'https://billing.example.workers.dev/api/v1/billing/checkout',
      );
      expect(captured.headers['Authorization'], 'Bearer jwt-token-test');
      expect(jsonDecode(captured.body), {'plan_id': 'pro_student'});
    });

    test('createCardSetupSession llama /api/v1/billing/setup-card', () async {
      final mockHttp = MockClient((req) async {
        expect(req.url.path, '/api/v1/billing/setup-card');
        return http.Response(
          jsonEncode({
            'checkout_id': 'chk_setup_1',
            'checkout_url': 'https://app.recurrente.com/c/chk_setup_1',
          }),
          201,
        );
      });

      final service = BillingService(
        httpClient: mockHttp,
        workerUrl: 'https://billing.example.workers.dev',
        accessTokenProvider: () => 'jwt-token-test',
      );

      final url = await service.createCardSetupSession();
      expect(url, 'https://app.recurrente.com/c/chk_setup_1');
    });

    test('changePlan y cancelSubscription envían PUT y DELETE respectivamente', () async {
      final methods = <String>[];
      final mockHttp = MockClient((req) async {
        methods.add(req.method);
        return http.Response(jsonEncode({'status': 'ok'}), 200);
      });

      final service = BillingService(
        httpClient: mockHttp,
        workerUrl: 'https://billing.example.workers.dev',
        accessTokenProvider: () => 'jwt-token-test',
      );

      await service.changePlan('business_local', mode: 'next_cycle');
      await service.cancelSubscription();

      expect(methods, ['PUT', 'DELETE']);
    });

    test('lanza BillingException cuando falta BILLING_WORKER_URL', () async {
      final service = BillingService(
        httpClient: MockClient((_) async => http.Response('{}', 200)),
        workerUrl: '',
        accessTokenProvider: () => 'jwt-token-test',
      );

      expect(
        () => service.createCheckoutSession('pro_student'),
        throwsA(isA<BillingException>()),
      );
    });

    test('fetchMySubscription consulta RPC get_my_subscription', () async {
      final fakeServer = FakePostgrestServer();
      fakeServer.on('POST', '/rest/v1/rpc/get_my_subscription', (_) => [
            {
              'id': 'sub-1',
              'plan_id': 'pro_student',
              'status': 'active',
              'cancel_at_period_end': false,
            },
          ]);

      final service = BillingService(
        supabaseClient: fakeServer.buildClient(),
        workerUrl: 'https://billing.example.workers.dev',
      );

      final sub = await service.fetchMySubscription();
      expect(sub, isNotNull);
      expect(sub!.planId, 'pro_student');
      expect(sub.isActive, isTrue);
    });
  });
}
