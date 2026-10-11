import 'package:finance_app/auth_service.dart';

class FakeAuth extends AuthService {
  String userId = 'owner';
  @override
  String? get currentUserId => signedIn ? userId : null;
  FakeAuth({this.signedIn = false});
  bool signedIn;
  Object? error;
  int attempts = 0;
  String? email;
  String? password;

  @override
  bool get isSignedIn => signedIn;
  @override
  String? get sessionError => null;

  @override
  Future<void> signIn(String email, String password) async {
    attempts++;
    this.email = email;
    this.password = password;
    if (error != null) throw error!;
    signedIn = true;
    notifyListeners();
  }

  @override
  Future<void> signOut() async {
    if (error != null) throw error!;
    signedIn = false;
    notifyListeners();
  }
}
