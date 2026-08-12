/**
 * Teleport
 * Copyright (C) 2024 Gravitational, Inc.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

import { ReactNode, useCallback, useEffect, useMemo, useState } from 'react';
import { flushSync } from 'react-dom';

import { ConfiguredThemeProvider } from 'design/ThemeProvider';
import { Theme as ThemePreference } from 'gen-proto-ts/teleport/userpreferences/v1/theme_pb';

import { switchonTheme } from 'teleport/theme/switchonTheme';
import { switchonDarkTheme } from 'teleport/theme/switchonDarkTheme';
import { ThemeContext } from 'teleport/theme/ThemeContext';

const STORAGE_KEY = 'switchon-theme';

function getInitialDark(): boolean {
  const stored = localStorage.getItem(STORAGE_KEY);
  if (stored === 'dark') return true;
  if (stored === 'light') return false;
  return (
    window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches
  );
}

export const ThemeProvider = (props: { children?: ReactNode }) => {
  const [isDark, setIsDark] = useState(getInitialDark);

  // Follow system changes only when user has no stored preference.
  useEffect(() => {
    const mq = window.matchMedia('(prefers-color-scheme: dark)');
    const handler = (e: MediaQueryListEvent) => {
      if (!localStorage.getItem(STORAGE_KEY)) {
        setIsDark(e.matches);
      }
    };
    mq.addEventListener('change', handler);
    return () => mq.removeEventListener('change', handler);
  }, []);

  const toggle = useCallback(() => {
    const applyTheme = () => {
      flushSync(() => {
        setIsDark(prev => {
          const next = !prev;
          localStorage.setItem(STORAGE_KEY, next ? 'dark' : 'light');
          return next;
        });
      });
    };

    // View Transitions API: browser snapshots current state, new theme
    // slides in from left revealing actual colors — no overlay box.
    if ((document as any).startViewTransition) {
      (document as any).startViewTransition(applyTheme);
    } else {
      applyTheme();
    }
  }, []);

  const ctx = useMemo(() => ({ isDark, toggle }), [isDark, toggle]);

  return (
    <ThemeContext.Provider value={ctx}>
      <ConfiguredThemeProvider theme={isDark ? switchonDarkTheme : switchonTheme}>
        {props.children}
        <style>{`
          @property --gl-wipe {
            syntax: '<percentage>';
            inherits: false;
            initial-value: -45%;
          }
          ::view-transition-old(root),
          ::view-transition-new(root) {
            animation: none;
            mix-blend-mode: normal;
          }
          ::view-transition-new(root) {
            mask-image: linear-gradient(
              115deg,
              black var(--gl-wipe),
              transparent calc(var(--gl-wipe) + 55%)
            );
            -webkit-mask-image: linear-gradient(
              115deg,
              black var(--gl-wipe),
              transparent calc(var(--gl-wipe) + 55%)
            );
            animation: theme-gradient-reveal 1s cubic-bezier(0.65, 0, 0.35, 1) forwards;
          }
          @keyframes theme-gradient-reveal {
            from { --gl-wipe: -45%; }
            to   { --gl-wipe: 120%; }
          }
        `}</style>
      </ConfiguredThemeProvider>
    </ThemeContext.Provider>
  );
};

/**
 * Determines the current theme preference.
 *
 * If the provided `currentTheme` is `UNSPECIFIED`, it checks the user's
 * system preference and returns a theme based on it.
 *
 * @TODO(avatus) when we add user settings page, we can add a Theme.SYSTEM option
 * and remove the checks for unspecified
 */
export function getCurrentTheme(
  currentTheme: ThemePreference
): ThemePreference {
  if (currentTheme === ThemePreference.UNSPECIFIED) {
    return getPrefersDark() ? ThemePreference.DARK : ThemePreference.LIGHT;
  }

  return currentTheme;
}

export function getNextTheme(currentTheme: ThemePreference): ThemePreference {
  return getCurrentTheme(currentTheme) === ThemePreference.LIGHT
    ? ThemePreference.DARK
    : ThemePreference.LIGHT;
}

export function getPrefersDark(): boolean {
  return (
    window.matchMedia &&
    window.matchMedia('(prefers-color-scheme: dark)').matches
  );
}

export function updateFavicon() {
  let base = '/web/app/';
  if (import.meta.env.MODE === 'development') {
    base = '/app/';
  }
  const darkModePreferred = getPrefersDark();
  const favicon = document.querySelector('link[rel="icon"]');

  if (favicon instanceof HTMLLinkElement) {
    if (darkModePreferred) {
      favicon.href = base + 'favicon-dark.png';
    } else {
      favicon.href = base + 'favicon-light.png';
    }
  }
}
