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

import React, { type JSX } from 'react';
import { matchPath, useHistory } from 'react-router';
import { Link } from 'react-router-dom';
import styled from 'styled-components';

import { breakpointsPx, Flex, TopNav } from 'design';
import { Moon, Sun } from 'design/Icon';
import { HoverTooltip } from 'design/Tooltip';

import { SwitchOnLogo } from 'teleport/components/SwitchOnLogo';
import { UserMenuNav } from 'teleport/components/UserMenuNav';
import cfg from 'teleport/config';
import { useFeatures } from 'teleport/FeaturesContext';
import { useLayout } from 'teleport/Main/LayoutContext';
import { zIndexMap } from 'teleport/Navigation/zIndexMap';
import { Notifications } from 'teleport/Notifications';
import { useThemeToggle } from 'teleport/theme/ThemeContext';
import useTeleport from 'teleport/useTeleport';

export function TopBar({
  CustomLogo,
}: {
  CustomLogo?: () => React.ReactElement;
}) {
  const ctx = useTeleport();
  const history = useHistory();
  const features = useFeatures();
  const { currentWidth } = useLayout();
  const { isDark, toggle } = useThemeToggle();

  // find active feature
  const feature = features.find(
    f =>
      f.route &&
      matchPath(history.location.pathname, {
        path: f.route.path,
        exact: f.route.exact ?? false,
      })
  );

  const iconSize =
    currentWidth >= breakpointsPx.medium
      ? navigationIconSizeMedium
      : navigationIconSizeSmall;

  return (
    <TopBarContainer navigationHidden={feature?.hideNavigation}>
      <TeleportLogo CustomLogo={CustomLogo} />
      {!feature?.logoOnlyTopbar && (
        <Flex height="100%" alignItems="center">
          <HoverTooltip tipContent={isDark ? 'Light mode' : 'Dark mode'} placement="bottom">
            <ThemeToggleButton onClick={toggle} aria-label="Toggle dark mode">
              <AnimatedIcon key={isDark ? 'dark' : 'light'}>
                {isDark ? <Sun size={iconSize} /> : <Moon size={iconSize} />}
              </AnimatedIcon>
            </ThemeToggleButton>
          </HoverTooltip>
          <Notifications iconSize={iconSize} />
          <UserMenuNav username={ctx.storeUser.state.username} />
        </Flex>
      )}
    </TopBarContainer>
  );
}

export const TopBarContainer = styled(TopNav)`
  position: fixed;
  width: 100%;
  display: flex;
  justify-content: space-between;
  background: ${p => p.theme.colors.levels.surface};
  overflow-y: initial;
  overflow-x: none;
  flex-shrink: 0;
  z-index: ${zIndexMap.topBar};
  border-bottom: 1px solid ${({ theme }) => theme.colors.spotBackground[1]};

  height: ${p => p.theme.topBarHeight[0]}px;
  @media screen and (min-width: ${p => p.theme.breakpoints.small}) {
    height: ${p => p.theme.topBarHeight[1]}px;
  }
`;

const TeleportLogo = ({
  CustomLogo,
}: {
  CustomLogo?: () => React.ReactElement;
}) => {
  return (
    <HoverTooltip placement="bottom" tipContent="DeepInspect Pro">
      <Link
        css={`
          cursor: pointer;
          display: flex;
          text-decoration: none;
          transition: background-color 0.1s linear;
          &:hover {
            background-color: ${p =>
              p.theme.colors.interactive.tonal.primary[0]};
          }
          align-items: center;
          height: 100%;
          margin-right: 0px;
          @media screen and (min-width: ${p => p.theme.breakpoints.medium}) {
            margin-right: 76px;
          }
          @media screen and (min-width: ${p => p.theme.breakpoints.large}) {
            margin-right: 67px;
          }
        `}
        to={cfg.routes.root}
      >
        {CustomLogo ? (
          <CustomLogo />
        ) : (
          <span
            data-testid="teleport-logo"
            style={{
              paddingLeft: 16,
              paddingRight: 16,
              display: 'flex',
              alignItems: 'center',
            }}
          >
            <SwitchOnLogo height={36} />
          </span>
        )}
      </Link>
    </HoverTooltip>
  );
};

const ThemeToggleButton = styled.button`
  display: flex;
  align-items: center;
  justify-content: center;
  background: none;
  border: none;
  cursor: pointer;
  padding: 8px;
  border-radius: 4px;
  color: ${p => p.theme.colors.text.main};
  transition: background-color 0.1s linear;
  overflow: hidden;
  &:hover {
    background-color: ${p => p.theme.colors.interactive.tonal.primary[0]};
  }
`;

const AnimatedIcon = styled.span`
  display: flex;
  align-items: center;
  justify-content: center;
  @keyframes theme-icon-in {
    from {
      transform: rotate(-90deg) scale(0.4);
      opacity: 0;
    }
    to {
      transform: rotate(0deg) scale(1);
      opacity: 1;
    }
  }
  animation: theme-icon-in 0.25s cubic-bezier(0.34, 1.56, 0.64, 1);
`;

export const navigationIconSizeSmall = 20;
export const navigationIconSizeMedium = 24;

export type NavigationItem = {
  title: string;
  path: string;
  Icon: JSX.Element;
};
