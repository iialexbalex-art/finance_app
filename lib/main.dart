import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_service.dart';
import 'config.dart';
import 'login_screen.dart';
import 'finance_controller.dart';
import 'finance_repository.dart';
import 'wallets_screen.dart';
import 'categories_screen.dart';
import 'expenses_screen.dart';
import 'app_theme.dart';
import 'transfers_screen.dart';
import 'overview_screen.dart';
import 'reports_screen.dart';
import 'backups_screen.dart';
import 'backup_service.dart';
import 'restored_assets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  String? startupError;
  AuthService? auth;
  if (!AppConfig.isValid) {
    startupError = 'Не заданы параметры подключения. Запустите приложение с --dart-define-from-file=config/local.json.';
  } else {
    try {
      await Supabase.initialize(
        url: AppConfig.supabaseUrl,
        publishableKey: AppConfig.publishableKey,
      );
      auth = SupabaseAuthService(Supabase.instance.client);
    } catch (_) {
      startupError = 'Не удалось подготовить подключение. Проверьте конфигурацию и перезапустите приложение.';
    }
  }
  runApp(
    FinanceApp(
      auth: auth,
      startupError: startupError,
      repository: auth == null
          ? null
          : SupabaseFinanceRepository(Supabase.instance.client),
    ),
  );
}

class FinanceApp extends StatelessWidget {
  const FinanceApp({this.auth, this.startupError, this.repository, super.key});
  final AuthService? auth;
  final String? startupError;
  final FinanceRepository? repository;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Финансы',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: financeTheme(),
      home: auth == null
          ? Scaffold(
              appBar: AppBar(title: const Text('Финансы')),
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(startupError ?? 'Подключение не настроено.'),
                ),
              ),
            )
          : ListenableBuilder(
              listenable: auth!,
              builder: (context, _) => auth!.isSignedIn
                  ? FinanceHome(
                      key: ValueKey(auth!.currentUserId),
                      auth: auth!,
                      repository: repository!,
                    )
                  : LoginScreen(auth: auth!),
            ),
    );
  }
}

enum AppSection {
  overview('Обзор', Icons.dashboard_outlined),
  wallets('Кошельки', Icons.account_balance_wallet_outlined),
  incomes('Доходы', Icons.add_card_outlined),
  transactions('Расходы', Icons.receipt_long_outlined),
  transfers('Переводы', Icons.swap_horiz),
  reports('Отчёты', Icons.analytics_outlined),
  categories('Категории', Icons.category_outlined),
  settings('Настройки', Icons.settings_outlined);

  const AppSection(this.label, this.icon);
  final String label;
  final IconData icon;
}

class FinanceHome extends StatefulWidget {
  const FinanceHome({required this.auth, required this.repository, super.key});
  final AuthService auth;
  final FinanceRepository repository;

  @override
  State<FinanceHome> createState() => _FinanceHomeState();
}

class _FinanceHomeState extends State<FinanceHome> {
  AppSection _section = AppSection.overview;
  late final FinanceController _finance;
  String? _expenseWalletId, _expenseSpaceId;
  String? _transferId;
  int _walletsEpoch = 0;
  int _reportsEpoch = 0;
  bool _templatesSyncStarted = false;
  final Map<String, Set<String>> _categoryExpansion = {};
  void _cashflowChanged() {
    _reportsEpoch++;
    _walletsEpoch++;
    _finance.loadWallets();
  }

  List<AppSection> get _sections => AppSection.values
      .where(
        (s) =>
            _finance.isOwner ||
            (s != AppSection.incomes &&
                s != AppSection.transfers &&
                s != AppSection.settings),
      )
      .toList();

  @override
  void initState() {
    super.initState();
    _finance = FinanceController(widget.auth, widget.repository);
    _finance.addListener(_changed);
    if (widget.repository is SupabaseFinanceRepository) {
      RestoredAssets.instance
          .load((widget.repository as SupabaseFinanceRepository).client)
          .catchError((Object _) {});
    }
  }

  void _changed() {
    if (!_templatesSyncStarted &&
        widget.repository is SupabaseFinanceRepository &&
        _finance.spaces.any(
          (s) => s.ownerUserId == widget.auth.currentUserId,
        )) {
      _templatesSyncStarted = true;
      BackupService((widget.repository as SupabaseFinanceRepository).client)
          .syncLegacyTemplates()
          .catchError((Object _) {});
    }
    if (_expenseSpaceId != _finance.selectedSpace?.id) {
      _expenseWalletId = null;
      _transferId = null;
    }
    if (!_sections.contains(_section)) _section = AppSection.overview;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    RestoredAssets.instance.clear();
    _finance.dispose();
    super.dispose();
  }

  void _select(int index) {
    setState(() {
      _section = AppSection.values[index];
      if (_section == AppSection.wallets) _walletsEpoch++;
      if (_section == AppSection.reports) _reportsEpoch++;
      _expenseWalletId = null;
      _transferId = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 760;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Финансы'),
            actions: [
              SignOutButton(auth: widget.auth),
              const SizedBox(width: 8),
            ],
            centerTitle: false,
          ),
          body: SafeArea(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (wide) ...[
                  SingleChildScrollView(
                    child: IntrinsicHeight(
                      child: NavigationRail(
                        extended: true,
                        selectedIndex: _sections.indexOf(_section),
                        onDestinationSelected: (index) =>
                            _select(_sections[index].index),
                        destinations: [
                          for (final section in _sections)
                            NavigationRailDestination(
                              icon: Icon(section.icon),
                              label: Text(section.label),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const VerticalDivider(width: 1),
                ],
                Expanded(
                  child: SingleChildScrollView(
                    key: ValueKey(_section),
                    padding: EdgeInsets.all(wide ? 32 : 16),
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1040),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (_section != AppSection.reports)
                              SpaceSelector(controller: _finance),
                            const SizedBox(height: 24),
                            Text(
                              _section.label,
                              style: Theme.of(context).textTheme.headlineMedium,
                            ),
                            const SizedBox(height: 8),
                            Text(switch (_section) {
                              AppSection.overview =>
                                'Ваши финансы в одном месте',
                              AppSection.wallets =>
                                'Счета и средства по группам',
                              AppSection.transactions =>
                                'Расходы выбранного пространства',
                              AppSection.incomes =>
                                'Доходы выбранного пространства',
                              AppSection.transfers =>
                                'Переводы между кошельками пространства',
                              AppSection.categories =>
                                'Категории выбранного пространства',
                              AppSection.reports =>
                                'Категории, динамика и денежный результат',
                              AppSection.settings =>
                                'Резервные копии и история изменений',
                            }, style: Theme.of(context).textTheme.bodyLarge),
                            const SizedBox(height: 24),
                            if (_section == AppSection.reports &&
                                _finance.selectedSpace == null)
                              if (_finance.loadingSpaces)
                                const Center(child: CircularProgressIndicator())
                              else if (_finance.spacesError != null)
                                Column(
                                  children: [
                                    Text(_finance.spacesError!),
                                    TextButton(
                                      onPressed: _finance.loadSpaces,
                                      child: const Text(
                                        'Повторить загрузку пространств',
                                      ),
                                    ),
                                  ],
                                )
                              else
                                const Text(
                                  'Нет доступных пространств для отчётов.',
                                ),
                            if (_finance.selectedSpace != null)
                              switch (_section) {
                                AppSection.settings =>
                                  widget.repository is SupabaseFinanceRepository
                                      ? BackupsScreen(
                                          service: BackupService(
                                            (widget.repository
                                                    as SupabaseFinanceRepository)
                                                .client,
                                          ),
                                          onRestored: () {
                                            _categoryExpansion.clear();
                                            _cashflowChanged();
                                            _finance.loadSpaces();
                                            RestoredAssets.instance
                                                .load(
                                                  (widget.repository
                                                          as SupabaseFinanceRepository)
                                                      .client,
                                                )
                                                .catchError((Object _) {});
                                            setState(() {});
                                          },
                                        )
                                      : const Text(
                                          'Сервер резервирования не подключён.',
                                        ),
                                AppSection.reports => ReportsScreen(
                                  key: ValueKey('reports:$_reportsEpoch'),
                                  repository: widget.repository,
                                  spaces: _finance.spaces,
                                  userId: widget.auth.currentUserId!,
                                ),
                                AppSection.overview => OverviewScreen(
                                  key: ValueKey(
                                    'overview:${_finance.spaces.map((space) => space.id).join(',')}',
                                  ),
                                  spaces: _finance.spaces
                                      .where(
                                        (space) =>
                                            space.ownerUserId ==
                                                widget.auth.currentUserId &&
                                            (space.kind == 'personal' ||
                                                space.kind == 'business'),
                                      )
                                      .toList(),
                                  isOwner: _finance.isOwner,
                                  repository: widget.repository,
                                  openWallets: () =>
                                      _select(AppSection.wallets.index),
                                ),
                                AppSection.incomes => ExpensesScreen(
                                  key: ValueKey(
                                    'income:${_finance.selectedSpace!.id}',
                                  ),
                                  space: _finance.selectedSpace!,
                                  isOwner: _finance.isOwner,
                                  userId: widget.auth.currentUserId!,
                                  auth: widget.auth,
                                  repository: widget.repository,
                                  isIncome: true,
                                  onChanged: _cashflowChanged,
                                ),
                                AppSection.transfers => TransfersScreen(
                                  key: ValueKey(
                                    'transfer:${_finance.selectedSpace!.id}:$_transferId',
                                  ),
                                  space: _finance.selectedSpace!,
                                  isOwner: _finance.isOwner,
                                  userId: widget.auth.currentUserId!,
                                  auth: widget.auth,
                                  repository: widget.repository,
                                  initialTransferId: _transferId,
                                ),
                                AppSection.wallets => WalletsScreen(
                                  key: ValueKey(
                                    '${_finance.selectedSpace!.id}:$_walletsEpoch',
                                  ),
                                  controller: _finance,
                                ),
                                AppSection.categories => CategoriesScreen(
                                  key: ValueKey(_finance.selectedSpace!.id),
                                  space: _finance.selectedSpace!,
                                  isOwner: _finance.isOwner,
                                  repository: widget.repository,
                                  expansionState: _categoryExpansion,
                                ),
                                AppSection.transactions => ExpensesScreen(
                                  key: ValueKey(_finance.selectedSpace!.id),
                                  onChanged: _cashflowChanged,
                                  initialWalletId: _expenseWalletId,
                                  onOpenTransfer: (id) => setState(() {
                                    _transferId = id;
                                    _expenseSpaceId =
                                        _finance.selectedSpace!.id;
                                    _section = AppSection.transfers;
                                  }),
                                  space: _finance.selectedSpace!,
                                  isOwner: _finance.isOwner,
                                  userId: widget.auth.currentUserId!,
                                  auth: widget.auth,
                                  repository: widget.repository,
                                ),
                              },
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          bottomNavigationBar: wide
              ? null
              : SafeArea(
                  top: false,
                  child: Material(
                    color: Colors.white,
                    child: SizedBox(
                      height: 64,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (final section in _sections)
                              SizedBox(
                                width: 84,
                                child: InkWell(
                                  onTap: () => _select(section.index),
                                  child: Semantics(
                                    selected: section == _section,
                                    button: true,
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                          section.icon,
                                          color: section == _section
                                              ? Theme.of(context)
                                                    .colorScheme
                                                    .primary
                                              : null,
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          section.label,
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: section == _section
                                                ? FontWeight.w700
                                                : FontWeight.normal,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
        );
      },
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    super.key,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
        child: Column(
          children: [
            Icon(icon, size: 48, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 20),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Text(message, textAlign: TextAlign.center),
            ),
            if (action != null) ...[const SizedBox(height: 24), action!],
          ],
        ),
      ),
    );
  }
}
