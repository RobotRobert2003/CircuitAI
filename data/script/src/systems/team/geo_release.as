// Explicit allied geothermal handoff for Cortex TECH frontline Cerberus.
// Message work is per requested vent, never per frame or per allied unit.
namespace Team { namespace GeoRelease {
    const string Prefix="georelease";
    const int TimeoutSeconds=90;
    const float VentRadius=64.0f;
    class Request { AIFloat3 position; int deadline=0, unit=-1; bool declined=false; IUnitTask@ reclaim; }
    dictionary requests;
    string Key(const AIFloat3 &in position) { return ""+int(position.x)+":"+int(position.z); }
    bool Enabled() { return Global::AISettings::Role==AiRole::TECH && Global::AISettings::Side=="cortex"; }
    CCircuitUnit@ PowerAt(const AIFloat3 &in position) {
        array<Id>@ units=OwnedEconomy::Geothermal();
        for (uint index=0;index<units.length();++index) {
            CCircuitUnit@ unit=ai.GetTeamUnit(units[index]);
            if (unit !is null && unit.GetBuildProgress()>=1 && unit.circuitDef.GetName().findFirst("geo")>=0
                && MapHelpers::SqDist(unit.GetPos(ai.frame),position)<=VentRadius*VentRadius) return unit;
        }
        return null;
    }
    bool Waiting(const AIFloat3 &in position) {
        Request@ request;
        return requests.get(Key(position),@request) && request !is null && !request.declined
            && ai.frame<request.deadline;
    }
    IUnitTask@ Work(CCircuitUnit@ worker,const AIFloat3 &in position) {
        if (!Enabled() || worker is null) return null;
        // The native GEO admission rejects allied base zones. Never ask an ally
        // to surrender power at a vent we cannot subsequently build on.
        if (aiTerrainMgr.IsZoneAlly(position)) return null;
        CCircuitDef@ definition=ai.GetCircuitDef("corbhmth");
        if (definition is null || !definition.IsBuildAllowed() || !worker.circuitDef.CanBuild(definition)
            || !aiTerrainMgr.CanReachAt(worker,position,worker.circuitDef.GetBuildDistance())) return null;
        if (definition.maxThisUnit<definition.count+1) definition.maxThisUnit=definition.count+1;
        // The native GEO task owns the vent and BAR's supported T1 upgrade.
        IUnitTask@ task=aiEconomyMgr.EnqueueLocalGeo(worker,definition,position,VentRadius);
        if (task !is null) return task;
        Request@ request;
        const string key=Key(position);
        if (!requests.get(key,@request) || request is null) {
            @request=Request(); request.position=position; request.deadline=ai.frame+TimeoutSeconds*SECOND;
            requests.set(key,@request); // publish before the scheduled allied reply
            AiSendMessage(Prefix+"|request|"+int(position.x)+"|"+int(position.z));
        }
        if (request.unit>=0 && !request.declined && ai.frame<request.deadline) {
            CCircuitUnit@ source=ai.GetTeamUnit(request.unit);
            // Only a plant explicitly handed over by its owner may be reclaimed.
            // A basic geo normally upgrades in place via the native path above.
            if (source !is null && source.circuitDef.GetName().findFirst("geo")>=0
                && MapHelpers::SqDist(source.GetPos(ai.frame),position)<=VentRadius*VentRadius) {
                if (request.reclaim !is null && !request.reclaim.IsDead()) return request.reclaim;
                @request.reclaim=aiBuilderMgr.Enqueue(TaskB::Reclaim(Task::Priority::HIGH,source,TimeoutSeconds*SECOND));
                return request.reclaim;
            }
        }
        return null;
    }
    bool HandleMessage(const string &in message,int sender) {
        if (message.findFirst(Prefix+"|")!=0) return false;
        array<string>@ fields=message.split("|");
        if (fields.length()<4) return true;
        const AIFloat3 position(float(parseInt(fields[2])),0,float(parseInt(fields[3])));
        if (fields[1]=="request") {
            Team::Roster::Entry@ requester=Team::Roster::Get(sender);
            if (requester is null || requester.role!=AiRole::TECH || requester.side!="cortex") return true;
            CCircuitDef@ artillery=ai.GetCircuitDef("corbhmth");
            if (artillery !is null && aiBuilderMgr.FindOwnNear(position,VentRadius,artillery) !is null) {
                AiSendMessage(Prefix+"|decline|"+fields[2]+"|"+fields[3],sender); return true;
            }
            CCircuitUnit@ source=PowerAt(position);
            if (source is null) return true;
            const float output=aiEconomyMgr.GetEnergyMake(source.circuitDef);
            if (aiEconomyMgr.isEnergyStalling || Economy::GetMinEnergyIncomeLast10s()-output<aiEconomyMgr.energy.pull) {
                AiSendMessage(Prefix+"|decline|"+fields[2]+"|"+fields[3],sender); return true;
            }
            const int identifier=source.id;
            array<CCircuitUnit@> transfer={source}; ai.GiveUnits(transfer,sender);
            AiSendMessage(Prefix+"|grant|"+fields[2]+"|"+fields[3]+"|"+identifier,sender);
            GenericHelpers::LogUtil("[GeoRelease] offered plant "+identifier+" to TECH team "+sender,1);
        } else if (Enabled()) {
            Request@ request;
            if (!requests.get(Key(position),@request) || request is null || ai.frame>=request.deadline) return true;
            if (fields[1]=="grant" && fields.length()==5) request.unit=parseInt(fields[4]);
            if (fields[1]=="decline") request.declined=true;
        }
        return true;
    }
} }
