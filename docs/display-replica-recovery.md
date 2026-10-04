# Missing MenuBox icon on one display

## Observed failure (2026-10-04)

Two read-only MenuBarAgent snapshots of the live three-display setup showed:

| Menu bar origin (Quartz) | Width | MenuBox hosts |
| --- | ---: | --- |
| `(0, 0)` — laptop | 1728 | collapsed marker (16 pt), Box (38 pt) |
| `(-2560, -323)` — external | 2560 | none |
| `(-5120, -323)` — external | 2560 | collapsed marker (16 pt), Box (38 pt) |

The middle display also lacked several other applications' hosted icons. This is
an incomplete macOS per-display host layout, not a global MenuBox visibility
preference or a Box drawing issue. The available snapshots do not establish which
macOS event originally dropped the hosts.

The application log continuously reported `hidden check deferred: incomplete`
and `hidden check pending: keeping existing transaction`. The five-second
inventory timer queued another verification while the current retries were
running. At the end of a failed retry batch, verification immediately restarted.

`canRepairStatusItems` previously rejected repairs whenever that applied
transaction was transitioning. Consequently, the missing replicas prevented
verification from completing, and verification prevented replicas from being
repaired. Each blocked inventory tick also reset the repair debounce, so a
persistent missing icon could remain indefinitely.

## Fix

An incomplete read during hidden-state reconciliation now explicitly permits
local status-item repair while retaining the applied visibility transaction.
Successful capture clears this condition; reveal clears it as well. Initial
apply/verification still has its original protection until an incomplete read is
observed. Sleep, a temporary native-menu lease, active menu interaction and
Command-drag continue to block repair.

The existing repair policy still requires two consecutive matching raw host
observations and retains its 30-second cooldown. It re-registers only MenuBox's
box and tape with their existing autosave names and collapsed marker state.
Missing identifiers are refreshed before escalating to recreation. Recovery does
not restart MenuBarAgent, change another app's visibility or reveal the hidden
section. Repair logs include per-display host counts for future diagnosis.

## Verification

A regression reproducing continuously queued checks failed on the old gate
(twelve blocked repair opportunities). With the fix it permits repair and settles
without additional visibility writes, restores or marker reveals. Additional
regressions cover the observed three-display host pattern and repair exclusion
during native-menu leases and sleep. The original initial-verification guard
regression remains in place.

Local observation evidence is in the ignored
`artifacts/display-replica-fix/` directory. The snapshots were taken from the
existing installed application; they confirm the failure, not deployment of the
new build. Final on-device recovery requires running the newly built app. macOS
can still drop host replicas; this fix removes the app's recovery deadlock.
