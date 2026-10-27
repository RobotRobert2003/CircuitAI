// Rez bot replenishment and sharing (owner, 2026-10-26; systems/production/rez_replenish.as).
// Off by default; experimental_balanced/main.as turns it on. The [RezRep] stat lines are
// written whatever Enabled says, so a baseline game logs the same numbers.
namespace Global {
namespace RezReplenish {
        // A T1 bot lab of this AI keeps the rez bot count (armrectr / cornecro / legrezbot,
        // finished plus in production) at the target while the alive mobile army - every
        // finished mobile unit that is not a constructor, rez bot or commander (no build
        // power) - is worth more than ArmyMinMetal.
        bool Enabled = false;
        float ArmyMinMetal = 1200.0f;
        // Flat target (Scale = false).
        int Target = 11;
        // Scale = true: the target is the last ScaleTargets entry whose ScaleArmy entry the
        // army exceeds (both ascending, same length; the first ScaleArmy should be ArmyMinMetal).
        bool Scale = false;
        array<float> ScaleArmy = {1200.0f, 3000.0f, 3600.0f, 4200.0f};
        array<int> ScaleTargets = {11, 15, 18, 20};
        // Rez bot orders still waiting for the lab to start them; at most this many at a time
        // across all our labs, and an order not started within OrderTimeoutSeconds is forgotten.
        int MaxOrdersInFlight = 2;
        int OrderTimeoutSeconds = 60;

        // Sharing: an AI with a T1 bot lab gives rez bots to allied BARb AIs that have a vehicle
        // plant and no T1 bot lab. Such an AI asks (AiSendMessage "barbrez|req") when it has fewer
        // than RequestBelow rez bots and an alive army above RequestMinArmy, for enough to reach
        // RequestUpTo. The bot-lab AI builds them on top of its own target and hands each one over
        // with ai.GiveUnits as it finishes, keeping at least max(own target, ShareKeepMin).
        bool ShareEnabled = false;
        int RequestBelow = 3;
        int RequestUpTo = 4;
        float RequestMinArmy = 1200.0f;
        int RequestCooldownSeconds = 60;
        int RequestExpirySeconds = 240;   // the donor forgets an unfilled request after this
        int ShareKeepMin = 2;
        int GiftSpacingSeconds = 4;
        int AnnounceSeconds = 60;         // bot-lab AIs announce themselves to allies this often

        // Stat line period ([RezRep] stat ...).
        int LogSeconds = 30;
    }
}
