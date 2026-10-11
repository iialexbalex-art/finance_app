// QA only. No Supabase, no mutations of user data, no installer on app launch.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:finance_app/app_theme.dart';
import 'package:finance_app/business_expense_catalog.dart';
import 'package:finance_app/categories_screen.dart';
import 'package:finance_app/expenses_screen.dart';
import 'package:finance_app/finance_repository.dart';

import 'package:finance_app/auth_service.dart';
import 'package:finance_app/category.dart';
import 'package:finance_app/expense.dart';
import 'package:finance_app/expense_filter.dart';
import 'package:finance_app/expense_draft_store.dart';

const businessSpace = FinanceSpace(
  id: 'business',
  ownerUserId: 'owner',
  name: 'Бизнес',
  kind: 'business',
);

class PreviewAuth extends AuthService {
  @override
  bool get isSignedIn => true;
  @override
  String get currentUserId => 'owner';
  @override
  String? get sessionError => null;
  @override
  Future<void> signIn(String email, String password) async {}
  @override
  Future<void> signOut() async {}
}

class PreviewRepository extends FinanceRepository {
  final categories = businessExpenseFixtures('business');
  final walletList = [
    const Wallet(
      id: 'cash',
      spaceId: 'business',
      name: 'Касса офис',
      group: WalletGroup.cash,
      currency: 'RUB',
      iconId: 'cash_register',
    ),
  ];
  @override
  final expenseDrafts = MemoryExpenseDraftStore();
  @override
  Future<List<FinanceCategory>> loadCategories(
    String spaceId,
    CategoryKind kind,
  ) async =>
      categories.where((c) => c.spaceId == spaceId && c.kind == kind).toList();
  @override
  Future<List<Wallet>> loadWallets(String spaceId) async => walletList;
  @override
  Future<ExpenseQueryResult> queryExpenses(
    String spaceId,
    ExpenseFilter filter, {
    Expense? before,
    required bool includeTotals,
  }) async => ExpenseQueryResult(ExpensePage([], false), []);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Preview is read-only');
}

void main() {
  final params = Uri.base.queryParameters;
  final repository = PreviewRepository();
  final auth = PreviewAuth();
  final expansion = <String, Set<String>>{
    'business:expense:true': params['view'] == 'expanded'
        ? {'advertising', 'salary'}
        : <String>{},
  };
  runApp(
    MaterialApp(
      title: 'Бизнес · предпросмотр нового каталога',
      theme: params['theme'] == 'dark'
          ? ThemeData.dark(useMaterial3: true)
          : financeTheme(),
      debugShowCheckedModeBanner: false,
      locale: const Locale('ru'),
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: const [Locale('ru')],
      home: Scaffold(
        appBar: AppBar(title: const Text('Предпросмотр · Бизнес → Расходы')),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1100),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Контрольные данные пакета: 11 основных категорий и 51 подкатегория. Изменения в базе проверяются отдельно.',
                  ),
                  const SizedBox(height: 16),
                  if (params['view'] == 'expense')
                    ExpensesScreen(
                      space: businessSpace,
                      isOwner: true,
                      userId: 'owner',
                      auth: auth,
                      repository: repository,
                    )
                  else
                    CategoriesScreen(
                      space: businessSpace,
                      isOwner: true,
                      repository: repository,
                      expansionState: expansion,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
