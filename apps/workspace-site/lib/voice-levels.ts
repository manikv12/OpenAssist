/**
 * Live audio level metering for the voice orb.
 *
 * Two streams are metered separately so the orb can tell the difference between
 * "the user is talking" and "the assistant is answering":
 *   - mic    → the local microphone track
 *   - output → the remote assistant audio track
 *
 * Level shaping happens exactly once, here. Consumers must not re-expand the
 * value with another envelope: stacking two envelopes crushes normal speech
 * down to near-zero drive and the orb stops looking alive.
 */

export type VoiceLevels = { mic: number; output: number };

const FFT_SIZE = 1024;
/** Below this RMS is room tone, not speech. */
const NOISE_FLOOR = 0.008;
/** Speech lands around this RMS; map it to the top of the range. */
const SPEECH_CEILING = 0.22;

type Meter = {
  analyser: AnalyserNode;
  buffer: Float32Array<ArrayBuffer>;
  source: MediaStreamAudioSourceNode;
  /** Smoothed value, with separate attack/release so speech reads instantly. */
  value: number;
  attack: number;
  release: number;
};

function shape(rms: number): number {
  if (rms <= NOISE_FLOOR) return 0;
  const scaled = (rms - NOISE_FLOOR) / (SPEECH_CEILING - NOISE_FLOOR);
  // pow < 1 lifts conversational speech without exaggerating loud peaks.
  return Math.min(1, Math.pow(Math.max(0, scaled), 0.62));
}

export class VoiceLevelMeter {
  private context: AudioContext | null = null;
  private mic: Meter | null = null;
  private output: Meter | null = null;
  private levels: VoiceLevels = { mic: 0, output: 0 };

  private ensureContext(): AudioContext | null {
    if (typeof window === 'undefined') return null;
    if (!this.context) {
      const Ctor = window.AudioContext ?? (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
      if (!Ctor) return null;
      this.context = new Ctor();
    }
    if (this.context.state === 'suspended') void this.context.resume().catch(() => undefined);
    return this.context;
  }

  private makeMeter(stream: MediaStream, attack: number, release: number): Meter | null {
    const context = this.ensureContext();
    if (!context || stream.getAudioTracks().length === 0) return null;
    const analyser = context.createAnalyser();
    analyser.fftSize = FFT_SIZE;
    // Keep the node's own smoothing low; the envelope below owns the feel.
    analyser.smoothingTimeConstant = 0.2;
    const source = context.createMediaStreamSource(stream);
    source.connect(analyser);
    return { analyser, source, buffer: new Float32Array(new ArrayBuffer(analyser.fftSize * 4)), value: 0, attack, release };
  }

  /** Mic is deliberately snappy: the user's own speech must feel instant. */
  attachMic(stream: MediaStream) {
    this.detachMic();
    this.mic = this.makeMeter(stream, 0.045, 0.20);
  }

  /**
   * The reply is deliberately slower: following syllables makes the orb
   * twitch, so it follows the shape of the phrase instead.
   */
  attachOutput(stream: MediaStream) {
    this.detachOutput();
    this.output = this.makeMeter(stream, 0.30, 0.62);
  }

  detachMic() {
    this.mic?.source.disconnect();
    this.mic = null;
    this.levels.mic = 0;
  }

  detachOutput() {
    this.output?.source.disconnect();
    this.output = null;
    this.levels.output = 0;
  }

  private read(meter: Meter | null, dt: number): number {
    if (!meter) return 0;
    meter.analyser.getFloatTimeDomainData(meter.buffer);
    let sum = 0;
    for (let i = 0; i < meter.buffer.length; i += 1) sum += meter.buffer[i] * meter.buffer[i];
    const target = shape(Math.sqrt(sum / meter.buffer.length));
    const tau = target > meter.value ? meter.attack : meter.release;
    // Frame-rate independent smoothing, so the feel is the same at 60 or 120Hz.
    meter.value += (target - meter.value) * (1 - Math.exp(-dt / tau));
    return meter.value;
  }

  sample(dt: number): VoiceLevels {
    this.levels = { mic: this.read(this.mic, dt), output: this.read(this.output, dt) };
    return this.levels;
  }

  dispose() {
    this.detachMic();
    this.detachOutput();
    void this.context?.close().catch(() => undefined);
    this.context = null;
  }
}
