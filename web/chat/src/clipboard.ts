function tryNativeCopy(text: string): boolean {
  const handler = window.webkit?.messageHandlers?.copyText;
  if (!handler || typeof handler.postMessage !== "function") {
    return false;
  }
  try {
    handler.postMessage(text);
    return true;
  } catch {
    return false;
  }
}

export async function copyPlainText(text: string): Promise<void> {
  if (tryNativeCopy(text)) {
    return;
  }

  if (navigator.clipboard?.writeText) {
    await navigator.clipboard.writeText(text);
    return;
  }

  if (tryNativeCopy(text)) {
    return;
  }

  throw new Error("Clipboard unavailable");
}
