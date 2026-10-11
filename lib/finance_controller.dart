import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_service.dart';
import 'expense.dart';
import 'finance_repository.dart';

enum WalletDeleteFailure { none, pendingOperation, linkedHistory, request }

class FinanceController extends ChangeNotifier {
  FinanceController(this.auth, this.repository) {
    auth.addListener(_authChanged);
    _authChanged();
  }
  final AuthService auth;
  final FinanceRepository repository;
  String? _userId;
  int _contextVersion = 0;
  int _walletRequest = 0;
  bool _disposed = false;
  List<FinanceSpace> spaces = [];
  FinanceSpace? selectedSpace;
  List<Wallet> wallets = [];
  Map<String, WalletExpenseBalance> walletBalances = {};
  bool loadingSpaces = false;
  bool loadingWallets = false;
  bool saving = false;
  String? spacesError;
  String? walletsError;
  String? saveError;
  WalletDeleteFailure deleteFailure = WalletDeleteFailure.none;

  bool get isOwner => _userId != null && selectedSpace?.ownerUserId == _userId;

  void _authChanged() {
    final id = auth.currentUserId;
    if (id == _userId) return;
    _userId = id;
    _clear();
    notifyListeners();
    if (id != null) unawaited(loadSpaces());
  }

  void _clear() {
    _contextVersion++;
    _walletRequest++;
    spaces = [];
    selectedSpace = null;
    wallets = [];
    walletBalances = {};
    loadingSpaces = loadingWallets = saving = false;
    spacesError = walletsError = saveError = null;
  }

  bool _current(int version) =>
      !_disposed &&
      version == _contextVersion &&
      _userId != null &&
      _userId == auth.currentUserId;

  Future<void> loadSpaces() async {
    if (_disposed || _userId == null) return;
    final previousId = selectedSpace?.id;
    _clear();
    final version = _contextVersion;
    loadingSpaces = true;
    notifyListeners();
    try {
      final result = await repository.loadSpaces();
      if (!_current(version)) return;
      spaces = result;
      loadingSpaces = false;
      selectedSpace =
          result.where((space) => space.id == previousId).firstOrNull ??
          result.firstOrNull;
      notifyListeners();
      if (selectedSpace != null) await loadWallets();
    } catch (error) {
      if (!_current(version)) return;
      loadingSpaces = false;
      spacesError = financeError(error);
      notifyListeners();
    }
  }

  void selectSpace(String id) {
    if (_disposed || selectedSpace?.id == id) return;
    final space = spaces.where((space) => space.id == id).firstOrNull;
    if (space == null) return;
    _contextVersion++;
    selectedSpace = space;
    saving = false;
    saveError = null;
    unawaited(loadWallets());
  }

  Future<void> loadWallets() async {
    final space = selectedSpace;
    if (_disposed || space == null || _userId == null) return;
    final version = _contextVersion;
    final request = ++_walletRequest;
    wallets = [];
    walletsError = null;
    loadingWallets = true;
    notifyListeners();
    try {
      final result = isOwner
          ? await repository.loadSpaceBalances(space.id)
          : SpaceBalances(await repository.loadWallets(space.id), const {});
      if (!_current(version) || request != _walletRequest) return;
      wallets = result.wallets;
      walletBalances = result.balances;
    } catch (error) {
      if (!_current(version) || request != _walletRequest) return;
      walletsError = financeError(error);
    }
    if (!_current(version) || request != _walletRequest) return;
    loadingWallets = false;
    notifyListeners();
  }

  Future<bool> createWallet(
    String name,
    WalletGroup group,
    String currency, {
    String? iconId,
  }) async {
    if (_disposed || saving || !isOwner || auth.currentUserId != _userId) {
      return false;
    }
    final trimmed = name.trim();
    if (trimmed.isEmpty ||
        trimmed.runes.length > 100 ||
        !walletCurrencies.contains(currency)) {
      return false;
    }
    final version = _contextVersion;
    final spaceId = selectedSpace!.id;
    saving = true;
    saveError = null;
    notifyListeners();
    try {
      await repository.createWallet(
        spaceId: spaceId,
        name: trimmed,
        group: group,
        currency: currency,
        iconId: iconId,
      );
      if (!_current(version)) return false;
      // An insert is already committed. A failed refresh must not offer another insert.
      unawaited(loadWallets());
      return true;
    } catch (error) {
      if (_current(version)) saveError = financeError(error);
      return false;
    } finally {
      if (_current(version)) {
        saving = false;
        notifyListeners();
      }
    }
  }

  Future<bool> editWallet(
    Wallet previous,
    String name,
    WalletGroup group, {
    String? iconId,
  }) async {
    final trimmed = name.trim();
    if (_disposed ||
        saving ||
        !isOwner ||
        previous.spaceId != selectedSpace?.id ||
        auth.currentUserId != _userId ||
        trimmed.isEmpty ||
        trimmed.runes.length > 100) {
      return false;
    }
    final version = _contextVersion;
    saving = true;
    saveError = null;
    notifyListeners();
    try {
      await repository.editWallet(previous, trimmed, group, iconId: iconId);
      if (!_current(version)) return false;
      await loadWallets();
      return true;
    } catch (_) {
      if (_current(version)) saveError = 'Не удалось сохранить реквизиты. Обновите кошельки: возможно, запись изменена или доступ отозван.';
      return false;
    } finally {
      if (_current(version)) {
        saving = false;
        notifyListeners();
      }
    }
  }

  Future<bool> setWalletArchived(Wallet wallet, bool archived) async {
    if (_disposed ||
        saving ||
        !isOwner ||
        wallet.spaceId != selectedSpace?.id) {
      return false;
    }
    final version = _contextVersion;
    saving = true;
    saveError = null;
    notifyListeners();
    try {
      await repository.setWalletArchived(wallet, archived);
      if (!_current(version)) return false;
      await loadWallets();
      return true;
    } catch (error) {
      if (_current(version)) saveError = financeError(error);
      return false;
    } finally {
      if (_current(version)) {
        saving = false;
        notifyListeners();
      }
    }
  }

  Future<bool> moveWallet(Wallet wallet, int delta) async {
    if (_disposed ||
        saving ||
        !isOwner ||
        wallet.spaceId != selectedSpace?.id) {
      return false;
    }
    final index = wallets.indexWhere((candidate) => candidate.id == wallet.id);
    final group = wallets
        .where(
          (candidate) =>
              candidate.group == wallet.group &&
              candidate.isArchived == wallet.isArchived,
        )
        .toList();
    final groupIndex = group.indexWhere(
      (candidate) => candidate.id == wallet.id,
    );
    final targetGroupIndex = groupIndex + delta;
    if (index < 0 ||
        groupIndex < 0 ||
        targetGroupIndex < 0 ||
        targetGroupIndex >= group.length) {
      return false;
    }
    final target = wallets.indexWhere(
      (candidate) => candidate.id == group[targetGroupIndex].id,
    );
    final ordered = [...wallets];
    final swapped = ordered[target];
    ordered[target] = ordered[index];
    ordered[index] = swapped;
    final version = _contextVersion;
    saving = true;
    saveError = null;
    notifyListeners();
    try {
      await repository.reorderWallets(
        selectedSpace!.id,
        ordered.map((item) => item.id).toList(),
      );
      if (!_current(version)) return false;
      await loadWallets();
      return true;
    } catch (error) {
      if (_current(version)) saveError = financeError(error);
      return false;
    } finally {
      if (_current(version)) {
        saving = false;
        notifyListeners();
      }
    }
  }

  Future<bool> deleteWallet(Wallet wallet) async {
    if (_disposed ||
        saving ||
        !isOwner ||
        wallet.spaceId != selectedSpace?.id) {
      return false;
    }
    final version = _contextVersion;
    saving = true;
    saveError = null;
    deleteFailure = WalletDeleteFailure.none;
    notifyListeners();
    try {
      if (await repository.hasPendingWalletUse(
        _userId!,
        wallet.spaceId,
        wallet.id,
      )) {
        deleteFailure = WalletDeleteFailure.pendingOperation;
        saveError = 'Кошелёк используется незавершённой операцией на этом устройстве. Завершите или отмените её перед удалением.';
        return false;
      }
      await repository.deleteWallet(wallet);
      if (!_current(version)) return false;
      await loadWallets();
      return true;
    } catch (error) {
      if (_current(version)) {
        if (error is PostgrestException && error.code == '23503') {
          deleteFailure = WalletDeleteFailure.linkedHistory;
          saveError = 'Кошелёк связан с расходами, доходами или переводами. Удаление невозможно; историю можно сохранить, переместив кошелёк в архив.';
        } else {
          deleteFailure = WalletDeleteFailure.request;
          saveError = financeError(error);
        }
      }
      return false;
    } finally {
      if (_current(version)) {
        saving = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    auth.removeListener(_authChanged);
    _disposed = true;
    _clear();
    super.dispose();
  }
}
