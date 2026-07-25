# Seamless agent reconnect

**Type**: Explanation (Diátaxis). For the stack these agents report to, see
[`architecture.md`](architecture.md); for the end-to-end proof that exercises this behaviour, see
[`../reference/poc-evidence.md`](../reference/poc-evidence.md).

A SIEM is only as good as its agents' willingness to come back. This document explains how agents
survive a manager rebuild without an operator touching them, and why the obvious fix was rejected.

## The requirement

The manager's OS disk is replaceable by design — that is the capability the end-to-end proof
exercises. When it is replaced, every agent must reconnect **on its own**. At fleet scale nobody
can log into thousands of endpoints to re-enroll them, so any design that needs a per-agent action
after a manager rebuild is not a design, it is an outage.

## What breaks by default

Two mechanisms in Wazuh 4.14.5 interact badly, and the failure is silent:

- **`remoted` refuses a key already in use.** If an agent reconnects while the manager still
  considers its previous session live, the connection is refused for up to
  `connection_overtake_time` (60s by default), plus up to another 10s of key-update lag.
- **Agents re-enroll rather than wait.** The stock retry budget — `max_retries` 5 at
  `retry_interval` 10 — gives up after roughly 40–55 seconds and falls back to enrollment. That is
  *inside* the refusal window.

`remoted` sends no negative acknowledgement for any of this; every failure looks like silence. So
an agent that should simply have waited instead re-enrolls, and a re-enrollment that collides with
the live registration leaves the agent registered, unconnectable, and irreplaceable.

## The design

Three properties, each verified against the wazuh/wazuh source at the version this repo pins:

**1. Enroll once.** An agent is enrolled by its first service start, which already has the final
configuration on disk. A configuration-changed restart moments later is a no-op for content but is
lethal to enrollment, because it drops the agent back into the refusal window. The role therefore
records whether the service was already running *before* it took ownership of the configuration,
and only restarts an agent that was already running the old configuration.

**2. Give reconnect a longer runway than the refusal window.** Both platforms' managed `<server>`
block sets `max_retries` 12 at `retry_interval` 10 — a 120-second runway against a 60-second
overtake window plus its key-update lag. An agent that merely lost its manager now always
reconnects rather than re-enrolling, because waiting outlasts the refusal.

**3. Keep the identity, so there is nothing to re-enroll.** `/var/ossec` is bind-mounted onto the
data disk before the packages are installed, so `client.keys`, `queue/rids`, and `queue/db/global.db`
live on the volume the OS swap does not touch. A rebuilt manager starts against the *existing*
registry: the agents' keys are already known, and a freshly started `remoted` holds no prior
session to overtake. These three files are one identity unit and must persist together — `authd`
refuses to replace an agent whose `global.db` row is missing, which would brick the name.

Two invariants keep that from silently regressing: the role refuses to proceed unless `/var/ossec`
really resolves to the data disk, and it captures a `client.keys` checksum before the package
install and asserts it unchanged afterwards.

## What was rejected, and why

The first fix for the deploy-time deadlock was an `authd` **zero-second force-replacement policy** —
let any re-enrolling agent immediately displace its own registration. It worked, and it was wrong:

- It is a **standing invitation to hijack**. Any party who can reach `authd` and name an existing
  agent takes over that agent's identity with no waiting period. The refusal window is a security
  control, and this deleted it fleet-wide to paper over a race this repo created.
- It **treats re-enrollment as normal**. Re-enrollment is a recovery path. A fleet whose steady
  state is "re-enroll on every hiccup" churns keys constantly and loses the audit value of a stable
  agent identity.

It was removed as a *negative* migration rather than a plain deletion: `ossec.conf` lives on the
persistent data disk, so simply dropping the task that wrote the block would have stranded it on
every already-deployed manager forever. The role now actively removes it, and `authd` returns to
its vendor defaults, where a live agent's name cannot be taken.

## Consequences

- A manager OS replacement is an unattended event for the fleet: no re-enrollment, no operator
  action, no key churn.
- The connected-state gate is load-bearing and stays. "Service running" is not "agent connected" —
  an agent can be registered, running, and mute. Deployment is only green when the agent's own
  state file says `connected`.
- The persistence guarantee is now enforced rather than assumed; if the data-disk bind is ever
  broken, the deploy fails loudly instead of quietly issuing every agent a new identity.

## Related

- [`architecture.md`](architecture.md) — the stack the agents report to.
- [`../reference/poc-evidence.md`](../reference/poc-evidence.md) — the recorded end-to-end run.
