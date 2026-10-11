import 'dart:convert';
import 'dart:io';

import 'package:finance_app/category.dart';
import 'package:finance_app/expense.dart';
import 'package:finance_app/finance_repository.dart';
import 'package:finance_app/report_model.dart';
import 'package:finance_app/report_export.dart';
import 'package:finance_app/transfer.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_finance.dart';

Expense reportEntry(
  String id, {
  String date = '2026-10-03',
  String currency = 'RUB',
  int scale = 2,
  String amount = '100',
  String category = 'food',
  String wallet = 'archive',
  String comment = '',
  String? transfer,
}) => Expense(
  id: id,
  date: date,
  amount: BigInt.parse(amount),
  currency: currency,
  scale: scale,
  walletId: wallet,
  categoryId: category,
  walletName: 'Снимок',
  categoryPath: '',
  comment: comment,
  transferId: transfer,
);
FakeFinance reportFixture() {
  final repo = FakeFinance();
  repo.wallets['business'] = [
    const Wallet(
      id: 'archive',
      spaceId: 'business',
      name: 'Архивный счёт',
      group: WalletGroup.bankAccount,
      currency: 'RUB',
      isArchived: true,
    ),
  ];
  repo.categories.addAll([
    const FinanceCategory(
      id: 'root',
      spaceId: 'business',
      kind: CategoryKind.expense,
      name: 'Бизнес',
    ),
    const FinanceCategory(
      id: 'food',
      spaceId: 'business',
      kind: CategoryKind.expense,
      name: 'Еда',
      parentId: 'root',
      isArchived: true,
    ),
  ]);
  repo.expenseRows['business'] = [
    reportEntry('first', date: '2026-10-01', amount: '100'),
    reportEntry('last', amount: '250'),
    reportEntry('fee', amount: '50', transfer: 'transfer-id'),
    reportEntry('missing', category: '', amount: '20'),
    reportEntry('usd', currency: 'USD', amount: '123'),
    reportEntry('old', date: '2026-09-03', amount: '100'),
    reportEntry('future', date: '2026-10-04', amount: '999999'),
  ];
  repo.expenseRows['personal'] = [reportEntry('personal', amount: '999')];
  repo.incomeLedger.expenseRows['business'] = [
    reportEntry('income', amount: '1000'),
  ];
  return repo;
}

void main() {
  final now = DateTime(2026, 10, 3);
  test('boundaries, archived history, currencies, missing categories, fee counted once, no balance reads', () async {
    final repo = reportFixture();
    final p = ReportParams.preset(ReportKind.businessExpenses);
    final data = await loadReportData(repo, repo.spaces, 'owner', p.range(now));
    final rows = data.select(p, p.range(now));
    final totals = reportTotals(rows);
    expect(
      totals.firstWhere((t) => t.currency == 'RUB').expense,
      BigInt.from(420),
    );
    expect(
      totals.firstWhere((t) => t.currency == 'USD').expense,
      BigInt.from(123),
    );
    expect(rows.length, 5);
    expect(rows.where((o) => o.entry.transferId != null).length, 1);
    expect(
      reportBuckets(
        data,
        rows,
        p,
        'RUB',
      ).any((b) => b.label == 'Без категории'),
      isTrue,
    );
    expect(data.walletName(rows.first.entry), contains('архив'));
    expect(repo.balanceReads + repo.currentReads, 0);
    expect(repo.totalsRequests.every((v) => !v), isTrue);
  });
  test('pagination beyond 1000, no truncation or writes', () async {
    final repo = FakeFinance();
    repo.expenseRows['business'] = List.generate(
      1103,
      (i) => reportEntry('id-${i.toString().padLeft(5, '0')}'),
    );
    final p = ReportParams.preset(ReportKind.businessExpenses);
    final data = await loadReportData(
      repo,
      [businessSpace],
      'owner',
      p.range(now),
    );
    expect(data.operations.length, 1103);
    expect(
      reportTotals(data.select(p, p.range(now))).single.expense,
      BigInt.from(110300),
    );
    expect(repo.filters.length, 45);
    expect(
      repo.expenseWrites +
          repo.inserts +
          repo.categoryWrites +
          repo.balanceWrites,
      0,
    );
  });
  test('ordinary transfers have no cash-flow effect; changing fee counts it exactly once', () async {
    final repo = FakeFinance();
    PendingTransfer transfer(
      String request,
      String fee, {
      String? id,
      String? revision,
    }) => PendingTransfer(
      requestId: request,
      data: {
        'space_id': 'business',
        'id': id,
        'revision': revision,
        'source_id': 'cash',
        'target_id': 'target',
        'source_minor': '100000',
        'target_minor': '100000',
        'source_currency': 'RUB',
        'target_currency': 'RUB',
        'source_scale': 2,
        'target_scale': 2,
        'date': '2026-10-03',
        'comment': 'Перевод',
        'fee_minor': fee,
        'fee_category_id': fee == '0' ? null : 'fees',
      },
      display: {
        'source_name': 'Касса',
        'target_name': 'Карта',
        'fee_category_path': fee == '0' ? null : 'Комиссии',
      },
    );
    final id = repo.commitTransfer(transfer('zero', '0'));
    var data = await loadReportData(
      repo,
      [businessSpace],
      'owner',
      const ReportRange('2026-10-01', '2026-10-03'),
    );
    expect(data.operations, isEmpty);
    final revision = repo.transfers['business']!.single.revision;
    repo.commitTransfer(transfer('fee', '123', id: id, revision: revision));
    data = await loadReportData(
      repo,
      [businessSpace],
      'owner',
      const ReportRange('2026-10-01', '2026-10-03'),
    );
    expect(data.operations.length, 1);
    expect(reportTotals(data.operations).single.expense, BigInt.from(123));
    final latest = repo.transfers['business']!.single.revision;
    repo.commitTransfer(transfer('change', '250', id: id, revision: latest));
    data = await loadReportData(
      repo,
      [businessSpace],
      'owner',
      const ReportRange('2026-10-01', '2026-10-03'),
    );
    expect(data.operations.length, 1);
    expect(reportTotals(data.operations).single.expense, BigInt.from(250));
  });
  test(
    'descendant filters do not multiply overlapping category branches',
    () async {
      final repo = reportFixture(),
          p = ReportParams.preset(ReportKind.businessExpenses)
            ..categoryIds = ['root', 'food'];
      final data = await loadReportData(
        repo,
        repo.spaces,
        'owner',
        p.range(now),
      );
      expect(data.select(p, p.range(now)).length, 4);
      expect(
        reportTotals(data.select(p, p.range(now)))
            .firstWhere((t) => t.currency == 'RUB')
            .expense,
        BigInt.from(400),
      );
    },
  );
  test(
    'exact money including different scales and numbers above JS safe integer',
    () {
      final rows = [
        ReportOperation(
          'business',
          CategoryKind.expense,
          reportEntry('1', amount: '9007199254740993'),
        ),
        ReportOperation(
          'business',
          CategoryKind.expense,
          reportEntry('2', amount: '1', scale: 0),
        ),
      ];
      expect(
        reportTotals(rows).single.expense,
        BigInt.parse('9007199254741093'),
      );
      expect(
        reportTotals(rows).single.format(ReportMetric.expense),
        '90071992547410,93 RUB',
      );
    },
  );
  test('calendar periods and comparable partial month clamp leap year', () {
    final p = ReportParams.preset(ReportKind.expenseComparison);
    expect(p.range(now).from, '2026-10-01');
    expect(p.range(now).to, '2026-10-03');
    expect(p.comparisonRange(now).from, '2026-09-01');
    expect(p.comparisonRange(now).to, '2026-09-03');
    expect(p.comparisonRange(DateTime(2024, 3, 31)).to, '2024-02-29');
    p.fullPreviousMonth = true;
    expect(p.comparisonRange(now).to, '2026-09-30');
    p.period = ReportPeriod.custom;
    p.from = '2026-09-30';
    p.to = '2026-10-01';
    p.fullPreviousMonth = false;
    expect(p.comparisonRange(now).from, '2026-09-28');
    expect(p.comparisonRange(now).to, '2026-09-29');
    expect(reportShare(BigInt.from(100), BigInt.from(80)), '125,00%');
    expect(reportShare(BigInt.from(-20), BigInt.from(80)), '-25,00%');
  });
  test(
    'bucket amounts share currency scale before percentages and sorting',
    () {
      final rows = [
        ReportOperation(
          'business',
          CategoryKind.expense,
          reportEntry('x', scale: 0, amount: '10', category: 'whole'),
        ),
        ReportOperation(
          'business',
          CategoryKind.expense,
          reportEntry('y', scale: 2, amount: '100', category: 'fraction'),
        ),
      ];
      final data = ReportData([businessSpace], [], [], rows),
          p = ReportParams.preset(ReportKind.businessExpenses);
      final buckets = reportBuckets(data, rows, p, 'RUB');
      expect(buckets.first.total.expense, BigInt.from(1000));
      expect(buckets.every((b) => b.total.scale == 2), isTrue);
      expect(
        reportRatio(
          buckets.first.total.expense,
          reportTotals(rows).single.expense,
        ),
        closeTo(10 / 11, 0.00001),
      );
    },
  );
  test(
    'relative template rolls forward, quick business preset resets everything',
    () {
      final old = ReportParams.preset(ReportKind.personalExpenses)
        ..walletIds = ['personal']
        ..search = 'text';
      final restored = ReportParams.fromJson(old.toJson());
      expect(restored.range(DateTime(2026, 11, 4)).from, '2026-11-01');
      final quick = ReportParams.preset(ReportKind.businessExpenses);
      expect(quick.scope, 'business');
      expect(quick.metric, ReportMetric.expense);
      expect(quick.walletIds, isEmpty);
      expect(quick.categoryIds, isEmpty);
      expect(quick.search, isEmpty);
    },
  );
  test('zero and negative comparison base never produces Infinity or NaN', () {
    expect(reportChange(BigInt.zero, BigInt.zero), '0%');
    expect(
      reportChange(BigInt.one, BigInt.zero),
      contains('в предыдущем периоде 0'),
    );
    expect(
      reportChange(BigInt.one, -BigInt.one),
      contains('неположительная база'),
    );
    expect(reportChange(BigInt.from(150), BigInt.from(100)), '50,00%');
  });
  test(
    'net, intersecting custom groups, unique aggregate, drilldown match',
    () async {
      final repo = reportFixture(),
          p = ReportParams.preset(ReportKind.custom)..scope = 'business';
      final data = await loadReportData(
        repo,
        repo.spaces,
        'owner',
        p.range(now),
      );
      final rows = data.select(p, p.range(now));
      final unique = uniqueReportGroups([rows, rows]);
      expect(unique.length, rows.length);
      final t = reportTotals(unique).firstWhere((t) => t.currency == 'RUB');
      expect(t.value(ReportMetric.net), BigInt.from(580));
      final buckets = reportBuckets(data, rows, p, 'RUB');
      expect(
        buckets.fold<BigInt>(
          BigInt.zero,
          (sum, b) => sum + b.total.value(p.metric),
        ),
        t.value(p.metric),
      );
    },
  );
  test('elapsed months and days are zero, future months are absent', () async {
    final repo = reportFixture(),
        p = ReportParams.preset(ReportKind.expenseMonths)..scope = 'business';
    final data = await loadReportData(repo, repo.spaces, 'owner', p.range(now));
    final buckets = reportBuckets(
      data,
      data.select(p, p.range(now)),
      p,
      'RUB',
      range: p.range(now),
    );
    expect(buckets.length, 12);
    expect(buckets.last.key, '2026-10-01');
    expect(buckets.first.total.expense, BigInt.zero);
  });
  test('manager never requests income, available spaces only', () async {
    final repo = reportFixture(), p = ReportParams.preset(ReportKind.custom);
    final data = await loadReportData(
      repo,
      [businessSpace],
      'manager',
      p.range(now),
    );
    expect(
      data.operations.every(
        (o) => o.spaceId == 'business' && o.kind == CategoryKind.expense,
      ),
      isTrue,
    );
    expect(repo.incomeLedger.filters, isEmpty);
  });
  test(
    'failed pagination fails entire report rather than partial zero',
    () async {
      final repo = FakeFinance()
        ..onExpenses = ((_, cursor) async {
          if (cursor != null) throw StateError('network');
          return ExpensePage([reportEntry('1')], true);
        });
      expect(
        loadReportData(
          repo,
          [businessSpace],
          'owner',
          const ReportRange('2026-10-01', '2026-10-03'),
        ),
        throwsStateError,
      );
    },
  );
  test(
    'CSV protects formulas, XLSX genuine zip, all periods and groups included',
    () async {
      final repo = reportFixture();
      repo.expenseRows['business']!.add(
        reportEntry('formula', comment: '=HYPERLINK("malicious")'),
      );
      final p = ReportParams.preset(ReportKind.expenseComparison)
        ..scope = 'business';
      final data = await loadReportData(
        repo,
        repo.spaces,
        'owner',
        const ReportRange('2026-09-01', '2026-10-03'),
      );
      final export = ReportExport(data: data, params: p, now: now);
      expect(export.operations.length, 7);
      final csv = utf8.decode(export.csv());
      expect(csv, contains("'=HYPERLINK"));
      expect(csv, contains('Период B'));
      final bytes = export.xlsx();
      expect(bytes.take(4), [80, 75, 3, 4]);
      final contents = utf8.decode(bytes, allowMalformed: true);
      expect(contents, contains('t="inlineStr"'));
      expect(contents, contains('=HYPERLINK'));
      expect(contents, contains('Сводка'));
      expect(contents, contains('s="1"><v>'));
      expect(contents, contains('s="2"><v>'));
      expect(contents, contains('420'));
      // Reviewable synthetic exports for independent OOXML/CSV verification.
      if (!const bool.fromEnvironment('dart.library.js_interop')) {
        Directory('build/reports_qa').createSync(recursive: true);
        File('build/reports_qa/controlled_report.xlsx').writeAsBytesSync(bytes);
        File('build/reports_qa/controlled_report.csv')
            .writeAsBytesSync(export.csv());
      }
    },
  );
}
