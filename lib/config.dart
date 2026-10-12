/// Supabase project details. Passed at build time:
///   flutter build apk --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_KEY=...
/// (The GitHub build reads them from the repository secrets.)
const supabaseUrl = String.fromEnvironment('SUPABASE_URL');

/// The project's publishable (anon) key. It is safe inside the app: every table is
/// protected by row level security.
const supabaseKey = String.fromEnvironment('SUPABASE_KEY');

bool get isConfigured => supabaseUrl.isNotEmpty && supabaseKey.isNotEmpty;
