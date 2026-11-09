import 'package:gong_server/gong_server.dart';
import 'package:test/test.dart';

void main() {
  group('PasswordHasher', () {
    test('verifies correct password and rejects wrong one', () {
      final hash = PasswordHasher.hash('geheim123', iterations: 1000);
      expect(hash, startsWith(r'pbkdf2-sha256$1000$'));
      expect(PasswordHasher.verify('geheim123', hash), isTrue);
      expect(PasswordHasher.verify('geheim124', hash), isFalse);
    });

    test('uses a random salt', () {
      expect(
        PasswordHasher.hash('x', iterations: 10),
        isNot(PasswordHasher.hash('x', iterations: 10)),
      );
    });

    test('matches RFC 7914 PBKDF2-HMAC-SHA256 test vector', () {
      // RFC 7914 §11: P="passwd", S="salt", c=1, dkLen=64 (first 32 bytes).
      const encoded =
          r'pbkdf2-sha256$1$c2FsdA$VawEblbjCJ_sFpHCJUS2BflBhSFt3gRl5oudV8INrLw';
      expect(PasswordHasher.verify('passwd', encoded), isTrue);
      // RFC 7914 §11: P="Password", S="NaCl", c=80000 (first 32 bytes).
      const encoded2 =
          r'pbkdf2-sha256$80000$TmFDbA$TdzY9guYviGDDO5e8icB-WQaRBjQTAQUrv8Ih2s0q1Y';
      expect(PasswordHasher.verify('Password', encoded2), isTrue);
    });

    test('rejects malformed hashes', () {
      for (final bad in [
        '',
        'plain',
        r'md5$1$c2FsdA$AAAA',
        r'pbkdf2-sha256$x$c2FsdA$AAAA',
        r'pbkdf2-sha256$1$$AAAA',
      ]) {
        expect(PasswordHasher.isValidFormat(bad), isFalse, reason: bad);
        expect(PasswordHasher.verify('x', bad), isFalse, reason: bad);
      }
    });
  });

  group('SessionStore', () {
    test('creates, validates with sliding expiry, revokes', () {
      var now = DateTime(2026, 11, 9);
      final store = SessionStore(ttl: const Duration(days: 1), now: () => now);
      final token = store.create();
      expect(token.length, greaterThanOrEqualTo(40));
      now = now.add(const Duration(hours: 20));
      expect(store.validate(token), isTrue);
      now = now.add(const Duration(hours: 20)); // sliding: still valid
      expect(store.validate(token), isTrue);
      now = now.add(const Duration(days: 2));
      expect(store.validate(token), isFalse);

      final t2 = store.create();
      store.revoke(t2);
      expect(store.validate(t2), isFalse);
      expect(store.validate(null), isFalse);
      expect(store.validate('unknown'), isFalse);
    });
  });

  group('LoginRateLimiter', () {
    test('blocks after max failures until window passes', () {
      var now = DateTime(2026, 11, 9);
      final limiter = LoginRateLimiter(
        maxFailures: 3,
        window: const Duration(minutes: 10),
        now: () => now,
      );
      for (var i = 0; i < 3; i++) {
        expect(limiter.retryAfter('ip'), isNull);
        limiter.recordFailure('ip');
        now = now.add(const Duration(minutes: 1));
      }
      expect(limiter.retryAfter('ip'), const Duration(minutes: 7));
      expect(limiter.retryAfter('other'), isNull);
      now = now.add(const Duration(minutes: 8));
      expect(limiter.retryAfter('ip'), isNull);
    });

    test('reset clears failures', () {
      final limiter = LoginRateLimiter(maxFailures: 1);
      limiter.recordFailure('ip');
      expect(limiter.retryAfter('ip'), isNotNull);
      limiter.reset('ip');
      expect(limiter.retryAfter('ip'), isNull);
    });
  });

  group('AppConfig', () {
    final hash = PasswordHasher.hash('geheim123', iterations: 10);

    test('parses env with defaults', () {
      final c = AppConfig.fromEnv({
        'SPH_USERNAME': 'u',
        'SPH_PASSWORD': 'p',
        'APP_PASSWORD_HASH': hash,
      });
      expect(c.sph.schoolId, 6128);
      expect(c.host, '127.0.0.1');
      expect(c.port, 8080);
      expect(c.webDir, isNull);
      expect(c.cookieSecure, isFalse);
      expect(c.sessionTtl, const Duration(days: 30));
    });

    test('parses overrides', () {
      final c = AppConfig.fromEnv({
        'SPH_SCHOOL_ID': '5151',
        'SPH_USERNAME': 'u',
        'SPH_PASSWORD': 'p',
        'APP_PASSWORD_HASH': hash,
        'HOST': '0.0.0.0',
        'PORT': '9000',
        'WEB_DIR': '/opt/web',
        'COOKIE_SECURE': 'true',
        'TRUST_PROXY': '1',
        'SESSION_TTL_DAYS': '7',
      });
      expect(c.sph.schoolId, 5151);
      expect(c.host, '0.0.0.0');
      expect(c.port, 9000);
      expect(c.webDir, '/opt/web');
      expect(c.cookieSecure, isTrue);
      expect(c.trustProxy, isTrue);
      expect(c.sessionTtl, const Duration(days: 7));
    });

    test('reports all problems at once', () {
      expect(
        () => AppConfig.fromEnv({'PORT': 'abc', 'APP_PASSWORD_HASH': 'x'}),
        throwsA(
          isA<ConfigException>().having((e) => e.problems, 'problems', [
            contains('SPH_USERNAME'),
            contains('invalid format'),
            contains('PORT'),
          ]),
        ),
      );
    });

    test('APP_PASSWORD (plain) is hashed and wins over the hash', () {
      final c = AppConfig.fromEnv({
        'SPH_USERNAME': 'u',
        'SPH_PASSWORD': 'p',
        'APP_PASSWORD': 'neues-passwort',
        'APP_PASSWORD_HASH': hash,
        'OPEN_BROWSER': 'true',
      }, passwordIterations: 10);
      expect(
        PasswordHasher.verify('neues-passwort', c.appPasswordHash),
        isTrue,
      );
      expect(c.openBrowser, isTrue);
      expect(
        () => AppConfig.fromEnv({
          'SPH_USERNAME': 'u',
          'SPH_PASSWORD': 'p',
          'APP_PASSWORD': 'kurz',
        }, passwordIterations: 10),
        throwsA(
          isA<ConfigException>().having((e) => e.problems, 'problems', [
            contains('at least 8'),
          ]),
        ),
      );
    });
  });
}
