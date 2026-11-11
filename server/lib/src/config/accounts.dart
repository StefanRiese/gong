import 'dart:math';

import '../storage/app_database.dart';
import 'app_config.dart';
import 'env.dart';

/// A Schulportal account (child) the server shows. All accounts are kept in
/// [AccountStore]; the first one answers the API paths without account.
class AccountConfig {
  /// Id of the account that existed before several accounts were possible
  /// (version 0.18 and older; see `migrateLegacyAccount`).
  static const legacyId = 'main';

  /// Number of accounts.
  static const maxAccounts = 8;
  static const maxNameLength = 40;

  /// Letters and digits only (used in database keys and URLs).
  static final idPattern = RegExp(r'^[a-z0-9]{1,16}$');

  final String id;

  /// Name shown in the account switcher, e.g. the child's first name.
  final String name;
  final SphCredentials sph;
  final CasedaConfig? caseda;
  final UntisConfig? untis;

  const AccountConfig({
    required this.id,
    required this.name,
    required this.sph,
    this.caseda,
    this.untis,
  });

  /// Stored form, including passwords (like the other web UI settings).
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'schoolId': sph.schoolId,
    'username': sph.username,
    'password': sph.password,
    if (caseda != null)
      'caseda': {
        'url': caseda!.url.toString(),
        'username': caseda!.username,
        'password': caseda!.password,
      },
    if (untis != null)
      'untis': {
        'server': untis!.server,
        'school': untis!.school,
        'username': untis!.username,
        'password': untis!.password,
      },
  };

  /// For the web UI: no passwords.
  Map<String, Object?> describe() => {
    'id': id,
    'name': name,
    'schoolId': sph.schoolId,
    'username': sph.username,
    'caseda': caseda == null
        ? null
        : {'url': caseda!.url.toString(), 'username': caseda!.username},
    'untis': untis == null
        ? null
        : {
            'server': untis!.server,
            'school': untis!.school,
            'username': untis!.username,
          },
  };

  /// Reads a stored account; null if it is damaged.
  static AccountConfig? fromStored(Object? json) {
    try {
      return AccountConfig.parse(
        (json as Map).cast<String, Object?>(),
        id: (json['id'] as String?) ?? '',
      );
    } on Object {
      return null;
    }
  }

  /// Validates [json] (from the web UI or the database). With [base], fields
  /// that are missing keep their value (partial update); an empty password
  /// keeps the stored one. `caseda` / `untis` set to null remove the login.
  /// Throws [ConfigException] listing the problems.
  factory AccountConfig.parse(
    Map<String, Object?> json, {
    required String id,
    AccountConfig? base,
  }) {
    final problems = <String>[];
    if (!idPattern.hasMatch(id)) problems.add('Invalid id');

    String? text(Map<String, Object?> m, String key) {
      final v = m[key];
      if (v == null) return null;
      if (v is! String && v is! num) {
        problems.add('$key must be text');
        return null;
      }
      final t = '$v'.trim();
      return t.isEmpty ? null : t;
    }

    // Without a name the user name is shown.
    final username = text(json, 'username') ?? base?.sph.username;
    final name =
        text(json, 'name') ??
        base?.name ??
        (username != null && username.length > maxNameLength
            ? username.substring(0, maxNameLength)
            : username);
    if (name != null && name.length > maxNameLength) {
      problems.add('The name may have at most $maxNameLength characters');
    }

    final schoolRaw = text(json, 'schoolId');
    final schoolId = schoolRaw == null
        ? base?.sph.schoolId ?? 6128
        : int.tryParse(schoolRaw);
    if (schoolId == null || schoolId < 1) {
      problems.add('schoolId must be a number');
    }
    if (username == null) {
      problems.add('A username is required');
    } else if (username.length > 100) {
      problems.add('The username is too long');
    }
    final password = text(json, 'password') ?? base?.sph.password;
    if (password == null) problems.add('A password is required');

    CasedaConfig? caseda = base?.caseda;
    if (json.containsKey('caseda')) {
      final c = json['caseda'];
      if (c == null) {
        caseda = null;
      } else if (c is! Map) {
        problems.add('caseda must be an object');
      } else {
        final m = c.cast<String, Object?>();
        final user = text(m, 'username') ?? base?.caseda?.username;
        final pw = text(m, 'password') ?? base?.caseda?.password;
        final url = Uri.tryParse(
          text(m, 'url') ??
              base?.caseda?.url.toString() ??
              'https://www.caseda-schulmenue.de',
        );
        if (user == null || pw == null) {
          problems.add('Caseda: username and password are both needed');
        } else if (url == null || !url.isScheme('https') || url.host.isEmpty) {
          problems.add('Caseda: the address must be an https URL');
        } else {
          caseda = CasedaConfig(url: url, username: user, password: pw);
        }
      }
    }

    UntisConfig? untis = base?.untis;
    if (json.containsKey('untis')) {
      final u = json['untis'];
      if (u == null) {
        untis = null;
      } else if (u is! Map) {
        problems.add('untis must be an object');
      } else {
        final m = u.cast<String, Object?>();
        final serverRaw = text(m, 'server') ?? base?.untis?.server;
        final server = serverRaw == null
            ? null
            : UntisConfig.parseServer(serverRaw);
        final user = text(m, 'username') ?? base?.untis?.username;
        final pw = text(m, 'password') ?? base?.untis?.password;
        if (serverRaw == null || user == null || pw == null) {
          problems.add('WebUntis: address, username and password are needed');
        } else if (server == null) {
          problems.add('WebUntis: the address must be like xyz.webuntis.com');
        } else {
          untis = UntisConfig(
            server: server,
            // Same server: keep the school name; another one: derive it.
            school:
                text(m, 'school') ??
                (server == base?.untis?.server ? base?.untis?.school : null) ??
                server.split('.').first,
            username: user,
            password: pw,
          );
        }
      }
    }

    if (problems.isNotEmpty) throw ConfigException(problems);
    return AccountConfig(
      id: id,
      name: name!,
      sph: SphCredentials(schoolId!, username!, password!),
      caseda: caseda,
      untis: untis,
    );
  }

  /// A new id that is not in [taken].
  static String newId(Set<String> taken, [Random? random]) {
    final r = random ?? Random.secure();
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    while (true) {
      final id = String.fromCharCodes(
        List.generate(6, (_) => chars.codeUnitAt(r.nextInt(chars.length))),
      );
      if (!taken.contains(id)) return id;
    }
  }
}

/// The further accounts, stored in the database.
class AccountStore {
  static const _key = 'accounts';
  final AppDatabase db;

  AccountStore(this.db);

  List<AccountConfig> load() {
    final raw = db.getJson(_key)?['accounts'];
    if (raw is! List) return [];
    return [for (final a in raw) ?AccountConfig.fromStored(a)];
  }

  void save(List<AccountConfig> accounts) => db.setJson(_key, {
    'accounts': [for (final a in accounts) a.toJson()],
  });
}
