# DNS and Service Visibility Roadmap

**Shipped note — April 2026**

This roadmap item is now implemented and kept only as historical design context.

Implemented behavior has been moved into the main docs:

- [Architecture — DNS and Service Visibility](../technical/ARCHITECTURE.md#dns-and-service-visibility)
- [Operations — Domain Configuration](../technical/OPERATIONS.md#domain-configuration)
- [User Guide](../user/GUIDE.md)

Already shipped and no longer tracked here:

- Per-domain public upstream routing via `gateway_services`
- Public wildcard TLS on the gateway via `public_service_tls_mode: namecheap`
- Namecheap-backed internal wildcard TLS for packaged monitoring aliases

Implemented behavior:

- Headplane no longer rides on the public Headscale hostname
- Headplane is exposed only on a tailnet-only control-node endpoint
- The public control hostname now serves Headscale coordination and DERP only

---

## Phase 5: Headplane behind MagicDNS only

### Summary

Move Headplane off the public Headscale hostname and expose it only inside the tailnet.

### Current behavior

Today Headplane remains publicly reachable at:

- `http://control-vm.in.yourdomain.com:3000`

That is workable because Headplane still has its own auth boundary, but it is an admin UI on a
public hostname and does not need to stay there.

### Implemented behavior

Serve Headplane only through the private namespace, for example:

- `http://control-vm.in.yourdomain.com:3000`

or an equivalent tailnet-only hostname.

The public control hostname would then serve only:

- Headscale coordination
- DERP relay

### Comparison

| Item | Current | Proposed |
|------|---------|----------|
| Headplane location | Public control hostname | Tailnet-only hostname on `control-vm:3000` |
| Exposure | Public admin surface | Private admin surface |
| Dependency | None beyond current control-host setup | Requires stable MagicDNS / private access workflow |

### Design notes

- This change should not move Headscale behind the gateway
- Headscale remains a separate exact-host public endpoint on the control VM
- Only the Headplane admin surface moves private
- ACL and host firewall expectations should be explicit when this is implemented

---

## Outcome

- Headplane is no longer reachable from the public internet
- Admins can still reach it reliably over MagicDNS / tailnet-only hostnames
- The public control hostname continues to serve Headscale and DERP correctly
