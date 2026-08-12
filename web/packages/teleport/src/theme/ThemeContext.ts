import { createContext, useContext } from 'react';

export type ThemeContextValue = {
  isDark: boolean;
  toggle: () => void;
};

export const ThemeContext = createContext<ThemeContextValue>({
  isDark: false,
  toggle: () => {},
});

export const useThemeToggle = () => useContext(ThemeContext);
