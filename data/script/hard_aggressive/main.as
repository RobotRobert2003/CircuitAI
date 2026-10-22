#include "../src/systems/diagnostics/artillery_policy.as"
namespace Main 
{
    void AiSuperWeaponFired(CCircuitUnit@ unit, const AIFloat3& in aim) { ArtilleryPolicy::Fired(unit, aim); }
    void AiUnitDestroyed(CCircuitUnit@ unit) { ArtilleryPolicy::Removed(unit); }


	void AiMain()
	{
		// for (Id defId = 1, count = ai.GetDefCount(); defId <= count; ++defId) {
		// 	CCircuitDef@ cdef = ai.GetCircuitDef(defId);
		// 	if (cdef.costM >= 200.f && !cdef.IsMobile() && aiEconomyMgr.GetEnergyMake(cdef) > 1.f)
		// 		cdef.AddAttribute(Unit::Attr::BASE.type);  // Build heavy energy at base
		// }

		// // Example of user-assigned custom attributes
		// array<string> names = {Factory::armalab, Factory::coralab, Factory::legalab, Factory::armavp, Factory::coravp, Factory::legavp,
		// 	Factory::armaap, Factory::coraap, Factory::legaap, Factory::armasy, Factory::corasy};
		// for (uint i = 0; i < names.length(); ++i) {
		// 	CCircuitDef@ cdef = ai.GetCircuitDef(names[i]);
		// 	if (cdef !is null)
		// 		Factory::userData[cdef.id].attr |= Factory::Attr::T2;
		// }
		// names = {Factory::armshltx, Factory::corgant, Factory::leggant};
		// for (uint i = 0; i < names.length(); ++i) {
		// 	CCircuitDef@ cdef = ai.GetCircuitDef(names[i]);
		// 	if (cdef !is null)
		// 		Factory::userData[cdef.id].attr |= Factory::Attr::T3;
		// }
	}

	void AiUpdate()  // SlowUpdate, every 30 frames with initial offset of skirmishAIId
	{
        ArtilleryPolicy::Check();
	}

}  // namespace Main
