#include "../define.as"
#include "../helpers/common/generic_helpers.as"
#include "../global.as"
#include "../types/role_config.as"
#include "../helpers/spatial/map_helpers.as"
#include "../systems/team/team_economy.as"

namespace Economy {

	// To not reset army requirement on factory switch, @see Factory::AiIsSwitchAllowed

	void AiLoad(IStream& istream)
	{
	}

	void AiSave(OStream& ostream)
	{
	}

	/*
	* struct SResourceInfo {
	*   const float current;
	*   const float storage;
	*   const float pull;
	*   const float income;
	* }
	*/
	void AiUpdateEconomy()
	{
		if (aiFactoryMgr.GetEnemyReclaimMisses() > 0)
			Invariants::Violation("INV-128", "turret.enemy", "eligible construction turret failed to take highest-priority enemy reclaim");
		const SResourceInfo@ metal = aiEconomyMgr.metal;
		const SResourceInfo@ energy = aiEconomyMgr.energy;

		// Update sliding-window minima trackers (10-second window)
		_UpdateSlidingMinima(ai.frame, metal.income, energy.income);

		aiEconomyMgr.isMetalEmpty = metal.current < metal.storage * 0.2f;
		aiEconomyMgr.isMetalFull = metal.current > metal.storage * 0.8f;
		aiEconomyMgr.isEnergyEmpty = energy.current < energy.storage * 0.1f;
		if (aiEconomyMgr.isMetalEmpty) {
			GenericHelpers::LogUtil("Metal Empty", 2);
			aiEconomyMgr.isEnergyStalling = aiEconomyMgr.isEnergyEmpty
				|| ((energy.income < energy.pull) && (energy.current < energy.storage * 0.3f));
		} else {
			aiEconomyMgr.isEnergyStalling = aiEconomyMgr.isEnergyEmpty
				|| ((energy.income < energy.pull) && (energy.current < energy.storage * 0.4f));
		}
		// NOTE: Default energy-to-metal conversion TeamRulesParam "mmLevel" = 0.75
		aiEconomyMgr.isEnergyFull = energy.current > energy.storage * 0.88f;

		// isSwitchAssist = isSwitchAssist && aiFactoryMgr.isAssistRequired;
		//aiFactoryMgr.isAssistRequired = false;
		// 	|| ((metal.current > metal.storage * 0.2f) && !aiEconomyMgr.isEnergyStalling);

		// Then allow role-specific adjustments
		RoleConfig@ cfg = (Global::profileController is null) ? null : Global::profileController.RoleCfg;
		if (cfg !is null && cfg.EconomyUpdateHandler !is null) {
			cfg.EconomyUpdateHandler();
		}

		// D-175: one overflow policy and cooldown for every experimental role.
		TeamEconomy::ShareOverflow();
		Invariants::CheckTeamShare();
		Invariants::CheckNonBuildPowerBuilders();   // D-293: INV-204, every role
	}

	/**************************************
	 * Rolling 10-second minimums (metal/energy)
	 * - Maintains monotonic deques per resource for O(1) amortized updates
	 * - Window length = 10 * SECOND frames
	 **************************************/

	// Small monotonic queue utility for sliding minimums
	class _SlidingMinQueue {
		array<int> frames;   // sample frame indices (monotonic increasing)
		array<float> values; // corresponding values; monotone non-decreasing across queue
		uint head;

		_SlidingMinQueue() { head = 0; }

		void push(int frameIdx, float v, int windowFrames) {
			// Maintain monotonicity by popping larger-or-equal values from the back
			while (values.length() > head) {
				uint backIdx = values.length() - 1;
				if (values[backIdx] >= v) {
					values.removeLast();
					frames.removeLast();
				} else {
					break;
				}
			}
			frames.insertLast(frameIdx);
			values.insertLast(v);
			// Drop out-of-window samples from the front
			int threshold = frameIdx - windowFrames;
			while (values.length() > head && frames[head] <= threshold) {
				head++;
			}
			// Compact occasionally to avoid unbounded head growth
			if (int(head) > 512 && int(head) * 2 > int(frames.length())) {
				_compact();
			}
		}

		float getMin(int frameIdx, int windowFrames, float fallback) {
			int threshold = frameIdx - windowFrames;
			while (values.length() > head && frames[head] <= threshold) {
				head++;
			}
			if (values.length() <= head) return fallback;
			return values[head];
		}

		void _compact() {
			array<int> nf; nf.reserve(frames.length() - head);
			array<float> nv; nv.reserve(values.length() - head);
			for (uint i = head; i < frames.length(); ++i) {
				nf.insertLast(frames[i]);
				nv.insertLast(values[i]);
			}
			frames = nf;
			values = nv;
			head = 0;
		}
	}

	// Shared window length (frames)
	const int _WINDOW_10S_FRAMES = 10 * SECOND;
	_SlidingMinQueue _metalMin10s;
	_SlidingMinQueue _energyMin10s;
	int _incomeFirstSample = -1, _incomeLastSample = -1;

	void _UpdateSlidingMinima(int frameIdx, float metalIncome, float energyIncome)
	{
		if (_incomeFirstSample < 0 || frameIdx < _incomeLastSample || frameIdx - _incomeLastSample > 2 * SECOND)
			_incomeFirstSample = frameIdx;
		_incomeLastSample = frameIdx;
		_metalMin10s.push(frameIdx, metalIncome, _WINDOW_10S_FRAMES);
		_energyMin10s.push(frameIdx, energyIncome, _WINDOW_10S_FRAMES);
	}
	bool IncomeWindowReady()
	{
		return _incomeFirstSample >= 0 && ai.frame - _incomeFirstSample >= _WINDOW_10S_FRAMES
			&& ai.frame - _incomeLastSample <= 2 * SECOND;
	}

	// Public getters: minimum income over the last 10 seconds (frame-based window)
	float GetMinMetalIncomeLast10s()
	{
		// Fallback to current income if window queue is empty
		return _metalMin10s.getMin(ai.frame, _WINDOW_10S_FRAMES, aiEconomyMgr.metal.income);
	}

	float GetMinEnergyIncomeLast10s()
	{
		return _energyMin10s.getMin(ai.frame, _WINDOW_10S_FRAMES, aiEconomyMgr.energy.income);
	}

	// Mex tracking helper to ensure we only upgrade our own MEXes
	namespace MexTracker
	{
		class MexInfo
		{
			AIFloat3 pos;
			bool isUpgraded;
			bool isUpgradeInProgress;

			MexInfo(const AIFloat3& in p)
			{
				pos = p;
				isUpgraded = false;
				isUpgradeInProgress = false;
			}
		}		
		
		array<MexInfo @> myMexes;

		void RegisterMex(const AIFloat3& in pos)
		{
			if (IsOwnedMex(pos))
				return;

			MexInfo @info = MexInfo(pos);
			myMexes.insertLast(info);
			GenericHelpers::LogUtil("[ECONOMY][MexTracker] Registered owned MEX at (" + pos.x + "," + pos.z + ")", 3);
		}

		void MarkUpgraded(const AIFloat3& in pos)
		{
			const float tolerance = 35.0f;
			for (uint i = 0; i < myMexes.length(); ++i)
			{
				if (MapHelpers::IsInRange(pos, myMexes[i].pos, tolerance))
				{
					if (!myMexes[i].isUpgraded)
					{
						myMexes[i].isUpgraded = true;
						GenericHelpers::LogUtil("[ECONOMY][MexTracker] Marked MEX at (" + pos.x + "," + pos.z + ") as upgraded", 3);
					}
					return;
				}
			}
		}

		void MarkUpgradeInProgress(const AIFloat3& in pos, bool inProgress)
		{
			const float tolerance = 35.0f;
			for (uint i = 0; i < myMexes.length(); ++i)
			{
				if (MapHelpers::IsInRange(pos, myMexes[i].pos, tolerance))
				{
					myMexes[i].isUpgradeInProgress = inProgress;
					GenericHelpers::LogUtil("[ECONOMY][MexTracker] Marked MEX at (" + pos.x + "," + pos.z + ") as upgrade in progress: " + inProgress, 3);
					return;
				}
			}
		}

		bool IsOwnedMex(const AIFloat3& in pos)
		{
			const float tolerance = 35.0f;
			for (uint i = 0; i < myMexes.length(); ++i)
			{
				if (MapHelpers::IsInRange(pos, myMexes[i].pos, tolerance))
				{
					return true;
				}
			}
			return false;
		}

		AIFloat3 GetNearestNonUpgradedMex(const AIFloat3& in unitPos)
		{
			AIFloat3 bestPos;
			float bestDistSq = 3.402823466e+38F;
			bool found = false;

			for (uint i = 0; i < myMexes.length(); ++i)
			{
				if (myMexes[i].isUpgraded || myMexes[i].isUpgradeInProgress)
					continue;

				float d = MapHelpers::SqDist(unitPos, myMexes[i].pos);
				
				if (d < bestDistSq)
				{
					bestDistSq = d;
					bestPos = myMexes[i].pos;
					found = true;
				}
			}

			if (found)
				return bestPos;
			return AIFloat3(-1, -1, -1);
		}

		AIFloat3 GetNearestNonUpgradedMexInRange(const AIFloat3& in unitPos, const AIFloat3& in center, float radius,
            CCircuitUnit@ worker = null, CCircuitDef@ upgrade = null)
		{
			AIFloat3 bestPos;
			float bestDistSq = 3.402823466e+38F;
			bool found = false;

			for (uint i = 0; i < myMexes.length(); ++i)
			{
				if (myMexes[i].isUpgraded || myMexes[i].isUpgradeInProgress)
					continue;

				if (MapHelpers::IsInRange(myMexes[i].pos, center, radius))
				{
					float d = MapHelpers::SqDist(unitPos, myMexes[i].pos);
					if (d < bestDistSq)
					{
                        // Optional admission for actual upgrade orders. Keep
                        // tracker-only prerequisite queries unchanged. A cliff,
                        // water-depth mismatch or unsafe approach must not make
                        // every spare worker allocate the same doomed upgrade.
                        // Read live safety; never blacklist a spot by timeout.
                        if (worker !is null && upgrade !is null
                            && (!aiTerrainMgr.CanUpgradeTerrain(upgrade, myMexes[i].pos)
                                || !aiTerrainMgr.CanReachAtSafe(worker, myMexes[i].pos,
                                    worker.circuitDef.GetBuildDistance()))) continue;
						bestDistSq = d;
						bestPos = myMexes[i].pos;
						found = true;
					}
				}
			}

			if (found)
				return bestPos;
			return AIFloat3(-1, -1, -1);
		}

		int GetOwnedMexCountInRange(const AIFloat3& in center, float radius)
		{
			int count = 0;
			for (uint i = 0; i < myMexes.length(); ++i)
			{
				if (MapHelpers::IsInRange(myMexes[i].pos, center, radius))
				{
					count++;
				}
			}
			return count;
		}

		bool AnyUpgradeInProgressNear(const AIFloat3& in pos, float radius)
		{
			const float r2 = radius * radius;
			for (uint i = 0; i < myMexes.length(); ++i)
			{
				if (myMexes[i].isUpgradeInProgress)
				{
					if (MapHelpers::SqDist(myMexes[i].pos, pos) <= r2)
					{
						return true;
					}
				}
			}
			return false;
		}
	}

}  // namespace Economy
