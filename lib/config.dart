class AppConfig {
  static const backupApiUrl = String.fromEnvironment('BACKUP_API_URL');
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const publishableKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
  );

  static bool get isValid {
    final uri = Uri.tryParse(supabaseUrl);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        publishableKey.startsWith('sb_publishable_');
  }
}
