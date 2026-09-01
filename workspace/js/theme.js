import { request } from './api.js';

/** Apply the active Omarchy theme to the workspace CSS variables. */
export async function loadTheme() {
  try {
    const theme = await request('/api/theme');
    const variables = {
      '--bg': theme.background,
      '--text': theme.foreground,
      '--accent': theme.accent,
      '--muted': theme.muted,
      '--faint': theme.border,
      '--danger': theme.error,
      '--toast-bg': theme.toast,
      '--toast-text': theme.toastText,
      '--toast-border': theme.accent
    };
    for (const [name, value] of Object.entries(variables))
      if (value) document.documentElement.style.setProperty(name, value);
    const rgb = theme.background?.match(/[0-9a-f]{2}/gi)?.map(value => parseInt(value, 16));
    if (rgb) {
      const luminance = (0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]) / 255;
      document.documentElement.style.colorScheme = luminance > 0.55 ? 'light' : 'dark';
    }
  } catch (_) {}
}
