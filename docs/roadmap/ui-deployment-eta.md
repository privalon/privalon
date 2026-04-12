# Roadmap: Deployment ETA & Section Timing

**Status:** Implemented in v1.13.26  
**Current shape:** Step-level timing profile rebuilt from persisted `[bp-progress]` markers

---

## Goal

Show a live ETA ("~3m 20s remaining") and overall progress ("phase 2 / 7") in every
running job pane, without requiring hardcoded timeouts that go stale as the project grows.

---

## Design

### What gets displayed

| Location | Content |
|---|---|
| Job pane header | `phase 2 / 7  ·  ETA ~3m 20s` (live countdown, 1 s tick) |
| Section header — Ansible plays | `tasks 3 / 12` (already in v1.8.7) |
| Section header — other sections | `N lines` (unchanged) |

The ETA is hidden on the very first deployment (no historical data).  
After the first successful run it is immediately available.

---

## Current implementation

After every **successful** job, the server writes or rebuilds:

```
environments/<env>/.ui-logs/timing-profile.json
```

```json
{
  "env": "test",
  "alpha": 0.3,
  "job_count": 16,
  "scopes": {
    "full": {
      "runs": 7,
      "steps": {
        "terraform-apply": { "avg_ms": 16510.0, "avg_weight": 12.0, "kind": "script", "runs": 7 },
        "ansible-main": { "avg_ms": 1558992.0, "avg_units": 348.8, "avg_unit_ms": 4453.6, "kind": "ansible", "runs": 7 }
      },
      "summary": {
        "avg_total_ms": 1609804.1,
        "avg_script_ms_per_weight": 1440.96,
        "avg_ansible_unit_ms": 4453.56
      }
    }
  },
  "updated": "2026-04-10T09:11:28Z"
}
```

**Why per-environment?**  
`prod` typically has more servers than `test`; their timings are independent.

---

The profile is rebuilt from successful persisted job logs, including terminal-triggered runs that `deploy.sh` recorded into `.ui-logs/`. Each step average uses an exponential moving average with $\alpha = 0.3$, and Ansible steps also track average observed task counts plus average milliseconds per task.

## Runtime estimator

At runtime the UI:

1. fetches `GET /timing/<env>` when a job stream opens,
2. maps the current plan's steps onto the historical step profile for that scope,
3. estimates unfinished script steps from historical milliseconds-per-weight when the exact step is new,
4. estimates unfinished Ansible work from historical milliseconds-per-task,
5. adjusts the current in-flight step upward when the live elapsed time indicates an overrun.

When there is no timing history yet, the UI falls back to the older live unit-rate estimator.

---

## Notes

This shipped implementation deliberately uses the existing persisted `[bp-progress]` markers rather than a second custom section-timing channel. That keeps the timing profile compatible with both Web UI jobs and terminal-triggered jobs that are later replayed in History.

---

## Scalability notes

| Scenario | Behaviour |
|---|---|
| New role added | New step missing from profile → fallback uses scope summary on the first run, then the exact step self-calibrates after a successful completion. |
| Server count doubled | Existing sections take longer; EMA converges in ~5 runs. |
| Section permanently removed | Profile entry becomes stale but doesn't affect ETA (section never starts). Safe to leave; prune manually or add auto-prune on `runs < 2 && age > 30d`. |
| Cancelled / failed job | Profile is **not** updated — partial timings would corrupt the averages. |

---

## Acceptance criteria

- [x] `timing-profile.json` is written after every successful deployment.
- [x] ETA renders from the environment timing profile when history exists.
- [x] Page refresh during a running job can fetch the same timing profile again immediately.
- [x] First-ever run falls back to the live unit-rate estimator instead of crashing.
- [x] Adding new plan steps self-heals through summary fallback on the first run and exact per-step timing after successful completion.
