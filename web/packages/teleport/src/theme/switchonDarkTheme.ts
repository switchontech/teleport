/**
 * SwitchOn brand dark theme overlay for Teleport.
 *
 * Extends the base darkTheme with GreenLight dark-mode tokens.
 * Mirrors the same structure as switchonTheme.ts (light) —
 * only fields that differ from Teleport's darkTheme are set here.
 *
 * GreenLight Dark Palette (derived from GreenLight design system):
 *   brand/primary  #4FBA6F  hover #5EC87A  active #6DD685   (lighter green on dark bg)
 *   accent/info    #5B8AF5  hover #6E9AF7  active #81AAF9
 *   danger         #F05555  hover #F37070  active #F68B8B
 *   warning        #FFAD0D  hover #FFBC33  active #FFCD66
 *   fg             #F3F4F6  fg-muted rgba(243,244,246,0.72)  fg-subtle rgba(243,244,246,0.54)
 *   bg-deep        #0C1210  bg-sunken #131A16  bg-surface #1C2820
 *   bg-elevated    #243228  bg-popout #2C3C30
 */

import { lighten } from 'design/theme/utils/colorManipulator';
import darkTheme, {
  dataVisualisationColors,
} from 'design/theme/themes/darkTheme';
import { fonts } from 'design/theme/fonts';
import { Theme } from 'design/theme/themes/types';

// Brand green — lighter for dark-bg contrast
const GL_GREEN = '#4FBA6F';
const GL_GREEN_HOVER = '#5EC87A';
const GL_GREEN_ACTIVE = '#6DD685';

// Accent blue
const GL_BLUE = '#5B8AF5';
const GL_BLUE_HOVER = '#6E9AF7';
const GL_BLUE_ACTIVE = '#81AAF9';

// Danger red
const GL_RED = '#F05555';
const GL_RED_HOVER = '#F37070';
const GL_RED_ACTIVE = '#F68B8B';

// Warning yellow
const GL_YELLOW = '#FFAD0D';
const GL_YELLOW_HOVER = '#FFBC33';
const GL_YELLOW_ACTIVE = '#FFCD66';

// Dark backgrounds — near-neutral with subtle green warmth
const levels = {
  deep: '#0C1210',
  sunken: '#131A16',
  surface: '#1C2820',
  elevated: '#243228',
  popout: '#2C3C30',
};

const neutralColors = [
  'rgba(255,255,255,0.06)',
  'rgba(255,255,255,0.13)',
  'rgba(255,255,255,0.18)',
];

const interFont = `Inter, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif`;
const jetBrainsFont = `"JetBrains Mono", "Droid Sans Mono", monospace`;

export const switchonDarkTheme: Theme = {
  ...darkTheme,
  name: 'dark',
  type: 'dark',
  isCustomTheme: true,
  font: interFont,
  fonts: { ...fonts, sansSerif: interFont, mono: jetBrainsFont },
  colors: {
    ...darkTheme.colors,

    brand: GL_GREEN,

    levels,

    spotBackground: neutralColors,

    interactive: {
      ...darkTheme.colors.interactive,
      solid: {
        ...darkTheme.colors.interactive.solid,
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
        ...darkTheme.colors.interactive.tonal,
        primary: [
          'rgba(79,186,111,0.10)',
          'rgba(79,186,111,0.18)',
          'rgba(79,186,111,0.25)',
        ],
        danger: [
          'rgba(240,85,85,0.10)',
          'rgba(240,85,85,0.18)',
          'rgba(240,85,85,0.25)',
        ],
        informational: [
          'rgba(91,138,245,0.10)',
          'rgba(91,138,245,0.18)',
          'rgba(91,138,245,0.25)',
        ],
      },
    },

    text: {
      main: '#F3F4F6',
      slightlyMuted: 'rgba(243,244,246,0.72)',
      muted: 'rgba(243,244,246,0.54)',
      disabled: 'rgba(243,244,246,0.36)',
      primaryInverse: '#1D2024',
    },

    buttons: {
      ...darkTheme.colors.buttons,
      text: '#F3F4F6',
      textDisabled: 'rgba(243,244,246,0.3)',
      bgDisabled: 'rgba(243,244,246,0.12)',

      primary: {
        text: '#1D2024',
        default: GL_GREEN,
        hover: GL_GREEN_HOVER,
        active: GL_GREEN_ACTIVE,
      },

      secondary: {
        default: 'rgba(255,255,255,0.07)',
        hover: 'rgba(255,255,255,0.13)',
        active: 'rgba(255,255,255,0.18)',
      },

      border: {
        default: 'rgba(255,255,255,0)',
        hover: 'rgba(255,255,255,0.07)',
        active: 'rgba(255,255,255,0.13)',
        border: 'rgba(255,255,255,0.36)',
      },

      warning: {
        text: '#1D2024',
        default: GL_RED,
        hover: GL_RED_HOVER,
        active: GL_RED_ACTIVE,
      },

      trashButton: {
        default: 'rgba(255,255,255,0.07)',
        hover: 'rgba(255,255,255,0.13)',
      },

      link: {
        default: GL_BLUE,
        hover: GL_BLUE_HOVER,
        active: GL_BLUE_ACTIVE,
      },
    },

    error: {
      main: GL_RED,
      hover: GL_RED_HOVER,
      active: GL_RED_ACTIVE,
    },

    success: {
      main: GL_GREEN,
      hover: GL_GREEN_HOVER,
      active: GL_GREEN_ACTIVE,
    },

    warning: {
      main: GL_YELLOW,
      hover: GL_YELLOW_HOVER,
      active: GL_YELLOW_ACTIVE,
    },

    accent: {
      main: GL_BLUE,
      hover: GL_BLUE_HOVER,
      active: GL_BLUE_ACTIVE,
    },

    link: GL_BLUE,

    progressBarColor: GL_GREEN,

    notice: {
      background: levels.elevated,
    },

    terminal: {
      ...darkTheme.colors.terminal,
      background: levels.sunken,
      cursorAccent: levels.sunken,
      brightWhite: lighten(levels.sunken, 0.89),
      white: lighten(levels.sunken, 0.78),
      brightBlack: lighten(levels.sunken, 0.61),
    },

    sessionRecording: {
      ...darkTheme.colors.sessionRecording,
      user: GL_GREEN_ACTIVE,
      player: {
        ...darkTheme.colors.sessionRecording.player,
        progressBar: {
          ...darkTheme.colors.sessionRecording.player.progressBar,
          progress: GL_GREEN,
        },
      },
    },

    sessionRecordingTimeline: {
      ...darkTheme.colors.sessionRecordingTimeline,
      background: levels.deep,
      events: {
        ...darkTheme.colors.sessionRecordingTimeline.events,
        inactivity: {
          background: 'rgba(79,186,111,0.25)',
          text: 'rgba(243,244,246,0.6)',
        },
        join: {
          background: GL_BLUE,
          text: 'rgba(0,0,0,0.87)',
        },
      },
    },

    highlightedNavigationItem: 'rgba(79,186,111,0.15)',

    dataVisualisation: dataVisualisationColors,
  },
};
