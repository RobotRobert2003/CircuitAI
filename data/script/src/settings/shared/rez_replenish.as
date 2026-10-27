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
        // Proposed table (headless 2026-10-26, Flats and Forests 8v8 +55, see the exp/rezbot-replenish
        // commit message): start low - every rez bot ordered at a 1200-3000 army is metal the army
        // misses while trades are close - and reach 15-20 only once the army is far past 4000.
        array<float> ScaleArmy = {1200.0f, 1500.0f, 2000.0f, 2500.0f, 3000.0f, 3500.0f, 4000.0f, 6000.0f, 9000.0f, 12000.0f};
        array<int> ScaleTargets = {3, 4, 5, 6, 8, 10, 12, 15, 18, 20};
        // 0 = off. N > 0: after N rez bot orders in a row a lab lets one build of its own production
        // through (unless fewer than InterleaveCriticalBelow rez bots are left), so a big deficit does
        // not stall constructors, openers and the army. Untested in games.
        int RezPerNormalBuild = 0;
        int InterleaveCriticalBelow = 2;
        // Rez bot orders still waiting for the lab to start them; at most this many at a time
        // across all our labs, and an order not started within OrderTimeoutSeconds is forgotten.
        int MaxOrdersInFlight = 2;
        // TECH and SUPPORT build their T1 bot lab as a throwaway opening lab and retire it at T2:
        // no replenishment and no donations from them unless this is set.
        bool IncludeTechSupport = false;
        int OrderTimeoutSeconds = 60;
        // A T1 bot lab Spam runs as a repeating pump never asks for a new task; while rez bots
        // are short, end one pump's repeat (at most once per lab per ReleaseSpacingSeconds) so the
        // lab takes the rez bot order and then returns to spam.
        bool ReleaseSpamLabs = true;
        int ReleaseSpacingSeconds = 20;

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
        int ShareMaxOutstanding = 8;      // rez bots a donor owes all requesters together, at most
        int GiftSpacingSeconds = 4;
        int AnnounceSeconds = 60;         // bot-lab AIs announce themselves to allies this often

        // Stat line period ([RezRep] stat ...).
        int LogSeconds = 30;
    }
}
