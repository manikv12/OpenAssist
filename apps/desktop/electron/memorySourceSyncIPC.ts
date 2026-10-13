import type { IpcMain } from "electron";
import type { MemorySourceWorkspaceCoordinator } from "./memorySourceWorkspaceCoordinator.js";

export const memorySourcePreviewIPCChannel = "openassist:memory-sources-preview";
export const memorySourceSyncIPCChannel = "openassist:memory-sources-sync";

/**
 * Isolated registration hook. The host must supply a coordinator backed by an
 * authenticated OpenAssist Workspace tool caller. Keeping construction outside
 * this module avoids adding OAuth state or secrets to the renderer.
 */
export function registerMemorySourceSyncIPC(
  ipcMain: Pick<IpcMain, "handle" | "removeHandler">,
  coordinator: MemorySourceWorkspaceCoordinator | (() => MemorySourceWorkspaceCoordinator | Promise<MemorySourceWorkspaceCoordinator>)
) {
  const resolveCoordinator = () => typeof coordinator === "function" ? coordinator() : coordinator;
  ipcMain.removeHandler(memorySourcePreviewIPCChannel);
  ipcMain.removeHandler(memorySourceSyncIPCChannel);
  ipcMain.handle(memorySourcePreviewIPCChannel, async () => (await resolveCoordinator()).preview());
  ipcMain.handle(memorySourceSyncIPCChannel, async () => (await resolveCoordinator()).sync());
  return () => {
    ipcMain.removeHandler(memorySourcePreviewIPCChannel);
    ipcMain.removeHandler(memorySourceSyncIPCChannel);
  };
}
