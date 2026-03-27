import { memo } from "react";
import { AppIcon } from "./AppIcon";

interface ChevronIconProps {
  expanded?: boolean;
  className?: string;
}

function ChevronIconInner({
  expanded = false,
  className,
}: ChevronIconProps) {
  const classes = ["chevron-icon", expanded ? "expanded" : "", className]
    .filter(Boolean)
    .join(" ");

  return (
    <AppIcon
      symbol="chevron.right"
      className={classes}
      size={14}
      strokeWidth={1.7}
    />
  );
}

export const ChevronIcon = memo(ChevronIconInner);
