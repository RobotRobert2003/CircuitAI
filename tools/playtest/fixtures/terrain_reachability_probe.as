namespace TerrainReachProbe {
    int commander = -1;
    bool exerciseTasks = false;
    IUnitTask@ invalidTask;
    IUnitTask@ validTask;
    bool rejected = false;

    bool Check(CCircuitUnit@ unit, const AIFloat3& in pos, float range, bool expected) {
        return aiTerrainMgr.CanReachAt(unit,pos,range)==expected
            && aiTerrainMgr.CanReachAtSafe(unit,pos,range)==expected;
    }

    bool Handle(const string& in message) {
        array<string>@ fields = message.split("|");
        if (fields.length()!=4 || fields[0]!="terrain-reach") return false;
        commander = parseInt(fields[1]);
        array<int> ids = {commander,parseInt(fields[2]),parseInt(fields[3])};
        const float width = AiTerrainWidth(), height = AiTerrainHeight();
        const float nan = fpFromIEEE(uint(0x7fc00000));
        const float infinity = fpFromIEEE(uint(0x7f800000));
        array<AIFloat3> invalid = {
            AIFloat3(409,0,10272), // exact reported crash destination; first for baseline reproduction
            AIFloat3(-0.1f,0,100), AIFloat3(100,0,-0.1f),
            AIFloat3(width,0,100), AIFloat3(100,0,height),
            AIFloat3(width+1,0,100), AIFloat3(100,0,height+1),
            AIFloat3(nan,0,100), AIFloat3(100,nan,100), AIFloat3(100,0,nan),
            AIFloat3(infinity,0,100), AIFloat3(100,0,-infinity)
        };
        for (uint i=0; i<ids.length(); ++i) {
            CCircuitUnit@ unit = ai.GetTeamUnit(ids[i]);
            if (unit is null) { GenericHelpers::LogUtil("[TerrainReachTest] FAIL missing unit",1); return true; }
            const AIFloat3 pos = unit.GetPos(ai.frame);
            bool passed = Check(unit,pos,64.f,true);
            for (uint j=0; j<invalid.length(); ++j) {
                GenericHelpers::LogUtil("[TerrainReachTest] query unit_kind="+i+" invalid="+j,1);
                passed = Check(unit,invalid[j],64.f,false) && passed;
            }
            passed = Check(unit,pos,-1.f,false) && passed;
            passed = Check(unit,pos,nan,false) && passed;
            passed = Check(unit,pos,infinity,false) && passed;
            if (i==1) { // flying: every finite in-map corner remains reachable
                passed = Check(unit,AIFloat3(0,0,0),0.f,true) && passed;
                passed = Check(unit,AIFloat3(width-0.5f,0,height-0.5f),0.f,true) && passed;
            }
            if (i==2) passed = Check(unit,AIFloat3(pos.x+128,pos.y,pos.z),64.f,false) && passed;
            GenericHelpers::LogUtil("[TerrainReachTest] "+(passed?"PASS ":"FAIL ")+"queries kind="+i,1);
        }
        GenericHelpers::LogUtil("[TerrainReachTest] "+(Check(null,AIFloat3(2000,0,2000),64.f,false)?"PASS ":"FAIL ")+"null_unit",1);
        exerciseTasks = true;
        return true;
    }

    IUnitTask@ Task(CCircuitUnit@ unit) {
        if (exerciseTasks && unit.id==commander) {
            if (invalidTask is null) {
                @invalidTask = aiBuilderMgr.Enqueue(TaskB::Common(Task::BuildType::DEFENCE,
                    Task::Priority::HIGH,ai.GetCircuitDef("armllt"),AIFloat3(409,0,10272),0.f,true,30*SECOND));
                return invalidTask;
            }
            if (!invalidTask.IsDead()) return invalidTask;
            if (!rejected) {
                rejected = true;
                GenericHelpers::LogUtil("[TerrainReachTest] PASS invalid_task_aborted",1);
            }
            if (validTask is null) {
                const AIFloat3 pos = unit.GetPos(ai.frame);
                @validTask = aiBuilderMgr.Enqueue(TaskB::Common(Task::BuildType::DEFENCE,
                    Task::Priority::HIGH,ai.GetCircuitDef("armllt"),AIFloat3(pos.x+128,pos.y,pos.z),32.f,true,60*SECOND));
            }
            if (validTask !is null && !validTask.IsDead()) return validTask;
        }
        return aiBuilderMgr.Enqueue(TaskB::Wait(SECOND));
    }
}
