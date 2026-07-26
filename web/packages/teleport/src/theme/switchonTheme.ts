/**
 * SwitchOn brand theme overlay for Teleport.
 *
 * Overrides the default lightTheme's colors with GreenLight design tokens.
 * Only fields that differ from Teleport's lightTheme are set here —
 * everything else is inherited via spread.
 *
 * Always rendered in light mode (forced in ThemeProvider).
 *
 * GreenLight palette:
 *   brand/primary  #27AE60  hover #1D8147  active #125F31
 *   accent/info    #2561ED  hover #1E4EC0  active #163B95
 *   danger         #E51A1A  hover #B81515  active #8A1010
 *   warning        #FFAD0D  hover #CC8A00  active #996700
 *   fg             #1D2024  fg-muted #5D6166  fg-subtle #777E8C
 *   bg             #FFFFFF  bg-page #FAFBFC  bg-subtle #F6F7F8  bg-muted #F3F4F6
 *   border         #E2E4E8
 */

import { fonts } from 'design/theme/fonts';
import lightTheme from 'design/theme/themes/lightTheme';
import { Theme } from 'design/theme/themes/types';

// Brand green
const GL_GREEN = '#27AE60';
const GL_GREEN_HOVER = '#1D8147';
const GL_GREEN_ACTIVE = '#125F31';

// Accent blue (GreenLight --blue-500)
const GL_BLUE = '#2561ED';
const GL_BLUE_HOVER = '#1E4EC0';
const GL_BLUE_ACTIVE = '#163B95';

// Danger (GreenLight --red-500)
const GL_RED = '#E51A1A';
const GL_RED_HOVER = '#B81515';
const GL_RED_ACTIVE = '#8A1010';

// Warning (GreenLight --yellow-500)
const GL_YELLOW = '#FFAD0D';
const GL_YELLOW_HOVER = '#CC8A00';
const GL_YELLOW_ACTIVE = '#996700';

const interFont = `Inter, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif`;
const jetBrainsFont = `"JetBrains Mono", "Droid Sans Mono", monospace`;

export const switchonTheme: Theme = {
  ...lightTheme,
  name: 'light',
  type: 'light',
  isCustomTheme: true,
  font: interFont,
  fonts: { ...fonts, sansSerif: interFont, mono: jetBrainsFont },
  colors: {
    ...lightTheme.colors,

    brand: GL_GREEN,

    levels: {
      deep: '#E2E4E8',
      sunken: '#F3F4F6',
      surface: '#FAFBFC',
      elevated: '#FFFFFF',
      popout: '#FFFFFF',
    },

    interactive: {
      ...lightTheme.colors.interactive,
      solid: {
        ...lightTheme.colors.interactive.solid,
        primary: {
          default: GL_GREEN,
          hover: GL_GREEN_HOVER,
          active: GL_GREEN_ACTIVE,
        },
        accent: {
          default: GL_BLUE,
          hover: GL_BLUE_HOVER,
          active: GL_BLUE_ACTIVE,
        },
        danger: {
          default: GL_RED,
          hover: GL_RED_HOVER,
          active: GL_RED_ACTIVE,
        },
        alert: {
          default: GL_YELLOW,
          hover: GL_YELLOW_HOVER,
          active: GL_YELLOW_ACTIVE,
        },
      },
      tonal: {
        ...lightTheme.colors.interactive.tonal,
        primary: [
          'rgba(39,174,96,0.1)',
          'rgba(39,174,96,0.18)',
          'rgba(39,174,96,0.25)',
        ],
        danger: [
          'rgba(229,26,26,0.1)',
          'rgba(229,26,26,0.18)',
          'rgba(229,26,26,0.25)',
        ],
        informational: [
          'rgba(37,97,237,0.1)',
          'rgba(37,97,237,0.18)',
          'rgba(37,97,237,0.25)',
        ],
      },
    },

    text: {
      ...lightTheme.colors.text,
      main: '#1D2024',
      slightlyMuted: '#5D6166',
      muted: '#777E8C',
      disabled: 'rgba(29,32,36,0.36)',
    },

    buttons: {
      ...lightTheme.colors.buttons,
      primary: {
        ...lightTheme.colors.buttons.primary,
        default: GL_GREEN,
        hover: GL_GREEN_HOVER,
        active: GL_GREEN_ACTIVE,
      },
    },

    sessionRecording: {
      ...lightTheme.colors.sessionRecording,
      user: GL_GREEN_ACTIVE,
      player: {
        ...lightTheme.colors.sessionRecording.player,
        progressBar: {
          ...lightTheme.colors.sessionRecording.player.progressBar,
          progress: GL_GREEN,
        },
      },
    },

    sessionRecordingTimeline: {
      ...lightTheme.colors.sessionRecordingTimeline,
      events: {
        ...lightTheme.colors.sessionRecordingTimeline.events,
        inactivity: {
          ...lightTheme.colors.sessionRecordingTimeline.events.inactivity,
          background: 'rgba(39,174,96,0.25)',
        },
      },
    },
  },
};
