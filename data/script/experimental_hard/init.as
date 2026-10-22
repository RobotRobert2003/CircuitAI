#include "../src/common.as"
#include "../src/unit.as"

namespace Init {

	SInitInfo AiInit()
	{
		AiLog("hard_aggressive AngelScript Rules!");

		SInitInfo data;
		data.armor = InitArmordef();
		data.category = InitCategories();
		@data.profile = @(array<string> = {"behaviour", "block_map", "build_chain", "commander", "economy", "metal_map", "factory", "response", "weapons", "lanes", "field"});
		if (string(aiSetupMgr.GetModOptions()["experimentallegionfaction"]) == "1")
			data.profile.insertAt(data.profile.length(), {"behaviour_leg", "build_chain_leg", "commander_leg", "economy_leg", "factory_leg"});
		return data;
	}

}