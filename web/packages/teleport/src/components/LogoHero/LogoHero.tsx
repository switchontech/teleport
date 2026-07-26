/*
 * Teleport
 * Copyright (C) 2023  Gravitational, Inc.
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

import Box from 'design/Box';

import { SwitchOnLogo } from 'teleport/components/SwitchOnLogo';

// Keep logoSrc exported — TopBar imports it.
export function logoSrc(_themeType: 'light' | 'dark'): string {
  const base = import.meta.env.MODE === 'development' ? '/app/' : '/web/app/';
  return `${base}logo-light.svg?v=1`;
}

export const LogoHero = ({ py = '48px' }: { py?: string; customSrc?: string }) => (
  <Box py={py} style={{ display: 'flex', justifyContent: 'center' }}>
    <SwitchOnLogo height={56} />
  </Box>
);
