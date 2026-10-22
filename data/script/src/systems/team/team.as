#include "../../global.as"
#include "../../helpers/units/unit_helpers.as"
#include "../../helpers/common/generic_helpers.as"
#include "roster.as"
#include "sea_tech.as"
#include "donation.as"
#include "sea_assist.as"
#include "builder_recovery.as"
#include "geo_release.as"
#include "commander_energy.as"

namespace Team {
    // Return true if the def represents a T2 constructor (land or air)
    bool IsT2Constructor(const CCircuitDef @d) {
        if (d is null) return false;
        // Tier via helper (bots/vehicles)
        int tier = UnitHelpers::GetConstructorTier(d);
        if (tier == 2) return true;
        // Air constructors: infer T2 by explicit names
        const string n = d.GetName();
        // T2 air constructors (BAR): armaca/coraca/legaca
        if (UnitHelpers::IsAirConstructor(d)) {
            if (n == "armaca" || n == "coraca" || n == "legaca") return true;
        }
        return false;
    }

    // Shared experimental-role recovery, replacing spare-only orphan donations.
    void CheckOrphaned() { Recovery::Update(); SeaTech::Tick(); }

    // True when teamId is on our ally team (ai.GetTeamIds() lists our own ally team).
    bool IsAlly(int teamId) {
        array<Id>@ teams = ai.GetTeamIds();
        if (teams is null) return false;
        for (uint i = 0; i < teams.length(); ++i) {
            if (int(teams[i]) == teamId) return true;
        }
        return false;
    }

    // Called from Main::AiMessage for every message from an allied BARb: roster
    // lines first, then the constructor recovery request. CInitScript::SendMessage only
    // delivers within one ally team; the check below keeps that true even if two
    // ally teams' AIs run in the same process and the native filter ever changes.
    void HandleMessage(const string &in msg, int fromTeamId) {
        if (!IsAlly(fromTeamId)) {
            GenericHelpers::LogUtil("[Team] Ignored message from non-allied team " + fromTeamId + ": " + msg, 2);
            return;
        }
        if (SeaTech::Handle(msg, fromTeamId)) return;
        if (Roster::HandleMessage(msg, fromTeamId)) return;
        if (CommanderEnergy::HandleMessage(msg, fromTeamId)) return;
        if (GeoRelease::HandleMessage(msg, fromTeamId)) return;
        if (Ferry::HandleMessage(msg, fromTeamId)) return;
        if (Donation::HandleMessage(msg, fromTeamId)) return;
        if (SeaAssist::HandleMessage(msg, fromTeamId)) return;
        if (AmphibiousBeaches::HandleMessage(msg, fromTeamId)) return;
        Recovery::HandleMessage(msg, fromTeamId);
    }

}
