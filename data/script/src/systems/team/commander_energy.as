// One selected allied AI donor per request, with grant/accept/delivery states.
// A bounded ledger retains deduplication until expiry; no per-unit messages.
namespace CommanderEnergy {
    class Grant {
        string id;
        int team=-1,expiry=0;
        float amount=0.f;
        bool sent=false;
    }
    array<Grant@> grants;
    string pending;
    int donor=-1,deadline=0,nextAsk=0,serial=0,operation=-1;
    bool accepted=false;
    float Reserved() {
        float total=0.f;
        for(uint i=0;i<grants.length();++i)
            if(!grants[i].sent && grants[i].expiry>=ai.frame) total+=grants[i].amount;
        return total;
    }
    float Available() {
        const float upkeep=AiMax(0.f,TeamEconomy::OwnEnergy(TeamEconomy::USAGE)
            -TeamEconomy::OwnEnergy(TeamEconomy::INCOME))*3.f;
        return AiMax(0.f,TeamEconomy::OwnEnergy(TeamEconomy::CURRENT)-upkeep
            -Global::Commander::DonorReserve-aiBuilderMgr.GetCommanderEnergyReserve()-Reserved());
    }
    bool Number(const string &in text,float &out result) {
        uint used=0; result=float(parseFloat(text,used));
        return used==text.length() && used>0 && result>=0.f && result<100000000.f;
    }
    void Update() {
        for(int i=int(grants.length())-1;i>=0;--i)
            if(grants[i].expiry<ai.frame) grants.removeAt(i);
        if(pending!="" && (ai.frame>deadline || operation!=aiBuilderMgr.GetCommanderOperation()
            || aiBuilderMgr.GetCommanderEnergyDeficit()<1.f)) {
            AiSendMessage("comenergy|cancel|"+pending,donor);
            pending=""; donor=-1; accepted=false;
        }
        if(pending!="" || ai.frame<nextAsk || !Global::Commander::Enabled) return;
        const float deficit=aiBuilderMgr.GetCommanderEnergyDeficit();
        if(deficit<100.f) return;
        nextAsk=ai.frame+int(Global::Commander::EnergyRequestSeconds*SECOND);
        array<Team::Roster::Entry@>@ allies=Team::Roster::All();
        int selected=-1; float best=100.f;
        for(uint i=0;i<allies.length();++i) {
            const int team=allies[i].teamId;
            if(team==ai.teamId || !TeamEconomy::UpdateTeam(team)) continue;
            const float spare=TeamEconomy::Energy(team,TeamEconomy::CURRENT)-Global::Commander::DonorReserve;
            if(spare>best) { best=spare; selected=team; }
        }
        if(selected<0) return;
        donor=selected; operation=aiBuilderMgr.GetCommanderOperation();
        pending=""+ai.frame+":"+(++serial)+":"+operation;
        deadline=ai.frame+int(Global::Commander::GrantSeconds*SECOND); accepted=false;
        const float amount=AiMin(Global::Commander::GrantLimit,AiMin(deficit,
            TeamEconomy::OwnEnergy(TeamEconomy::FREE)));
        if(amount<1.f) { pending=""; return; }
        AiSendMessage("comenergy|request|"+pending+"|"+amount+"|"+deadline,donor);
        GenericHelpers::LogUtil("[CommanderEnergy] request="+pending+" deficit="+amount+" donor="+donor,1);
    }
    bool HandleMessage(const string &in message,int sender) {
        if(message.findFirst("comenergy|")!=0) return false;
        if(message.length()>256 || Team::Roster::Get(sender) is null) return true;
        array<string>@ f=message.split("|");
        if(f.length()<3 || f[2].length()>80) return true;
        Grant@ grant=null;
        for(uint i=0;i<grants.length();++i)
            if(grants[i].team==sender && grants[i].id==f[2]) { @grant=grants[i]; break; }
        if(f[1]=="request" && f.length()==5) {
            float amount=0.f,expiry=0.f;
            if(!Number(f[3],amount) || !Number(f[4],expiry) || expiry<ai.frame
                || expiry>ai.frame+10*SECOND || grant !is null || grants.length()>=64) return true;
            // Refuse a second live obligation from this team, including sent
            // grants retained for duplicate-accept protection.
            for(uint i=0;i<grants.length();++i)
                if(grants[i].team==sender && grants[i].expiry>=ai.frame) return true;
            if(!TeamEconomy::UpdateTeam(sender)) return true;
            amount=AiMin(amount,AiMin(Available(),TeamEconomy::Energy(sender,TeamEconomy::FREE)));
            amount=AiMin(amount,Global::Commander::GrantLimit);
            if(amount<1.f) return true;
            @grant=Grant(); grant.id=f[2]; grant.team=sender; grant.expiry=int(expiry); grant.amount=amount;
            grants.insertLast(grant);
            AiSendMessage("comenergy|grant|"+grant.id+"|"+amount,sender);
        } else if(f[1]=="grant" && f.length()==4 && sender==donor && f[2]==pending
            && !accepted && ai.frame<=deadline && operation==aiBuilderMgr.GetCommanderOperation()) {
            float amount=0.f;
            if(!Number(f[3],amount) || amount<=0.f) return true;
            accepted=true; AiSendMessage("comenergy|accept|"+pending,sender);
        } else if(f[1]=="accept" && f.length()==3 && grant !is null
            && !grant.sent && grant.expiry>=ai.frame) {
            // Release our own reservation before calculating the final send.
            grant.sent=true;
            if(!TeamEconomy::UpdateTeam(sender)) return true;
            const float amount=AiMin(grant.amount,AiMin(Available(),TeamEconomy::Energy(sender,TeamEconomy::FREE)));
            if(amount>0.f && TeamEconomy::SendEnergy(sender,amount)) {
                AiSendMessage("comenergy|sent|"+grant.id+"|"+amount,sender);
                GenericHelpers::LogUtil("[CommanderEnergy] sent="+amount+" request="+grant.id+" team="+sender,1);
            }
        } else if(f[1]=="cancel" && grant !is null) {
            grant.sent=true; // tombstone, not immediate deletion
        } else if(f[1]=="sent" && sender==donor && f[2]==pending) {
            // Keep the operation pending until the bank or timeout resolves it.
            // Dispatch success is not authoritative engine delivery.
            GenericHelpers::LogUtil("[CommanderEnergy] transfer dispatched request="+pending,1);
        }
        return true;
    }
}
