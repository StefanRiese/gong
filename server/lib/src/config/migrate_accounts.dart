import '../storage/app_database.dart';
import '../storage/portal_state.dart';
import 'accounts.dart';
import 'app_config.dart';
import 'env.dart';
import 'server_settings.dart';

/// Settings of the one account of versions before 0.19 (environment /
/// config.env / web UI). Since 0.19 every account, the first one too, lives
/// in the [AccountStore]; these keys are only read once, by
/// [migrateLegacyAccount].
const legacyAccountKeys = {
  'ACCOUNT_NAME',
  'SPH_SCHOOL_ID',
  'SPH_USERNAME',
  'SPH_PASSWORD',
  'CASEDA_ENABLED',
  'CASEDA_URL',
  'CASEDA_USERNAME',
  'CASEDA_PASSWORD',
  'UNTIS_ENABLED',
  'UNTIS_SERVER',
  'UNTIS_SCHOOL',
  'UNTIS_USERNAME',
  'UNTIS_PASSWORD',
};

const _marker = 'accounts-schema';

/// Version of the account storage written by this program.
const accountsSchema = '2';

/// Update from versions before 0.19, which had one account configured by
/// the settings in [legacyAccountKeys]: makes it the first entry of the
/// [AccountStore] (id [AccountConfig.legacyId]), moves its cached data, seen
/// items, sync status and user settings to the account's scope and deletes
/// the old settings from the web UI settings. Everything happens in one
/// transaction and only once (marker in the database). Accounts that were
/// added with 0.18 stay; the old account comes first.
///
/// [env] is the environment / config file: a new installation can still get
/// its first account from `SPH_*` there (install.sh, developers' `.env`);
/// after the migration those keys are ignored.
///
/// Returns the name of the account taken over, or null if there was none
/// (or the migration was done before).
String? migrateLegacyAccount({
  required AppDatabase db,
  required Map<String, String> env,
  required WebSettingsStore web,
  required AccountStore store,
  void Function(String message)? log,
}) {
  if (db.getMeta(_marker) == accountsSchema) return null;
  final values = {...env, ...web.loadRaw()};
  final legacy = _legacyAccount(values, log ?? (_) {});
  String? taken;
  db.transaction(() {
    final accounts = store.load();
    final sameLogin =
        legacy != null &&
        accounts.any(
          (a) =>
              a.sph.schoolId == legacy.sph.schoolId &&
              a.sph.username.toLowerCase() == legacy.sph.username.toLowerCase(),
        );
    if (legacy != null && !sameLogin) {
      accounts.insert(0, legacy);
      db.moveUnscopedTo(scopePrefix(legacy.id));
      taken = legacy.name;
    } else {
      db.resetPortalState(); // nothing belongs to the data without scope
    }
    store.save(accounts);
    // Saving keeps the settings that still exist and drops the old ones.
    web.save(web.loadRaw());
    db.setMeta(_marker, accountsSchema);
  });
  if (taken != null) {
    (log ?? (_) {})('Account "$taken" taken over from the old settings');
  }
  return taken;
}

AccountConfig? _legacyAccount(
  Map<String, String> values,
  void Function(String) log,
) {
  String? get(String key) {
    final v = values[key]?.trim();
    return v == null || v.isEmpty ? null : v;
  }

  bool enabled(String key) => !const {
    '0',
    'false',
    'no',
    'off',
  }.contains(values[key]?.trim().toLowerCase());

  final sph = SphCredentials.fromEnv(values);
  if (sph == null) return null;

  final caseda =
      get('CASEDA_USERNAME') != null &&
          get('CASEDA_PASSWORD') != null &&
          enabled('CASEDA_ENABLED')
      ? {
          'url': get('CASEDA_URL'),
          'username': get('CASEDA_USERNAME'),
          'password': get('CASEDA_PASSWORD'),
        }
      : null;
  final untis =
      get('UNTIS_SERVER') != null &&
          get('UNTIS_USERNAME') != null &&
          get('UNTIS_PASSWORD') != null &&
          enabled('UNTIS_ENABLED')
      ? {
          'server': get('UNTIS_SERVER'),
          'school': get('UNTIS_SCHOOL'),
          'username': get('UNTIS_USERNAME'),
          'password': get('UNTIS_PASSWORD'),
        }
      : null;

  Map<String, Object?> json({bool extras = true}) => {
    'name': get('ACCOUNT_NAME'),
    'schoolId': sph.schoolId,
    'username': sph.username,
    'password': sph.password,
    if (extras && caseda != null) 'caseda': caseda,
    if (extras && untis != null) 'untis': untis,
  };

  try {
    return AccountConfig.parse(json(), id: AccountConfig.legacyId);
  } on ConfigException catch (e) {
    log(
      'Old settings: Caseda / WebUntis not taken over (${e.problems.join('; ')})',
    );
  }
  try {
    return AccountConfig.parse(json(extras: false), id: AccountConfig.legacyId);
  } on ConfigException catch (e) {
    log('Old settings: account not taken over (${e.problems.join('; ')})');
    return null;
  }
}
