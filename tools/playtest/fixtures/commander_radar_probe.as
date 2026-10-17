namespace CommanderRadarProbe {
    int commander = -1;
    bool building = false;
    CCircuitDef@ radar;
    void Enable(bool value) {
        aiBuilderMgr.SetCommanderCombatOption("front_duty",value?1.f:0.f);
        aiBuilderMgr.SetCommanderCombatOption("front_ready",value?1.f:0.f);
    }
    bool Handle(const string& in message) {
        array<string>@ fields = message.split("|");
        if (fields.length()<2 || fields[0]!="commander-radar") return false;
        if (fields[1]=="setup") {
            commander = parseInt(fields[2]);
            @radar = ai.GetCircuitDef(fields[3]);
            Enable(false);
        } else if (fields[1]=="build") {
            building = true;
        } else if (fields[1]=="check") {
            CCircuitUnit@ unit = ai.GetTeamUnit(commander);
            CCircuitUnit@ constructor = ai.GetTeamUnit(parseInt(fields[4]));
            if (unit is null || constructor is null || radar is null) {
                GenericHelpers::LogUtil("[CommanderRadarTest] FAIL missing inputs",1); return true;
            }
            const bool allowed = fields[3]=="1";
            Enable(true);
            IUnitTask@ task = aiBuilderMgr.CommanderFrontWork(unit,10,radar,0.f);
            const bool ladderAllowed = task !is null;
            bool passed = ladderAllowed==allowed;
            if (task !is null) {
                IUnitTask@ again = aiBuilderMgr.CommanderFrontWork(unit,10,radar,0.f);
                passed = passed && again is task;
                task.Abort();
            }
            // Ordinary defence-queue jobs use the same admission rule. They
            // must remain available to non-commanders and non-FRONT duty.
            const AIFloat3 pos = unit.GetPos(ai.frame);
            IUnitTask@ queued = aiBuilderMgr.Enqueue(TaskB::Common(Task::BuildType::RADAR,
                Task::Priority::HIGH,radar,AIFloat3(pos.x+700,pos.y,pos.z),0.f,true,30*SECOND));
            IUnitTask@ selected = aiBuilderMgr.FindQueuedTask(unit,int(Task::BuildType::RADAR));
            const bool queueAllowed = selected is queued;
            passed = passed && queueAllowed==allowed;
            @selected = aiBuilderMgr.FindQueuedTask(constructor,int(Task::BuildType::RADAR));
            passed = passed && selected is queued;
            Enable(false);
            @selected = aiBuilderMgr.FindQueuedTask(unit,int(Task::BuildType::RADAR));
            passed = passed && selected is queued;
            queued.Abort();
            GenericHelpers::LogUtil("[CommanderRadarTest] admission "+fields[2]+" expected="+(allowed?1:0)
                +" ladder="+(ladderAllowed?1:0)+" queue="+(queueAllowed?1:0),1);
            GenericHelpers::LogUtil("[CommanderRadarTest] "+(passed?"PASS ":"FAIL ")+fields[2]+" ladder_and_queue",1);
        }
        return true;
    }
    IUnitTask@ Task(CCircuitUnit@ unit) {
        if (building && unit.id==commander) {
            Enable(true);
            IUnitTask@ task = aiBuilderMgr.CommanderFrontWork(unit,10,radar,0.f);
            Enable(false);
            if (task !is null) return task;
        }
        return aiBuilderMgr.Enqueue(TaskB::Wait(SECOND));
    }
}
