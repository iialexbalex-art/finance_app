import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

abstract class AuthService extends ChangeNotifier {
  bool get isSignedIn;
  String? get currentUserId;
  String? get sessionError;
  Future<void> signIn(String email, String password);
  Future<void> signOut();
}

class SupabaseAuthService extends AuthService {
  SupabaseAuthService(this._client) {
    _subscription = _client.auth.onAuthStateChange.listen(
      (state) {
        _sessionError = null;
        notifyListeners();
      },
      onError: (Object error, StackTrace stack) {
        _sessionError = authErrorMessage(error);
        notifyListeners();
      },
    );
  }

  final SupabaseClient _client;
  late final StreamSubscription<AuthState> _subscription;
  String? _sessionError;

  @override
  bool get isSignedIn {
    final session = _client.auth.currentSession;
    return session != null && !session.isExpired;
  }

  @override
  String? get sessionError => _sessionError;

  @override
  String? get currentUserId =>
      isSignedIn ? _client.auth.currentSession?.user.id : null;

  @override
  Future<void> signIn(String email, String password) async {
    final result = await _client.auth.signInWithPassword(
      email: email,
      password: password,
    );
    if (result.session == null) {
      throw const AuthException('No session');
    }
    notifyListeners();
  }

  @override
  Future<void> signOut() async {
    await _client.auth.signOut(scope: SignOutScope.local);
    notifyListeners();
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}

String authErrorMessage(Object error) {
  if (error is AuthRetryableFetchException || error is TimeoutException) {
    return 'Не удалось связаться с сервером. Проверьте интернет и попробуйте ещё раз.';
  }
  if (error is AuthException) {
    return switch (error.code) {
      'invalid_credentials' => 'Неверный email или пароль.',
      'email_not_confirmed' => 'Подтвердите email перед входом.',
      'over_request_rate_limit' || 'over_email_send_rate_limit' =>
        'Слишком много попыток. Подождите немного и повторите вход.',
      'user_banned' => 'Вход для этой учётной записи временно ограничен.',
      'signup_disabled' || 'email_provider_disabled' =>
        'Вход по email недоступен. Обратитесь к администратору.',
      _ => 'Не удалось выполнить запрос. Попробуйте ещё раз позднее.',
    };
  }
  return 'Не удалось выполнить запрос. Проверьте подключение и попробуйте ещё раз.';
}
