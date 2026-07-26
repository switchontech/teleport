/**
 * SwitchOn brand theme overlay for Teleport.
 *
 * Maps GreenLight design tokens to Teleport's Chakra semantic token tree.
 * Only tokens that differ from Teleport defaults are defined here —
 * everything else inherits from the base teleport theme.
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

import {
  defineConfig,
  defineSemanticTokens,
} from '@gravitational/design-system';

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

const colors = defineSemanticTokens.colors({
  // --- Brand ---
  brand: { value: { _light: GL_GREEN, _dark: GL_GREEN } },

  // --- Levels (background layers) — GreenLight bg scale ---
  levels: {
    deep: { value: { _light: '#E2E4E8', _dark: '#E2E4E8' } },
    sunken: { value: { _light: '#F3F4F6', _dark: '#F3F4F6' } },
    surface: { value: { _light: '#FAFBFC', _dark: '#FAFBFC' } },
    elevated: { value: { _light: '#FFFFFF', _dark: '#FFFFFF' } },
    popout: { value: { _light: '#FFFFFF', _dark: '#FFFFFF' } },
  },

  // --- Interactive solid ---
  interactive: {
    solid: {
      primary: {
        default: { value: { _light: GL_GREEN, _dark: GL_GREEN } },
        hover: { value: { _light: GL_GREEN_HOVER, _dark: GL_GREEN_HOVER } },
        active: { value: { _light: GL_GREEN_ACTIVE, _dark: GL_GREEN_ACTIVE } },
      },
      accent: {
        default: { value: { _light: GL_BLUE, _dark: GL_BLUE } },
        hover: { value: { _light: GL_BLUE_HOVER, _dark: GL_BLUE_HOVER } },
        active: { value: { _light: GL_BLUE_ACTIVE, _dark: GL_BLUE_ACTIVE } },
      },
      danger: {
        default: { value: { _light: GL_RED, _dark: GL_RED } },
        hover: { value: { _light: GL_RED_HOVER, _dark: GL_RED_HOVER } },
        active: { value: { _light: GL_RED_ACTIVE, _dark: GL_RED_ACTIVE } },
      },
      alert: {
        default: { value: { _light: GL_YELLOW, _dark: GL_YELLOW } },
        hover: { value: { _light: GL_YELLOW_HOVER, _dark: GL_YELLOW_HOVER } },
        active: { value: { _light: GL_YELLOW_ACTIVE, _dark: GL_YELLOW_ACTIVE } },
      },
    },
    tonal: {
      primary: {
        0: { value: { _light: 'rgba(39,174,96,0.1)', _dark: 'rgba(39,174,96,0.1)' } },
        1: { value: { _light: 'rgba(39,174,96,0.18)', _dark: 'rgba(39,174,96,0.18)' } },
        2: { value: { _light: 'rgba(39,174,96,0.25)', _dark: 'rgba(39,174,96,0.25)' } },
      },
      danger: {
        0: { value: { _light: 'rgba(229,26,26,0.1)', _dark: 'rgba(229,26,26,0.1)' } },
        1: { value: { _light: 'rgba(229,26,26,0.18)', _dark: 'rgba(229,26,26,0.18)' } },
        2: { value: { _light: 'rgba(229,26,26,0.25)', _dark: 'rgba(229,26,26,0.25)' } },
      },
      informational: {
        0: { value: { _light: 'rgba(37,97,237,0.1)', _dark: 'rgba(37,97,237,0.1)' } },
        1: { value: { _light: 'rgba(37,97,237,0.18)', _dark: 'rgba(37,97,237,0.18)' } },
        2: { value: { _light: 'rgba(37,97,237,0.25)', _dark: 'rgba(37,97,237,0.25)' } },
      },
    },
  },

  // --- Text ---
  text: {
    main: { value: { _light: '#1D2024', _dark: '#1D2024' } },
    slightlyMuted: { value: { _light: '#5D6166', _dark: '#5D6166' } },
    muted: { value: { _light: '#777E8C', _dark: '#777E8C' } },
    disabled: { value: { _light: 'rgba(29,32,36,0.36)', _dark: 'rgba(29,32,36,0.36)' } },
  },

  // --- Buttons ---
  buttons: {
    primary: {
      default: { value: { _light: GL_GREEN, _dark: GL_GREEN } },
      hover: { value: { _light: GL_GREEN_HOVER, _dark: GL_GREEN_HOVER } },
      active: { value: { _light: GL_GREEN_ACTIVE, _dark: GL_GREEN_ACTIVE } },
    },
  },

  // --- Session recording ---
  sessionRecording: {
    player: {
      progressBar: {
        progress: { value: { _light: GL_GREEN, _dark: GL_GREEN } },
      },
    },
    user: { value: { _light: GL_GREEN_ACTIVE, _dark: GL_GREEN_ACTIVE } },
  },

  sessionRecordingTimeline: {
    events: {
      inactivity: {
        background: {
          value: { _light: 'rgba(39,174,96,0.25)', _dark: 'rgba(39,174,96,0.25)' },
        },
      },
    },
  },
});

export const switchonOverrides = defineConfig({
  theme: { semanticTokens: { colors } },
});
