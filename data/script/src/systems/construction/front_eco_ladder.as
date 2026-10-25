// FRONT eco ladder (owner, 2026-10-16; third fusion and earlier reclaim 2026-10-17): FRONT's eco climbs
// to metal enough for a gantry.
//   1. one fusion (the fusion the T2 vehicle plant's build chain puts behind it counts: every fusion
//      of ours, framed or queued, is one of the ladder's)
//   2. a second fusion; from the first fusion standing, winds, solars, advanced solars and T1
//      converters come down (systems/construction/front_reclaim.as) and T2 converters go up
//   3. a third fusion
//   4. an advanced fusion
//   5. a second advanced fusion; the fusions are reclaimed as it builds (their metal pays for it)
//   6. more advanced fusions, one after another, while metal income is under
//      Front::EcoLadderGantryMetalIncome (225); the gantry waits for that income, and is ordered at it from any stage
//      (roles/front/front.as Front_TryLadderGantry); none while the gantry is going up. Once the
//      gantry is framed, its Front::EcoLadderGantryNanos caretaker turrets are ordered, one at a time
//   7. the gantry stands: the rest of its turrets
//   8. advanced fusions again, one after another, up to Front::EcoLadderMaxAdvFusions
// From the first advanced fusion, up to Front::EcoLadderMetalStorages metal storages while storage is
// under a fusion's cost plus Front::EcoLadderStorageSpare, so the fusion refunds fit the bank.
// T2 converters (owner, 2026-10-17: "appropriate amount ... to avoid wasting energy"): from the
// first fusion, one more whenever the energy bank is at Front::EcoLadderConvertBankPercent and income
// beats the pull by a converter's draw (Front::EcoLadderT2ConverterEnergy) plus
// Front::EcoLadderT2ConverterReserve, up to Front::EcoLadderMaxT2Converters; one at a time.
// The stage also caps the native eco (economy.json asks for 30-40 fusions and build_chain.json rings
// each advanced fusion with 5 T2 converters): fusions at 3 (0 once the second advanced fusion is
// framed), advanced fusions at 2 (then EcoLadderMaxAdvFusions), T1 converters, winds and solars at 0
// from the first fusion, T2 converters at the ladder's count. Map limits still win (Front_IncomeLimits
// applies them after). Off unless the profile sets Front::EcoLadder (experimental_balanced/main.as).
// Log [FRONT][Eco].
namespace FrontEcoLadder {
    bool On() { return Global::RoleSettings::Front::EcoLadder && Global::AISettings::Role == AiRole::FRONT; }

    // stages
    const int S_FUS1 = 1, S_FUS2 = 2, S_FUS3 = 3, S_AFUS1 = 4, S_AFUS2 = 5, S_GANTRY = 6, S_TURRETS = 7, S_AFTER = 8;
    const int Fusions_Wanted = 3;   // before the first advanced fusion

    string Side() { return Global::AISettings::Side; }
    CCircuitDef@ Def(const string &in name) { return ai.GetCircuitDef(name); }
    // standing and framed
    int Total(const string &in name) { CCircuitDef@ d = Def(name); return d is null ? 0 : d.count; }
    // standing finished
    int Done(const string &in name) { CCircuitDef@ d = Def(name); return d is null ? 0 : AiMax(0, d.count - aiBuilderMgr.GetUnfinishedCount(d)); }

    int Fusions() { return Done(UnitHelpers::GetFusionNameForSide(Side())); }
    int FusionsTotal() { return Total(UnitHelpers::GetFusionNameForSide(Side())); }
    // framed, standing and queued by anyone (the T2 vehicle plant's build chain, the native eco)
    int FusionsPlanned()
    {
        CCircuitDef@ d = Def(UnitHelpers::GetFusionNameForSide(Side()));
        return d is null ? 0 : d.count + aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::ENERGY), d);
    }
    int AdvFusions() { return Done(UnitHelpers::GetAdvFusionNameForSide(Side())); }
    int AdvFusionsTotal() { return Total(UnitHelpers::GetAdvFusionNameForSide(Side())); }
    int Gantries() { return UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllLandGantries()); }

    // Our finished land gantry with the fewest turrets ordered, null if none stands
    CCircuitUnit@ GantryStanding()
    {
        CCircuitUnit@ best = null;
        for (uint i = 0; i < Factory::factoryList.length(); ++i) {
            CCircuitUnit@ f = Factory::factoryList[i];
            if (f is null || f.circuitDef is null || f.GetBuildProgress() < 1.0f || !UnitHelpers::IsLandGantry(f.circuitDef.GetName())) continue;
            if (best is null || Factory::_GetNanoCount(f) < Factory::_GetNanoCount(best)) @best = f;
        }
        return best;
    }
    bool GantryGoingUp()
    {
        CCircuitDef@ g = Def(UnitHelpers::GetLandGantryForSide(Side()));
        return (g !is null && aiBuilderMgr.GetUnfinishedCount(g) > 0) || Builder::LandGantryQueuedCount > 0;
    }
    // Our land gantry frame, null if none is going up (looked up at most every 5 s)
    int gantryFrameId = -1;
    int gantryFrameLook = -100000;
    CCircuitUnit@ GantryFrame()
    {
        CCircuitDef@ g = Def(UnitHelpers::GetLandGantryForSide(Side()));
        if (g is null || aiBuilderMgr.GetUnfinishedCount(g) < 1) { gantryFrameId = -1; return null; }
        if (gantryFrameId >= 0) {
            CCircuitUnit@ f = ai.GetTeamUnit(gantryFrameId);
            if (f !is null && f.circuitDef is g && f.GetBuildProgress() < 1.0f) return f;
            gantryFrameId = -1;
        }
        if (ai.frame - gantryFrameLook < 5 * SECOND) return null;
        gantryFrameLook = ai.frame;
        array<Id>@ ids = ai.GetOwnedUnitIds();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
            if (u is null || u.circuitDef is null || u.GetBuildProgress() >= 1.0f || !UnitHelpers::IsLandGantry(u.circuitDef.GetName())) continue;
            gantryFrameId = u.id;
            return u;
        }
        return null;
    }

    // 1-3 fusions, 4 advanced fusion, 5 second advanced fusion, 6 advanced fusions to the gantry's metal,
    // the gantry and (once it is framed) its turrets, 7 the standing gantry's turrets, 8 advanced fusions
    // after the gantry
    int Stage()
    {
        const int afus = AdvFusions();
        // the gantry step from Front::EcoLadderGantryAfterAdvFusions advanced fusions (2; 1 in
        // experimental_balanced, owner 2026-10-19: played on All That Glitters, FRONTs at +200-300 metal
        // income waited past 25 minutes for their second advanced fusion)
        if (afus >= AiMax(1, Global::RoleSettings::Front::EcoLadderGantryAfterAdvFusions)) {
            CCircuitUnit@ g = GantryStanding();
            if (g is null) return S_GANTRY;
            return Factory::_GetNanoCount(g) < Global::RoleSettings::Front::EcoLadderGantryNanos ? S_TURRETS : S_AFTER;
        }
        if (afus >= 1) return S_AFUS2;
        const int fus = Fusions();
        if (fus >= Fusions_Wanted) return S_AFUS1;
        if (fus >= 2) return S_FUS3;
        if (fus >= 1) return S_FUS2;
        return S_FUS1;
    }
    string StageName(int s)
    {
        if (s == S_FUS1) return "first fusion";
        if (s == S_FUS2) return "second fusion";
        if (s == S_FUS3) return "third fusion";
        if (s == S_AFUS1) return "first advanced fusion";
        if (s == S_AFUS2) return "second advanced fusion";
        if (s == S_GANTRY) return "advanced fusions to the gantry's metal";
        if (s == S_TURRETS) return "gantry turrets";
        return "advanced fusions after the gantry";
    }

    // front_reclaim.as: winds, solars, advanced solars and T1 converters come down once the first
    // fusion stands (owner, 2026-10-17)
    bool FirstFusionStands() { return On() && (Fusions() >= 1 || AdvFusions() >= 1); }
    bool ReclaimT1Converters() { return FirstFusionStands(); }
    // ... and fusions once the second advanced fusion is framed
    bool ReclaimFusions() { return On() && AdvFusions() >= 1 && AdvFusionsTotal() >= 2; }
    bool SecondAdvFusionStands() { return AdvFusions() >= 2; }
    // eco_planner.as OutputOf
    float FusionOutput(const string &in name)
    {
        if (name == "corfus") return 850.0f;
        if (name == "legfus") return 950.0f;
        return 750.0f;
    }

    // Metal storage for the fusion refunds (front_reclaim.as waits until one fits the bank)
    string StorageName() { return UnitHelpers::GetMetalStorageNameForSide(Side()); }
    bool StoragesDone() { return Total(StorageName()) >= Global::RoleSettings::Front::EcoLadderMetalStorages; }
    IUnitTask@ Storage(CCircuitUnit@ u)
    {
        CCircuitDef@ d = Def(StorageName());
        CCircuitDef@ fus = Def(UnitHelpers::GetFusionNameForSide(Side()));
        if (d is null || fus is null || FusionsTotal() < 1 || StoragesDone()) return null;
        if (!u.circuitDef.CanBuild(d) || !d.IsAvailable(ai.frame) || Pending(d, Task::BuildType::STORE) > 0) return null;
        if (aiEconomyMgr.metal.storage >= fus.costM + Global::RoleSettings::Front::EcoLadderStorageSpare) return null;
        IUnitTask@ t = aiBuilderMgr.Enqueue(TaskB::Common(Task::BuildType::STORE, Task::Priority::NORMAL, d, Anchor(), SQUARE_SIZE * 32, true, 120 * SECOND));
        if (t !is null) GenericHelpers::LogUtil("[FRONT][Eco] metal storage " + (d.count + 1) + "/" + Global::RoleSettings::Front::EcoLadderMetalStorages
            + " for the fusion refunds (" + int(fus.costM) + " each, storage " + int(aiEconomyMgr.metal.storage) + ") by " + u.circuitDef.GetName() + " " + u.id, 1);
        return t;
    }

    // T2 converters for the energy we would waste: one more than we have while the bank is up and income
    // beats the pull by a converter's draw and the reserve; as many as we have otherwise (the native
    // eco and the advanced fusions' build chain capped to it too)
    int T2ConverterTarget(int s)
    {
        CCircuitDef@ d = Def(UnitHelpers::GetAdvEnergyConverterNameForSide(Side()));
        if (s < S_FUS2 || d is null) return 0;
        const int have = d.count;
        const float spare = aiEconomyMgr.energy.income - aiEconomyMgr.energy.pull;
        // or the bank is nearly full: the pull counts demand that is not being met, and with a full bank
        // the energy above it is lost (played p17c, All That Glitters +75: banks full 13-41% of the time
        // with pull above income)
        const bool full = aiEconomyMgr.energy.storage > 0.0f && aiEconomyMgr.energy.current >= aiEconomyMgr.energy.storage * Global::RoleSettings::Front::EcoLadderConvertFullPercent;
        const bool surplus = ConvertBankOk()
            && (full || spare >= Global::RoleSettings::Front::EcoLadderT2ConverterEnergy + Global::RoleSettings::Front::EcoLadderT2ConverterReserve);
        return AiMin(Global::RoleSettings::Front::EcoLadderMaxT2Converters, surplus ? have + 1 : have);
    }
    // Advanced fusions wanted, standing and framed: past two, one more at a time while metal income is
    // under the gantry's
    int AdvFusionTarget(int s, float metalIncome)
    {
        if (s <= S_FUS3) return 0;
        if (s == S_AFUS1) return 1;
        if (s == S_AFUS2) return 2;
        if (Global::RoleSettings::Front::EcoLadderGantryAfterAdvFusions <= 1) {
            // gantry after one advanced fusion: the second goes up alongside the gantry once that is ordered
            // (the gantry and its turrets first for metal); none past two before the gantry stands with its turrets
            if (s == S_TURRETS) return 2;
            if (s == S_GANTRY && metalIncome >= Global::RoleSettings::Front::EcoLadderGantryMetalIncome)
                return GantryGoingUp() || Gantries() > 0 ? 2 : AdvFusions();
            if (s == S_GANTRY) return AiMin(Global::RoleSettings::Front::EcoLadderMaxAdvFusions, AdvFusions() + 1);
        }
        if (s == S_TURRETS) return 0;   // the gantry's turrets first
        if (s == S_GANTRY && (metalIncome >= Global::RoleSettings::Front::EcoLadderGantryMetalIncome || GantryGoingUp())) return 0;
        return AiMin(Global::RoleSettings::Front::EcoLadderMaxAdvFusions, AdvFusions() + 1);
    }

    // The values the ladder found on each def before it first capped it
    dictionary original;
    void Cap(const string &in name, int cap)
    {
        CCircuitDef@ d = Def(name);
        if (d is null) return;
        int was;
        if (!original.get(name, was)) { was = d.maxThisUnit; original.set(name, was); }
        if (cap < 0 || (was >= 0 && was < cap)) cap = was;   // never above what was there before
        if (d.maxThisUnit != cap) {
            d.maxThisUnit = cap;
            GenericHelpers::LogUtil("[FRONT][Eco] cap " + name + " = " + cap, 3);
        }
    }

    // Caretaker turrets standing within GantryNanoRadius of our gantry (frame or standing)
    const float GantryNanoRadius = 500.0f;
    int GantryTurretsDone(CCircuitUnit@ g)
    {
        CCircuitDef@ nano = Def(UnitHelpers::GetT1NanoNameForSide(Side()));
        if (g is null || nano is null) return 0;
        const AIFloat3 at = g.GetPos(ai.frame);
        int n = 0;
        array<Id>@ ids = ai.GetOwnedUnitIds();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
            if (u is null || u.circuitDef !is nano || u.GetBuildProgress() < 1.0f) continue;
            if (MapHelpers::SqDist(u.GetPos(ai.frame), at) <= GantryNanoRadius * GantryNanoRadius) n++;
        }
        return n;
    }

    int lastStage = 0;
    int lastLog = -100000;
    // Front_IncomeLimits, before the map limits
    void ApplyCaps()
    {
        if (!On()) return;
        const string side = Side();
        const int s = Stage();
        const bool fusionEra = s >= S_FUS2;
        Cap(UnitHelpers::GetFusionNameForSide(side), (s >= S_GANTRY || ReclaimFusions()) ? 0 : Fusions_Wanted);   // none rebuilt while they come down
        Cap(UnitHelpers::GetAdvFusionNameForSide(side), s >= S_GANTRY ? Global::RoleSettings::Front::EcoLadderMaxAdvFusions : 2);
        Cap(UnitHelpers::GetEnergyConverterNameForSide(side), fusionEra ? 0 : -1);
        const int t2Target = T2ConverterTarget(s);
        Cap(UnitHelpers::GetAdvEnergyConverterNameForSide(side), t2Target);
        Cap(UnitHelpers::GetWindNameForSide(side), fusionEra ? 0 : -1);
        Cap(UnitHelpers::GetSolarNameForSide(side), fusionEra ? 0 : -1);
        Cap(UnitHelpers::GetAdvSolarNameForSide(side), fusionEra ? 0 : -1);
        if (s != lastStage || ai.frame - lastLog >= Global::RoleSettings::Front::EcoLadderLogSeconds * SECOND) {
            CCircuitUnit@ g = GantryStanding();
            if (g is null) @g = GantryFrame();
            GenericHelpers::LogUtil("[FRONT][Eco] stage " + s + " (" + StageName(s) + ")" + (s != lastStage && lastStage > 0 ? " from " + lastStage : "")
                + " | fusions " + Fusions() + "/" + FusionsTotal() + "/" + FusionsPlanned() + " adv " + AdvFusions() + "/" + AdvFusionsTotal()
                + " | T1 conv " + Total(UnitHelpers::GetEnergyConverterNameForSide(side))
                + " T2 conv " + Total(UnitHelpers::GetAdvEnergyConverterNameForSide(side)) + "/" + t2Target
                + " | gantries " + Gantries() + (g is null ? "" : " (" + int(g.GetBuildProgress() * 100.0f) + "%, turrets " + GantryTurretsDone(g)
                    + " standing, " + Factory::_GetNanoCount(g) + " ordered)")
                + " | ladder T2 ctors " + (Builder::primaryT2BotConstructor !is null ? "B" : "-") + (Builder::secondaryT2BotConstructor !is null ? "b" : "-")
                + (Builder::primaryT2VehConstructor !is null ? "V" : "-") + (Builder::secondaryT2VehConstructor !is null ? "v" : "-")
                + " of " + (UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2BotConstructors()) + UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2VehicleConstructors()))
                + " | M +" + int(Economy::GetMinMetalIncomeLast10s()) + " bank " + int(aiEconomyMgr.metal.current)
                + " | E +" + int(aiEconomyMgr.energy.income) + " pull " + int(aiEconomyMgr.energy.pull)
                + " bank " + int(aiEconomyMgr.energy.current) + "/" + int(aiEconomyMgr.energy.storage), 1);
            lastStage = s; lastLog = ai.frame;
        }
    }

    // Eco stands behind the start, away from the map centre, clear of the factory exits
    const float EdgeMargin = 640.0f;
    AIFloat3 Anchor()
    {
        const AIFloat3 start = Global::Map::StartPos;
        const float w = float(aiTerrainMgr.GetTerrainWidth()), h = float(aiTerrainMgr.GetTerrainHeight());
        const float dx = start.x - w * 0.5f, dz = start.z - h * 0.5f;
        const float len = sqrt(dx * dx + dz * dz);
        if (len < 1.0f) return start;
        // never nearer the map edge than EdgeMargin (played h26, All That Glitters: a corner start put
        // the anchor at 202,9993, on the edge)
        const float back = Global::RoleSettings::Front::EcoLadderAnchorBack;
        const float m = AiMin(EdgeMargin, AiMin(w, h) * 0.25f);
        return AIFloat3(AiMax(m, AiMin(w - m, start.x + dx / len * back)), start.y,
            AiMax(m, AiMin(h - m, start.z + dz / len * back)));
    }

    // Gantry spots away from the fight (owner, 2026-10-17): the eco anchor behind the start, the start,
    // then 600 and 1200 to each side across the start-centre line, and only then 600 toward the centre;
    // each kept EdgeMargin off the map edge. Played (p17c, All That Glitters +75): the engine-sited
    // fallback walked 600 a step toward the centre; on the pressed side every frame there was killed or
    // left as its builder died, and four FRONTs had no gantry at 45 minutes.
    AIFloat3 Clamped(float x, float z)
    {
        const float w = float(aiTerrainMgr.GetTerrainWidth()), h = float(aiTerrainMgr.GetTerrainHeight());
        const float m = AiMin(EdgeMargin, AiMin(w, h) * 0.25f);
        return AIFloat3(AiMax(m, AiMin(w - m, x)), 0.0f, AiMax(m, AiMin(h - m, z)));
    }
    array<AIFloat3>@ GantryAnchors()
    {
        array<AIFloat3> a;
        const AIFloat3 start = Global::Map::StartPos;
        a.insertLast(Anchor());
        a.insertLast(Clamped(start.x, start.z));
        const float dx = float(aiTerrainMgr.GetTerrainWidth()) * 0.5f - start.x, dz = float(aiTerrainMgr.GetTerrainHeight()) * 0.5f - start.z;
        const float len = sqrt(dx * dx + dz * dz);
        if (len < 1.0f) return a;
        const float ux = dx / len, uz = dz / len;   // toward the centre
        for (int k = 1; k <= 2; ++k) {
            const float s = 600.0f * float(k);
            a.insertLast(Clamped(start.x - uz * s, start.z + ux * s));
            a.insertLast(Clamped(start.x + uz * s, start.z - ux * s));
        }
        a.insertLast(Clamped(start.x + ux * 600.0f, start.z + uz * 600.0f));
        return a;
    }

    bool Affordable(CCircuitDef@ d, float metalIncome, float required)
    {
        return metalIncome >= required || aiEconomyMgr.metal.current >= d.costM * Global::RoleSettings::Front::EcoLadderStoredFraction;
    }
    int Pending(CCircuitDef@ d, Task::BuildType type)
    {
        return aiBuilderMgr.GetQueuedBuildCount(int(type), d) + aiBuilderMgr.GetUnfinishedCount(d);
    }
    bool ConvertBankOk()
    {
        return !aiEconomyMgr.isEnergyStalling && aiEconomyMgr.energy.storage > 0.0f
            && aiEconomyMgr.energy.current >= aiEconomyMgr.energy.storage * Global::RoleSettings::Front::EcoLadderConvertBankPercent;
    }

    IUnitTask@ Converter(CCircuitUnit@ u, CCircuitDef@ d, int target, const string &in label)
    {
        if (d is null || !u.circuitDef.CanBuild(d) || !d.IsAvailable(ai.frame)) return null;
        if (d.count >= target || Pending(d, Task::BuildType::CONVERT) > 0 || !ConvertBankOk()) return null;
        IUnitTask@ t = aiBuilderMgr.Enqueue(TaskB::Common(Task::BuildType::CONVERT, Task::Priority::NORMAL, d, Anchor(), SQUARE_SIZE * 32, true, 120 * SECOND));
        if (t !is null) GenericHelpers::LogUtil("[FRONT][Eco] " + label + " " + (d.count + 1) + "/" + target + " " + d.GetName()
            + " by " + u.circuitDef.GetName() + " " + u.id + " | E +" + int(aiEconomyMgr.energy.income) + " pull " + int(aiEconomyMgr.energy.pull)
            + " bank " + int(aiEconomyMgr.energy.current), 1);
        return t;
    }

    // A caretaker turret for our gantry, one at a time (as Front_TryFirstT2LabNano), by any of our
    // constructors that can build one within GantryNanoReach. Owner (2026-10-17): the turrets are tasked
    // as soon as the gantry is framed, so they stand (and help it up) before it finishes. Played (h25,
    // All That Glitters +75): no turret in 5 minutes of stage 6; the overflow kept turrets queued for an
    // advanced vehicle plant, which the old "any turret queued" check read as ours, and only the
    // ladder's T1 constructors asked.
    int nanoLog = -100000;
    IUnitTask@ nanoTask = null;
    const float GantryNanoReach = 3000.0f;
    IUnitTask@ GantryNano(CCircuitUnit@ u, CCircuitUnit@ g)
    {
        CCircuitDef@ nano = Def(UnitHelpers::GetT1NanoNameForSide(Side()));
        if (nano is null || g is null || !u.circuitDef.CanBuild(nano)) return null;
        const int have = Factory::_GetNanoCount(g), want = Global::RoleSettings::Front::EcoLadderGantryNanos;
        if (have >= want) return null;
        const AIFloat3 at = g.GetPos(ai.frame);
        if (MapHelpers::SqDist(u.GetPos(ai.frame), at) > GantryNanoReach * GantryNanoReach) return null;
        CCircuitUnit@ frame = aiBuilderMgr.FindUnfinishedNear(at, GantryNanoRadius, nano);
        if (frame !is null) return aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::HIGH, frame, 30 * SECOND));
        if (nanoTask !is null && !nanoTask.IsDead()) return null;   // ours is ordered, not framed yet
        // the energy-based turret cap is lifted by one for it, as for an overflow turret
        if (nano.maxThisUnit >= 0 && nano.count >= nano.maxThisUnit) nano.maxThisUnit = nano.count + 1;
        IUnitTask@ t = Factory::EnqueueNanoForFactory(g, Task::Priority::HIGH);
        @nanoTask = t;
        if (t !is null || ai.frame - nanoLog > 30 * SECOND) {
            nanoLog = ai.frame;
            GenericHelpers::LogUtil("[FRONT][Eco] gantry turret " + (have + 1) + " of " + want + " for " + g.circuitDef.GetName() + " " + g.id
                + " (" + (g.GetBuildProgress() < 1.0f ? "frame " + int(g.GetBuildProgress() * 100.0f) + "%" : "standing") + ")"
                + (t is null ? ": no site" : " ordered by " + u.circuitDef.GetName() + " " + u.id), 1);
        }
        return t;
    }

    // The ladder's reactor frame gets builders until it stands, up to Front::EcoLadderFrameHelpers at a
    // time. Played (h25, Scylla +75, a81efa5): an advanced fusion framed at 19:59 was still a frame at
    // 38:59 (stage 3 throughout, metal bank 0-250, income +93 to +278); nothing helped it.
    array<IUnitTask@> frameHelpers;
    int frameLog = -100000;
    IUnitTask@ HelpFrame(CCircuitUnit@ u, int s)
    {
        for (int i = int(frameHelpers.length()) - 1; i >= 0; --i)
            if (frameHelpers[i] is null || frameHelpers[i].IsDead()) frameHelpers.removeAt(i);
        if (frameHelpers.length() >= uint(Global::RoleSettings::Front::EcoLadderFrameHelpers)) return null;
        // the gantry frame first (played p17c, All That Glitters +75: a frame left while its builder was away
        // was lost), then the stage's reactor
        string what = "";
        CCircuitUnit@ frame = null;
        const AIFloat3 wp = u.GetPos(ai.frame);
        const float r = Global::RoleSettings::Front::EcoLadderFrameHelpRadius;
        if (s == S_GANTRY) {
            CCircuitUnit@ g = GantryFrame();
            if (g !is null && MapHelpers::SqDist(wp, g.GetPos(ai.frame)) <= r * r) { @frame = g; what = g.circuitDef.GetName(); }
        }
        if (frame is null) {
            CCircuitDef@ reactor = Def(s <= S_FUS3 ? UnitHelpers::GetFusionNameForSide(Side()) : UnitHelpers::GetAdvFusionNameForSide(Side()));
            if (reactor is null || aiBuilderMgr.GetUnfinishedCount(reactor) < 1) return null;
            @frame = aiBuilderMgr.FindUnfinishedNear(wp, r, reactor);
            what = reactor.GetName();
        }
        if (frame is null) return null;
        IUnitTask@ t = aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::HIGH, frame, 120 * SECOND));
        if (t is null) return null;
        frameHelpers.insertLast(t);
        if (ai.frame - frameLog >= 30 * SECOND) {
            frameLog = ai.frame;
            GenericHelpers::LogUtil("[FRONT][Eco] helping " + what + " " + frame.id + " (" + int(frame.GetBuildProgress() * 100.0f) + "%) with "
                + u.circuitDef.GetName() + " " + u.id + ", helpers " + frameHelpers.length() + " | M +" + int(Economy::GetMinMetalIncomeLast10s())
                + " bank " + int(aiEconomyMgr.metal.current), 1);
        }
        return t;
    }

    // The ladder's own reactor order: aborted when no frame of it appears within ReactorFrameSeconds, and
    // the next order tries the next site (eco anchor, start, 600 toward the centre), after a pause that
    // grows by 30 s with each failure in a row (to 120 s)
    IUnitTask@ reactorTask = null;
    int reactorOrdered = -1;
    int reactorBefore = 0;
    int reactorTry = 0;
    int reactorHoldLog = -100000;
    int reactorFails = 0;          // aborted orders in a row
    int reactorRetry = -1;         // no new order before this frame
    const int ReactorFrameSeconds = 90;
    // later advanced fusions (Front::EcoLadderLaterAdvFusionAtStart, on in experimental_balanced) start the
    // rotation at the start, not the eco anchor (owner, 2026-10-19: on a corner start the anchor already held
    // the fusions and the first advanced fusion, and the second's order there never framed)
    AIFloat3 ReactorAnchor(int first = 0)
    {
        const int k = (reactorTry + first) % 3;
        if (k == 1) return Global::Map::StartPos;
        if (k == 2) {
            // played (h27, Scylla +75, corner start): the preferred factory spot was the failed gantry spot
            // and the advanced fusion ordered there never framed
            const AIFloat3 start = Global::Map::StartPos;
            const AIFloat3 centre(float(aiTerrainMgr.GetTerrainWidth()) * 0.5f, 0.0f, float(aiTerrainMgr.GetTerrainHeight()) * 0.5f);
            const float d = sqrt(MapHelpers::SqDist(start, centre));
            if (d > 1.0f) {
                const float f = AiMin(600.0f, d) / d;
                return AIFloat3(start.x + (centre.x - start.x) * f, start.y, start.z + (centre.z - start.z) * f);
            }
            return start;
        }
        return Anchor();
    }
    void ReactorHeld(const string &in why)
    {
        if (ai.frame - reactorHoldLog < 60 * SECOND) return;
        reactorHoldLog = ai.frame;
        GenericHelpers::LogUtil("[FRONT][Eco] reactor held: " + why, 1);
    }
    void WatchReactor(CCircuitDef@ reactor)
    {
        if (reactorTask is null) return;
        if (reactorTask.IsDead()) { @reactorTask = null; return; }
        if (reactor.count > reactorBefore || aiBuilderMgr.GetUnfinishedCount(reactor) > 0) { @reactorTask = null; reactorFails = 0; return; }   // framed
        if (ai.frame - reactorOrdered < ReactorFrameSeconds * SECOND) return;
        // played (h27, Scylla +75): T15 re-ordered its third advanced fusion six times in a row, none framed
        reactorFails++;
        const int wait = 30 * (reactorFails < 4 ? reactorFails : 4);
        reactorRetry = ai.frame + wait * SECOND;
        GenericHelpers::LogUtil("[FRONT][Eco] " + reactor.GetName() + " order never framed in " + ReactorFrameSeconds + " s (" + reactorFails
            + " in a row, bank " + int(aiEconomyMgr.metal.current) + "); aborted, next site in " + wait + " s", 1);
        aiBuilderMgr.AbortTask(reactorTask);
        @reactorTask = null;
        reactorTry++;
    }

    bool IsLadderT1(CCircuitUnit@ u)
    {
        return u is Builder::primaryT1BotConstructor || u is Builder::secondaryT1BotConstructor
            || u is Builder::primaryT1VehConstructor || u is Builder::secondaryT1VehConstructor;
    }
    bool IsLadderT2(CCircuitUnit@ u)
    {
        return u is Builder::primaryT2BotConstructor || u is Builder::secondaryT2BotConstructor
            || u is Builder::primaryT2VehConstructor || u is Builder::secondaryT2VehConstructor;
    }

    // Front_BuilderAiMakeTask, after the reclaim and before the native default task
    IUnitTask@ Work(CCircuitUnit@ u)
    {
        if (!On() || u is null || u.circuitDef is null || UnitHelpers::IsCommander(u.circuitDef)) return null;
        const string side = Side();
        const int s = Stage();
        // the gantry's turrets, from the moment it is framed
        if (s == S_TURRETS || s == S_GANTRY) {
            CCircuitUnit@ g = s == S_TURRETS ? GantryStanding() : GantryFrame();
            if (g !is null) {
                IUnitTask@ turret = GantryNano(u, g);
                if (turret !is null) return turret;
            }
        }
        if (IsLadderT1(u)) {
            if (s >= S_AFUS2) {
                IUnitTask@ store = Storage(u);
                if (store !is null) return store;
            }
            return HelpFrame(u, s);
        }
        if (!IsLadderT2(u)) return null;
        if (s >= S_AFUS2) {
            IUnitTask@ store = Storage(u);
            if (store !is null) return store;
        }
        const float mi = Economy::GetMinMetalIncomeLast10s();
        const bool fusionStep = s <= S_FUS3;
        CCircuitDef@ reactor = Def(fusionStep ? UnitHelpers::GetFusionNameForSide(side) : UnitHelpers::GetAdvFusionNameForSide(side));
        const int want = fusionStep ? s : AdvFusionTarget(s, mi);
        // fusions: every one of ours counts, framed or queued by the build chain or the native eco
        const int have = fusionStep ? FusionsPlanned() : AdvFusionsTotal();
        if (reactor !is null) WatchReactor(reactor);
        if (reactor !is null && u.circuitDef.CanBuild(reactor) && have < want) {
            const float need = fusionStep ? Global::RoleSettings::Front::EcoLadderFusionMetalIncome : Global::RoleSettings::Front::EcoLadderAdvFusionMetalIncome;
            if (reactorTask !is null) ReactorHeld(reactor.GetName() + " " + (have + 1) + "/" + want + ": our order is open, not framed yet ("
                + ((ai.frame - reactorOrdered) / SECOND) + " of " + ReactorFrameSeconds + " s)");
            else if (ai.frame < reactorRetry) ReactorHeld(reactor.GetName() + " " + (have + 1) + "/" + want + ": pause after " + reactorFails
                + " orders that never framed (" + ((reactorRetry - ai.frame) / SECOND) + " s left)");
            else if (!Affordable(reactor, mi, need)) ReactorHeld(reactor.GetName() + " " + (have + 1) + "/" + want + ": metal income +" + int(mi)
                + " of " + int(need) + ", bank " + int(aiEconomyMgr.metal.current) + " of " + int(reactor.costM * Global::RoleSettings::Front::EcoLadderStoredFraction));
            else {
                // ordered here, not through Builder::EnqueueFUS/AFUS: their queued counters stayed up for an
                // order that never framed and refused every later one (played h26, Scylla +75: T15's first fusion
                // ordered at 15:02 never framed and none was ordered again to 22:05)
                const int first = (!fusionStep && Global::RoleSettings::Front::EcoLadderLaterAdvFusionAtStart && AdvFusionsTotal() >= 1) ? 1 : 0;
                const AIFloat3 at = ReactorAnchor(first);
                IUnitTask@ t = aiBuilderMgr.Enqueue(TaskB::Common(Task::BuildType::ENERGY, Task::Priority::HIGH, reactor, at, SQUARE_SIZE * 32, true, 0));
                if (t !is null) {
                    if (fusionStep) @Builder::FusionBuildTask = t; else @Builder::AdvancedFusionBuildTask = t;
                    @reactorTask = t; reactorOrdered = ai.frame; reactorBefore = fusionStep ? FusionsTotal() : have;
                    GenericHelpers::LogUtil("[FRONT][Eco] " + StageName(s) + ": " + reactor.GetName() + " " + (have + 1) + "/" + want
                        + " at " + int(at.x) + "," + int(at.z) + (reactorTry + first > 0 ? " (site " + ((reactorTry + first) % 3 + 1) + " of 3)" : "")
                        + " by " + u.circuitDef.GetName() + " " + u.id + " | M +" + int(mi) + " bank " + int(aiEconomyMgr.metal.current), 1);
                    return t;
                }
                ReactorHeld(reactor.GetName() + " could not be ordered at " + int(at.x) + "," + int(at.z));
                reactorTry++;
            }
        }
        // the reactor is going up: help it, then a converter if one is due
        IUnitTask@ help = HelpFrame(u, s);
        if (help !is null) return help;
        return Converter(u, Def(UnitHelpers::GetAdvEnergyConverterNameForSide(side)), T2ConverterTarget(s), "T2 converter");
    }
}
