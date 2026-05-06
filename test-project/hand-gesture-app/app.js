const video = document.getElementById("camera");
const canvas = document.getElementById("overlay");
const ctx = canvas.getContext("2d");
const statusEl = document.getElementById("status");
const intensitySlider = document.getElementById("intensity");
const flipBtn = document.getElementById("flip");

let mirror = true;

flipBtn.addEventListener("click", () => {
  mirror = !mirror;
  flipBtn.textContent = `Flip view: ${mirror ? "ON" : "OFF"}`;
});

function resizeCanvas() {
  const rect = video.getBoundingClientRect();
  const ratio = window.devicePixelRatio || 1;
  canvas.width = rect.width * ratio;
  canvas.height = rect.height * ratio;
  ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
}

window.addEventListener("resize", resizeCanvas);

function lerp(a, b, t) {
  return a + (b - a) * t;
}

function drawSparkle(x, y, size = 10) {
  const spikes = 4;
  const outer = size;
  const inner = size * 0.35;

  ctx.save();
  ctx.translate(x, y);
  ctx.beginPath();

  for (let i = 0; i < spikes * 2; i += 1) {
    const radius = i % 2 === 0 ? outer : inner;
    const angle = (Math.PI * i) / spikes;
    const px = Math.cos(angle) * radius;
    const py = Math.sin(angle) * radius;

    if (i === 0) {
      ctx.moveTo(px, py);
    } else {
      ctx.lineTo(px, py);
    }
  }

  ctx.closePath();
  ctx.fillStyle = "rgba(255, 245, 160, 0.85)";
  ctx.shadowColor = "rgba(64, 227, 255, 0.8)";
  ctx.shadowBlur = 10;
  ctx.fill();
  ctx.restore();
}

function drawGestureEffects(handLandmarks) {
  const intensity = Number(intensitySlider.value);

  drawConnectors(ctx, handLandmarks, HAND_CONNECTIONS, {
    color: "#40e3ff",
    lineWidth: 3,
  });

  drawLandmarks(ctx, handLandmarks, {
    color: "#ffd166",
    fillColor: "#ffd166",
    lineWidth: 1,
    radius: 4,
  });

  HAND_CONNECTIONS.forEach(([a, b]) => {
    const p1 = handLandmarks[a];
    const p2 = handLandmarks[b];
    const sparkleCount = Math.max(1, Math.floor(intensity / 2));

    for (let i = 0; i < sparkleCount; i += 1) {
      const t = Math.random();
      const x = lerp(p1.x, p2.x, t) * canvas.clientWidth;
      const y = lerp(p1.y, p2.y, t) * canvas.clientHeight;
      drawSparkle(x, y, Math.random() * 5 + 3);
    }
  });

  handLandmarks.forEach((point) => {
    if (Math.random() < intensity / 15) {
      drawSparkle(
        point.x * canvas.clientWidth,
        point.y * canvas.clientHeight,
        Math.random() * 9 + 4,
      );
    }
  });
}

function onResults(results) {
  resizeCanvas();
  ctx.clearRect(0, 0, canvas.clientWidth, canvas.clientHeight);

  ctx.save();
  if (mirror) {
    ctx.translate(canvas.clientWidth, 0);
    ctx.scale(-1, 1);
  }

  if (results.multiHandLandmarks?.length) {
    results.multiHandLandmarks.forEach(drawGestureEffects);
    statusEl.textContent = `Tracking ${results.multiHandLandmarks.length} hand(s)`;
  } else {
    statusEl.textContent = "Show your hand to the camera";
  }

  ctx.restore();
}

const hands = new Hands({
  locateFile: (file) =>
    `https://cdn.jsdelivr.net/npm/@mediapipe/hands/${file}`,
});

hands.setOptions({
  maxNumHands: 2,
  modelComplexity: 1,
  minDetectionConfidence: 0.7,
  minTrackingConfidence: 0.6,
});

hands.onResults(onResults);

async function start() {
  try {
    const stream = await navigator.mediaDevices.getUserMedia({
      video: { width: { ideal: 1280 }, height: { ideal: 720 } },
      audio: false,
    });

    video.srcObject = stream;

    await video.play();
    resizeCanvas();

    const camera = new Camera(video, {
      onFrame: async () => {
        await hands.send({ image: video });
      },
      width: 1280,
      height: 720,
    });

    camera.start();
    statusEl.textContent = "Camera ready. Move your hand!";
  } catch (error) {
    console.error(error);
    statusEl.textContent =
      "Could not access camera. Please allow camera permissions and refresh.";
  }
}

start();
