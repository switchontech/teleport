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

import {
  createThemeSystem,
  ThemeProvider as NewThemeProvider,
  TELEPORT_THEME,
  THEMES,
} from '@gravitational/design-system';
import { useMemo, type PropsWithChildren } from 'react';

import { lightTheme, resolveTheme, Theme } from 'design/theme';
import { ConfiguredThemeProvider } from 'design/ThemeProvider';
import { Theme as ThemePreference } from 'gen-proto-ts/teleport/userpreferences/v1/theme_pb';

import { switchonOverrides } from 'teleport/theme/switchonTheme';

export function ThemeProvider({ children }: PropsWithChildren) {
  const selectedTheme = useMemo(() => {
    const theme = THEMES.find(t => t.name === TELEPORT_THEME.name);

    return {
      ...theme,
      system: createThemeSystem(theme.config, switchonOverrides),
    };
  }, []);

  // GreenLight design system is light-only — always force light.
  const colorMode = 'light';

  const legacyTheme: Theme = useMemo(() => {
    const theme = resolveTheme(lightTheme);
    const interFont = `Inter, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif`;
    const jetBrainsFont = `"JetBrains Mono", "Droid Sans Mono", monospace`;
    return {
      ...theme,
      font: interFont,
      fonts: { sansSerif: interFont, mono: jetBrainsFont },
    };
  }, []);

  return (
    <NewThemeProvider forcedTheme={colorMode} system={selectedTheme.system}>
      <ConfiguredThemeProvider theme={legacyTheme}>
        {children}
      </ConfiguredThemeProvider>
    </NewThemeProvider>
  );
}


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
