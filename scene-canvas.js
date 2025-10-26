// scene-canvas.js
// Minimal OffscreenCanvas 2D sample with deterministic animation (no external libs).

export async function createSceneController({ canvas, width, height }) {
  const ctx = canvas.getContext('2d', {
    alpha: false,
    desynchronized: false
  });
  if (!ctx) {
    throw new Error('2D canvas context not available');
  }

  canvas.width = width;
  canvas.height = height;
  ctx.imageSmoothingEnabled = true;

  function renderFrame(tSec) {
    const w = canvas.width;
    const h = canvas.height;

    // Reset any leftover transforms.
    if (typeof ctx.resetTransform === 'function') {
      ctx.resetTransform();
    } else {
      ctx.setTransform(1, 0, 0, 1, 0, 0);
    }

    // Background gradient slowly shifts hue over time.
    const hueBase = (tSec * 30) % 360;
    const gradient = ctx.createLinearGradient(0, 0, 0, h);
    gradient.addColorStop(0, `hsl(${hueBase} 70% 20%)`);
    gradient.addColorStop(1, `hsl(${(hueBase + 150) % 360} 60% 6%)`);
    ctx.fillStyle = gradient;
    ctx.fillRect(0, 0, w, h);

    // Concentric waves orbiting around the center.
    const orbitCount = 24;
    const radiusBase = Math.min(w, h) * 0.35;
    ctx.save();
    ctx.translate(w / 2, h / 2);

    for (let i = 0; i < orbitCount; i++) {
      const wavePhase = tSec * 0.8 + i * 0.3;
      const radius = radiusBase * (0.35 + 0.55 * Math.sin(wavePhase));
      const angle = (Math.PI * 2 * i) / orbitCount + tSec * 0.4;
      const x = Math.cos(angle) * radius;
      const y = Math.sin(angle) * radius * 0.6;
      const size = 8 + 6 * Math.sin(tSec * 1.4 + i);

      ctx.beginPath();
      ctx.fillStyle = `hsla(${(hueBase + i * 12) % 360} 80% 55% / 0.85)`;
      ctx.arc(x, y, Math.max(2, size), 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.restore();

    // Overlay radial motion blur styled strokes.
    ctx.lineWidth = 1.5;
    ctx.lineCap = 'round';
    ctx.strokeStyle = `hsla(${(hueBase + 200) % 360} 45% 85% / 0.22)`;
    const lineCount = 40;
    for (let i = 0; i < lineCount; i++) {
      const ratio = i / lineCount;
      const sweep = (Math.PI * 2 * ratio) + tSec * 0.35;
      const inner = Math.min(w, h) * 0.1;
      const outer = Math.min(w, h) * 0.48;
      const x0 = w / 2 + inner * Math.cos(sweep);
      const y0 = h / 2 + inner * Math.sin(sweep);
      const x1 = w / 2 + outer * Math.cos(sweep + Math.sin(tSec * 0.6 + ratio * 6) * 0.4);
      const y1 = h / 2 + outer * Math.sin(sweep + Math.cos(tSec * 0.7 + ratio * 4) * 0.4);

      ctx.beginPath();
      ctx.moveTo(x0, y0);
      ctx.lineTo(x1, y1);
      ctx.stroke();
    }

    // Simple HUD text showing time.
    ctx.fillStyle = 'rgba(255, 255, 255, 0.65)';
    ctx.font = `${Math.round(Math.max(16, Math.min(w, h) * 0.032))}px "Plus Jakarta Sans", system-ui, sans-serif`;
    ctx.textBaseline = 'bottom';
    ctx.textAlign = 'right';
    ctx.fillText(`t = ${tSec.toFixed(2)}s`, w - 16, h - 16);
  }

  function resize(nextWidth, nextHeight) {
    canvas.width = nextWidth;
    canvas.height = nextHeight;
    ctx.imageSmoothingEnabled = true;
  }

  renderFrame(0);

  return {
    renderFrame,
    resize
  };
}
