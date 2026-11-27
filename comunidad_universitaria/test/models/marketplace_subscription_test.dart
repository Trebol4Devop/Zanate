import 'package:flutter_test/flutter_test.dart';
import 'package:comunidad_universitaria/core/models/marketplace_subscription.dart';

void main() {
  group('MarketplaceSubscription', () {
    test('parsea correctamente desde snake_case y expone helpers de estado', () {
      final sub = MarketplaceSubscription.fromMap({
        'id': 'sub-uuid-1',
        'plan_id': 'pro_student',
        'status': 'past_due',
        'current_period_start': '2026-11-01T00:00:00Z',
        'current_period_end': '2026-12-01T00:00:00Z',
        'cancel_at_period_end': true,
        'updated_at': '2026-11-26T12:00:00Z',
      });

      expect(sub.id, 'sub-uuid-1');
      expect(sub.planId, 'pro_student');
      expect(sub.status, 'past_due');
      expect(sub.isPastDue, isTrue);
      expect(sub.isActive, isFalse);
      expect(sub.isOpen, isTrue);
      expect(sub.cancelAtPeriodEnd, isTrue);
      expect(sub.currentPeriodEnd?.year, 2026);
    });
  });
}
