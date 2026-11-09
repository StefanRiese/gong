import { api, errorMessage } from '../api.js';
import { h, errorBox } from '../dom.js';

export const title = 'Anmelden';

/** @param {{onSuccess: () => void}} options */
export function render({ onSuccess }) {
  const password = h('input', {
    type: 'password', id: 'password', name: 'password', autocomplete: 'current-password',
    required: true, autofocus: true,
  });
  const message = h('div', { 'aria-live': 'assertive' });
  const submit = h('button', { type: 'submit', class: 'button primary' }, 'Anmelden');

  const form = h('form', { class: 'login-card card' },
    h('img', { src: '/icon.svg', alt: '', class: 'login-logo' }),
    h('h1', null, 'Gong'),
    h('p', { class: 'muted login-tagline' }, 'dein Schulportal-Begleiter für Hessen'),
    h('label', { for: 'password' }, 'Passwort'),
    password,
    message,
    submit,
  );

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    submit.disabled = true;
    submit.textContent = 'Anmelden …';
    message.replaceChildren();
    try {
      await api('/api/auth/login', { method: 'POST', body: { password: password.value } });
      onSuccess();
    } catch (err) {
      message.replaceChildren(errorBox(errorMessage(err)));
      password.select();
      submit.disabled = false;
      submit.textContent = 'Anmelden';
    }
  });

  queueMicrotask(() => password.focus());
  return h('main', { class: 'login' }, form);
}
