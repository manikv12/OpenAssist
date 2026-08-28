'use client';

import { useEffect, useRef } from 'react';
import type { VoiceLevelMeter } from '../../lib/voice-levels';

export type OrbPhase = 'idle' | 'listening' | 'thinking' | 'speaking';

const VERTEX_SHADER = `
attribute vec2 a_position;
varying vec2 v_uv;
void main() {
  v_uv = a_position;
  gl_Position = vec4(a_position, 0.0, 1.0);
}
`;

/**
 * Fluid orb.
 *
 * Colour model is "palette as light, not pigment": the body is a clean blend of
 * two base colours, and the accent hues are ADDED as key/rim light in the outer
 * edge band where the body is dark. Blending clashing hues into the body
 * averages them into mud, so accents only ever add.
 */
const FRAGMENT_SHADER = `
precision highp float;

varying vec2 v_uv;

uniform float u_time;
uniform float u_micLevel;
uniform float u_outputLevel;
uniform float u_cumulative;
uniform float u_listen;
uniform float u_think;
uniform float u_speak;
uniform vec3 u_colorLow;
uniform vec3 u_colorMid;
uniform vec3 u_colorKey;
uniform vec3 u_colorRim;

vec2 hash2(vec2 p) {
  p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
  return fract(sin(p) * 43758.5453) * 2.0 - 1.0;
}

float noise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  float a = dot(hash2(i + vec2(0.0, 0.0)), f - vec2(0.0, 0.0));
  float b = dot(hash2(i + vec2(1.0, 0.0)), f - vec2(1.0, 0.0));
  float c = dot(hash2(i + vec2(0.0, 1.0)), f - vec2(0.0, 1.0));
  float d = dot(hash2(i + vec2(1.0, 1.0)), f - vec2(1.0, 1.0));
  return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p) {
  float total = 0.0;
  float amplitude = 0.5;
  for (int i = 0; i < 5; i++) {
    total += noise(p) * amplitude;
    p *= 2.02;
    amplitude *= 0.5;
  }
  return total;
}

void main() {
  vec2 uv = v_uv;
  float dist = length(uv);

  // Idle drift keeps the orb alive; voice stirs the fluid harder.
  float churn = u_time * 0.11 + u_cumulative * 0.55;

  // Low-frequency domain warp: broad, slow currents rather than fine noise.
  vec2 warp = vec2(
    fbm(uv * 0.85 + vec2(churn * 0.34, churn * 0.25)),
    fbm(uv * 0.85 + vec2(churn * 0.21 + 4.7, churn * 0.30 + 2.1))
  );

  float detail = fbm(uv * 1.05 + warp * 1.25 + churn * 0.16);
  float flow = fbm(uv * 1.55 + warp * 1.6 - churn * 0.12);

  // Mic reacts instantly; the reply swells gently on phrase shape.
  float swell = u_micLevel * 0.15 + u_outputLevel * 0.09;

  // Sphere first: an almost-round silhouette that only breathes a little.
  float baseRadius = 0.94 + swell * 0.5 + u_think * 0.015;
  float wobble = detail * (0.020 + u_micLevel * 0.030) + sin(u_time * 0.55) * 0.006;
  float edge = baseRadius + wobble;

  // Tight falloff = a solid body with a soft rim, not a cloud.
  float body = smoothstep(edge, edge - 0.10, dist);
  if (body <= 0.001) discard;

  // Normalised position on the sphere, used for real spherical shading.
  float r = clamp(dist / max(edge, 0.001), 0.0, 1.0);
  float z = sqrt(max(0.0, 1.0 - r * r));
  vec3 normal = normalize(vec3(uv / max(edge, 0.001), z));

  // Body: two colours only, blended by the slow internal current. The orb is
  // lit from WITHIN - it emits rather than reflects, so it reads as energy
  // rather than a lit rock.
  // Energy is organised RADIALLY - a bright core fading outward - with the
  // noise only perturbing that falloff. Using raw noise as the colour driver
  // put the gold in one off-centre lobe and read as a blotch.
  float turbulence = (detail * 0.55 + flow * 0.45);
  float energy = pow(1.0 - r, 1.35) + turbulence * (0.26 + u_micLevel * 0.20);
  energy = clamp(energy, 0.0, 1.0);

  // Deep violet ink at the edge rising to gold at the core.
  vec3 color = mix(u_colorLow * 0.40, u_colorMid, smoothstep(0.05, 0.85, energy));

  // Molten filaments where the turbulence peaks inside the hot zone.
  float hot = smoothstep(0.66, 1.0, energy);
  color += u_colorMid * hot * 0.55;
  color += vec3(1.0, 0.95, 0.86) * pow(hot, 4.0) * 0.22;

  // Gentle upper-left form light so it still reads as a sphere.
  vec3 lightDir = normalize(vec3(-0.40, 0.56, 0.72));
  float lambert = clamp(dot(normal, lightDir), 0.0, 1.0);
  color += u_colorMid * pow(lambert, 3.2) * 0.30;

  // Small, sharp glass highlight.
  vec3 viewDir = vec3(0.0, 0.0, 1.0);
  vec3 halfDir = normalize(lightDir + viewDir);
  color += vec3(1.0, 0.97, 0.90) * pow(clamp(dot(normal, halfDir), 0.0, 1.0), 70.0) * 0.30;

  // Accent hues live ONLY in the dark outer band, added as light.
  float edgeBand = smoothstep(0.58, 1.0, r);
  float keyAngle = clamp(dot(normalize(uv + vec2(0.0001)), normalize(vec2(-0.62, 0.60))), 0.0, 1.0);
  float rimAngle = clamp(dot(normalize(uv + vec2(0.0001)), normalize(vec2(0.68, -0.55))), 0.0, 1.0);
  float drift = sin(u_time * 0.19) * 0.12;
  color += u_colorKey * pow(keyAngle, 3.0) * edgeBand * (0.50 + drift + u_micLevel * 0.30);
  color += u_colorRim * pow(rimAngle, 3.0) * edgeBand * (0.44 - drift + u_outputLevel * 0.28);

  // Fresnel rim keeps the edge luminous against a dark page.
  color += u_colorMid * pow(1.0 - z, 2.6) * 0.52;

  // Phase lift: listening brightens, thinking adds a travelling shimmer.
  color *= 1.0 + u_listen * 0.14 + u_speak * 0.09;
  float shimmer = sin(r * 9.0 - u_time * 2.0) * 0.5 + 0.5;
  color += u_colorKey * shimmer * u_think * 0.14 * edgeBand;

  float alpha = body;
  gl_FragColor = vec4(color * alpha, alpha);
}
`;

function compile(gl: WebGLRenderingContext, type: number, source: string): WebGLShader | null {
  const shader = gl.createShader(type);
  if (!shader) return null;
  gl.shaderSource(shader, source);
  gl.compileShader(shader);
  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
    gl.deleteShader(shader);
    return null;
  }
  return shader;
}

function hexToRgb(hex: string): [number, number, number] {
  const value = hex.replace('#', '');
  const full = value.length === 3 ? value.split('').map((c) => c + c).join('') : value;
  const int = Number.parseInt(full, 16);
  if (Number.isNaN(int)) return [1, 1, 1];
  return [((int >> 16) & 255) / 255, ((int >> 8) & 255) / 255, (int & 255) / 255];
}

export function VoiceOrb({
  phase,
  meter,
  size = 44,
  colors = { low: '#241B44', mid: '#E0BC63', key: '#7C6BF0', rim: '#3FB9C6' },
}: {
  phase: OrbPhase;
  meter: VoiceLevelMeter | null;
  size?: number;
  colors?: { low: string; mid: string; key: string; rim: string };
}) {
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const phaseRef = useRef(phase);
  const meterRef = useRef(meter);

  useEffect(() => { phaseRef.current = phase; }, [phase]);
  useEffect(() => { meterRef.current = meter; }, [meter]);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;

    const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (reduceMotion) return;

    const gl = (canvas.getContext('webgl', { alpha: true, premultipliedAlpha: true, antialias: true })
      ?? canvas.getContext('experimental-webgl', { alpha: true, premultipliedAlpha: true })) as WebGLRenderingContext | null;
    if (!gl) return;

    const vertex = compile(gl, gl.VERTEX_SHADER, VERTEX_SHADER);
    const fragment = compile(gl, gl.FRAGMENT_SHADER, FRAGMENT_SHADER);
    const program = gl.createProgram();
    if (!vertex || !fragment || !program) return;
    gl.attachShader(program, vertex);
    gl.attachShader(program, fragment);
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) return;
    gl.useProgram(program);

    const buffer = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    const position = gl.getAttribLocation(program, 'a_position');
    gl.enableVertexAttribArray(position);
    gl.vertexAttribPointer(position, 2, gl.FLOAT, false, 0, 0);

    gl.enable(gl.BLEND);
    gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);

    const uniform = (name: string) => gl.getUniformLocation(program, name);
    const uTime = uniform('u_time');
    const uMic = uniform('u_micLevel');
    const uOutput = uniform('u_outputLevel');
    const uCumulative = uniform('u_cumulative');
    const uListen = uniform('u_listen');
    const uThink = uniform('u_think');
    const uSpeak = uniform('u_speak');

    gl.uniform3fv(uniform('u_colorLow'), hexToRgb(colors.low));
    gl.uniform3fv(uniform('u_colorMid'), hexToRgb(colors.mid));
    gl.uniform3fv(uniform('u_colorKey'), hexToRgb(colors.key));
    gl.uniform3fv(uniform('u_colorRim'), hexToRgb(colors.rim));

    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const pixels = Math.round(size * dpr);
    canvas.width = pixels;
    canvas.height = pixels;
    gl.viewport(0, 0, pixels, pixels);

    canvas.parentElement?.classList.add('is-gl');

    let frame = 0;
    let last = performance.now();
    let cumulative = 0;
    // Springs give the swell a little overshoot instead of a dead ramp.
    let micValue = 0;
    let micVelocity = 0;
    let outValue = 0;
    let outVelocity = 0;
    const blend = { listening: 0, thinking: 0, speaking: 0 };

    const render = (now: number) => {
      const dt = Math.min((now - last) / 1000, 1 / 20);
      last = now;

      const sampled = meterRef.current?.sample(dt) ?? { mic: 0, output: 0 };
      const current = phaseRef.current;

      // When we have no real audio yet, keep a gentle synthetic cadence so the
      // orb still reads as "speaking" rather than freezing.
      const micTarget = sampled.mic;
      const outTarget = current === 'speaking' && sampled.output <= 0.001
        ? 0.34 + Math.sin(now / 1000 * 1.05) * 0.16
        : sampled.output;

      // Mic: stiff spring, reacts immediately. Output: soft, phrase-shaped.
      const micAccel = (micTarget - micValue) * 130 - micVelocity * 13;
      micVelocity += micAccel * dt;
      micValue = Math.max(0, micValue + micVelocity * dt);

      const outAccel = (outTarget - outValue) * 26 - outVelocity * 9.5;
      outVelocity += outAccel * dt;
      outValue = Math.max(0, outValue + outVelocity * dt);

      const drive = Math.max(micValue, outValue * 0.7);
      cumulative += drive * dt * (current === 'speaking' ? 3.6 : 3.0);

      const ease = 1 - Math.exp(-dt / 0.28);
      blend.listening += ((current === 'listening' ? 1 : 0) - blend.listening) * ease;
      blend.thinking += ((current === 'thinking' ? 1 : 0) - blend.thinking) * ease;
      blend.speaking += ((current === 'speaking' ? 1 : 0) - blend.speaking) * ease;

      gl.uniform1f(uTime, now / 1000);
      gl.uniform1f(uMic, micValue);
      gl.uniform1f(uOutput, outValue);
      gl.uniform1f(uCumulative, cumulative);
      gl.uniform1f(uListen, blend.listening);
      gl.uniform1f(uThink, blend.thinking);
      gl.uniform1f(uSpeak, blend.speaking);

      gl.clearColor(0, 0, 0, 0);
      gl.clear(gl.COLOR_BUFFER_BIT);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
      frame = requestAnimationFrame(render);
    };
    frame = requestAnimationFrame(render);

    return () => {
      cancelAnimationFrame(frame);
      canvas.parentElement?.classList.remove('is-gl');
      gl.deleteProgram(program);
      gl.deleteShader(vertex);
      gl.deleteShader(fragment);
      gl.deleteBuffer(buffer);
    };
  }, [colors.key, colors.low, colors.mid, colors.rim, size]);

  return (
    <span className={`oa-orb oa-orb--${phase}`} style={{ width: size, height: size }} aria-hidden="true">
      <canvas ref={canvasRef} className="oa-orb__canvas" style={{ width: size, height: size }} />
    </span>
  );
}
