#include "../src/systems/diagnostics/artillery_policy.as"
namespace Main 
{
    void AiSuperWeaponFired(CCircuitUnit@ unit, const AIFloat3& in aim) { ArtilleryPolicy::Fired(unit, aim); }
    void AiUnitDestroyed(CCircuitUnit@ unit) { ArtilleryPolicy::Removed(unit); }


    void AiMain()  // Initialize config params
    {
    }

    void AiUpdate()  // SlowUpdate, every 30 frames with initial offset of skirmishAIId
    {
        ArtilleryPolicy::Check();
    }

}  
