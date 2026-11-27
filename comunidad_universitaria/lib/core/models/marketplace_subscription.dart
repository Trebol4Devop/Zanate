class MarketplaceSubscription {
  final String id;
  final String planId;
  final String status;
  final DateTime? currentPeriodStart;
  final DateTime? currentPeriodEnd;
  final bool cancelAtPeriodEnd;
  final DateTime? updatedAt;

  const MarketplaceSubscription({
    required this.id,
    required this.planId,
    required this.status,
    this.currentPeriodStart,
    this.currentPeriodEnd,
    this.cancelAtPeriodEnd = false,
    this.updatedAt,
  });

  bool get isActive => status == 'active';
  bool get isPastDue => status == 'past_due';
  bool get isPaused => status == 'paused';
  bool get isCancelled => status == 'cancelled';
  bool get isOpen => isActive || isPastDue || isPaused;

  static DateTime? _parseDate(dynamic raw) {
    if (raw == null) return null;
    if (raw is DateTime) return raw;
    return DateTime.tryParse(raw.toString());
  }

  factory MarketplaceSubscription.fromMap(Map<String, dynamic> map) {
    return MarketplaceSubscription(
      id: map['id']?.toString() ?? '',
      planId: (map['plan_id'] ?? map['planId'])?.toString() ?? 'free',
      status: map['status']?.toString() ?? 'cancelled',
      currentPeriodStart: _parseDate(
        map['current_period_start'] ?? map['currentPeriodStart'],
      ),
      currentPeriodEnd: _parseDate(
        map['current_period_end'] ?? map['currentPeriodEnd'],
      ),
      cancelAtPeriodEnd:
          map['cancel_at_period_end'] == true ||
          map['cancelAtPeriodEnd'] == true,
      updatedAt: _parseDate(map['updated_at'] ?? map['updatedAt']),
    );
  }

  factory MarketplaceSubscription.fromJson(Map<String, dynamic> json) =>
      MarketplaceSubscription.fromMap(json);

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'plan_id': planId,
      'status': status,
      'current_period_start': currentPeriodStart?.toIso8601String(),
      'current_period_end': currentPeriodEnd?.toIso8601String(),
      'cancel_at_period_end': cancelAtPeriodEnd,
      'updated_at': updatedAt?.toIso8601String(),
    };
  }
}
