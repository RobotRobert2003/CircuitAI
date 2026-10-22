namespace TechConversionProbe {
    bool checked=false;
    bool releaseChecked=false;
    void Tick() {
        if (ai.teamId==0 && !releaseChecked && ai.frame>=6*SECOND && ai.frame<10*SECOND) {
            const AIFloat3 home=TechWeapons::Base();
            AIFloat3 forward=home; forward.x+=Global::RoleSettings::Tech::WeaponBaseRadius+1.0f;
            const bool correct=TechWeapons::PlacementReleased(TechWeapons::AIR,home)
                && !TechWeapons::PlacementReleased(TechWeapons::KILL,forward)
                && !TechWeapons::PlacementReleased(TechWeapons::AIR,forward);
            GenericHelpers::LogUtil("[TechConversion] "+(correct ? "PASS" : "FAIL")+" forward defense waits for air economy",1);
            releaseChecked=true;
        }
        if (ai.teamId!=0 || ai.frame<20*SECOND || ai.frame%(30*SECOND)>=SECOND) return;
        const float headroom=EcoPlanner::TechConversionHeadroom();
        GenericHelpers::LogUtil("[TechConversion] headroom="+headroom+" converters="+EcoPlanner::Count("legadveconv")+" reactors="+EcoPlanner::Count("legafus"),1);
        if (!checked && headroom<0) {
            CCircuitUnit@ worker=ai.GetTeamUnit(TechBuild::airConvId);
            if (worker is null) return;
            EcoPlanner::State@ state=EcoPlanner::Read(worker,aiEconomyMgr.metal.income,aiEconomyMgr.energy.income);
            string why;
            const string result=EcoPlanner::PickConverter(state,aiEconomyMgr.energy.income,why);
            GenericHelpers::LogUtil("[TechConversion] "+(result=="" ? "PASS" : "FAIL")+" excess capacity rejects converter",1);
            checked=true;
        }
    }
}
