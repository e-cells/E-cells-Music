import type { Howl } from 'howler';
import logger from './logger';

const TAG = 'WebAudioEffectEngine';

const EQ_FREQUENCIES = [60, 170, 310, 600, 1000, 3000, 6000, 12000, 14000, 16000];
const EQ_FILTER_TYPE: BiquadFilterType = 'peaking';
const EQ_Q = 1.4;

export class WebAudioEffectEngine {
  private audioCtx: AudioContext | null = null;
  private sourceNode: MediaElementAudioSourceNode | null = null;
  private eqFilters: BiquadFilterNode[] = [];
  private outputGain: GainNode | null = null;

  private currentAudioElement: HTMLAudioElement | null = null;
  private connected = false;
  private currentEffect: string = 'none';

  // Effect nodes (inserted between EQ chain and outputGain)
  private effectNodes: AudioNode[] = [];

  // Cached IR buffers
  private reverbIR: AudioBuffer | null = null;

  private getOrCreateContext(): AudioContext | null {
    if (this.audioCtx) return this.audioCtx;
    try {
      const AudioCtx = window.AudioContext || (window as any).webkitAudioContext;
      if (!AudioCtx) return null;
      this.audioCtx = new AudioCtx();
      return this.audioCtx;
    } catch (e) {
      logger.warn(TAG, 'Failed to create AudioContext', e);
      return null;
    }
  }

  private buildEQChain(ctx: AudioContext): BiquadFilterNode[] {
    const filters: BiquadFilterNode[] = [];
    for (let i = 0; i < EQ_FREQUENCIES.length; i++) {
      const f = ctx.createBiquadFilter();
      f.type = EQ_FILTER_TYPE;
      f.frequency.value = EQ_FREQUENCIES[i];
      f.Q.value = EQ_Q;
      f.gain.value = 0;
      filters.push(f);
    }
    // Chain: filter[0] -> filter[1] -> ... -> filter[9]
    for (let i = 0; i < filters.length - 1; i++) {
      filters[i].connect(filters[i + 1]);
    }
    return filters;
  }

  private ensureChain(ctx: AudioContext, source: MediaElementAudioSourceNode): void {
    if (this.connected) return;

    this.eqFilters = this.buildEQChain(ctx);
    this.outputGain = ctx.createGain();
    this.outputGain.gain.value = 1.0;

    // source -> eq[0] -> ... -> eq[9] -> outputGain -> destination
    source.connect(this.eqFilters[0]);
    this.eqFilters[this.eqFilters.length - 1].connect(this.outputGain);
    this.outputGain.connect(ctx.destination);

    this.connected = true;
  }

  attachToHowl(howl: Howl): void {
    const ctx = this.getOrCreateContext();
    if (!ctx) return;

    const audioEl = this.extractAudioElement(howl);
    if (!audioEl) {
      logger.warn(TAG, 'Could not extract <audio> element from Howl');
      return;
    }

    // Same element already attached — skip
    if (audioEl === this.currentAudioElement && this.connected) return;

    // Disconnect previous chain
    this.disconnect();

    try {
      this.sourceNode = ctx.createMediaElementSource(audioEl);
      this.currentAudioElement = audioEl;
      this.ensureChain(ctx, this.sourceNode);
      logger.info(TAG, 'Attached to Howl audio element');
    } catch (e) {
      // createMediaElementSource can fail if called twice on same element
      // or on cross-origin audio
      logger.warn(TAG, 'Failed to create MediaElementSource', e);
      this.connected = false;
    }
  }

  private extractAudioElement(howl: Howl): HTMLAudioElement | null {
    try {
      const sounds = (howl as any)._sounds;
      if (!Array.isArray(sounds) || sounds.length === 0) return null;
      const node = sounds[0]._node;
      if (node instanceof HTMLAudioElement) return node;
      return null;
    } catch {
      return null;
    }
  }

  setEqualizer(gains: number[]): void {
    if (!this.connected || this.eqFilters.length === 0) return;
    for (let i = 0; i < Math.min(gains.length, this.eqFilters.length); i++) {
      const clamped = Math.max(-12, Math.min(12, gains[i]));
      this.eqFilters[i].gain.value = clamped;
    }
  }

  setEffect(effect: string): void {
    if (effect === this.currentEffect) return;
    this.currentEffect = effect;
    if (!this.connected || !this.audioCtx || !this.outputGain) return;

    this.removeEffectNodes();

    const lastEq = this.eqFilters[this.eqFilters.length - 1];
    if (!lastEq) return;

    switch (effect) {
      case 'viper_tape':
        this.applyTapeEffect(lastEq);
        break;
      case 'viper_atmos':
        this.applyAtmosEffect(lastEq);
        break;
      case 'viper_clear':
        this.applyClearEffect(lastEq);
        break;
      case 'vocal':
        this.applyVocalEffect(lastEq);
        break;
      case 'none':
      default:
        lastEq.connect(this.outputGain);
        break;
    }
  }

  private removeEffectNodes(): void {
    if (!this.connected || !this.outputGain) return;
    const lastEq = this.eqFilters[this.eqFilters.length - 1];
    if (!lastEq) return;

    try { lastEq.disconnect(this.outputGain); } catch { /* not connected directly */ }
    for (const node of this.effectNodes) {
      try { node.disconnect(); } catch { /* ignore */ }
      try { lastEq.disconnect(node as AudioNode); } catch { /* ignore */ }
    }
    this.effectNodes = [];
  }

  private chainEffectNodes(lastEq: BiquadFilterNode, nodes: AudioNode[]): void {
    if (!this.outputGain) return;
    this.effectNodes = nodes;

    lastEq.connect(nodes[0]);
    for (let i = 0; i < nodes.length - 1; i++) {
      nodes[i].connect(nodes[i + 1]);
    }
    nodes[nodes.length - 1].connect(this.outputGain);
  }

  private applyEqPresetEffect(lastEq: BiquadFilterNode, gains: number[], label: string): void {
    const ctx = this.audioCtx!;
    const nodes: BiquadFilterNode[] = [];
    for (let i = 0; i < gains.length && i < EQ_FREQUENCIES.length; i++) {
      const f = ctx.createBiquadFilter();
      f.type = 'peaking';
      f.frequency.value = EQ_FREQUENCIES[i];
      f.Q.value = 1.4;
      f.gain.value = Math.max(-12, Math.min(12, gains[i]));
      nodes.push(f);
    }
    this.chainEffectNodes(lastEq, nodes);
    logger.info(TAG, `Applied EQ preset effect: ${label}`);
  }

  private applyVocalEffect(lastEq: BiquadFilterNode): void {
    const ctx = this.audioCtx!;
    // 声道平均提取人声：保留中央声像（主唱人声通常在中央位置）
    const processor = ctx.createScriptProcessor(4096, 2, 2);
    processor.onaudioprocess = (e) => {
      const inputL = e.inputBuffer.getChannelData(0);
      const inputR = e.inputBuffer.getChannelData(1);
      const outputL = e.outputBuffer.getChannelData(0);
      const outputR = e.outputBuffer.getChannelData(1);
      for (let i = 0; i < inputL.length; i++) {
        const center = (inputL[i] + inputR[i]) * 0.5;
        outputL[i] = center;
        outputR[i] = center;
      }
    };
    this.chainEffectNodes(lastEq, [processor]);
    logger.info(TAG, 'Applied vocal extraction effect');
  }

  private applyTapeEffect(lastEq: BiquadFilterNode): void {
    const ctx = this.audioCtx!;
    const shaper = ctx.createWaveShaper();
    const curve = this.generateTapeSaturationCurve(8192);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (shaper as any).curve = curve;
    shaper.oversample = '4x';
    this.chainEffectNodes(lastEq, [shaper]);
    logger.info(TAG, 'Applied tape saturation effect');
  }

  private applyAtmosEffect(lastEq: BiquadFilterNode): void {
    const ctx = this.audioCtx!;
    const convolver = ctx.createConvolver();
    convolver.buffer = this.getReverbIR();
    // Mix wet/dry: reduce dry, add reverb
    const dryGain = ctx.createGain();
    dryGain.gain.value = 0.7;
    const wetGain = ctx.createGain();
    wetGain.gain.value = 0.4;

    // lastEq -> dryGain -> outputGain
    // lastEq -> convolver -> wetGain -> outputGain
    this.effectNodes = [dryGain, convolver, wetGain];
    lastEq.connect(dryGain);
    dryGain.connect(this.outputGain!);
    lastEq.connect(convolver);
    convolver.connect(wetGain);
    wetGain.connect(this.outputGain!);
    logger.info(TAG, 'Applied spatial atmosphere effect');
  }

  private applyClearEffect(lastEq: BiquadFilterNode): void {
    const ctx = this.audioCtx!;
    const compressor = ctx.createDynamicsCompressor();
    compressor.threshold.value = -20;
    compressor.knee.value = 10;
    compressor.ratio.value = 4;
    compressor.attack.value = 0.003;
    compressor.release.value = 0.25;
    this.chainEffectNodes(lastEq, [compressor]);
    logger.info(TAG, 'Applied clarity compression effect');
  }

  private applySubwooferEffect(lastEq: BiquadFilterNode): void {
    const ctx = this.audioCtx!;
    const bass = ctx.createBiquadFilter();
    bass.type = 'lowshelf';
    bass.frequency.value = 100;
    bass.gain.value = 6;
    this.chainEffectNodes(lastEq, [bass]);
    logger.info(TAG, 'Applied subwoofer bass boost effect');
  }

  private getReverbIR(): AudioBuffer {
    if (this.reverbIR) return this.reverbIR;
    const ctx = this.audioCtx!;
    const duration = 1.5;
    const decay = 2.0;
    const sampleRate = ctx.sampleRate;
    const length = Math.floor(sampleRate * duration);
    const buffer = ctx.createBuffer(2, length, sampleRate);
    for (let ch = 0; ch < 2; ch++) {
      const data = buffer.getChannelData(ch);
      for (let i = 0; i < length; i++) {
        data[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / length, decay);
      }
    }
    this.reverbIR = buffer;
    return buffer;
  }

  private generateTapeSaturationCurve(samples: number): Float32Array {
    const curve = new Float32Array(samples);
    const k = 2;
    for (let i = 0; i < samples; i++) {
      const x = (i * 2) / samples - 1;
      curve[i] = ((Math.PI + k) * x) / (Math.PI + k * Math.abs(x));
    }
    return curve;
  }

  setVolume(value: number): void {
    if (this.outputGain) {
      this.outputGain.gain.value = Math.max(0, Math.min(1, value));
    }
  }

  isConnected(): boolean {
    return this.connected;
  }

  disconnect(): void {
    if (this.sourceNode) {
      try { this.sourceNode.disconnect(); } catch { /* ignore */ }
    }
    for (const f of this.eqFilters) {
      try { f.disconnect(); } catch { /* ignore */ }
    }
    for (const node of this.effectNodes) {
      try { node.disconnect(); } catch { /* ignore */ }
    }
    if (this.outputGain) {
      try { this.outputGain.disconnect(); } catch { /* ignore */ }
    }
    this.sourceNode = null;
    this.eqFilters = [];
    this.outputGain = null;
    this.effectNodes = [];
    this.connected = false;
    this.currentAudioElement = null;
  }

  async resume(): Promise<void> {
    if (this.audioCtx && this.audioCtx.state === 'suspended') {
      try {
        await this.audioCtx.resume();
      } catch (e) {
        logger.warn(TAG, 'Failed to resume AudioContext', e);
      }
    }
  }

  async suspend(): Promise<void> {
    if (this.audioCtx && this.audioCtx.state === 'running') {
      try {
        await this.audioCtx.suspend();
      } catch (e) {
        logger.warn(TAG, 'Failed to suspend AudioContext', e);
      }
    }
  }
}
