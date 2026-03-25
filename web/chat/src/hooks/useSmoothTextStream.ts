import { useState, useEffect, useRef } from "react";

export function useSmoothTextStream(targetText: string, isStreaming: boolean): string {
  const [displayedText, setDisplayedText] = useState(targetText);
  const rafRef = useRef<number>(0);
  const targetTextRef = useRef(targetText);

  useEffect(() => {
    targetTextRef.current = targetText;
    
    if (!isStreaming) {
      setDisplayedText(targetText);
      if (rafRef.current) {
        cancelAnimationFrame(rafRef.current);
        rafRef.current = 0;
      }
    }
  }, [targetText, isStreaming]);

  useEffect(() => {
    if (!isStreaming) return;

    setDisplayedText((current) => {
      if (current.length > targetTextRef.current.length || !targetTextRef.current.startsWith(current)) {
         return targetTextRef.current;
      }
      return current;
    });

    let lastTick = performance.now();
    let fraction = 0;

    function tick(now: number) {
      const deltaMs = now - lastTick;
      lastTick = now;

      setDisplayedText((current) => {
        const target = targetTextRef.current;
        if (current === target) {
          return current;
        }
        
        const remainingChars = target.length - current.length;
        if (remainingChars <= 0 || !target.startsWith(current)) {
          return target;
        }

        const baseCharsPerSec = 30; 
        const catchupFactor = remainingChars / 25; 
        const charsPerSec = Math.max(baseCharsPerSec, baseCharsPerSec * catchupFactor);
        
        // Use a fractional accumulator for smoother sub-millisecond pacing at low speeds
        fraction += (charsPerSec * deltaMs) / 1000;
        let charsToAdd = Math.floor(fraction);
        
        if (charsToAdd > 0) {
          fraction -= charsToAdd;
          if (charsToAdd > remainingChars) {
            charsToAdd = remainingChars;
          }
          return target.slice(0, current.length + charsToAdd);
        }

        return current;
      });

      rafRef.current = requestAnimationFrame(tick);
    }

    rafRef.current = requestAnimationFrame(tick);

    return () => {
      if (rafRef.current) {
        cancelAnimationFrame(rafRef.current);
      }
    };
  }, [isStreaming]);

  return displayedText;
}
