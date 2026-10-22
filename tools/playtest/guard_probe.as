// Isolated fixture only. Exercise real native guard admission via the existing
// public task API; never inject this into the production data tree.
namespace GuardProbe {
    array<int> owned;
    bool Owns(int id) { return owned.find(id)>=0; }
    bool Handle(const string& in message) {
        array<string>@ fields=message.split("|");
        if (fields.length()!=3 || (fields[0]!="guard-probe" && fields[0]!="guard-stop" && fields[0]!="guard-move")) return false;
        CCircuitUnit@ worker=ai.GetTeamUnit(parseInt(fields[1]));
        if (worker is null) return true;
        if (fields[0]=="guard-stop") { worker.CmdStop(); return true; }
        if (fields[0]=="guard-move") { worker.CmdMoveTo(AIFloat3(6900,0,10800)); return true; }
        CCircuitUnit@ vip=ai.GetTeamUnit(parseInt(fields[2]));
        if (worker is null || vip is null) return true;
        if (!Owns(worker.id)) owned.insertLast(worker.id);
        IUnitTask@ task=aiBuilderMgr.Enqueue(TaskB::Guard(Task::Priority::HIGH,vip,false,0));
        if (task !is null) aiBuilderMgr.AssignTask(worker,task);
        return true;
    }
}
