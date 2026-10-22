// One authoritative lease per connected sea. Only the native ally leader
// grants; clients never infer ownership from an incomplete peer roster.
namespace SeaTech {
    class Request { int team=-1, body=-1, frame=-1, stage=0; }
    array<Request@> requests;
    dictionary owners, expires;
    int lastTick=-1, lastSend=-100000, grantedBody=-1, grantedUntil=-1, leader=-1;
    int requestedBody=-1, requestedStage=0, coordinator=-1, reconcileUntil=-1;
    void Send(const string &in msg,int target) {
        if (target==ai.teamId) Handle(msg,ai.teamId); else AiSendMessage(msg,target);
    }
    bool Handle(const string &in msg,int sender) {
        if (msg.findFirst("sea-tech|")!=0) return false;
        array<string>@ fields=msg.split("|");
        if (fields.length()!=4) return true;
        const int body=int(parseInt(fields[2])), value=int(parseInt(fields[3]));
        if (fields[1]=="grant") {
            if (sender==ai.GetLeadTeamId() && body==requestedBody && value>ai.frame) {
                grantedBody=body; grantedUntil=value;
            }
        } else if (fields[1]=="request" && ai.teamId==ai.GetLeadTeamId() && body>=0 && value>=0 && value<=2) {
            Request@ entry=null;
            for (uint i=0;i<requests.length();++i) if (requests[i].team==sender) { @entry=requests[i]; break; }
            if (entry is null) { @entry=Request(); entry.team=sender; requests.insertLast(entry); }
            entry.body=body; entry.stage=value; entry.frame=ai.frame;
        }
        return true;
    }
    bool Permit(int body,int stage) {
        if (!Global::RoleSettings::Sea::CoordinateTech) return true;
        if (body<0) return false;
        const int currentLeader=ai.GetLeadTeamId();
        if (leader!=currentLeader) { leader=currentLeader; grantedUntil=-1; lastSend=-100000; }
        if (body!=requestedBody || stage!=requestedStage || ai.frame-lastSend>=5*SECOND) {
            if (requestedBody>=0 && body!=requestedBody) Send("sea-tech|request|"+requestedBody+"|0",leader);
            requestedBody=body; requestedStage=stage; lastSend=ai.frame;
            Send("sea-tech|request|"+body+"|"+stage,leader);
        }
        return grantedBody==body && ai.frame<grantedUntil;
    }
    void Release() {
        if (requestedBody>=0) Send("sea-tech|request|"+requestedBody+"|0",ai.GetLeadTeamId());
        requestedBody=-1; requestedStage=0; grantedUntil=-1;
    }
    void Tick() {
        if (ai.frame-lastTick<SECOND) return;
        lastTick=ai.frame;
        if (Global::AISettings::Role!=AiRole::SEA && requestedBody>=0) Release();
        if (ai.teamId!=ai.GetLeadTeamId()) { coordinator=-1; return; }
        if (coordinator!=ai.teamId) {
            coordinator=ai.teamId; reconcileUntil=ai.frame+20*SECOND;
            owners.deleteAll(); expires.deleteAll();
        }
        // A new coordinator waits out grants from its predecessor. Framed
        // projects renew during this window and win over unstarted requests.
        if (ai.frame<reconcileUntil) return;
        // S is allied requesters (<= team count). O(S^2) at 1 Hz, no unit scan.
        // Entries expire; ownership is never granted by multiple participants.
        for (int i=int(requests.length())-1;i>=0;--i)
            if (ai.frame-requests[i].frame>20*SECOND) requests.removeAt(i);
        for (uint i=0;i<requests.length();++i) {
            Request@ request=requests[i]; if (request.stage==0) continue;
            const string key=""+request.body;
            int owner=-1, until=-1;
            if (!owners.get(key,owner)) owner=-1;
            if (!expires.get(key,until)) until=-1;
            Request@ incumbent=null;
            Request@ chosen=request;
            for (uint j=0;j<requests.length();++j) {
                Request@ other=requests[j];
                if (other.body!=request.body || other.stage==0) continue;
                if (other.team==owner && ai.frame<until) @incumbent=other;
                if (other.stage>chosen.stage || (other.stage==chosen.stage && other.team<chosen.team)) @chosen=other;
            }
            if (incumbent !is null) @chosen=incumbent;
            if (chosen.team!=request.team) continue;
            const int expiry=chosen.frame+20*SECOND;
            if (owner!=chosen.team || expiry!=until) {
                owners.set(key,chosen.team); expires.set(key,expiry);
                Send("sea-tech|grant|"+key+"|"+expiry,chosen.team);
                if (owner!=chosen.team) GenericHelpers::LogUtil("[SEA][TechLease] body="+key+" owner="+chosen.team,1);
            }
        }
    }
}
