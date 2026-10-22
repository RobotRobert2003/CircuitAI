// Shared defaults; existing Global namespaces are retained for callers.
namespace Global {
namespace SeaAssist {
        bool Enabled = true;
        // SEA's sliding-minimum metal income before it can spare one.
        float MinMetalIncome = 50.0f;
        // Construction ships SEA keeps for itself before donating the surplus.
        int KeepConstructors = 1;
        // TACTICAL's shipyard caps once it owns a sea constructor. They start
        // at 0 in RoleSettings::Tactical, which is what stops it building any
        // naval structure at all.
        int UnlockedT1Shipyards = 2;
        int UnlockedT2Shipyards = 1;
        // Placement slack for the seeded shipyard around the ship's position.
        float SeedShake = 256.0f;
    }
}
namespace Global {
namespace BuilderRecovery {
        bool Enabled = true;
        // Losing the last mobile constructor merits help even with a commander.
        bool CommanderCounts = false;
        int OpeningGraceSeconds = 60;
        int RetrySeconds = 20;
        int LeaseSeconds = 120; // heartbeats retain a request through missing labs
        float DropRadius = 2400.0f; // coastal roles may need the nearest dry shore
    }
}
namespace Global {
namespace ConstructorRequest {
        // T2 constructors from TECH on request (Team::Donation, D-041). TECH
        // always answers a request: one extra constructor from its advanced
        // lab, flown by the ferry transport when it owns one.
        bool Enabled = true;
        // Requester side: a non-TECH BARb with no T2 constructor and no T2 lab
        // of its own asks once its sliding-minimum metal income clears this.
        float RequestMinMetalIncome = 15.0f;
        int MaxRequests = 1;               // automatic requests per game
        int RequestCooldownSeconds = 300;  // between re-asks (no TECH on the team yet)
        // TECH side: an order the lab has not delivered within this is re-placed.
        int OrderTimeoutSeconds = 240;
        // SUPPORT ("front tech") techs on its own: no automatic request from it
        // (D-046). An explicit RequestConstructor() is still always served.
        bool AutoRequestFromSupport = false;
    }
}
