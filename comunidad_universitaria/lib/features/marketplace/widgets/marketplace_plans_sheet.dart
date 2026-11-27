import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/constants/zanate_colors.dart';
import '../../../core/models/marketplace_subscription.dart';
import '../../../core/services/billing_service.dart';
import '../../../core/services/marketplace_service.dart';
import '../../../core/services/supabase_service.dart';
import '../../../core/utils/responsive.dart';
import '../../shared/widgets/auth_modal.dart';
import '../marketplace_theme.dart';

class MarketplacePlansSheet extends StatefulWidget {
  final List<MarketplacePlan>? initialPlans;
  final MarketplaceSellerStatus? initialStatus;
  final MarketplaceSubscription? initialSubscription;
  final String? initialError;
  final BillingService? billingService;
  final Future<bool> Function(Uri url)? launchUrlFn;
  final bool? isAuthenticatedOverride;

  const MarketplacePlansSheet({
    super.key,
    this.initialPlans,
    this.initialStatus,
    this.initialSubscription,
    this.initialError,
    this.billingService,
    this.launchUrlFn,
    this.isAuthenticatedOverride,
  });

  static Future<void> show(BuildContext context) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (ctx) => const MarketplacePlansSheet(),
      ),
    );
  }

  @override
  State<MarketplacePlansSheet> createState() => _MarketplacePlansSheetState();
}

class _MarketplacePlansSheetState extends State<MarketplacePlansSheet>
    with WidgetsBindingObserver {
  late final BillingService _billingService;
  List<MarketplacePlan> _plans = [];
  MarketplaceSellerStatus? _myStatus;
  MarketplaceSubscription? _subscription;
  bool _isLoading = true;
  bool _isSubmittingBilling = false;
  bool _awaitingPaymentConfirmation = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _billingService = widget.billingService ?? BillingService();

    if (widget.initialError != null) {
      _errorMessage = widget.initialError;
      _isLoading = false;
    } else if (widget.initialPlans != null) {
      _plans = widget.initialPlans!;
      _myStatus = widget.initialStatus;
      _subscription = widget.initialSubscription;
      _isLoading = false;
      if (_plans.isEmpty) {
        _errorMessage =
            'No pudimos cargar los planes. Revisa tu conexión e inténtalo de nuevo.';
      }
    } else {
      _loadPlansAndStatus();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _awaitingPaymentConfirmation) {
      _refreshAfterCheckout();
    }
  }

  Future<void> _loadPlansAndStatus() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final results = await Future.wait([
        MarketplaceService.fetchPlans(),
        MarketplaceService.fetchMyStatus(),
        _safeFetchSubscription(),
      ]);

      if (!mounted) return;
      final fetchedPlans = results[0] as List<MarketplacePlan>;
      final fetchedStatus = results[1] as MarketplaceSellerStatus?;
      final fetchedSub = results[2] as MarketplaceSubscription?;

      setState(() {
        _plans = fetchedPlans;
        _myStatus = fetchedStatus;
        _subscription = fetchedSub;
        _isLoading = false;
        if (fetchedPlans.isEmpty) {
          _errorMessage =
              'No pudimos cargar los planes. Revisa tu conexión e inténtalo de nuevo.';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _plans = const [];
        _isLoading = false;
        _errorMessage =
            'No pudimos cargar los planes desde el servidor. Revisa tu conexión e inténtalo de nuevo.';
      });
    }
  }

  bool get _isAuthenticated =>
      widget.isAuthenticatedOverride ?? SupabaseService.isAuthenticated;

  Future<MarketplaceSubscription?> _safeFetchSubscription() async {
    if (!_isAuthenticated) return null;
    try {
      return await _billingService.fetchMySubscription();
    } catch (_) {
      return null;
    }
  }

  Future<void> _refreshAfterCheckout() async {
    if (!mounted) return;
    setState(() {
      _awaitingPaymentConfirmation = true;
    });

    try {
      final results = await Future.wait([
        MarketplaceService.fetchMyStatus(),
        _safeFetchSubscription(),
      ]);
      if (!mounted) return;
      final fetchedStatus = results[0] as MarketplaceSellerStatus?;
      final fetchedSub = results[1] as MarketplaceSubscription?;
      final confirmed =
          fetchedSub?.isActive == true ||
          (fetchedStatus != null && fetchedStatus.planId != 'free');

      setState(() {
        _myStatus = fetchedStatus;
        _subscription = fetchedSub;
        if (confirmed) {
          _awaitingPaymentConfirmation = false;
        }
      });
    } catch (_) {
      // Mantiene el banner de confirmación pendiente para reintento manual
    }
  }

  Future<void> _launchCheckoutUrl(String rawUrl) async {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null) {
      throw const BillingException('URL de pago inválida.');
    }
    final launcher =
        widget.launchUrlFn ??
        (u) => launchUrl(u, mode: LaunchMode.externalApplication);
    final launched = await launcher(uri);
    if (!launched) {
      throw const BillingException('No se pudo abrir la pasarela de pago.');
    }
  }

  Future<void> _handlePlanAction(MarketplacePlan plan) async {
    if (!_isAuthenticated) {
      AuthModal.show(
        context,
        title: 'Inicia sesión para solicitar un plan',
        subtitle:
            'Para asociar un plan a tu cuenta estudiantil o comercial debes iniciar sesión.',
        onAuthenticated: () {
          _loadPlansAndStatus();
        },
      );
      return;
    }

    if (plan.priceMonthly <= 0 || plan.id == 'free') {
      return;
    }

    setState(() => _isSubmittingBilling = true);
    try {
      final checkoutUrl = await _billingService.createCheckoutSession(plan.id);
      await _launchCheckoutUrl(checkoutUrl);
      if (!mounted) return;
      setState(() {
        _awaitingPaymentConfirmation = true;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    } finally {
      if (mounted) {
        setState(() => _isSubmittingBilling = false);
      }
    }
  }

  Future<void> _handleUpdateCard() async {
    if (!_isAuthenticated) return;
    setState(() => _isSubmittingBilling = true);
    try {
      final setupUrl = await _billingService.createCardSetupSession();
      await _launchCheckoutUrl(setupUrl);
      if (!mounted) return;
      setState(() {
        _awaitingPaymentConfirmation = true;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    } finally {
      if (mounted) {
        setState(() => _isSubmittingBilling = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final isDesktop = Responsive.isDesktop(context);
    final isMobile = Responsive.isMobile(context);
    final scaffoldBg = ZanateColors.bg(isDark);
    final primaryText = ZanateColors.textPrimary(isDark);
    final borderColor = ZanateColors.border(isDark);

    Widget body;
    if (_isLoading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_errorMessage != null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: isDark
                      ? ZanateColors.zanateEyeYellow
                      : ZanateColors.zanateBlack,
                  foregroundColor:
                      isDark ? ZanateColors.zanateBlack : Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: _loadPlansAndStatus,
                child: const Text('Reintentar'),
              ),
            ],
          ),
        ),
      );
    } else {
      body = SingleChildScrollView(
        padding: EdgeInsets.symmetric(
          horizontal: isMobile ? 18 : 28,
          vertical: isMobile ? 16 : 24,
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: isDesktop ? 960 : 680),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Intro compacto
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: ZanateColors.zanateEyeYellow.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Center(
                        child: PhosphorIcon(
                          PhosphorIconsBold.sparkle,
                          color: isDark
                              ? ZanateColors.zanateEyeYellow
                              : ZanateColors.zanateBlack,
                          size: 20,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Más visibilidad, más catálogo, más herramientas. Sin comisiones por venta.',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: isDark
                                  ? const Color(0xFF94A3B8)
                                  : ZanateColors.mutedText,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Container(
                            width: 44,
                            height: 4,
                            decoration: BoxDecoration(
                              color: ZanateColors.zanateEyeYellow,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Mandatory Note (UX-MKT-018) en la parte superior sin necesidad de scroll
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: ZanateColors.surface(isDark),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: borderColor,
                      width: 0.8,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        PhosphorIconsRegular.info,
                        size: 18,
                        color: ZanateColors.textMuted(isDark),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'La coordinación y el pago del plan se realizan fuera de la app con el equipo. La plataforma no cobra comisiones por tus ventas.',
                          style: TextStyle(
                            fontSize: 11,
                            color: ZanateColors.textSecondary(isDark),
                            height: 1.3,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                if (_subscription?.isPastDue == true) ...[
                  const SizedBox(height: 12),
                  _buildPastDueBanner(isDark),
                ],

                if (_awaitingPaymentConfirmation) ...[
                  const SizedBox(height: 12),
                  _buildConfirmingBanner(isDark),
                ],

                const SizedBox(height: 18),

                if (isDesktop)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: _plans
                        .map(
                          (plan) => Expanded(
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 6),
                              child: _buildPlanCard(plan, isDark),
                            ),
                          ),
                        )
                        .toList(),
                  )
                else
                  Column(
                    children: _plans
                        .map(
                          (plan) => Padding(
                            padding: const EdgeInsets.only(bottom: 14),
                            child: _buildPlanCard(plan, isDark),
                          ),
                        )
                        .toList(),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    return MarketplaceTheme.wrap(
      context,
      Scaffold(
        backgroundColor: scaffoldBg,
        appBar: AppBar(
          backgroundColor: scaffoldBg,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            tooltip: 'Volver',
            icon: PhosphorIcon(
              PhosphorIconsBold.caretLeft,
              color: primaryText,
              size: 22,
            ),
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Text(
            'Planes del Marketplace',
            style: GoogleFonts.outfit(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: primaryText,
            ),
          ),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(1),
            child: Divider(height: 1, color: borderColor),
          ),
        ),
        body: SafeArea(child: body),
      ),
    );
  }

  Widget _buildPastDueBanner(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFCA5A5)),
      ),
      child: Row(
        children: [
          const Icon(
            PhosphorIconsBold.warningCircle,
            color: Color(0xFFDC2626),
            size: 20,
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Tu suscripción está pendiente de pago. Actualiza tu tarjeta para mantener tus beneficios.',
              style: TextStyle(
                fontSize: 12,
                color: Color(0xFF991B1B),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: _isSubmittingBilling ? null : _handleUpdateCard,
            child: const Text('Actualizar tarjeta'),
          ),
        ],
      ),
    );
  }

  Widget _buildConfirmingBanner(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ZanateColors.surface(isDark),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ZanateColors.zanateEyeYellow),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Confirmando pago… Estamos esperando la confirmación de la pasarela.',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          TextButton(
            onPressed: _refreshAfterCheckout,
            child: const Text('Ya completé mi pago'),
          ),
        ],
      ),
    );
  }

  Widget _buildPlanCard(MarketplacePlan plan, bool isDark) {
    final currentPlanId = _myStatus?.planId ?? _subscription?.planId ?? 'free';
    final isCurrentPlan = plan.id == currentPlanId;
    final isRecommended = plan.id == 'pro_student';
    final isFreePlan = plan.priceMonthly <= 0 || plan.id == 'free';

    final borderColor = isCurrentPlan
        ? const Color(0xFF10B981)
        : (isRecommended
            ? ZanateColors.zanateEyeYellow
            : ZanateColors.border(isDark));

    final bool disableAction =
        isCurrentPlan ||
        _isSubmittingBilling ||
        (_isAuthenticated && isFreePlan);

    return Container(
      decoration: BoxDecoration(
        color: ZanateColors.card(isDark),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: borderColor,
          width: isCurrentPlan || isRecommended ? 1.5 : 1.0,
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Plan Name & Badges
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  plan.name,
                  style: GoogleFonts.outfit(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white : ZanateColors.zanateBlack,
                  ),
                ),
              ),
              if (isCurrentPlan || isRecommended) const SizedBox(width: 8),
              if (isCurrentPlan)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF10B981).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'Plan actual',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF059669),
                    ),
                  ),
                )
              else if (isRecommended)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: ZanateColors.zanateEyeYellow,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'Recomendado',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                      color: ZanateColors.zanateBlack,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),

          // Price
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                plan.formattedPrice,
                style: GoogleFonts.outfit(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: isDark
                      ? ZanateColors.zanateEyeYellow
                      : ZanateColors.zanateBlack,
                ),
              ),
              if (plan.priceMonthly > 0)
                Text(
                  ' /mes',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark
                        ? const Color(0xFF94A3B8)
                        : const Color(0xFF64748B),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),

          // Limits Summary
          Text(
            plan.isUnlimited
                ? 'Publicaciones activas: Ilimitadas'
                : 'Hasta ${plan.maxActiveItems} publicaciones activas',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${plan.maxImagesPerItem} imágenes por publicación${plan.allowVideo ? ' + video' : ''}',
            style: TextStyle(
              fontSize: 11.5,
              color: isDark
                  ? const Color(0xFF94A3B8)
                  : const Color(0xFF64748B),
            ),
          ),
          const SizedBox(height: 12),

          // Features List
          ...plan.features.map(
            (feat) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Icon(
                      PhosphorIconsBold.check,
                      size: 13,
                      color: Color(0xFF10B981),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      feat,
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark
                            ? const Color(0xFFE2E8F0)
                            : ZanateColors.zanateDark,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),

          // Action Button
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: disableAction
                  ? ZanateColors.pill(isDark)
                  : ZanateColors.ctaBg(isDark),
              foregroundColor: disableAction
                  ? ZanateColors.textMuted(isDark)
                  : ZanateColors.ctaFg(isDark),
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            onPressed: disableAction ? null : () => _handlePlanAction(plan),
            child: Text(
              isCurrentPlan
                  ? 'Plan actual'
                  : (!_isAuthenticated
                      ? 'Inicia sesión para solicitar'
                      : (isFreePlan ? 'Plan base' : 'Mejorar plan')),
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: disableAction
                    ? Colors.grey
                    : (isDark ? ZanateColors.zanateBlack : Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
