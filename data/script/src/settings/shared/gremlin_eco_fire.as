// Gremlins (armgremlin) fire only at enemy economy structures (owner, 2026-10-19).
// Off by default; experimental_balanced/main.as turns it on.
namespace Global {
namespace GremlinEcoFire {
        bool Enabled = false;
        // An economy structure counts as in reach within weapon range + this (elmos):
        // the engine acquires to the target's edge, and the Gremlin moves ~70 elmos/s.
        float ReachMargin = 40.0f;
        // Any other observed ground contact this far beyond weapon range keeps fire held,
        // so fire at will cannot pick an army unit, turret, wall or radar instead.
        float GuardMargin = 150.0f;
        // Re-send the wanted fire state this often even if unchanged (a retreat or
        // another task resets the Gremlin to its def's hold fire).
        int ResendSeconds = 5;
    }
}
