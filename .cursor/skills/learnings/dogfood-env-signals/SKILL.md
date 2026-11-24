---
name: dogfood-env-signals
description: >-
  MUST be used when an ai-flow test asserts that a spawned child did or
  did not receive an env key the dispatcher exports to the agent (the
  isolation overlay, the preserved allowlist, the auth slots).
---

# The suite runs inside the posture it tests — assert a marker, not the key

ai-flow's own tests run under ai-flow: a /build pass executes them as the
agent user, so every key the dispatcher exports to the agent
(`AGENT_CLI_CREDENTIAL_STORE`, the preserved allowlist, once `GEM_HOME`)
is already in the test process's `ENV` and inherits into every child.
A child seeing the key therefore proves nothing, and a child *not* seeing
it cannot be asserted at all. The test double at the seam injects a key of
its own (`MarkerIsolation#redirect_env` merges `AI_FLOW_OVERLAY_MARKER`)
and the test asserts that marker's presence or absence; the real overlay's
content is asserted on the policy object directly, never through a spawn.

Wrong:

```ruby
executor.stream(RUBY, "-e", 'puts ENV.key?("AGENT_CLI_CREDENTIAL_STORE")') # true on a host that set it
lines == ["false"]
```

Right:

```ruby
class MarkerIsolation < AiFlow::AgentIsolation
  def redirect_env = super.merge("AI_FLOW_OVERLAY_MARKER" => "yes")
end
executor.stream(RUBY, "-e", 'puts ENV.key?("AI_FLOW_OVERLAY_MARKER")')
lines == ["false"]
```

learned-from: ai-flow#107 (the non-isolated-stream test went red on the
agent host because the host env carried the overlay's one key); the
earlier `GEM_HOME` instance lived as a comment in the same test.
date: 2026-11-24
