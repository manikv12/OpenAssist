import { memo } from "react";

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
    <svg
      className={classes}
      width="14"
      height="14"
      viewBox="0 0 14 14"
      fill="none"
      aria-hidden="true"
    >
      <path
        d="M5 3.5L8.75 7L5 10.5"
        stroke="currentColor"
        strokeWidth="1.7"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

export const ChevronIcon = memo(ChevronIconInner);
