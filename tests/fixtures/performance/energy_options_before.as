// D-199 frozen reference from 195f5e7a; do not update to match the optimized code.
array<Option@> EnergyOptions(const State@ s)
    {
        const string side = Global::AISettings::Side;
        array<Option@> opts;
        Option@ o;
        @o = Make("solar", UnitHelpers::GetSolarNameForSide(side), s, false); if (o !is null) opts.insertLast(o);
        @o = Make("advsolar", UnitHelpers::GetAdvSolarNameForSide(side), s, false);
        if (o !is null && (s.mIncome >= Global::RoleSettings::Tech::EcoAdvSolarMinMetalIncome || s.mCur >= o.cost)) opts.insertLast(o);
        @o = Make("wind", UnitHelpers::GetWindNameForSide(side), s, false);
        if (o !is null && WindEffective(s) >= Global::RoleSettings::Tech::EcoWindMinimum) opts.insertLast(o);
        if (s.builderIsT2) {
            @o = Make("fusion", UnitHelpers::GetFusionNameForSide(side), s, true);
            if (o !is null && s.mIncome >= Global::RoleSettings::Tech::MinimumMetalIncomeForFUS) opts.insertLast(o);
            @o = Make("afus", UnitHelpers::GetAdvFusionNameForSide(side), s, true);
            if (o !is null && s.mIncome >= Global::RoleSettings::Tech::MinimumMetalIncomeForAFUS) opts.insertLast(o);
        }
        // affordable first, then metal per E/s, then the larger output
        array<Option@> sorted;
        for (uint i = 0; i < opts.length(); ++i) {
            Option@ c = opts[i];
            uint at = sorted.length();
            for (uint k = 0; k < sorted.length(); ++k) {
                const bool ca = Affordable(c, s);
                const bool ka = Affordable(sorted[k], s);
                if (ca && !ka) { at = k; break; }
                if (ca == ka && (c.metalPerE < sorted[k].metalPerE || (c.metalPerE == sorted[k].metalPerE && c.output > sorted[k].output))) { at = k; break; }
            }
            sorted.insertAt(at, c);
        }
        return sorted;
    }
