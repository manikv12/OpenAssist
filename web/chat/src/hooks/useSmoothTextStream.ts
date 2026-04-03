import { useEffect, useRef, useState } from "react";

const STREAM_FRAME_INTERVAL_MS = 42;
const BASE_STREAM_CHARS_PER_SEC = 84;
const MAX_STREAM_CHARS_PER_SEC = 220;
const MAX_STREAM_CHARS_PER_TICK = 20;

export function useSmoothTextStream(targetText: string, isStreaming: boolean): string {
  const [displayedText, setDisplayedText] = useState(targetText);
  const rafRef = useRef<number>(0);
  const targetTextRef = useRef(targetText);
  const displayedTextRef = useRef(targetText);
  const fractionRef = useRef(0);
  const lastTickRef = useRef(0);

  function stopAnimation() {
    if (rafRef.current) {
      cancelAnimationFrame(rafRef.current);
      rafRef.current = 0;
    }
  }

  function setDisplayedTextValue(nextText: string) {
    displayedTextRef.current = nextText;
    setDisplayedText((current) => (current === nextText ? current : nextText));
  }

  useEffect(() => {
    targetTextRef.current = targetText;

    if (!isStreaming) {
      stopAnimation();
      fractionRef.current = 0;
      setDisplayedTextValue(targetText);
      return;
    }

    const current = displayedTextRef.current;
    if (
      current.length > targetText.length ||
      !targetText.startsWith(current)
    ) {
      fractionRef.current = 0;
      stopAnimation();
      setDisplayedTextValue(targetText);
      return;
    }

    function tick(now: number) {
      const target = targetTextRef.current;
      const current = displayedTextRef.current;
      if (current === target) {
        fractionRef.current = 0;
        rafRef.current = 0;
        return;
      }

      const deltaMs = now - lastTickRef.current;
      if (deltaMs < STREAM_FRAME_INTERVAL_MS) {
        rafRef.current = requestAnimationFrame(tick);
        return;
      }
      lastTickRef.current = now;

      if (current.length > target.length || !target.startsWith(current)) {
        fractionRef.current = 0;
        setDisplayedTextValue(target);
        rafRef.current = 0;
        return;
      }

      const remainingChars = target.length - current.length;
      if (remainingChars <= 0) {
        fractionRef.current = 0;
        rafRef.current = 0;
        return;
      }

      const catchupBoost = Math.min(1.8, remainingChars / 90);
      const charsPerSec = Math.min(
        MAX_STREAM_CHARS_PER_SEC,
        BASE_STREAM_CHARS_PER_SEC * (1 + catchupBoost)
      );

      fractionRef.current += (charsPerSec * deltaMs) / 1000;
      const availableChars = Math.floor(fractionRef.current);
      const charsToAdd = Math.min(
        availableChars,
        MAX_STREAM_CHARS_PER_TICK,
        remainingChars
      );

      if (charsToAdd > 0) {
        fractionRef.current -= charsToAdd;
        setDisplayedTextValue(target.slice(0, current.length + charsToAdd));
      }

      if (displayedTextRef.current === targetTextRef.current) {
        fractionRef.current = 0;
        rafRef.current = 0;
        return;
      }

      rafRef.current = requestAnimationFrame(tick);
    }

    if (current !== targetText && rafRef.current === 0) {
      lastTickRef.current = performance.now();
      rafRef.current = requestAnimationFrame(tick);
    }
  }, [targetText, isStreaming]);

  useEffect(() => stopAnimation, []);

  return displayedText;
}
