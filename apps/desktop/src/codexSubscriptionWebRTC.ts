export type CodexSubscriptionProtocolEvent = {
  type?: string;
  [key: string]: unknown;
};

type CodexSubscriptionWebRTCCallbacks = {
  onConnectionState?: (state: RTCPeerConnectionState) => void;
  onProtocolEvent?: (event: CodexSubscriptionProtocolEvent) => void;
  onAudioPlaying?: (playing: boolean) => void;
  onError?: (message: string) => void;
};

function waitForIceGathering(peer: RTCPeerConnection, timeoutMs = 2_500) {
  if (peer.iceGatheringState === "complete") return Promise.resolve();
  return new Promise<void>((resolve) => {
    let settled = false;
    const finish = () => {
      if (settled) return;
      settled = true;
      peer.removeEventListener("icegatheringstatechange", onChange);
      resolve();
    };
    const onChange = () => {
      if (peer.iceGatheringState === "complete") finish();
    };
    peer.addEventListener("icegatheringstatechange", onChange);
    window.setTimeout(finish, timeoutMs);
  });
}

export function normalizeCodexSubscriptionSessionDescriptionSdp(value: unknown) {
  const raw = typeof value === "string" ? value : "";
  if (!raw.trim()) return "";
  return raw.endsWith("\r\n") ? raw : `${raw.replace(/(?:\r?\n)+$/, "")}\r\n`;
}

export class CodexSubscriptionWebRTC {
  private peer: RTCPeerConnection | null = null;
  private events: RTCDataChannel | null = null;
  private audio: HTMLAudioElement | null = null;
  private outputSuppressed = false;

  constructor(private readonly callbacks: CodexSubscriptionWebRTCCallbacks = {}) {}

  async prepare(stream: MediaStream) {
    this.close();
    const peer = new RTCPeerConnection();
    this.peer = peer;
    for (const track of stream.getAudioTracks()) peer.addTrack(track, stream);

    const events = peer.createDataChannel("oai-events");
    this.events = events;
    events.addEventListener("message", (message) => {
      if (typeof message.data !== "string") return;
      try {
        const event = JSON.parse(message.data) as CodexSubscriptionProtocolEvent;
        this.callbacks.onProtocolEvent?.(event);
      } catch {
        // Experimental provider events are best effort. Never log their body.
      }
    });

    peer.addEventListener("connectionstatechange", () => {
      this.callbacks.onConnectionState?.(peer.connectionState);
      if (peer.connectionState === "failed") {
        this.callbacks.onError?.("Codex Voice lost its secure audio connection.");
      }
    });
    peer.addEventListener("track", (event) => {
      if (event.track.kind !== "audio") return;
      this.attachRemoteAudio(event.streams[0] ?? new MediaStream([event.track]));
    });

    await peer.setLocalDescription(await peer.createOffer({ offerToReceiveAudio: true }));
    await waitForIceGathering(peer);
    const sdp = peer.localDescription?.sdp;
    if (!sdp?.trim()) throw new Error("Codex Voice could not prepare its secure audio offer.");
    return sdp;
  }

  async acceptAnswer(sdp: string) {
    const peer = this.peer;
    if (!peer) throw new Error("Codex Voice audio was not prepared.");
    if (peer.currentRemoteDescription) return;
    const normalizedSdp = normalizeCodexSubscriptionSessionDescriptionSdp(sdp);
    if (!normalizedSdp) throw new Error("Codex Voice returned an empty audio answer.");
    await peer.setRemoteDescription({ type: "answer", sdp: normalizedSdp });
  }

  setMuted(muted: boolean) {
    for (const sender of this.peer?.getSenders() ?? []) {
      if (sender.track?.kind === "audio") sender.track.enabled = !muted;
    }
  }

  setOutputSuppressed(suppressed: boolean) {
    this.outputSuppressed = suppressed;
    if (!this.audio) return;
    this.audio.muted = suppressed;
    if (suppressed) {
      this.callbacks.onAudioPlaying?.(false);
    } else if (!this.audio.paused && !this.audio.ended) {
      this.callbacks.onAudioPlaying?.(true);
    }
  }

  close() {
    this.callbacks.onAudioPlaying?.(false);
    if (this.audio) {
      this.audio.pause();
      this.audio.srcObject = null;
      this.audio.remove();
      this.audio = null;
    }
    try { this.events?.close(); } catch { /* already closed */ }
    this.events = null;
    try { this.peer?.close(); } catch { /* already closed */ }
    this.peer = null;
  }

  private attachRemoteAudio(stream: MediaStream) {
    if (this.audio) {
      this.audio.pause();
      this.audio.srcObject = null;
      this.audio.remove();
    }
    const audio = document.createElement("audio");
    audio.autoplay = true;
    audio.setAttribute("playsinline", "");
    audio.style.display = "none";
    audio.muted = this.outputSuppressed;
    audio.srcObject = stream;
    audio.addEventListener("playing", () => this.callbacks.onAudioPlaying?.(!this.outputSuppressed));
    const finished = () => this.callbacks.onAudioPlaying?.(false);
    audio.addEventListener("pause", finished);
    audio.addEventListener("ended", finished);
    document.body.appendChild(audio);
    this.audio = audio;
    void audio.play().catch(() => {
      this.callbacks.onError?.("Codex Voice connected, but macOS blocked assistant audio playback.");
    });
  }
}
