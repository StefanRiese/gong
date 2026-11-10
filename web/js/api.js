// HTTP client for the server API.

export class ApiError extends Error {
  /**
   * @param {number} status
   * @param {string} code
   * @param {string} message
   * @param {Record<string, any>} [details]
   */
  constructor(status, code, message, details = {}) {
    super(message);
    this.status = status;
    this.code = code;
    this.details = details;
  }

  get isUnauthorized() {
    return this.status === 401 && this.code === 'unauthorized';
  }
}

/**
 * Calls the API and returns the parsed JSON body (null for 204).
 * @param {string} path
 * @param {{method?: string, body?: any, headers?: Record<string, string>}} [options]
 */
export async function api(path, { method = 'GET', body, headers = {} } = {}) {
  let res;
  try {
    res = await fetch(path, {
      method,
      credentials: 'same-origin',
      headers: body === undefined ? headers : { 'content-type': 'application/json', ...headers },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  } catch {
    throw new ApiError(0, 'network', 'Server nicht erreichbar');
  }
  if (res.status === 204) return null;
  let json = null;
  try {
    json = await res.json();
  } catch {
    // non-JSON response
  }
  if (!res.ok) {
    const e = json?.error ?? {};
    const retry = res.headers.get('retry-after');
    throw new ApiError(res.status, e.code ?? `http_${res.status}`, e.message ?? res.statusText, {
      ...e,
      retryAfterSeconds: retry ? Number(retry) : undefined,
    });
  }
  return json;
}

/** User-facing German message for an API error. */
export function errorMessage(err) {
  if (!(err instanceof ApiError)) return 'Unerwarteter Fehler.';
  switch (err.code) {
    case 'network':
      return 'Der Server ist nicht erreichbar. Bitte Verbindung prüfen.';
    case 'invalid_password':
      return 'Falsches Passwort.';
    case 'too_many_attempts': {
      const min = Math.ceil((err.details.retryAfterSeconds ?? 60) / 60);
      return `Zu viele Fehlversuche. Bitte in ${min} Minute${min === 1 ? '' : 'n'} erneut versuchen.`;
    }
    case 'sph_unavailable':
      return 'Das Schulportal ist gerade nicht erreichbar oder wird gewartet.';
    case 'sph_auth_failed':
      return 'Die Anmeldung beim Schulportal ist fehlgeschlagen. Bitte Zugangsdaten auf dem Server prüfen.';
    case 'sph_bad_response':
      return 'Das Schulportal hat unerwartete Daten geliefert.';
    case 'feature_disabled':
      return 'Dieser Bereich ist für das Konto nicht freigeschaltet.';
    case 'not_found':
      return 'Nicht gefunden.';
    case 'sph_login_failed':
      return 'Die Anmeldung beim Schulportal ist fehlgeschlagen. Bitte Schule, Benutzername und Passwort prüfen.';
    case 'setup_token_invalid':
      return 'Der Einrichtungslink ist ungültig oder abgelaufen. Bitte den Link aus dem Protokoll des Servers verwenden.';
    case 'setup_required':
      return 'Der Server ist noch nicht eingerichtet.';
    case 'invalid_settings':
      return 'Einige Angaben sind ungültig.';
    case 'meals_login_failed':
    case 'meals_auth_failed':
      return 'Die Anmeldung bei Caseda ist fehlgeschlagen. Bitte E-Mail und Passwort prüfen.';
    case 'meals_unavailable':
      return 'Caseda Schulmenü ist gerade nicht erreichbar.';
    default:
      return err.message || 'Unerwarteter Fehler.';
  }
}
