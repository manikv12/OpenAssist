import { createContext, useContext } from "react";

export const StreamingContext = createContext(false);

export function useIsStreaming(): boolean {
  return useContext(StreamingContext);
}
