// Actual production protocol in the embedded VM; only engine/roster effects
// are mocked. No live transfers occur in this suite.
const int SECOND=30;
float AiMin(float a,float b) { return a<b?a:b; }
float AiMax(float a,float b) { return a>b?a:b; }
class TestAi { int frame=100,teamId=0; }
TestAi ai;
class TestBuilder {
    float reserve=0,deficit=1000; int operation=1;
    float GetCommanderEnergyReserve() { return reserve; }
    float GetCommanderEnergyDeficit() { return deficit; }
    int GetCommanderOperation() { return operation; }
}
TestBuilder aiBuilderMgr;
namespace Global { namespace Commander {
    bool Enabled=true;
    float DonorReserve=1200,GrantLimit=4000,EnergyRequestSeconds=3,GrantSeconds=3;
} }
namespace GenericHelpers { void LogUtil(const string &in text,int level) {} }
array<string> messages;
void AiSendMessage(const string &in message,int team) { messages.insertLast(message); }
namespace Team { namespace Roster {
    class Entry { int teamId=1; }
    Entry entry; array<Entry@> entries={entry};
    Entry@ Get(int team) { if(team==1) return entry; return null; }
    array<Entry@>@ All() { return entries; }
} }
namespace TeamEconomy {
    const int CURRENT=0,USAGE=1,INCOME=2,FREE=3;
    float bank=10000,usage=0,income=0,space=5000,sent=0;
    int sends=0;
    bool UpdateTeam(int team) { return team==1; }
    float OwnEnergy(int kind) { return kind==CURRENT?bank:kind==USAGE?usage:kind==INCOME?income:space; }
    float Energy(int team,int kind) { return kind==FREE?space:10000; }
    bool SendEnergy(int team,float amount) { ++sends; sent+=amount; bank-=amount; return true; }
}
void Reset() {
    CommanderEnergy::grants.resize(0); CommanderEnergy::pending="";
    CommanderEnergy::donor=-1; CommanderEnergy::deadline=0; CommanderEnergy::nextAsk=0;
    CommanderEnergy::accepted=false; messages.resize(0);
    ai.frame=100; aiBuilderMgr.operation=1; aiBuilderMgr.reserve=0; aiBuilderMgr.deficit=1000;
    TeamEconomy::bank=10000; TeamEconomy::space=5000; TeamEconomy::sends=0; TeamEconomy::sent=0;
    TeamEconomy::usage=0;
}
void test_duplicate_accept_sends_once() {
    Reset(); CommanderEnergy::HandleMessage("comenergy|request|a|1000|190",1);
    Check(CommanderEnergy::Reserved()==1000);
    CommanderEnergy::HandleMessage("comenergy|accept|a",1);
    CommanderEnergy::HandleMessage("comenergy|accept|a",1);
    Check(TeamEconomy::sends==1 && TeamEconomy::sent==1000);
    Check(CommanderEnergy::Reserved()==0);
    CommanderEnergy::HandleMessage("comenergy|request|a|1000|190",1);
    Check(CommanderEnergy::grants.length()==1);
}
void test_donor_rechecks_bank_and_recipient_space() {
    Reset(); aiBuilderMgr.reserve=2000;
    CommanderEnergy::HandleMessage("comenergy|request|a|4000|190",1);
    TeamEconomy::bank=3500; TeamEconomy::space=100;
    CommanderEnergy::HandleMessage("comenergy|accept|a",1);
    Check(TeamEconomy::sent==100 && TeamEconomy::bank==3400);
}
void test_cancel_and_expiry_never_send() {
    Reset(); CommanderEnergy::HandleMessage("comenergy|request|a|1000|190",1);
    CommanderEnergy::HandleMessage("comenergy|cancel|a",1);
    CommanderEnergy::HandleMessage("comenergy|accept|a",1);
    Check(TeamEconomy::sends==0);
    Reset(); CommanderEnergy::HandleMessage("comenergy|request|a|1000|190",1);
    ai.frame=191; CommanderEnergy::HandleMessage("comenergy|accept|a",1);
    Check(TeamEconomy::sends==0);
}
void test_invalid_sender_amount_and_expiry_rejected() {
    Reset();
    CommanderEnergy::HandleMessage("comenergy|request|a|1000|190",9);
    CommanderEnergy::HandleMessage("comenergy|request|a|1000garbage|190",1);
    CommanderEnergy::HandleMessage("comenergy|request|a|1e999|190",1);
    CommanderEnergy::HandleMessage("comenergy|request|a|-1|190",1);
    CommanderEnergy::HandleMessage("comenergy|request|a|1000|9999",1);
    Check(CommanderEnergy::grants.length()==0 && TeamEconomy::sends==0);
}
void test_operation_change_cancels_request() {
    Reset(); CommanderEnergy::Update();
    const string id=CommanderEnergy::pending;
    Check(id!="" && CommanderEnergy::donor==1);
    aiBuilderMgr.operation=2; CommanderEnergy::Update();
    Check(CommanderEnergy::pending=="");
    CommanderEnergy::HandleMessage("comenergy|grant|"+id+"|1000",1);
    Check(!CommanderEnergy::accepted);
}
void test_dispatch_message_is_not_banked_energy() {
    Reset(); CommanderEnergy::Update();
    const string id=CommanderEnergy::pending;
    CommanderEnergy::HandleMessage("comenergy|grant|"+id+"|1000",1);
    Check(CommanderEnergy::accepted);
    CommanderEnergy::HandleMessage("comenergy|sent|"+id+"|1000",1);
    Check(aiBuilderMgr.deficit==1000 && CommanderEnergy::pending==id);
    aiBuilderMgr.deficit=0; CommanderEnergy::Update();
    Check(CommanderEnergy::pending=="");
}
