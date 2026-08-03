/**
 * Teleport
 * Copyright (C) 2026  Gravitational, Inc.
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

import styled from 'styled-components';

import Flex from 'design/Flex';
import { Terminal } from 'design/Icon';
import Text, { H3 } from 'design/Text';

import type { SessionCommandEntry } from 'teleport/services/recordings';
import { InfoGridLabel } from 'teleport/SessionRecordings/view/SessionRecordingDetails';

interface CommandsPanelProps {
  commands: SessionCommandEntry[];
  enhancedRecordingEnabled: boolean;
  onSeek: (offsetMs: number) => void;
}

export function CommandsPanel({
  commands,
  enhancedRecordingEnabled,
  onSeek,
}: CommandsPanelProps) {
  return (
    <Container>
      <Flex alignItems="center" gap={3} px={3}>
        <Terminal size="small" />

        <H3>Commands</H3>
      </Flex>

      {commands.length === 0 ? (
        <EmptyState>
          {enhancedRecordingEnabled ? (
            <Text color="text.slightlyMuted">
              No commands were recorded for this session.
            </Text>
          ) : (
            <Text color="text.slightlyMuted">
              Enhanced session recording was not enabled for this session, so
              individual commands were not captured.
            </Text>
          )}
        </EmptyState>
      ) : (
        <CommandList>
          {commands.map((command, i) => (
            <CommandRow
              key={`${command.pid}-${i}`}
              onClick={() => onSeek(command.offsetMs)}
            >
              <InfoGridLabel as="span">
                {formatOffset(command.offsetMs)}
              </InfoGridLabel>

              <CommandText title={command.cmd}>{command.cmd}</CommandText>

              {command.returnCode !== 0 && (
                <ExitCodeBadge>{command.returnCode}</ExitCodeBadge>
              )}
            </CommandRow>
          ))}
        </CommandList>
      )}
    </Container>
  );
}

function formatOffset(ms: number): string {
  const totalSeconds = Math.floor(ms / 1000);
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;

  if (hours > 0) {
    return `${hours}:${minutes.toString().padStart(2, '0')}:${seconds
      .toString()
      .padStart(2, '0')}`;
  }

  return `${minutes}:${seconds.toString().padStart(2, '0')}`;
}

const Container = styled.div`
  display: flex;
  flex-direction: column;
  gap: ${p => p.theme.space[2]}px;
  flex: 1;
  min-height: 0;
`;

const EmptyState = styled.div`
  padding: ${p => p.theme.space[1]}px ${p => p.theme.space[3]}px 0;
`;

const CommandList = styled.div`
  display: flex;
  flex-direction: column;
  overflow-y: auto;
  min-height: 0;
`;

const CommandRow = styled.button`
  display: flex;
  align-items: center;
  gap: ${p => p.theme.space[2]}px;
  padding: ${p => p.theme.space[1]}px ${p => p.theme.space[3]}px;
  border: none;
  background: none;
  color: inherit;
  font: inherit;
  text-align: left;
  cursor: pointer;
  width: 100%;

  &:hover {
    background-color: ${p => p.theme.colors.spotBackground[0]};
  }
`;

const CommandText = styled.span`
  font-family: ${p => p.theme.fonts.mono};
  font-size: ${p => p.theme.fontSizes[1]}px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  flex: 1;
`;

const ExitCodeBadge = styled.span`
  font-family: ${p => p.theme.fonts.mono};
  font-size: ${p => p.theme.fontSizes[0]}px;
  color: ${p => p.theme.colors.error.main};
  border: 1px solid ${p => p.theme.colors.error.main};
  border-radius: ${p => p.theme.radii[1]}px;
  padding: 0 ${p => p.theme.space[1]}px;
  flex-shrink: 0;
`;
