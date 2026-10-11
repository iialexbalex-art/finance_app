import 'package:flutter/material.dart';

import 'finance_repository.dart';

const expenseColor = Color(0xFFB3261E);
const incomeColor = Color(0xFF246B50);

ThemeData financeTheme() => ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(
    seedColor: const Color(0xFF246B50),
    brightness: Brightness.light,
    primary: const Color(0xFF246B50),
    surface: Colors.white,
  ),
  scaffoldBackgroundColor: const Color(0xFFF1F5F2),
  appBarTheme: const AppBarTheme(
    backgroundColor: Color(0xFF246B50),
    foregroundColor: Colors.white,
  ),
  cardTheme: CardThemeData(
    elevation: 0,
    color: Colors.white,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
  ),
  inputDecorationTheme: const InputDecorationTheme(
    filled: true,
    fillColor: Colors.white,
    border: OutlineInputBorder(),
    isDense: true,
  ),
  navigationBarTheme: const NavigationBarThemeData(
    height: 64,
    backgroundColor: Colors.white,
    labelTextStyle: WidgetStatePropertyAll(TextStyle(fontSize: 11)),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
  ),
);

IconData walletIcon(WalletGroup group) => switch (group) {
  WalletGroup.cash => Icons.payments_outlined,
  WalletGroup.bankAccount => Icons.account_balance_outlined,
  WalletGroup.card => Icons.credit_card_outlined,
};

/// Amount moves below the description on phones; neither column has a fixed height.
class FinanceRow extends StatelessWidget {
  const FinanceRow({
    required this.icon,
    required this.title,
    required this.details,
    required this.amount,
    this.onTap,
    this.action,
    this.leading,
    this.titleWidget,
    super.key,
  });
  final IconData icon;
  final String title;
  final Widget details, amount;
  final VoidCallback? onTap;
  final Widget? action;
  final Widget? leading, titleWidget;
  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.symmetric(vertical: 4),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: LayoutBuilder(
          builder: (context, box) {
            final description = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                titleWidget ??
                    Text(title, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                details,
              ],
            );
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                leading ??
                    Icon(
                      icon,
                      color: Theme.of(context).colorScheme.primary,
                      size: 22,
                    ),
                const SizedBox(width: 10),
                Expanded(
                  child: box.maxWidth < 560
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            description,
                            const SizedBox(height: 8),
                            amount,
                          ],
                        )
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: description),
                            const SizedBox(width: 16),
                            Flexible(child: amount),
                          ],
                        ),
                ),
                ?action,
              ],
            );
          },
        ),
      ),
    ),
  );
}
