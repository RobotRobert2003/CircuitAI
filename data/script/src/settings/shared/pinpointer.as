// Shared pinpointer pool (owner, 2026-10-16; systems/team/pinpointer_pool.as)
namespace Global { namespace Team {
    int PinpointerPoolSize = 0;               // pinpointers across every allied SMRTBARb; 0 = off (3 in experimental_balanced)
    float PinpointerMinMetalIncome = 60.0f;   // an AI takes part from this 10 s minimum metal income
    float PinpointerKeepAway = 1200.0f;       // FRONT/SUPPORT/other builders stay this far from AIR and TECH start positions
    float PinpointerClaimSeconds = 90.0f;     // a claim counts as one under way this long, or until a count replaces it
    float PinpointerHaveSeconds = 60.0f;      // each AI re-sends its count at least this often
} }
