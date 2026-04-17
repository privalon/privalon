#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
Usage:
  scripts/tests/run.sh <suite>

Suites:
  bootstrap-smoke         Verifies Terraform outputs + SSH reachability (Tailscale-first)
  static-gateway          Verifies gateway config parsing and Caddy template rendering locally
  static-observability    Verifies observability role guard behavior for partial/control-only runs
  dashboard-json          Verifies provisioned Grafana dashboard JSON structure and labels
  dns-helper-local       Verifies local Namecheap DNS helper logic with stubbed API responses
  tailnet-management      Verifies public headscale + tailnet-only headplane + local tailscale + tailscale SSH + monitoring and observability APIs
  backup-verify           Verifies backup system: Restic installed, timers active, metrics, Backrest, Grafana dashboard
  portable-recovery       Verifies portable recovery bundle refresh and prepare-only restore locally
  headscale-recovery      Breaks headscale container and recovers via converge
  lockdown-public-ssh     Removes public SSH allowlist and asserts public SSH is blocked (requires CONFIRM_LOCKDOWN=1)
  core-redeploy           Redeploys core (control+workloads) as recovery test (requires CONFIRM_REDEPLOY_CORE=1)

Environment toggles:
  TEST_ENV=<name>         Environment to test against (default: test, e.g. TEST_ENV=prod)
  REQUIRE_TS_SSH=1        Enforce SSH-over-Tailscale in the tailnet-management suite
  REQUIRE_CONTROL_SSH=1   Enforce control SSH checks in 10_verify_headscale.sh
  CONFIRM_LOCKDOWN=1      Allow lockdown-public-ssh suite (disables public SSH)
  CONFIRM_REDEPLOY_CORE=1 Allow core-redeploy suite (disruptive)
USAGE
}

run() {
  local name="$1"
  echo "[suite] $name" >&2
  bash "$SCRIPT_DIR/$name";
}

suite="${1:-}"
if [[ -z "$suite" || "$suite" == "-h" || "$suite" == "--help" ]]; then
  usage
  exit 0
fi

case "$suite" in
  bootstrap-smoke)
    run 00_smoke.sh
    run 12_verify_headscale_public_endpoint.sh
    run 15_verify_dns_setup.sh
    ;;
  static-gateway)
    run 16_verify_gateway_static.sh
    ;;
  static-observability)
    run 17_verify_observability_guard_static.sh
    ;;
  dashboard-json)
    run 05_verify_grafana_dashboards.sh
    ;;
  dns-helper-local)
    run 14_verify_dns_helper_local.sh
    ;;
  tailnet-management)
    run 10_verify_headscale.sh
    run 12_verify_headscale_public_endpoint.sh
    run 65_verify_headplane.sh
    run 20_verify_local_tailscale.sh
    run 25_verify_gateway_exit_node.sh
    # Make Tailscale SSH required by default for this suite.
    export REQUIRE_TS_SSH="${REQUIRE_TS_SSH:-1}"
    run 30_verify_tailscale_ssh_optional.sh
    run 60_verify_monitoring_stack.sh
    run 62_verify_service_observability.sh
    ;;
  backup-verify)
    run 80_verify_backup_restore.sh
    run 82_verify_backrest_auth.sh
    run 84_verify_backrest_snapshot_api.sh
    ;;
  portable-recovery)
    run 90_verify_portable_recovery_bundle.sh
    run 92_verify_data_model_migrations.sh
    ;;
  data-model-migrations)
    run 92_verify_data_model_migrations.sh
    ;;
  headscale-recovery)
    run 40_break_and_recover_headscale_container.sh
    ;;
  lockdown-public-ssh)
    run 70_lockdown_public_ssh.sh
    ;;
  core-redeploy)
    # Requires explicit confirmation.
    if [[ "${CONFIRM_REDEPLOY_CORE:-0}" != "1" ]]; then
      echo "[suite][FAIL] CONFIRM_REDEPLOY_CORE=1 is required" >&2
      exit 2
    fi
    run 50_redeploy_broken_headscale_vm.sh
    ;;
  *)
    usage
    exit 2
    ;;
esac

echo "[suite] OK" >&2
