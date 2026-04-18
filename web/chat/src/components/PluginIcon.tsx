import { memo } from "react";
import { AppIcon } from "./AppIcon";

interface PluginIconProps {
  iconDataUrl?: string;
  displayName: string;
  className?: string;
  size?: number;
  strokeWidth?: number;
}

function PluginIconInner({
  iconDataUrl,
  displayName,
  className = "",
  size = 12,
  strokeWidth = 2,
}: PluginIconProps) {
  const resolvedClassName = ["plugin-chip-icon", className].filter(Boolean).join(" ");

  if (iconDataUrl) {
    return (
      <span className={resolvedClassName} aria-hidden="true">
        <img src={iconDataUrl} alt="" loading="lazy" />
      </span>
    );
  }

  return (
    <span
      className={resolvedClassName}
      aria-hidden="true"
      title={`${displayName} plugin`}
    >
      <AppIcon symbol="plug" size={size} strokeWidth={strokeWidth} />
    </span>
  );
}

export const PluginIcon = memo(PluginIconInner);
