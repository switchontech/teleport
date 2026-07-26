import * as React from 'react';

// Icon only (geometric mark, 49×48 viewBox).
// Paths are white — render on brand-green background.
export const SwitchOnIcon = ({
  pathColor = '#fff',
  accentColor = '#4FBA6F',
  ...props
}: React.SVGProps<SVGSVGElement> & { pathColor?: string; accentColor?: string }) => (
  <svg
    width={32}
    height={32}
    viewBox="0 0 49 48"
    fill="none"
    xmlns="http://www.w3.org/2000/svg"
    {...props}
  >
    <path
      d="M12.962 5.548c.706 0 1.279-.56 1.279-1.25s-.573-1.25-1.28-1.25c-.706 0-1.278.56-1.278 1.25s.572 1.25 1.279 1.25zM4.4 13.912c.707 0 1.28-.56 1.28-1.25s-.573-1.25-1.28-1.25c-.706 0-1.279.56-1.279 1.25s.573 1.25 1.28 1.25zM1.28 25.308c.706 0 1.278-.56 1.278-1.25s-.572-1.25-1.279-1.25c-.706 0-1.279.56-1.279 1.25s.573 1.25 1.28 1.25zM13.167 45.034c.706 0 1.279-.56 1.279-1.25s-.573-1.249-1.28-1.249c-.706 0-1.278.56-1.278 1.25s.572 1.25 1.279 1.25zM24.799 48c.706 0 1.279-.56 1.279-1.25s-.573-1.249-1.28-1.249c-.706 0-1.278.56-1.278 1.25S24.091 48 24.799 48zM36.379 44.868c.706 0 1.279-.56 1.279-1.25s-.573-1.25-1.28-1.25c-.706 0-1.278.56-1.278 1.25s.572 1.25 1.279 1.25zM47.72 25.174c.707 0 1.28-.559 1.28-1.25 0-.69-.573-1.249-1.28-1.249-.706 0-1.279.56-1.279 1.25s.573 1.25 1.28 1.25zM44.565 13.912c.707 0 1.28-.56 1.28-1.25s-.573-1.25-1.28-1.25c-.706 0-1.279.56-1.279 1.25s.573 1.25 1.28 1.25zM37.28 4.806a1.245 1.245 0 00-.861-1.554c-.677-.197-1.39.18-1.59.842a1.245 1.245 0 00.861 1.554c.677.196 1.39-.18 1.59-.842z"
      fill={pathColor}
    />
    <path d="M36.527 4.3L.941 23.993l.286.493L36.813 4.793l-.286-.493zM48.192 23.916L12.606 43.61l.286.493 35.586-19.693-.286-.493z" fill={pathColor} />
    <path d="M48.324 23.553L35.964 3.988l-.464.28 12.36 19.566.464-.28zM13.438 43.657L1.08 24.09l-.464.28 12.359 19.567.464-.28z" fill={pathColor} />
    <path d="M45.076 12.267l-40.898.225.003.567 40.899-.226-.004-.566z" fill={pathColor} />
    <path d="M4.41 35.582l.078-22.992-.545-.002-.078 22.992.546.002zM45.025 35.495l.078-22.992-.546-.002-.078 22.992.546.002z" fill={pathColor} />
    <path d="M48.243 24.417L13.156 3.885l-.298.486 35.087 20.532.298-.486zM36.577 44.034L1.49 23.502l-.298.486L36.28 44.52l.298-.486z" fill={pathColor} />
    <path d="M1.242 24.006L13.307 4.263l-.469-.273L.773 23.733l.469.273zM36.523 44.012L48.588 24.27l-.469-.273-12.065 19.743.47.273z" fill={pathColor} />
    <path d="M25.542 47.034L4.684 12.667l-.5.289 20.86 34.367.498-.289zM4.323 12.82L24.673 1.27l-.274-.46-20.35 11.55.274.461z" fill={pathColor} />
    <path d="M24.708 46.864l20.35-11.551-.275-.461-20.35 11.551.275.461z" fill={pathColor} />
    <path d="M37.254 44.054l-.803-39.945-.58.011.804 39.945.58-.011zM13.863 44.519L13.06 4.574l-.58.011.803 39.945.58-.011z" fill={pathColor} />
    <path d="M12.876 4.668l23.53-.593-.015-.533-23.53.593.015.533zM13.326 44.512l23.53-.593-.015-.533-23.529.593.014.533z" fill={pathColor} />
    <path d="M24.77 47.768l20.032-34.83-.506-.278-20.032 34.83.506.278z" fill={pathColor} />
    <path d="M4.68 35.853l20.032-34.83-.506-.278-20.032 34.83.506.278z" fill={accentColor} />
    <path d="M44.807 12.746L24.94.417l-.292.45 19.867 12.329.292-.45zM24.612 47.047l-20.05-12.04-.286.454 20.05 12.04.286-.454z" fill={pathColor} />
    <path d="M24.628 2.5c.706 0 1.279-.56 1.279-1.25S25.334 0 24.627 0c-.706 0-1.278.56-1.278 1.25s.572 1.25 1.279 1.25zM4.52 36.704c.706 0 1.279-.56 1.279-1.25s-.573-1.25-1.28-1.25c-.706 0-1.279.56-1.279 1.25s.573 1.25 1.28 1.25z" fill={accentColor} />
    <path d="M45.076 35.06l-40.898.225.003.566 40.899-.225-.004-.567z" fill={accentColor} />
    <path d="M44.821 36.52c.707 0 1.28-.559 1.28-1.249 0-.69-.573-1.25-1.28-1.25-.706 0-1.279.56-1.279 1.25s.573 1.25 1.28 1.25z" fill={accentColor} />
    <path d="M45.778 35.615L24.92 1.248l-.499.289L45.28 35.904l.5-.289z" fill={accentColor} />
  </svg>
);

// Icon wrapped in brand-green circle — use wherever background is light/white.
export const SwitchOnIconBadge = ({
  size = 36,
}: {
  size?: number;
}) => (
  <span
    style={{
      display: 'inline-flex',
      alignItems: 'center',
      justifyContent: 'center',
      width: size,
      height: size,
      borderRadius: '50%',
      background: '#27AE60',
      flexShrink: 0,
    }}
  >
    <SwitchOnIcon width={size * 0.7} height={size * 0.7} />
  </span>
);

// Full wordmark: [icon] Deep**Inspect** Pro
// "Deep" regular, "Inspect" bold, "Pro" small badge — matches DeepInspect brand.
export const SwitchOnLogo = ({ height = 48 }: { height?: number }) => {
  const fontSize = height * 0.48;
  const font =
    'Inter, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif';

  return (
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 12, height }}>
      <SwitchOnIcon width={height} height={height} pathColor="#27AE60" accentColor="#1D8147" />
      <span style={{ display: 'inline-flex', alignItems: 'baseline', gap: 6 }}>
        <span
          style={{
            fontFamily: font,
            fontSize,
            color: '#1D2024',
            letterSpacing: '-0.02em',
            lineHeight: 1,
          }}
        >
          <span style={{ fontWeight: 400 }}>Deep</span>
          <span style={{ fontWeight: 700 }}>Inspect</span>
        </span>
        <span
          style={{
            fontFamily: font,
            fontSize: fontSize * 0.52,
            fontWeight: 600,
            color: '#FFFFFF',
            background: '#27AE60',
            borderRadius: 4,
            padding: '2px 6px',
            letterSpacing: '0.02em',
            lineHeight: 1.4,
            alignSelf: 'center',
          }}
        >
          Pro
        </span>
      </span>
    </span>
  );
};
