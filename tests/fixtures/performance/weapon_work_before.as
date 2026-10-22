// Frozen D-199 baseline weapon admission/selection, pre-optimization.
int OutstandingOrders()
    {
        int n = 0;
        for (uint i = 0; i < clusters.length(); ++i) {
            if (clusters[i].kind == SUPER) continue;
            for (uint j = 0; j < clusters[i].slots.length(); ++j) {
                Slot@ s = clusters[i].slots[j];
                if (s.standFrame >= 0 || s.dead) continue;
                // out: ordered in the last 30 s, or a frame going up (a failed order
                // no longer holds a place for a minute)
                if (ai.frame - s.orderedFrame < 30 * SECOND) { ++n; continue; }
                CCircuitDef@ d = Def(s.role);
                if (d !is null && ai.frame - s.orderedFrame < 300 * SECOND && aiBuilderMgr.FindUnfinishedNear(s.pos, 96.0f, d) !is null) ++n;
            }
        }
        return n;
    }
IUnitTask@ Work(CCircuitUnit@ u)
    {
        if (u is null || u.circuitDef is null || !Active()) return null;
        const bool air = UnitHelpers::IsAirConstructor(u.circuitDef);
        const AIFloat3 from = u.GetPos(ai.frame);
        const float mi = MetalIncome();
        for (uint i = 0; i < clusters.length(); ++i) {
            WCluster@ c = clusters[i];
            if (c.stale || mi < Gate(c.kind)) continue;
            if (c.kind == SUPER && !SuperStartable(c)) continue;
            if (!air && from.distance2D(c.pos) > Global::RoleSettings::Tech::WeaponWorkRadius) continue;
            const bool escort = (c.kind == SUPER);
            // a full metal bank: the economy has nothing to spend it on, so no budget and twice the orders
            const bool flooded = aiEconomyMgr.isMetalFull;
            if (!escort && OutstandingOrders() >= Global::RoleSettings::Tech::WeaponMaxConcurrent * (flooded ? 2 : 1)) return null;
            for (uint j = 0; j < c.slots.length(); ++j) {
                Slot@ s = c.slots[j];
                if (s.dead || s.standFrame >= 0 || ai.frame - s.orderedFrame < 60 * SECOND) continue;
                if (s.role == "art2" && mi < Global::RoleSettings::Tech::WeaponArtyMinIncome) continue;
                if (s.role == "super" && air) continue;   // the cannon itself: SuperTask frames it with all air build power
                CCircuitDef@ d = Def(s.role);
                if (d is null) { s.dead = true; continue; }
                if (!u.circuitDef.CanBuild(d)) continue;
                if (aiBuilderMgr.FindUnfinishedNear(s.pos, 64.0f, d) !is null) continue;   // going up: someone is on it
                if (!escort && !flooded && tokens < d.costM) {
                    if (ai.frame - lastBudgetLog > 30 * SECOND) {
                        lastBudgetLog = ai.frame;
                        GenericHelpers::LogUtil("[TECH][Weapons] budget: " + int(tokens) + " metal saved, " + d.GetName() + " costs " + int(d.costM) + " (D-126)", 2);
                    }
                    return null;
                }
                AIFloat3 at;
                if (!Site(s, d, at)) { s.dead = true; continue; }
                IUnitTask@ t = Order(u, c, s, d, at);
                if (t is null) continue;
                if (!escort) tokens -= d.costM;
                return t;
            }
        }
        return null;
    }
