# Commander observation adapter

`unit_circuit_commander_observation.lua` is an optional BAR game gadget for
`LuaRules/Gadgets/` in a development game package. It is not an AI data script
or a spectator widget. Ordinary commander control works without it.

The gadget publishes local enemy projectile volumes only when visible to the
AI's ally team, plus exact owned transport status. CircuitAI rejects stale,
duplicate, future, malformed and oversized packets. It does not transmit
hidden enemy identities or grant access to an omniscient projectile feed.

Installation requires a game package containing the gadget on participating
clients. Source is provided here; the BAR reference and live installation are
not modified by the AI build. See the [implementation and integration limits](../../../rjm.bar.docs/projects/circuitai/reviews/2026-10-12-commander-combat.md).
