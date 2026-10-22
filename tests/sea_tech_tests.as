// Exercise the real coordinator with a deterministic message transport stub.
const int SECOND=30;
namespace AiRole { const int SEA=1; }
namespace Global {
namespace AISettings { int Role=1; }
namespace RoleSettings { namespace Sea { bool CoordinateTech=true; } }
}
class TestAI {
    int frame=0, teamId=0, lead=0;
    int GetLeadTeamId() { return lead; }
}
TestAI ai;
array<string> sent;
array<int> recipients;
void AiSendMessage(const string &in msg,int recipient) { sent.insertLast(msg); recipients.insertLast(recipient); }
namespace GenericHelpers { void LogUtil(const string &in msg,int level) {} }
void ResetLease() {
    SeaTech::requests.resize(0); SeaTech::owners.deleteAll(); SeaTech::expires.deleteAll();
    SeaTech::lastTick=-1; SeaTech::coordinator=0; SeaTech::reconcileUntil=0;
    SeaTech::requestedBody=-1; SeaTech::grantedUntil=-1; SeaTech::lastSend=-100000;
    SeaTech::leader=-1; sent.resize(0); recipients.resize(0);
    ai.teamId=0; ai.lead=0; ai.frame=60;
}
void test_lease_batches_ties_and_separates_water_bodies() {
    ResetLease();
    SeaTech::Handle("sea-tech|request|2|1",3);
    SeaTech::Handle("sea-tech|request|2|1",1);
    SeaTech::Handle("sea-tech|request|4|1",2);
    SeaTech::Tick();
    Check(sent.length()==2);
    Check(recipients.find(1)>=0 && recipients.find(2)>=0 && recipients.find(3)<0);
}
void test_lease_retains_owner_and_releases_on_request() {
    ResetLease();
    SeaTech::Handle("sea-tech|request|2|1",3); SeaTech::Tick();
    ai.frame+=30; SeaTech::Handle("sea-tech|request|2|1",1); SeaTech::Tick();
    Check(recipients.length()==1 && recipients[0]==3);
    ai.frame+=30; SeaTech::Handle("sea-tech|request|2|0",3); SeaTech::Tick();
    Check(recipients.length()==2 && recipients[1]==1);
}
void test_lease_expires_and_prefers_existing_frame() {
    ResetLease();
    SeaTech::Handle("sea-tech|request|2|1",1); SeaTech::Tick();
    ai.frame+=601;
    SeaTech::Handle("sea-tech|request|2|1",2);
    SeaTech::Handle("sea-tech|request|2|2",3); SeaTech::Tick();
    Check(recipients.length()==2 && recipients[1]==3);
}
void test_lease_ignores_forged_grants_and_waits_for_coordinator_recovery() {
    ResetLease(); ai.teamId=1;
    Check(!SeaTech::Permit(2,1));
    SeaTech::Handle("sea-tech|grant|2|600",2);
    Check(!SeaTech::Permit(2,1));
    SeaTech::Handle("sea-tech|grant|2|600",0);
    Check(SeaTech::Permit(2,1));
    ai.lead=1; Check(!SeaTech::Permit(2,1));
    SeaTech::Tick(); Check(!SeaTech::Permit(2,1));
    ai.frame+=601; SeaTech::Permit(2,1); SeaTech::Tick();
    Check(SeaTech::Permit(2,1));
}
