const prefersReducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

const sleep = (milliseconds) => new Promise((resolve) => { setTimeout(resolve, milliseconds); });

const escapeHtml = (text) => text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

const runNetwork = () => {
  const canvas = document.getElementById('network');
  const context = canvas.getContext('2d');
  const linkDistance = 150;
  const pointer = { x: -9999, y: -9999 };
  let nodes = [];
  let lastZoom = 0;
  let width = 0;
  let height = 0;
  let running = true;

  const resize = () => {
    const ratio = Math.min(window.devicePixelRatio || 1, 2);
    width = window.innerWidth;
    height = window.innerHeight;
    canvas.width = width * ratio;
    canvas.height = height * ratio;
    context.setTransform(ratio, 0, 0, ratio, 0, 0);
    const count = Math.min(150, Math.round((width * height) / 13000));
    nodes = Array.from({ length: count }, () => makeNode(Math.random() * width, Math.random() * height));
  };

  const makeNode = (x, y) => ({
    x,
    y,
    vx: (Math.random() - 0.5) * 0.22,
    vy: (Math.random() - 0.5) * 0.22,
    radius: Math.random() * 1.4 + 0.6,
    phase: Math.random() * Math.PI * 2,
    fade: 1,
    zoom: null,
  });

  const startZoom = (time) => {
    const candidates = nodes.filter((node) => !node.zoom && node.fade === 1 && node.x > 0 && node.x < width && node.y > 0 && node.y < height);
    if (candidates.length === 0) return;
    const node = candidates[Math.floor(Math.random() * candidates.length)];
    const angle = Math.random() * Math.PI * 2;
    node.zoom = { dx: Math.cos(angle), dy: Math.sin(angle), speed: 0.4, trail: [] };
    lastZoom = time;
  };

  const draw = (time) => {
    context.clearRect(0, 0, width, height);
    for (let i = 0; i < nodes.length; i += 1) {
      const a = nodes[i];
      if (a.zoom) continue;
      for (let j = i + 1; j < nodes.length; j += 1) {
        const b = nodes[j];
        if (b.zoom) continue;
        const distance = Math.hypot(a.x - b.x, a.y - b.y);
        if (distance < linkDistance) {
          const near = Math.max(0, 1 - Math.hypot((a.x + b.x) / 2 - pointer.x, (a.y + b.y) / 2 - pointer.y) / 220);
          const alpha = (1 - distance / linkDistance) * (0.11 + near * 0.3) * Math.min(a.fade, b.fade);
          context.strokeStyle = `rgba(137, 251, 229, ${alpha})`;
          context.lineWidth = 0.6;
          context.beginPath();
          context.moveTo(a.x, a.y);
          context.lineTo(b.x, b.y);
          context.stroke();
        }
      }
    }
    nodes.forEach((node) => {
      if (node.zoom && node.zoom.trail.length > 1) {
        const tail = node.zoom.trail[0];
        const gradient = context.createLinearGradient(tail.x, tail.y, node.x, node.y);
        gradient.addColorStop(0, 'rgba(137, 251, 229, 0)');
        gradient.addColorStop(1, 'rgba(200, 255, 225, 0.85)');
        context.strokeStyle = gradient;
        context.lineWidth = node.radius * 1.4;
        context.lineCap = 'round';
        context.beginPath();
        context.moveTo(tail.x, tail.y);
        context.lineTo(node.x, node.y);
        context.stroke();
      }
      const alpha = node.zoom ? 0.95 : (0.35 + 0.4 * Math.sin(time / 1100 + node.phase) ** 2) * node.fade;
      context.fillStyle = `rgba(160, 255, 200, ${alpha})`;
      context.beginPath();
      context.arc(node.x, node.y, node.radius, 0, Math.PI * 2);
      context.fill();
    });
  };

  const step = (time) => {
    if (!running) {
      return;
    }
    nodes.forEach((node, index) => {
      if (node.zoom) {
        const zoom = node.zoom;
        zoom.speed = Math.min(zoom.speed * 1.025, 3.5);
        node.x += zoom.dx * zoom.speed;
        node.y += zoom.dy * zoom.speed;
        zoom.trail.push({ x: node.x, y: node.y });
        if (zoom.trail.length > 28) zoom.trail.shift();
        if (node.x < -60 || node.x > width + 60 || node.y < -60 || node.y > height + 60) {
          nodes[index] = { ...makeNode(Math.random() * width, Math.random() * height), fade: 0 };
        }
        return;
      }
      node.fade = Math.min(1, node.fade + 0.008);
      node.x += node.vx;
      node.y += node.vy;
      if (node.x < -20) node.x = width + 20;
      if (node.x > width + 20) node.x = -20;
      if (node.y < -20) node.y = height + 20;
      if (node.y > height + 20) node.y = -20;
    });
    if (time - lastZoom > 2500 && Math.random() < 0.012) {
      startZoom(time);
    }
    draw(time);
    window.requestAnimationFrame(step);
  };

  resize();
  window.addEventListener('resize', () => {
    resize();
    if (prefersReducedMotion) draw(0);
  });
  if (prefersReducedMotion) {
    draw(0);
    return;
  }
  window.addEventListener('pointermove', (event) => {
    pointer.x = event.clientX;
    pointer.y = event.clientY;
  });
  document.addEventListener('visibilitychange', () => {
    running = !document.hidden;
    if (running) window.requestAnimationFrame(step);
  });
  window.requestAnimationFrame(step);
};

const SCENARIOS = [
  {
    who: 'operator',
    tokens: [['fn', 'executeViaAdapter'], ['', '(\n  '], ['addr', 'ERC4626_ADAPTER'], ['', ', '], ['addr', 'MORPHO_VAULT'], ['', ',\n  deposit(1,000 USDC)\n)']],
    target: 'Morpho vault',
    checks: ['pass', 'pass', 'pass', 'pass'],
    verdict: ['ok', 'Executed: 1,000 USDC deposited into the vault'],
  },
  {
    who: 'attacker with a stolen operator key',
    tokens: [['fn', 'executeViaAdapter'], ['', '(\n  '], ['addr', 'ERC4626_ADAPTER'], ['', ', '], ['evil', 'ATTACKER_VAULT'], ['', ',\n  deposit(everything)\n)']],
    target: 'Protocol',
    checks: ['pass', 'pass', 'fail', 'skip'],
    verdict: ['no', 'Reverted: AdapterNotRegistered'],
  },
  {
    who: 'attacker with a stolen operator key',
    tokens: [['fn', 'execute'], ['', '(\n  '], ['addr', 'USDC'], ['', ',\n  transfer('], ['evil', 'ATTACKER'], ['', ', everything)\n)']],
    target: 'Protocol',
    checks: ['pass', 'fail', 'skip', 'skip'],
    verdict: ['no', 'Rejected: operators can only run adapters'],
  },
  {
    who: 'owner',
    tokens: [['fn', 'withdrawAllAssetToUser'], ['', '(\n  '], ['addr', 'OWNER'], ['', ', '], ['addr', 'USDC'], ['', '\n)']],
    target: 'Owner',
    checks: ['pass', 'pass', 'skip', 'skip'],
    verdict: ['ok', 'Executed: funds sent to the owner'],
  },
];

const runHero = async () => {
  const call = document.getElementById('call-line');
  const checks = Array.from(document.querySelectorAll('#checks li'));
  const verdict = document.getElementById('verdict');
  const targetLabel = document.getElementById('target-label');
  const [inTrack, outTrack] = document.querySelectorAll('.flow-track');
  const nodes = {
    operator: document.querySelector('[data-node="operator"]'),
    wallet: document.querySelector('[data-node="wallet"]'),
    target: document.querySelector('[data-node="target"]'),
  };

  const buildHtml = (scenario, characters) => {
    let remaining = characters;
    let html = `<span class="who">// signed by ${escapeHtml(scenario.who)}</span>\n`;
    for (const [className, text] of scenario.tokens) {
      if (remaining <= 0) break;
      const part = text.slice(0, remaining);
      remaining -= part.length;
      html += className ? `<span class="${className}">${escapeHtml(part)}</span>` : escapeHtml(part);
    }
    return html;
  };

  const waiting = 'Waiting for a UserOperation…';
  const sizers = (items) => items.map((html) => `<span class="sizer" aria-hidden="true">${html}</span>`).join('');
  call.innerHTML = `${sizers(SCENARIOS.map((scenario) => buildHtml(scenario, Infinity)))}<span class="live"></span>`;
  verdict.innerHTML = `${sizers([waiting, ...SCENARIOS.map((scenario) => escapeHtml(scenario.verdict[1]))])}<span class="live"></span>`;
  const callText = call.querySelector('.live');
  const verdictText = verdict.querySelector('.live');

  const render = (scenario, characters, withCursor) => {
    const html = buildHtml(scenario, characters);
    callText.innerHTML = withCursor ? `${html}<span class="cursor"></span>` : html;
  };

  const reset = (scenario) => {
    checks.forEach((check) => check.classList.remove('pass', 'fail', 'skip'));
    verdict.className = 'verdict';
    verdictText.textContent = waiting;
    Object.values(nodes).forEach((node) => node.classList.remove('active', 'denied'));
    [inTrack, outTrack].forEach((track) => track.classList.remove('go'));
    targetLabel.textContent = scenario.target;
  };

  const settle = (scenario) => {
    scenario.checks.forEach((state, index) => checks[index].classList.add(state));
    verdict.className = `verdict ${scenario.verdict[0]}`;
    verdictText.textContent = scenario.verdict[1];
    if (scenario.verdict[0] === 'ok') {
      nodes.wallet.classList.add('active');
      nodes.target.classList.add('active');
    } else {
      nodes.wallet.classList.add('denied');
    }
  };

  if (prefersReducedMotion) {
    const scenario = SCENARIOS[1];
    reset(scenario);
    render(scenario, Infinity, false);
    settle(scenario);
    return;
  }

  for (let index = 0; ; index = (index + 1) % SCENARIOS.length) {
    const scenario = SCENARIOS[index];
    const length = scenario.tokens.reduce((total, [, text]) => total + text.length, 0);
    reset(scenario);
    nodes.operator.classList.add('active');
    for (let characters = 0; characters <= length; characters += 1) {
      render(scenario, characters, true);
      await sleep(16);
    }
    render(scenario, length, false);
    void inTrack.offsetWidth;
    inTrack.classList.add('go');
    await sleep(900);
    nodes.operator.classList.remove('active');
    for (let checkIndex = 0; checkIndex < checks.length; checkIndex += 1) {
      const state = scenario.checks[checkIndex];
      checks[checkIndex].classList.add(state);
      await sleep(state === 'skip' ? 120 : 420);
      if (state === 'fail') {
        for (let rest = checkIndex + 1; rest < checks.length; rest += 1) checks[rest].classList.add('skip');
        break;
      }
    }
    if (scenario.verdict[0] === 'ok') {
      nodes.wallet.classList.add('active');
      void outTrack.offsetWidth;
      outTrack.classList.add('go');
      await sleep(850);
      nodes.target.classList.add('active');
    } else {
      nodes.wallet.classList.add('denied');
    }
    verdict.className = `verdict ${scenario.verdict[0]}`;
    verdictText.textContent = scenario.verdict[1];
    await sleep(2600);
  }
};

const setupReveal = () => {
  const elements = document.querySelectorAll('.reveal');
  if (prefersReducedMotion || !('IntersectionObserver' in window)) {
    elements.forEach((element) => element.classList.add('visible'));
    return;
  }
  const observer = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (entry.isIntersecting) {
        entry.target.classList.add('visible');
        observer.unobserve(entry.target);
      }
    });
  }, { threshold: 0.12, rootMargin: '0px 0px -40px 0px' });
  elements.forEach((element) => {
    const siblings = Array.from(element.parentElement.children).filter((child) => child.classList.contains('reveal'));
    element.style.transitionDelay = `${(siblings.indexOf(element) % 4) * 80}ms`;
    observer.observe(element);
  });
};

const STATS_URL = 'https://api.yieldseeker.xyz/v1/platform-stats-detail';

const STAT_FORMATS = {
  agents: (value) => Math.round(value).toLocaleString('en-US'),
  volume: (value) => `$${Math.round(value / 1e6).toLocaleString('en-US')}M`,
};

const setupLiveStats = async () => {
  let values;
  try {
    const response = await fetch(STATS_URL, { signal: AbortSignal.timeout(6000) });
    if (!response.ok) return;
    const { platformStatsDetail } = await response.json();
    values = { agents: platformStatsDetail.totalAgentCountEver, volume: platformStatsDetail.totalTransactionVolumeUsd };
  } catch {
    return;
  }
  if (!Number.isFinite(values.agents) || !Number.isFinite(values.volume)) return;
  const animate = (element, key) => {
    const start = performance.now();
    const tick = (now) => {
      const progress = Math.min(1, (now - start) / 1600);
      element.textContent = STAT_FORMATS[key](values[key] * (1 - (1 - progress) ** 3));
      if (progress < 1) window.requestAnimationFrame(tick);
    };
    window.requestAnimationFrame(tick);
  };
  const observer = 'IntersectionObserver' in window && !prefersReducedMotion ? new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (entry.isIntersecting) {
        animate(entry.target, entry.target.dataset.stat);
        observer.unobserve(entry.target);
      }
    });
  }) : null;
  document.querySelectorAll('[data-stat]').forEach((element) => {
    const key = element.dataset.stat;
    if (observer && 'countUp' in element.dataset) {
      observer.observe(element);
    } else {
      element.textContent = STAT_FORMATS[key](values[key]);
    }
  });
};

const setupCardGlow = () => {
  document.querySelectorAll('.glow').forEach((card) => {
    card.addEventListener('pointermove', (event) => {
      const rect = card.getBoundingClientRect();
      card.style.setProperty('--mx', `${event.clientX - rect.left}px`);
      card.style.setProperty('--my', `${event.clientY - rect.top}px`);
    });
  });
};

const setupCopy = () => {
  document.querySelectorAll('.copy').forEach((button) => {
    button.addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(document.getElementById(button.dataset.copy).textContent);
        button.textContent = 'Copied';
        button.classList.add('copied');
      } catch {
        button.textContent = 'Select it';
      }
      setTimeout(() => {
        button.textContent = 'Copy';
        button.classList.remove('copied');
      }, 1600);
    });
  });
};

const setupMenu = () => {
  const toggle = document.querySelector('.menu-toggle');
  const links = document.getElementById('nav-links');
  const setOpen = (open) => {
    toggle.setAttribute('aria-expanded', String(open));
    toggle.setAttribute('aria-label', open ? 'Close menu' : 'Open menu');
    links.classList.toggle('open', open);
  };
  toggle.addEventListener('click', () => setOpen(toggle.getAttribute('aria-expanded') !== 'true'));
  links.querySelectorAll('a').forEach((link) => link.addEventListener('click', () => setOpen(false)));
};

runNetwork();
setupReveal();
setupLiveStats();
setupCardGlow();
setupCopy();
setupMenu();
runHero();
