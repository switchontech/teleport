/**
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

import React from 'react';
import styled from 'styled-components';

import { ButtonPrimary, Link } from 'design';
import Flex from 'design/Flex';
import { Unlock } from 'design/Icon';

import cfg from 'teleport/config';
import { getSalesURL } from 'teleport/services/sales';
import { CtaEvent, userEventService } from 'teleport/services/userEvent';
import useTeleport from 'teleport/useTeleport';

export type Props = {
  children: React.ReactNode;
  noIcon?: boolean;
  event?: CtaEvent;
  textLink?: boolean;
  url?: string;
  [index: string]: any;
};

export function ButtonLockedFeature(_props: Props) {
  return null;
}

const UnlockIcon = styled(Unlock)`
  color: inherit;
  font-weight: 500;
  font-size: 15px;
  margin-right: 10px;
`;
