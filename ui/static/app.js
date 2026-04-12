/**
 * Blueprint UI — app.js
 *
 * Handles:
 *  - Tab navigation (Deploy / Environments / History)
 *  - Loading environment list from /environments
 *  - Deploy form → POST /jobs
 *  - Per-job SSE log pane with Last-Event-ID replay
 *  - ANSI escape code → HTML rendering
 *  - Phase detection from log output
 *  - Active-job status bar
 *  - History view (completed jobs from GET /jobs)
 */

'use strict';

// ── ANSI colour map ───────────────────────────────────────────────────────────
const ANSI_FG = {
  30: '#6e7681', 31: '#f47067', 32: '#57ab5a', 33: '#c69026',
  34: '#539bf5', 35: '#b083f0', 36: '#39c5cf', 37: '#cdd9e5',
  90: '#636e7b', 91: '#ff938a', 92: '#6bc46d', 93: '#daaa3f',
  94: '#6cb6ff', 95: '#dcbdfb', 96: '#56d4dd', 97: '#cdd9e5',
};

const JOB_SOURCE_LABELS = {
  ui: 'Web UI',
  terminal: 'Terminal',
};

/**
 * Convert a raw log line (potentially containing ANSI escape codes) to safe HTML.
 * Handles SGR colour/bold codes; strips cursor-movement codes.
 */
function ansiToHtml(raw) {
  // Strip cursor-movement / erase sequences we can't render meaningfully
  raw = raw.replace(/\x1b\[[0-9;]*[ABCDEFGHJKSTfu]/g, '');
  // Also strip OSC sequences (window title etc.)
  raw = raw.replace(/\x1b\][^\x07]*\x07/g, '');

  // HTML-escape the text portions
  const escHtml = (s) =>
    s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

  // Split on SGR codes: \x1b[...m
  const parts = raw.split(/(\x1b\[[0-9;]*m)/);
  const out = [];
  let openSpan = false;

  for (const part of parts) {
    const m = part.match(/^\x1b\[([0-9;]*)m$/);
    if (!m) {
      out.push(escHtml(part));
      continue;
    }
    // Close any open span first
    if (openSpan) { out.push('</span>'); openSpan = false; }

    const code = m[1];
    if (code === '' || code === '0') continue; // reset, nothing to open

    const nums = code.split(';').map(Number);
    const styles = [];
    for (const n of nums) {
      if (n === 1)                          styles.push('font-weight:bold');
      else if (n === 3)                     styles.push('font-style:italic');
      else if (n === 4)                     styles.push('text-decoration:underline');
      else if (ANSI_FG[n])                  styles.push(`color:${ANSI_FG[n]}`);
      else if (n >= 40 && n <= 47 && ANSI_FG[n - 10])
                                            styles.push(`background:${ANSI_FG[n - 10]}`);
    }
    if (styles.length) {
      out.push(`<span style="${styles.join(';')}">`);
      openSpan = true;
    }
  }
  if (openSpan) out.push('</span>');
  return out.join('');
}

// ── Phase detection ───────────────────────────────────────────────────────────

const PHASE_RULES = [
  [/Initializing the backend/,                 'Initializing Terraform'],
  [/Initializing provider plugins/,            'Initializing Terraform'],
  [/Terraform has been successfully initialized/, 'Terraform ready'],
  [/Refreshing state/,                         'Refreshing state'],
  [/Terraform will perform the following/,     'Planning'],
  [/Plan:/,                                    'Planning'],
  [/Apply complete!/,                          'Apply complete ✓'],
  [/Destroy complete!/,                        'Destroy complete'],
  [/No changes\. Your infrastructure matches/, 'No changes'],
  [/PLAY \[/,                                  'Running Ansible'],
  [/TASK \[/,                                  'Ansible tasks'],
  [/PLAY RECAP/,                               'Ansible recap'],
];

function detectPhase(line) {
  // Strip ANSI before matching
  const plain = line.replace(/\x1b\[[0-9;]*[A-Za-z]/g, '');
  for (const [re, label] of PHASE_RULES) {
    if (re.test(plain)) return label;
  }
  return null;
}

// ── Utilities ─────────────────────────────────────────────────────────────────

function fmtTime(isoStr) {
  if (!isoStr) return '—';
  try {
    return new Date(isoStr).toLocaleString(undefined, {
      month: 'short', day: 'numeric',
      hour: '2-digit', minute: '2-digit', second: '2-digit',
    });
  } catch { return isoStr; }
}

function fmtDuration(start, end) {
  if (!start || !end) return '';
  const secs = Math.round((new Date(end) - new Date(start)) / 1000);
  if (secs < 60) return `${secs}s`;
  const m = Math.floor(secs / 60), s = secs % 60;
  return `${m}m ${s}s`;
}

function fmtJobSource(source) {
  return JOB_SOURCE_LABELS[source] || 'Unknown';
}

function jobPhaseLabel(job) {
  if (job.status === 'done') return 'Complete ✓';
  if (job.status === 'failed') return 'Failed ✗';
  if (job.status === 'interrupted') return 'Interrupted';
  return 'starting…';
}

async function apiFetch(path, opts = {}) {
  const res = await fetch(path, opts);
  if (!res.ok) {
    const body = await res.text().catch(() => '');
    throw new Error(`${res.status} ${body}`);
  }
  return res.json();
}

// ── Job store (in-memory, synced with server) ─────────────────────────────────

const jobStore = new Map(); // job_id → job meta
const activeStreams = new Map(); // job_id → EventSource
const DESTROY_PROMPT_SCOPES = new Set(['full', 'gateway', 'control']);
const jobProgressState = new Map();
const timingProfileStore = new Map();
const timingProfileLoads = new Map();
const PROGRESS_DIAGNOSTIC_INTERVAL_MS = 10000;

function resetJobUiState(jobId) {
  jobProgressState.delete(jobId);
  jobSectionState.delete(jobId);
}

function getProgressState(jobId) {
  if (!jobProgressState.has(jobId)) {
    jobProgressState.set(jobId, {
      unitsTotal: 0,
      currentStepId: null,
      currentPlay: '',
      steps: new Map(),
      hasPlan: false,
      timingProfile: null,
      lastDiagnosticAtMs: 0,
      lastDiagnosticPct: null,
      lastDiagnosticLabel: '',
      lastDiagnosticEta: '',
      lastDiagnosticMode: '',
    });
  }
  return jobProgressState.get(jobId);
}

function fetchTimingProfile(env, options = {}) {
  const { forceRefresh = false } = options;
  if (!env) return Promise.resolve(null);
  if (!forceRefresh && timingProfileStore.has(env)) return Promise.resolve(timingProfileStore.get(env));
  if (timingProfileLoads.has(env)) return timingProfileLoads.get(env);

  const load = apiFetch(`/timing/${encodeURIComponent(env)}`)
    .then(profile => {
      timingProfileStore.set(env, profile);
      timingProfileLoads.delete(env);
      return profile;
    })
    .catch(() => {
      timingProfileLoads.delete(env);
      return null;
    });

  timingProfileLoads.set(env, load);
  return load;
}

function loadTimingProfileForJob(jobId) {
  const job = jobStore.get(jobId);
  if (!job?.env) return;
  if (timingProfileStore.has(job.env)) {
    const progress = getProgressState(jobId);
    progress.timingProfile = timingProfileStore.get(job.env);
    renderProgress(jobId);
  }
  fetchTimingProfile(job.env, { forceRefresh: job.status === 'running' }).then(profile => {
    const progress = getProgressState(jobId);
    progress.timingProfile = profile;
    renderProgress(jobId);
  });
}

function formatEta(seconds) {
  if (!Number.isFinite(seconds) || seconds <= 0) return 'ETA --';
  const rounded = Math.round(seconds);
  if (rounded < 60) return `ETA ${rounded}s`;
  const minutes = Math.floor(rounded / 60);
  const secs = rounded % 60;
  if (minutes < 60) return `ETA ${minutes}m ${secs}s`;
  const hours = Math.floor(minutes / 60);
  const mins = minutes % 60;
  return `ETA ${hours}h ${mins}m`;
}

function parseProgressMarker(line) {
  const plain = line.replace(/\x1b\[[0-9;]*[A-Za-z]/g, '');
  if (!plain.startsWith('[bp-progress] ')) return null;
  try {
    return JSON.parse(plain.slice(14));
  } catch {
    return null;
  }
}

function ensureProgressStep(progress, stepId, defaults = {}) {
  if (!progress.steps.has(stepId)) {
    progress.steps.set(stepId, {
      id: stepId,
      label: defaults.label || stepId,
      kind: defaults.kind || 'script',
      weight: defaults.weight || 1,
      completed: false,
      currentUnits: 0,
      startedAtMs: null,
      completedAtMs: null,
      actualElapsedMs: null,
    });
  }
  return progress.steps.get(stepId);
}

function getScopeTimingProfile(progress, job) {
  const scopes = progress.timingProfile?.scopes;
  if (!scopes || !job?.scope) return null;
  return scopes[job.scope] || null;
}

function estimateStepTotalMs(scopeTiming, step) {
  if (!scopeTiming || !step) return null;

  const profileStep = scopeTiming.steps?.[step.id] || null;
  if (profileStep) {
    if (step.kind === 'ansible') {
      const totalUnits = Math.max(step.weight || 0, step.currentUnits || 0, Math.round(profileStep.avg_units || 0), 1);
      if (Number.isFinite(profileStep.avg_unit_ms) && profileStep.avg_unit_ms > 0) {
        return profileStep.avg_unit_ms * totalUnits;
      }
    }
    if (Number.isFinite(profileStep.avg_ms) && profileStep.avg_ms > 0) {
      return profileStep.avg_ms;
    }
  }

  if (step.kind === 'ansible') {
    const avgUnitMs = scopeTiming.summary?.avg_ansible_unit_ms;
    const totalUnits = Math.max(step.weight || 0, step.currentUnits || 0, 1);
    if (Number.isFinite(avgUnitMs) && avgUnitMs > 0) {
      return avgUnitMs * totalUnits;
    }
    return null;
  }

  const avgScriptMsPerWeight = scopeTiming.summary?.avg_script_ms_per_weight;
  if (Number.isFinite(avgScriptMsPerWeight) && avgScriptMsPerWeight > 0) {
    return avgScriptMsPerWeight * Math.max(step.weight || 1, 1);
  }
  return null;
}

function getRunningElapsedMs(step) {
  if (!step?.startedAtMs) return 0;
  return Math.max(0, Date.now() - step.startedAtMs);
}

function getRunningStepTotalMs(step, estimatedMs) {
  if (!Number.isFinite(estimatedMs) || estimatedMs <= 0) return null;

  const elapsedMs = getRunningElapsedMs(step);
  if (step.kind === 'ansible') {
    const seenUnits = Math.max(step.currentUnits || 0, 0);
    const totalUnits = Math.max(step.weight || 0, step.currentUnits || 0, 1);
    if (seenUnits > 0 && elapsedMs > 0) {
      return Math.max(estimatedMs, (elapsedMs / seenUnits) * totalUnits);
    }
  }

  return Math.max(estimatedMs, elapsedMs * (step.kind === 'ansible' ? 1.05 : 1.1));
}

function durationProgressSnapshot(progress, job) {
  const scopeTiming = getScopeTimingProfile(progress, job);
  if (!scopeTiming) return null;

  let totalMs = 0;
  let doneMs = 0;
  let estimatedCount = 0;

  for (const step of progress.steps.values()) {
    const estimatedMs = estimateStepTotalMs(scopeTiming, step);
    if (!Number.isFinite(estimatedMs) || estimatedMs <= 0) return null;

    estimatedCount += 1;
    if (step.completed) {
      const actualMs = Number.isFinite(step.actualElapsedMs) && step.actualElapsedMs > 0
        ? step.actualElapsedMs
        : estimatedMs;
      totalMs += actualMs;
      doneMs += actualMs;
      continue;
    }

    if (progress.currentStepId === step.id) {
      const runningTotalMs = getRunningStepTotalMs(step, estimatedMs);
      if (!Number.isFinite(runningTotalMs) || runningTotalMs <= 0) return null;
      const elapsedMs = getRunningElapsedMs(step);
      totalMs += runningTotalMs;
      doneMs += Math.min(elapsedMs, runningTotalMs * 0.99);
      continue;
    }

    totalMs += estimatedMs;
  }

  if (estimatedCount !== progress.steps.size || totalMs <= 0) return null;
  const remainingMs = Math.max(0, totalMs - doneMs);
  return {
    pct: Math.max(0, Math.min(99, Math.round((doneMs / totalMs) * 100))),
    etaSeconds: Math.max(0, Math.round(remainingMs / 1000)),
  };
}

function progressSnapshot(jobId) {
  const progress = getProgressState(jobId);
  const job = jobStore.get(jobId);
  let total = 0;
  let done = 0;

  for (const step of progress.steps.values()) {
    total += step.weight;
    done += step.completed ? step.weight : Math.min(step.weight, step.currentUnits || 0);
  }

  const effectiveTotal = progress.unitsTotal || total;
  const effectiveDone = Math.min(done, effectiveTotal || done);
  const status = job ? job.status : 'running';
  const canEstimateProgress = progress.hasPlan && effectiveTotal > 0;
  const durationEstimate = job && status === 'running' ? durationProgressSnapshot(progress, job) : null;
  const pct = status === 'done'
    ? 100
    : durationEstimate
      ? durationEstimate.pct
      : canEstimateProgress
        ? Math.max(0, Math.min(99, Math.round((effectiveDone / effectiveTotal) * 100)))
        : 0;

  let etaText = 'ETA --';
  let etaSeconds = null;
  let estimateMode = 'none';
  if (durationEstimate) {
    etaSeconds = durationEstimate.etaSeconds;
    etaText = formatEta(etaSeconds);
    estimateMode = 'timing-profile';
  } else if (job && status === 'running' && canEstimateProgress && effectiveDone > 0) {
    const elapsedSeconds = Math.max(1, (Date.now() - new Date(job.start_time).getTime()) / 1000);
    const rate = effectiveDone / elapsedSeconds;
    if (rate > 0) {
      etaSeconds = Math.max(0, Math.round((effectiveTotal - effectiveDone) / rate));
      etaText = formatEta(etaSeconds);
      estimateMode = 'unit-rate';
    }
  }

  const currentStep = progress.steps.get(progress.currentStepId);
  const label = currentStep
    ? (progress.hasPlan ? currentStep.label : 'Preparing deploy plan')
    : status === 'done'
      ? 'Complete'
      : status === 'failed'
        ? 'Failed'
        : status === 'interrupted'
          ? 'Interrupted'
          : (progress.hasPlan ? 'Starting deploy' : 'Preparing deploy plan');

  return {
    pct,
    label: progress.currentPlay && currentStep && currentStep.kind === 'ansible'
      ? `${currentStep.label} - ${progress.currentPlay}`
      : label,
    etaText: status === 'running' ? etaText : fmtDuration(job?.start_time, job?.end_time) || 'Done',
    etaSeconds,
    hasPlan: progress.hasPlan,
    estimateMode,
    unitsDone: effectiveDone,
    unitsTotal: effectiveTotal,
  };
}

function renderProgress(jobId) {
  const snap = progressSnapshot(jobId);
  const bar = document.getElementById(`progressbar-${jobId}`);
  const pct = document.getElementById(`progresspct-${jobId}`);
  const label = document.getElementById(`progresslabel-${jobId}`);
  const eta = document.getElementById(`progresseta-${jobId}`);
  const wrap = document.getElementById(`progress-${jobId}`);
  if (bar) bar.style.width = `${snap.pct}%`;
  if (pct) pct.textContent = `${snap.pct}%`;
  if (label) label.textContent = snap.label;
  if (eta) eta.textContent = snap.etaText;
  if (wrap) wrap.classList.toggle('is-idle', !snap.hasPlan && snap.pct === 0);
  refreshStatusBar();
}

function applyProgressEvent(jobId, payload) {
  const progress = getProgressState(jobId);

  if (payload.type === 'plan') {
    const previousSteps = progress.steps;
    const previousCurrentStepId = progress.currentStepId;
    const previousPlay = progress.currentPlay;
    progress.unitsTotal = payload.units_total || 0;
    progress.steps = new Map();
    for (const step of payload.steps || []) {
      const previous = previousSteps.get(step.id);
      const weight = Math.max(1, step.weight || 1);
      const completed = !!previous?.completed;
      progress.steps.set(step.id, {
        id: step.id,
        label: step.label,
        kind: step.kind,
        weight,
        completed,
        currentUnits: completed ? weight : Math.min(weight, previous?.currentUnits || 0),
        startedAtMs: previous?.startedAtMs || null,
        completedAtMs: previous?.completedAtMs || null,
        actualElapsedMs: previous?.actualElapsedMs || null,
      });
    }
    const currentStep = progress.steps.get(previousCurrentStepId);
    progress.currentStepId = currentStep && !currentStep.completed ? previousCurrentStepId : null;
    progress.currentPlay = progress.currentStepId ? previousPlay : '';
    progress.hasPlan = true;
    renderProgress(jobId);
    return;
  }

  if (payload.type === 'step-start') {
    const step = ensureProgressStep(progress, payload.step_id);
    step.startedAtMs = payload.ts_ms || Date.now();
    step.completedAtMs = null;
    step.actualElapsedMs = null;
    progress.currentStepId = payload.step_id;
    progress.currentPlay = '';
    renderProgress(jobId);
    return;
  }

  if (payload.type === 'step-done') {
    const step = ensureProgressStep(progress, payload.step_id);
    step.completed = true;
    step.currentUnits = step.weight;
    step.completedAtMs = payload.ts_ms || Date.now();
    if (Number.isFinite(payload.step_elapsed_ms)) {
      step.actualElapsedMs = payload.step_elapsed_ms;
    } else if (step.startedAtMs) {
      step.actualElapsedMs = Math.max(0, step.completedAtMs - step.startedAtMs);
    }
    if (progress.currentStepId === payload.step_id) progress.currentStepId = null;
    if (step.kind === 'ansible') progress.currentPlay = '';
    renderProgress(jobId);
    return;
  }

  if (payload.type === 'ansible-play') {
    const step = ensureProgressStep(progress, payload.step_id, { kind: 'ansible' });
    if (!step.startedAtMs) step.startedAtMs = payload.ts_ms || Date.now();
    progress.currentStepId = payload.step_id;
    progress.currentPlay = payload.play || '';
    renderProgress(jobId);
    return;
  }

  if (payload.type === 'ansible-task') {
    const step = ensureProgressStep(progress, payload.step_id, { kind: 'ansible' });
    if (!step.startedAtMs) step.startedAtMs = payload.ts_ms || Date.now();
    progress.currentStepId = payload.step_id;
    progress.currentPlay = payload.play || progress.currentPlay || '';
    step.currentUnits = (step.currentUnits || 0) + 1;
    if (step.currentUnits > step.weight) {
      const delta = step.currentUnits - step.weight;
      step.weight = step.currentUnits;
      progress.unitsTotal += delta;
    }
    renderProgress(jobId);
  }
}

function shouldApplyProgressEvent(jobId) {
  const job = jobStore.get(jobId);
  return !job || job.status !== 'done';
}

function isUiProgressDiagnosticLine(line) {
  const plain = line.replace(/\x1b\[[0-9;]*[A-Za-z]/g, '');
  return plain.startsWith('[bp-progress-ui] ');
}

function shouldLogProgressDiagnostic(progress, payload, snap, nowMs) {
  if (!payload || !payload.type) return false;
  if (payload.type !== 'ansible-task') return true;
  if (progress.lastDiagnosticPct !== snap.pct) return true;
  if (progress.lastDiagnosticLabel !== snap.label) return true;
  if (progress.lastDiagnosticEta !== snap.etaText) return true;
  if (progress.lastDiagnosticMode !== snap.estimateMode) return true;
  return (nowMs - progress.lastDiagnosticAtMs) >= PROGRESS_DIAGNOSTIC_INTERVAL_MS;
}

function maybeLogProgressDiagnostic(jobId, payload) {
  const job = jobStore.get(jobId);
  if (!job || job.status !== 'running') return;

  const progress = getProgressState(jobId);
  const nowMs = Date.now();
  const snap = progressSnapshot(jobId);
  if (!shouldLogProgressDiagnostic(progress, payload, snap, nowMs)) return;

  const elapsedMs = job.start_time ? Math.max(0, nowMs - new Date(job.start_time).getTime()) : null;
  progress.lastDiagnosticAtMs = nowMs;
  progress.lastDiagnosticPct = snap.pct;
  progress.lastDiagnosticLabel = snap.label;
  progress.lastDiagnosticEta = snap.etaText;
  progress.lastDiagnosticMode = snap.estimateMode;

  fetch(`/jobs/${jobId}/progress-log`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      event_type: payload.type,
      event_ts_ms: payload.ts_ms || nowMs,
      pct: snap.pct,
      label: snap.label,
      eta_text: snap.etaText,
      eta_seconds: snap.etaSeconds,
      has_plan: snap.hasPlan,
      units_done: snap.unitsDone,
      units_total: snap.unitsTotal,
      estimate_mode: snap.estimateMode,
      elapsed_ms: elapsedMs,
      current_step_id: progress.currentStepId,
      current_play: progress.currentPlay,
      event_payload: payload,
    }),
  }).catch(() => {});
}

// ── Section state ─────────────────────────────────────────────────────────────

const jobSectionState = new Map();

function getSectionState(jobId) {
  if (!jobSectionState.has(jobId)) {
    jobSectionState.set(jobId, {
      currentId: null,
      lastSectionId: null,
      lastSummaryId: null,
      taskCounts: new Map(),
      sectionMeta: new Map(),
      env: null,
    });
  }
  return jobSectionState.get(jobId);
}

// localStorage key for persisting task totals across runs.
function _taskKey(env, signature) {
  return `bp-tasks:${env}:${signature}`;
}

function _isPlaySignature(signature) {
  return signature && signature.startsWith('play:');
}

// Retrieve the known task total for a section from localStorage (null if unknown).
function _knownTotal(env, signature) {
  if (!env || !_isPlaySignature(signature)) return null;
  const v = localStorage.getItem(_taskKey(env, signature));
  return v !== null ? parseInt(v, 10) : null;
}

// Persist the final task count after a section completes.
function _saveTotal(env, signature, count) {
  if (!env || !_isPlaySignature(signature) || count < 1) return;
  localStorage.setItem(_taskKey(env, signature), String(count));
}

function _renderCount(kind, seen, total) {
  if (kind === 'play') {
    if (total !== null && total > 0) return `${seen} / ${total} tasks`;
    return seen > 0 ? `${seen} tasks` : '';
  }
  // Non-ansible sections: plain line count
  return seen > 0 ? seen + (seen === 1 ? ' line' : ' lines') : '';
}

function escapeHtml(str) {
  return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

// Scroll an element into view within its log-wrap scroll container.
function scrollWrapTo(jobId, target, { align = 'nearest' } = {}) {
  const wrap = document.getElementById(`log-${jobId}`);
  if (!wrap || !target) return;
  const wRect = wrap.getBoundingClientRect();
  const tRect = target.getBoundingClientRect();
  const relTop = tRect.top - wRect.top + wrap.scrollTop;
  if (align === 'start') {
    wrap.scrollTo({ top: relTop, behavior: 'smooth' });
  } else {
    const inView = tRect.top >= wRect.top && tRect.bottom <= wRect.bottom;
    if (!inView) wrap.scrollTo({ top: relTop, behavior: 'smooth' });
  }
}

function getOrCreateSection(jobId, sectionId, title, signature, kind) {
  const sectionsEl = document.getElementById(`sections-${jobId}`);
  if (!sectionsEl) return null;
  let el = document.getElementById(`sec-${jobId}-${sectionId}`);
  if (!el) {
    const state = getSectionState(jobId);
    state.sectionMeta.set(sectionId, { signature, kind, title });
    if (kind === 'summary') state.lastSummaryId = sectionId;
    // Pre-populate count display when we have a known total from a previous run.
    const total = _knownTotal(state.env, signature);
    const initialCount = kind === 'play' && total ? `0 / ${total} tasks` : '';
    el = document.createElement('div');
    el.className = 'log-section';
    el.id = `sec-${jobId}-${sectionId}`;
    // New sections start collapsed — they open when they become the active one
    el.innerHTML = `
      <div class="section-hdr" onclick="toggleSection('${jobId}','${sectionId}')">
        <span class="section-dot active" id="secdot-${jobId}-${sectionId}"></span>
        <span class="section-name">${escapeHtml(title)}</span>
        <span class="section-count" id="seccount-${jobId}-${sectionId}">${initialCount}</span>
        <span class="section-chv" id="secchv-${jobId}-${sectionId}">&#9654;</span>
      </div>
      <div class="section-body" id="secbody-${jobId}-${sectionId}">
        <pre id="secpre-${jobId}-${sectionId}"></pre>
      </div>`;
    sectionsEl.appendChild(el);
  }
  // Open this section and scroll its header into view inside the log-wrap
  const body = document.getElementById(`secbody-${jobId}-${sectionId}`);
  const chv  = document.getElementById(`secchv-${jobId}-${sectionId}`);
  if (body) body.classList.add('open');
  if (chv)  chv.classList.add('open');
  const hdr = el.querySelector('.section-hdr');
  scrollWrapTo(jobId, hdr, { align: 'nearest' });
  return el;
}

function markSectionDone(jobId, sectionId, failed) {
  const dot  = document.getElementById(`secdot-${jobId}-${sectionId}`);
  const body = document.getElementById(`secbody-${jobId}-${sectionId}`);
  const chv  = document.getElementById(`secchv-${jobId}-${sectionId}`);
  if (dot) dot.className = 'section-dot ' + (failed ? 'failed' : 'done');
  // Collapse the finished section
  if (body) body.classList.remove('open');
  if (chv)  chv.classList.remove('open');
  // Persist ansible task totals so next run can show "0 / N tasks" from the start.
  const state = getSectionState(jobId);
  const meta = state.sectionMeta.get(sectionId);
  if (meta && meta.kind === 'play') {
    const count = state.taskCounts.get(sectionId) || 0;
    _saveTotal(state.env, meta.signature, count);
  }
}

function collapseAllSections(jobId, { keepOpen } = {}) {
  const sectionsEl = document.getElementById(`sections-${jobId}`);
  if (!sectionsEl) return;
  sectionsEl.querySelectorAll('.log-section').forEach(sec => {
    const sid = sec.id.replace(`sec-${jobId}-`, '');
    if (keepOpen && keepOpen.includes(sid)) return;
    const body = sec.querySelector('.section-body');
    const chv  = sec.querySelector('.section-chv');
    if (body) body.classList.remove('open');
    if (chv)  chv.classList.remove('open');
  });
  // Scroll to the kept-open section if any, inside the log-wrap
  if (keepOpen && keepOpen.length) {
    const target = document.getElementById(`sec-${jobId}-${keepOpen[0]}`);
    scrollWrapTo(jobId, target, { align: 'start' });
  }
}

function toggleSection(jobId, sectionId) {
  const body = document.getElementById(`secbody-${jobId}-${sectionId}`);
  const chv  = document.getElementById(`secchv-${jobId}-${sectionId}`);
  if (!body) return;
  const open = body.classList.toggle('open');
  if (chv) chv.classList.toggle('open', open);
}
window.toggleSection = toggleSection;

function updateJobStore(job) {
  jobStore.set(job.job_id, job);
}

// ── Status bar ────────────────────────────────────────────────────────────────

function refreshStatusBar() {
  const bar = document.getElementById('status-bar');
  const active = [...jobStore.values()].filter(j => j.status === 'running');
  if (active.length === 0) {
    bar.classList.add('hidden');
    bar.innerHTML = '';
    return;
  }
  bar.classList.remove('hidden');
  bar.innerHTML = '<span style="font-size:12px;color:var(--text-muted);flex-shrink:0">Active:</span> ' +
    active.map(j => {
      const dot = `<span class="status-dot running"></span>`;
      const snap = progressSnapshot(j.job_id);
      const eta = snap.etaText !== 'ETA --' ? ` • ${snap.etaText}` : '';
      return `<span class="status-pill">${dot}<span>${j.env} / ${j.scope} • ${snap.pct}%${eta}</span></span>`;
    }).join(' ');
}

// ── Job pane construction ─────────────────────────────────────────────────────

function createJobPane(job) {
  const pane = document.createElement('div');
  pane.className = 'job-pane';
  pane.id = `pane-${job.job_id}`;

  pane.innerHTML = `
    <div class="job-header" id="hdr-${job.job_id}">
      <span class="status-dot ${job.status}" id="dot-${job.job_id}"></span>
      <span class="job-title">
        <span class="job-id">${job.job_id}</span>
        <span class="job-title-suffix" id="jobtitle-${job.job_id}"></span>
      </span>
      <span class="job-meta">
        <span>${job.scope}</span>
        <span>${job.env}</span>
        <span>${fmtJobSource(job.source)}</span>
        <span id="started-${job.job_id}">${fmtTime(job.start_time)}</span>
      </span>
      <span class="phase-badge" id="phase-${job.job_id}">${jobPhaseLabel(job)}</span>
      <span class="chevron open" id="chv-${job.job_id}">&#9654;</span>
    </div>
    <div class="job-body open" id="body-${job.job_id}">
      <div class="log-wrap" id="log-${job.job_id}">
        <div class="job-progress" id="progress-${job.job_id}">
          <div class="job-progress-meta">
            <span class="job-progress-label" id="progresslabel-${job.job_id}">Waiting for progress data</span>
            <span class="job-progress-eta" id="progresseta-${job.job_id}">ETA --</span>
            <span class="job-progress-pct" id="progresspct-${job.job_id}">0%</span>
          </div>
          <div class="job-progress-track"><span class="job-progress-fill" id="progressbar-${job.job_id}"></span></div>
        </div>
        <div class="log-sections" id="sections-${job.job_id}"></div>
      </div>
      <div id="banner-${job.job_id}"></div>
      <div class="job-actions">
        <button class="btn-sm" id="cancel-${job.job_id}" onclick="cancelJob('${job.job_id}')"${job.status !== 'running' ? ' style="display:none"' : ''}>&#9632; Cancel</button>
        <button class="btn-sm" onclick="downloadLog('${job.job_id}')">&#8595; Download log</button>
      </div>
    </div>
  `;

  // Toggle expand/collapse
  pane.querySelector(`#hdr-${job.job_id}`).addEventListener('click', () => {
    const body = document.getElementById(`body-${job.job_id}`);
    const chv  = document.getElementById(`chv-${job.job_id}`);
    const open = body.classList.toggle('open');
    chv.classList.toggle('open', open);
  });

  return pane;
}

function updateJobPane(job) {
  const dot = document.getElementById(`dot-${job.job_id}`);
  if (dot) {
    dot.className = `status-dot ${job.status}`;
  }
  if (job.status !== 'running') {
    setJobTitleSuffix(job.job_id, '');
  }
  renderProgress(job.job_id);
}

function setJobTitleSuffix(jobId, title) {
  const el = document.getElementById(`jobtitle-${jobId}`);
  if (!el) return;

  const job = jobStore.get(jobId);
  if (job && job.status !== 'running' && title) return;

  if (title) {
    el.textContent = ` - ${title}`;
    el.title = title;
    return;
  }

  el.textContent = '';
  el.removeAttribute('title');
}

function setPhase(jobId, phase) {
  const el = document.getElementById(`phase-${jobId}`);
  if (el) el.textContent = phase;
}

function appendLogLine(jobId, lineData, lineHtml) {
  const state = getSectionState(jobId);
  const secId = lineData.section_id || state.currentId;
  if (!secId) return;

  state.currentId = secId;
  state.lastSectionId = secId;

  const pre = document.getElementById(`secpre-${jobId}-${secId}`);
  if (!pre) return;
  const div = document.createElement('div');
  div.innerHTML = lineHtml;
  pre.appendChild(div);

  // Count 'TASK [...]' lines inside ansible play sections.
  if (lineData.section_kind === 'play' && /^TASK \[/.test(lineData.text)) {
    const prev = state.taskCounts.get(secId) || 0;
    state.taskCounts.set(secId, prev + 1);
  }

  const countEl = document.getElementById(`seccount-${jobId}-${secId}`);
  if (countEl) {
    if (lineData.section_kind === 'play') {
      const seen  = state.taskCounts.get(secId) || 0;
      const total = _knownTotal(state.env, lineData.section_signature);
      countEl.textContent = _renderCount(lineData.section_kind, seen, total);
    } else {
      const n = pre.children.length;
      countEl.textContent = _renderCount(lineData.section_kind, n, null);
    }
  }

  const wrap = document.getElementById(`log-${jobId}`);
  if (wrap) {
    const nearBottom = wrap.scrollHeight - wrap.scrollTop - wrap.clientHeight < 80;
    if (nearBottom) wrap.scrollTop = wrap.scrollHeight;
  }
}

function showResultBanner(jobId, status, exitCode) {
  const el = document.getElementById(`banner-${jobId}`);
  if (!el) return;
  if (status === 'done') {
    el.className = 'result-banner success';
    el.innerHTML = '&#10003; Deploy complete';
    return;
  }
  if (status === 'interrupted') {
    el.className = 'result-banner failure';
    el.innerHTML = '&#9888; Deploy interrupted before completion';
    return;
  }
  el.className = 'result-banner failure';
  el.innerHTML = `&#10007; Deploy failed — exit code ${exitCode}`;
}

// ── SSE stream management ─────────────────────────────────────────────────────

function startStream(jobId) {
  if (activeStreams.has(jobId)) return; // already streaming

  const es = new EventSource(`/jobs/${jobId}/stream`);
  activeStreams.set(jobId, es);
  loadTimingProfileForJob(jobId);

  // Store env on section state so task counts can be persisted per-environment.
  const state = getSectionState(jobId);
  if (!state.env) { const j = jobStore.get(jobId); if (j) state.env = j.env; }

  es.addEventListener('section-start', (e) => {
    const data = JSON.parse(e.data);
    getOrCreateSection(jobId, data.id, data.title, data.signature, data.kind);
    state.currentId = data.id;
    state.lastSectionId = data.id;
    setJobTitleSuffix(jobId, data.title);
  });

  es.addEventListener('section-end', (e) => {
    const data = JSON.parse(e.data);
    markSectionDone(jobId, data.id, !!data.failed);
    if (state.currentId === data.id) state.currentId = null;
  });

  es.addEventListener('line', (e) => {
    const line = JSON.parse(e.data);
    const state = getSectionState(jobId);
    const progressEvent = parseProgressMarker(line.text);
    if (progressEvent) {
      if (shouldApplyProgressEvent(jobId)) {
        applyProgressEvent(jobId, progressEvent);
        maybeLogProgressDiagnostic(jobId, progressEvent);
      }
      return;
    }
    if (isUiProgressDiagnosticLine(line.text)) return;
    appendLogLine(jobId, line, ansiToHtml(line.text));
    const phase = detectPhase(line.text);
    if (phase) setPhase(jobId, phase);
  });

  es.addEventListener('done', (e) => {
    const data = JSON.parse(e.data);
    const exitCode = data.exit_code ?? -1;
    const status = data.status || (exitCode === 0 ? 'done' : 'failed');

    es.close();
    activeStreams.delete(jobId);

    // Collapse everything — keep summary open; on failure also keep the last section
    const state = getSectionState(jobId);
    const keepOpen = exitCode !== 0 && state.lastSectionId
      ? [state.lastSectionId, state.lastSummaryId].filter(Boolean)
      : [state.lastSummaryId].filter(Boolean);
    collapseAllSections(jobId, { keepOpen });
    // Re-open sections that should be visible
    keepOpen.forEach(sid => {
      const body = document.getElementById(`secbody-${jobId}-${sid}`);
      const chv  = document.getElementById(`secchv-${jobId}-${sid}`);
      if (body) body.classList.add('open');
      if (chv)  chv.classList.add('open');
    });

    // Hide cancel button — job is no longer running
    const cancelBtn = document.getElementById(`cancel-${jobId}`);
    if (cancelBtn) {
      clearTimeout(cancelBtn._confirmTimer);
      cancelBtn.style.display = 'none';
    }

    const job = jobStore.get(jobId);
    if (job) {
      job.status = status;
      job.exit_code = exitCode;
      updateJobPane(job);
    }
    const progress = getProgressState(jobId);
    if (status === 'done') {
      for (const step of progress.steps.values()) {
        step.completed = true;
        step.currentUnits = step.weight;
      }
      progress.currentStepId = null;
      progress.currentPlay = '';
      renderProgress(jobId);
    }
    setJobTitleSuffix(jobId, '');
    setPhase(jobId, status === 'interrupted' ? 'Interrupted' : (exitCode === 0 ? 'Complete ✓' : 'Failed ✗'));
    showResultBanner(jobId, status, exitCode);
    refreshStatusBar();

    // Reload job meta for history
    apiFetch(`/jobs/${jobId}`).then(jobMeta => {
      updateJobStore(jobMeta);
      updateJobPane(jobMeta);
      refreshStatusBar();
    }).catch(() => {});
  });

  es.onerror = () => {
    // EventSource will auto-reconnect; nothing to do here
  };
}

function stopStream(jobId) {
  const es = activeStreams.get(jobId);
  if (es) { es.close(); activeStreams.delete(jobId); }
}

async function cancelJob(jobId) {
  const btn = document.getElementById(`cancel-${jobId}`);
  if (!btn) return;
  // Two-step confirm: first click arms, second click fires.
  if (!btn.dataset.confirm) {
    btn.dataset.confirm = '1';
    btn.textContent = 'Confirm?';
    btn.classList.add('btn-confirm');
    btn._confirmTimer = setTimeout(() => {
      // Reset if user doesn't click again within 3 s.
      delete btn.dataset.confirm;
      btn.textContent = '\u25FC Cancel';
      btn.classList.remove('btn-confirm');
    }, 3000);
    return;
  }
  clearTimeout(btn._confirmTimer);
  delete btn.dataset.confirm;
  btn.classList.remove('btn-confirm');
  btn.disabled = true;
  btn.textContent = 'Cancelling\u2026';
  try {
    await apiFetch(`/jobs/${jobId}`, { method: 'DELETE' });
  } catch (err) {
    btn.disabled = false;
    btn.textContent = '\u25FC Cancel';
    alert(`Cancel failed: ${err.message}`);
  }
}
window.cancelJob = cancelJob;

// ── Deploy form ───────────────────────────────────────────────────────────────

async function loadEnvironments() {
  const sel = document.getElementById('env-select');
  const btn = document.getElementById('deploy-btn');
  try {
    const envs = await apiFetch('/environments');
    sel.innerHTML = envs.length
      ? envs.map(e => `<option value="${e.name}">${e.name}${e.config_complete ? '' : ' ⚠ incomplete'}</option>`).join('')
      : '<option value="">No environments found</option>';
    btn.disabled = envs.length === 0;
  } catch (err) {
    sel.innerHTML = '<option value="">Error loading environments</option>';
  }
}

function syncRecreatePolicyControl() {
  const scope = document.getElementById('scope-select').value;
  const select = document.getElementById('recreate-policy-select');
  const hint = document.getElementById('recreate-policy-hint');
  const freshTailnet = document.getElementById('opt-fresh-tailnet');
  const usesDestroyPrompt = DESTROY_PROMPT_SCOPES.has(scope);

  select.disabled = !usesDestroyPrompt;
  if (usesDestroyPrompt) {
    hint.textContent = 'Web UI jobs are non-interactive, so this preselects how deploy.sh answers the destroy prompt.';
    freshTailnet.disabled = select.value !== 'destroy';
    if (freshTailnet.disabled) freshTailnet.checked = false;
    return;
  }

  freshTailnet.disabled = true;
  freshTailnet.checked = false;
  hint.textContent = 'This scope does not use the existing-infrastructure prompt, so the selection is ignored.';
}

async function handleDeploy() {
  const env   = document.getElementById('env-select').value;
  const scope = document.getElementById('scope-select').value;
  const extra = [];
  const recreatePolicy = document.getElementById('recreate-policy-select').value;

  if (DESTROY_PROMPT_SCOPES.has(scope)) {
    extra.push(recreatePolicy === 'destroy' ? '--yes' : '--no-destroy');
  }
  if (document.getElementById('opt-no-restore').checked) extra.push('--no-restore');
  if (document.getElementById('opt-fresh-tailnet').checked) extra.push('--fresh-tailnet');
  if (document.getElementById('opt-my-ip').checked)      extra.push('--allow-ssh-from-my-ip');

  const errEl = document.getElementById('deploy-error');
  errEl.classList.add('hidden');

  try {
    const job = await apiFetch('/jobs', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ env, scope, extra_args: extra }),
    });
    updateJobStore(job);
    refreshStatusBar();

    const panes = document.getElementById('job-panes');
    resetJobUiState(job.job_id);
    const pane  = createJobPane(job);
    panes.prepend(pane);
    renderProgress(job.job_id);

    startStream(job.job_id);
  } catch (err) {
    errEl.textContent = `Failed to start deploy: ${err.message}`;
    errEl.classList.remove('hidden');
  }
}

// ── History view ──────────────────────────────────────────────────────────────

async function loadHistory() {
  const list  = document.getElementById('history-list');
  const empty = document.getElementById('history-empty');
  list.innerHTML = '';

  try {
    const jobs = await apiFetch('/jobs');
    if (jobs.length === 0) {
      empty.classList.remove('hidden');
      return;
    }
    empty.classList.add('hidden');
    for (const job of jobs) {
      updateJobStore(job);
      const item = document.createElement('div');
      item.className = 'history-item';
      const statusClass = job.status === 'done' ? 'ok' : job.status === 'failed' ? 'bad' : job.status === 'interrupted' ? 'warn' : 'warn';
      const dur = fmtDuration(job.start_time, job.end_time);
      item.innerHTML = `
        <span class="history-id">${job.job_id}</span>
        <span class="history-meta">
          <span>${job.env}</span>
          <span>${job.scope}</span>
          <span>${fmtJobSource(job.source)}</span>
          <span>${fmtTime(job.start_time)}</span>
          ${dur ? `<span>${dur}</span>` : ''}
        </span>
        <span class="history-status">
          <span class="badge ${statusClass}">${job.status}</span>
        </span>
      `;
      item.addEventListener('click', () => openJobFromHistory(job));
      list.appendChild(item);
    }
  } catch (err) {
    list.innerHTML = `<p class="muted">Error loading history: ${err.message}</p>`;
  }
}

function openJobFromHistory(job) {
  // Switch to deploy tab and show the job pane
  switchView('deploy');
  const existingPane = document.getElementById(`pane-${job.job_id}`);
  if (existingPane) {
    existingPane.scrollIntoView({ behavior: 'smooth' });
    return;
  }

  updateJobStore(job);
  const panes = document.getElementById('job-panes');
  resetJobUiState(job.job_id);
  const pane  = createJobPane(job);
  panes.prepend(pane);
  const phaseLabel = job.status === 'running' ? 'starting…' : jobPhaseLabel(job);
  setPhase(job.job_id, phaseLabel);
  renderProgress(job.job_id);

  // Replay from start (job is finished, SSE will stream all at once then send done)
  startStream(job.job_id);
}

// ── Status view (Phase 3) ─────────────────────────────────────────────────────

async function initStatusView() {
  const sel = document.getElementById('status-env-select');
  if (sel.options.length === 0 || sel.options[0].value === '') {
    try {
      const envs = await apiFetch('/environments');
      sel.innerHTML = envs.map(e => `<option value="${e.name}">${e.name}</option>`).join('');
    } catch { return; }
  }
  if (sel.options.length > 0) loadStatus(sel.value);
  sel.onchange = () => loadStatus(sel.value);
}

async function loadStatus(env) {
  const container = document.getElementById('status-content');
  container.innerHTML = '<p class="muted">Loading…</p>';
  try {
    const s = await apiFetch(`/status/${env}`);
    container.innerHTML = renderStatus(s, env);
  } catch (err) {
    container.innerHTML = `<p class="muted">Error: ${err.message}</p>`;
  }
}

function renderStatus(s, env) {
  if (!s.has_outputs) {
    return `<p class="muted">No deployment outputs found for <strong>${env}</strong>. Run a deploy first.</p>`;
  }

  function row(label, value) {
    if (!value) return '';
    return `<div class="status-row"><span>${label}</span><span>${value}</span></div>`;
  }
  function linkRow(label, url) {
    if (!url) return '';
    return `<div class="status-row"><span>${label}</span><a href="${url}" target="_blank" rel="noopener">${url}</a></div>`;
  }

  const wips = Object.entries(s.workloads.private_ips || {})
    .map(([k, v]) => row(k, v)).join('');

  return `
  <div class="status-grid">
    <div class="status-card">
      <div class="status-card-header">&#127760; Gateway VM</div>
      <div class="status-card-body">
        ${row('Public IP', s.gateway.public_ip)}
        ${row('Private IP', s.gateway.private_ip)}
        ${row('Mycelium IP', s.gateway.mycelium_ip)}
        ${row('Console', s.gateway.console_url)}
        ${row('Network range', s.network_ip_range)}
      </div>
    </div>
    <div class="status-card">
      <div class="status-card-header">&#9881; Control VM (Headscale)</div>
      <div class="status-card-body">
        ${row('Public IP', s.control.public_ip)}
        ${row('Private IP', s.control.private_ip)}
        ${row('Mycelium IP', s.control.mycelium_ip)}
        ${row('Console', s.control.console_url)}
      </div>
    </div>
    <div class="status-card">
      <div class="status-card-header">&#9654; Service URLs</div>
      <div class="status-card-body">
        ${linkRow('Headscale', s.urls.headscale)}
        ${linkRow('Headplane admin', s.urls.headplane)}
        ${linkRow('Grafana', s.urls.grafana)}
        ${linkRow('Prometheus', s.urls.prometheus)}
      </div>
    </div>
    ${Object.keys(s.workloads.private_ips || {}).length > 0 ? `
    <div class="status-card">
      <div class="status-card-header">&#128736; Workload VMs</div>
      <div class="status-card-body">${wips}</div>
    </div>` : ''}
  </div>`;
}

// ── Environments view ─────────────────────────────────────────────────────────

async function loadEnvironmentsView() {
  const grid = document.getElementById('env-list');
  grid.innerHTML = '';
  try {
    const envs = await apiFetch('/environments');
    for (const env of envs) {
      const card = document.createElement('div');
      card.className = 'env-card';
      const cfgBadge = env.config_complete
        ? '<span class="badge ok">complete</span>'
        : '<span class="badge warn">incomplete</span>';
      const lastDeploy = env.last_job
        ? `${fmtTime(env.last_job.start_time)} — <span class="badge ${env.last_job.status === 'done' ? 'ok' : 'bad'}">${env.last_job.status}</span>`
        : '<span class="muted">never</span>';
      card.innerHTML = `
        <div class="env-name">${env.name}</div>
        <div class="env-status">
          <div class="env-row"><span>Config</span>${cfgBadge}</div>
          <div class="env-row"><span>terraform.tfvars</span><span class="badge ${env.has_tfvars ? 'ok' : 'bad'}">${env.has_tfvars ? 'present' : 'missing'}</span></div>
          <div class="env-row"><span>secrets.env</span><span class="badge ${env.has_secrets ? 'ok' : 'bad'}">${env.has_secrets ? 'present' : 'missing'}</span></div>
          <div class="env-row"><span>Last deploy</span><span>${lastDeploy}</span></div>
        </div>
        <div style="margin-top:12px;display:flex;gap:8px">
          <button class="btn-sm" onclick="switchView('configure');document.getElementById('config-env-select').value='${env.name}';loadConfigForm('${env.name}')">Configure</button>
          <button class="btn-sm" onclick="switchView('status');document.getElementById('status-env-select').value='${env.name}';loadStatus('${env.name}')">Status</button>
        </div>
      `;
      grid.appendChild(card);
    }
    if (envs.length === 0) {
      grid.innerHTML = '<p class="muted">No environments found under environments/.</p>';
    }
  } catch (err) {
    grid.innerHTML = `<p class="muted">Error: ${err.message}</p>`;
  }
}

async function createEnvironment() {
  const name = prompt('New environment name (lowercase, a-z0-9-_):');
  if (!name) return;
  try {
    await apiFetch('/environments', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name: name.trim() }),
    });
    loadEnvironments(); // reload deploy dropdown
    loadEnvironmentsView();
  } catch (err) {
    alert(`Failed to create environment: ${err.message}`);
  }
}
window.createEnvironment = createEnvironment;

// ── Download log ──────────────────────────────────────────────────────────────

function downloadLog(jobId) {
  const a = document.createElement('a');
  a.href = `/jobs/${jobId}/log`;
  a.download = `${jobId}.log`;
  a.click();
}
window.downloadLog = downloadLog; // expose for inline onclick

// ── Configure view (Phase 2) ──────────────────────────────────────────────────

async function initConfigureView() {
  const sel = document.getElementById('config-env-select');
  if (sel.options.length === 0 || sel.options[0].value === '') {
    try {
      const envs = await apiFetch('/environments');
      sel.innerHTML = envs.map(e => `<option value="${e.name}">${e.name}</option>`).join('');
    } catch { return; }
  }
  if (sel.options.length > 0) loadConfigForm(sel.value);

  sel.onchange = () => loadConfigForm(sel.value);
}

async function loadConfigForm(env) {
  const container = document.getElementById('config-form-container');
  container.innerHTML = '<p class="muted">Loading…</p>';
  try {
    const cfg = await apiFetch(`/config/${env}`);
    container.innerHTML = renderConfigForm(env, cfg);
    bindConfigFormHandlers(env);
  } catch (err) {
    container.innerHTML = `<p class="muted">Error: ${err.message}</p>`;
  }
}

function renderConfigForm(env, cfg) {
  const g = cfg.grid;
  const dns = cfg.dns;
  const bk = cfg.backup;
  const creds = cfg.credentials;
  const sshKeys = (cfg.ssh.public_keys || []).join('\n');

  const networks = ['main', 'test', 'qa', 'dev'];
  const netOpts = networks.map(n =>
    `<option value="${n}"${g.tfgrid_network === n ? ' selected' : ''}>${n}</option>`
  ).join('');

  return `
  <!-- Grid -->
  <div class="config-section" id="section-grid">
    <div class="config-section-header">&#9881; Grid</div>
    <div class="config-section-body">
      <div class="config-row">
        <div class="form-field">
          <label>Network</label>
          <select id="cfg-network">${netOpts}</select>
        </div>
        <div class="form-field">
          <label>Deployment name</label>
          <input type="text" id="cfg-name" value="${_esc(g.name)}">
        </div>
      </div>
      <div class="form-field" style="margin-bottom:0">
        <label style="display:flex;align-items:center;gap:8px;cursor:pointer">
          <input type="checkbox" id="cfg-scheduler"${g.use_scheduler ? ' checked' : ''}>
          Use auto-scheduler (let TFGrid pick nodes)
        </label>
      </div>
      <div class="save-row">
        <button class="btn-primary" onclick="saveGrid('${env}')">Save Grid</button>
        <span class="save-feedback" id="fb-grid"></span>
      </div>
    </div>
  </div>

  <!-- SSH -->
  <div class="config-section" id="section-ssh">
    <div class="config-section-header">&#128273; SSH Public Keys</div>
    <div class="config-section-body">
      <div class="form-field">
        <label>One key per line</label>
        <textarea class="ssh-keys" id="cfg-ssh-keys">${_esc(sshKeys)}</textarea>
      </div>
      <div class="save-row">
        <button class="btn-primary" onclick="saveSsh('${env}')">Save SSH Keys</button>
        <span class="save-feedback" id="fb-ssh"></span>
      </div>
    </div>
  </div>

  <!-- Credentials -->
  <div class="config-section" id="section-credentials">
    <div class="config-section-header">&#128274; Credentials</div>
    <div class="config-section-body">
      <div class="config-row">
        <div class="form-field">
          <label>TFGrid mnemonic <span class="hint">(leave blank to keep current)</span></label>
          <div class="secret-field">
            <input type="password" id="cfg-mnemonic" placeholder="twelve word phrase…" autocomplete="new-password">
            <span class="secret-badge ${creds.mnemonic_set ? 'set' : 'unset'}">${creds.mnemonic_set ? 'saved' : 'not set'}</span>
          </div>
        </div>
        <div class="form-field">
          <label>Services admin password <span class="hint">(leave blank to keep current)</span></label>
          <div class="secret-field">
            <input type="password" id="cfg-admin-pw" placeholder="new password…" autocomplete="new-password">
            <span class="secret-badge ${creds.admin_password_set ? 'set' : 'unset'}">${creds.admin_password_set ? 'saved' : 'not set'}</span>
          </div>
        </div>
      </div>
      <div class="save-row">
        <button class="btn-primary" onclick="saveCredentials('${env}')">Save Credentials</button>
        <span class="save-feedback" id="fb-creds"></span>
      </div>
    </div>
  </div>

  <!-- DNS -->
  <div class="config-section" id="section-dns">
    <div class="config-section-header">&#127760; DNS</div>
    <div class="config-section-body">
      <div class="config-row">
        <div class="form-field">
          <label>Base domain</label>
          <input type="text" id="cfg-base-domain" value="${_esc(dns.base_domain)}" placeholder="example.com">
        </div>
        <div class="form-field">
          <label>Headscale subdomain</label>
          <input type="text" id="cfg-headscale-sub" value="${_esc(dns.headscale_subdomain)}" placeholder="headscale">
        </div>
      </div>
      <div class="config-row">
        <div class="form-field">
          <label>Admin email <span class="hint">(Let's Encrypt)</span></label>
          <input type="text" id="cfg-admin-email" value="${_esc(dns.admin_email)}" placeholder="admin@example.com">
        </div>
        <div class="form-field">
          <label>MagicDNS base domain</label>
          <input type="text" id="cfg-magic-dns-domain" value="${_esc(dns.magic_dns_base_domain)}" placeholder="in.example.com">
        </div>
      </div>
      <div class="config-row">
        <div class="form-field">
          <label>Public service TLS mode</label>
          <select id="cfg-public-tls-mode">
            <option value="letsencrypt"${dns.public_service_tls_mode === 'letsencrypt' ? ' selected' : ''}>Per-host Let's Encrypt</option>
            <option value="namecheap"${dns.public_service_tls_mode === 'namecheap' ? ' selected' : ''}>Wildcard via Namecheap DNS-01</option>
          </select>
        </div>
        <div class="form-field">
          <label>Internal service TLS mode</label>
          <select id="cfg-internal-tls-mode">
            <option value="internal"${dns.internal_service_tls_mode === 'internal' ? ' selected' : ''}>Caddy internal CA</option>
            <option value="namecheap"${dns.internal_service_tls_mode === 'namecheap' ? ' selected' : ''}>Namecheap wildcard via gateway</option>
          </select>
        </div>
      </div>
      <div class="config-row">
        <div class="form-field">
          <label>Namecheap API user <span class="hint">(leave blank to keep)</span></label>
          <div class="secret-field">
            <input type="text" id="cfg-nc-user" placeholder="your-username">
            <span class="secret-badge ${dns.namecheap_user_set ? 'set' : 'unset'}">${dns.namecheap_user_set ? 'saved' : 'not set'}</span>
          </div>
        </div>
        <div class="form-field">
          <label>Namecheap API key <span class="hint">(leave blank to keep)</span></label>
          <div class="secret-field">
            <input type="password" id="cfg-nc-key" placeholder="api-key…" autocomplete="new-password">
            <span class="secret-badge ${dns.namecheap_key_set ? 'set' : 'unset'}">${dns.namecheap_key_set ? 'saved' : 'not set'}</span>
          </div>
        </div>
      </div>
      <div class="save-row">
        <button class="btn-primary" onclick="saveDns('${env}')">Save DNS</button>
        <span class="save-feedback" id="fb-dns"></span>
      </div>
    </div>
  </div>

  <!-- Backup -->
  <div class="config-section" id="section-backup">
    <div class="config-section-header">&#128190; Backup (Restic + S3)</div>
    <div class="config-section-body">
      <div class="form-field" style="margin-bottom:16px">
        <label style="display:flex;align-items:center;gap:8px;cursor:pointer">
          <input type="checkbox" id="cfg-backup-enabled"${bk.backup_enabled ? ' checked' : ''}>
          Enable backup system
        </label>
      </div>
      <div class="config-row">
        <div class="form-field">
          <label>Restic password <span class="hint">(leave blank to keep)</span></label>
          <div class="secret-field">
            <input type="password" id="cfg-restic-pw" placeholder="encryption password…" autocomplete="new-password">
            <span class="secret-badge ${bk.restic_password_set ? 'set' : 'unset'}">${bk.restic_password_set ? 'saved' : 'not set'}</span>
          </div>
        </div>
      </div>
      <div class="config-row">
        <div class="form-field">
          <label>S3 primary access key</label>
          <div class="secret-field">
            <input type="text" id="cfg-s3p-access" placeholder="access key…">
            <span class="secret-badge ${bk.s3_primary_access_set ? 'set' : 'unset'}">${bk.s3_primary_access_set ? 'saved' : 'not set'}</span>
          </div>
        </div>
        <div class="form-field">
          <label>S3 primary secret key</label>
          <div class="secret-field">
            <input type="password" id="cfg-s3p-secret" placeholder="secret key…" autocomplete="new-password">
            <span class="secret-badge ${bk.s3_primary_secret_set ? 'set' : 'unset'}">${bk.s3_primary_secret_set ? 'saved' : 'not set'}</span>
          </div>
        </div>
      </div>
      <div class="config-row">
        <div class="form-field">
          <label>S3 secondary access key</label>
          <div class="secret-field">
            <input type="text" id="cfg-s3s-access" placeholder="access key…">
            <span class="secret-badge ${bk.s3_secondary_access_set ? 'set' : 'unset'}">${bk.s3_secondary_access_set ? 'saved' : 'not set'}</span>
          </div>
        </div>
        <div class="form-field">
          <label>S3 secondary secret key</label>
          <div class="secret-field">
            <input type="password" id="cfg-s3s-secret" placeholder="secret key…" autocomplete="new-password">
            <span class="secret-badge ${bk.s3_secondary_secret_set ? 'set' : 'unset'}">${bk.s3_secondary_secret_set ? 'saved' : 'not set'}</span>
          </div>
        </div>
      </div>
      <div class="save-row">
        <button class="btn-primary" onclick="saveBackup('${env}')">Save Backup</button>
        <span class="save-feedback" id="fb-backup"></span>
      </div>
    </div>
  </div>
  `;
}

function _esc(s) {
  return String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function bindConfigFormHandlers(env) {
  // (handlers are set via inline onclick for simplicity; expose to window)
  window._configEnv = env;
}

function setFeedback(id, ok, msg) {
  const el = document.getElementById(id);
  if (!el) return;
  el.className = `save-feedback ${ok ? 'ok' : 'err'}`;
  el.textContent = ok ? '✓ Saved' : `✗ ${msg}`;
  setTimeout(() => { el.textContent = ''; }, 4000);
}

async function saveGrid(env) {
  try {
    await apiFetch(`/config/${env}/grid`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        tfgrid_network: document.getElementById('cfg-network').value,
        name:           document.getElementById('cfg-name').value,
        use_scheduler:  document.getElementById('cfg-scheduler').checked,
      }),
    });
    setFeedback('fb-grid', true);
  } catch (e) { setFeedback('fb-grid', false, e.message); }
}

async function saveSsh(env) {
  const raw = document.getElementById('cfg-ssh-keys').value;
  const keys = raw.split('\n').map(l => l.trim()).filter(Boolean);
  try {
    await apiFetch(`/config/${env}/ssh`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ public_keys: keys }),
    });
    setFeedback('fb-ssh', true);
  } catch (e) { setFeedback('fb-ssh', false, e.message); }
}

async function saveCredentials(env) {
  const payload = {};
  const m = document.getElementById('cfg-mnemonic').value.trim();
  const p = document.getElementById('cfg-admin-pw').value.trim();
  if (m) payload.mnemonic = m;
  if (p) payload.admin_password = p;
  if (!m && !p) { setFeedback('fb-creds', false, 'No changes'); return; }
  try {
    await apiFetch(`/config/${env}/credentials`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    document.getElementById('cfg-mnemonic').value = '';
    document.getElementById('cfg-admin-pw').value = '';
    setFeedback('fb-creds', true);
    // Reload to update badges
    setTimeout(() => loadConfigForm(env), 300);
  } catch (e) { setFeedback('fb-creds', false, e.message); }
}

async function saveDns(env) {
  const payload = {
    base_domain:         document.getElementById('cfg-base-domain').value.trim() || null,
    headscale_subdomain: document.getElementById('cfg-headscale-sub').value.trim() || null,
    magic_dns_base_domain: document.getElementById('cfg-magic-dns-domain').value.trim() || null,
    public_service_tls_mode: document.getElementById('cfg-public-tls-mode').value || 'letsencrypt',
    internal_service_tls_mode: document.getElementById('cfg-internal-tls-mode').value || 'internal',
    admin_email:         document.getElementById('cfg-admin-email').value.trim() || null,
    namecheap_user:      document.getElementById('cfg-nc-user').value.trim() || null,
    namecheap_key:       document.getElementById('cfg-nc-key').value.trim() || null,
  };
  try {
    await apiFetch(`/config/${env}/dns`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    setFeedback('fb-dns', true);
    setTimeout(() => loadConfigForm(env), 300);
  } catch (e) { setFeedback('fb-dns', false, e.message); }
}

async function saveBackup(env) {
  const payload = {
    backup_enabled:          document.getElementById('cfg-backup-enabled').checked,
    restic_password:         document.getElementById('cfg-restic-pw').value.trim() || null,
    s3_primary_access_key:   document.getElementById('cfg-s3p-access').value.trim() || null,
    s3_primary_secret_key:   document.getElementById('cfg-s3p-secret').value.trim() || null,
    s3_secondary_access_key: document.getElementById('cfg-s3s-access').value.trim() || null,
    s3_secondary_secret_key: document.getElementById('cfg-s3s-secret').value.trim() || null,
  };
  try {
    await apiFetch(`/config/${env}/backup`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    setFeedback('fb-backup', true);
    setTimeout(() => loadConfigForm(env), 300);
  } catch (e) { setFeedback('fb-backup', false, e.message); }
}

// expose save functions for inline onclick
Object.assign(window, { saveGrid, saveSsh, saveCredentials, saveDns, saveBackup });

// ── Tab navigation ────────────────────────────────────────────────────────────

function switchView(name) {
  document.querySelectorAll('.view').forEach(v => v.classList.add('hidden'));
  document.querySelectorAll('.tab').forEach(t => t.classList.toggle('active', t.dataset.view === name));
  document.getElementById(`view-${name}`).classList.remove('hidden');

  if (name === 'history')      loadHistory();
  if (name === 'environments') loadEnvironmentsView();
  if (name === 'configure')    initConfigureView();
  if (name === 'status')       initStatusView();
}

// ── Initialise ────────────────────────────────────────────────────────────────

document.addEventListener('DOMContentLoaded', () => {
  // Tab clicks
  document.querySelectorAll('.tab').forEach(btn => {
    btn.addEventListener('click', () => switchView(btn.dataset.view));
  });

  // Deploy button
  document.getElementById('deploy-btn').addEventListener('click', handleDeploy);
  document.getElementById('scope-select').addEventListener('change', syncRecreatePolicyControl);
  document.getElementById('recreate-policy-select').addEventListener('change', syncRecreatePolicyControl);

  // Load environments into select
  loadEnvironments();
  syncRecreatePolicyControl();

  // Re-subscribe to any in-flight jobs loaded from server state
  apiFetch('/jobs').then(jobs => {
    for (const job of jobs) {
      updateJobStore(job);
      if (job.status === 'running') {
        resetJobUiState(job.job_id);
        const pane = createJobPane(job);
        document.getElementById('job-panes').appendChild(pane);
        renderProgress(job.job_id);
        startStream(job.job_id);
      }
    }
    refreshStatusBar();
  }).catch(() => {});
});
