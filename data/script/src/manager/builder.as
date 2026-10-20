#include "../unit.as"
#include "../task.as"
#include "../global.as"
#include "../helpers/common/generic_helpers.as"
// Unit helpers for selecting defs by side
#include "../helpers/units/unit_helpers.as"
// UnitDef helpers for counts
#include "../helpers/units/unitdef_helpers.as"
// Guard assignment helper utilities
#include "../helpers/construction/guard_helpers.as"
// Map helpers (distance/range checks)
#include "../helpers/spatial/map_helpers.as"
// Shared enum for strategic building types
#include "../types/building_type.as"
// Team state: T1 constructor registry for orphan rescue
#include "../systems/team/team.as"
#include "../systems/team/ferry.as"
#include "../systems/construction/layout.as"
#include "../systems/team/sea_assist.as"

namespace Builder {
	// CCircuitUnit is registered as asOBJ_NOCOUNT (see InitScript.cpp).
	// Script handles do not keep the native alive; any method/property may deref freed memory.
	// Always pass Ids around and reacquire a live unit with ai.GetTeamUnit(id) before native calls.
	IUnitTask@ MakeDefaultTaskWithLog(Id unitId, const string &in roleLabel)
	{
		CCircuitUnit@ v = ai.GetTeamUnit(unitId);
		if (v is null) {
			// Unit died/transferred; nothing to do
			return null;
		}

		// Safe: call native with a freshly reacquired handle
		IUnitTask@ t = aiBuilderMgr.DefaultMakeTask(v);

		// Defensive logging (avoid builder-only calls unless you’re sure of the type)
		string taskTypeStr = "<null>";
		if (t !is null) {
			taskTypeStr = "" + t.GetType();
		}

		string unitDefName = (v.circuitDef !is null) ? v.circuitDef.GetName() : "<null>";
		const AIFloat3 p = v.GetPos(ai.frame);

		GenericHelpers::LogUtil("[" + roleLabel + "][Builder] DefaultMakeTask created: taskType=" + taskTypeStr +
			" unitDef=" + unitDefName + " pos=(" + p.x + "," + p.z + ")", 3);

		// If this is a builder task, log the build definition details for better visibility
		if (t !is null && Task::Type(t.GetType()) == Task::Type::BUILDER) {
			string buildDefName; int buildTypeVal;
			ExtractTaskBuildMeta(t, buildDefName, buildTypeVal);
			if (buildDefName.length() > 0) {
				GenericHelpers::LogUtil("[" + roleLabel + "][Builder] Build meta: def='" + buildDefName + "' buildType=" + buildTypeVal, 3);
			} else {
				GenericHelpers::LogUtil("[" + roleLabel + "][Builder] Build meta: <no construction buildDef> buildType=" + buildTypeVal, 4);
			}
		}

		return t;
	}

	/******************************************************************************
    
	BUILDER STATE (moved from Global::Units)
    
	******************************************************************************/
	CCircuitUnit@ commander = null;
	dictionary commanderGuards;

	// Tactical constructor configuration (global)
	// When enabled, the first constructor encountered of a category becomes its tactical constructor.
	// Guards will prefer assisting the category tactical constructor before the leaders of that same category.
	bool TacticalEnabled = false;

	CCircuitUnit@ tacticalBotConstructor = null;     dictionary tacticalBotConstructorGuards;
	CCircuitUnit@ tacticalVehConstructor = null;     dictionary tacticalVehConstructorGuards;
	CCircuitUnit@ tacticalAirConstructor = null;     dictionary tacticalAirConstructorGuards;
	CCircuitUnit@ tacticalSeaConstructor = null;     dictionary tacticalSeaConstructorGuards;
	CCircuitUnit@ tacticalHoverConstructor = null;   dictionary tacticalHoverConstructorGuards;

	CCircuitUnit@ freelanceT2BotConstructor = null;
	CCircuitUnit@ freelanceT2VehConstructor = null;
	CCircuitUnit@ freelanceT2AirConstructor = null;
	CCircuitUnit@ freelanceT2SeaConstructor = null;
	// HOVER freelance (T1 only)
	CCircuitUnit@ freelanceT1HoverConstructor = null;

	// NOTE: These refer specifically to BOT constructors (T1/T2). Aircraft/vehicle variants may be added later.
	CCircuitUnit@ primaryT1BotConstructor = null;
	CCircuitUnit@ secondaryT1BotConstructor = null;
	CCircuitUnit@ primaryT2BotConstructor = null;
	CCircuitUnit@ secondaryT2BotConstructor = null;

	// VEHICLE constructors (T1/T2)
	CCircuitUnit@ primaryT1VehConstructor = null;
	CCircuitUnit@ secondaryT1VehConstructor = null;
	CCircuitUnit@ primaryT2VehConstructor = null;
	CCircuitUnit@ secondaryT2VehConstructor = null;

	// AIR constructors (T1/T2)
	CCircuitUnit@ primaryT1AirConstructor = null;
	CCircuitUnit@ secondaryT1AirConstructor = null;
	CCircuitUnit@ primaryT2AirConstructor = null;
	CCircuitUnit@ secondaryT2AirConstructor = null;

	// SEA constructors (T1/T2)
	CCircuitUnit@ primaryT1SeaConstructor = null;
	CCircuitUnit@ secondaryT1SeaConstructor = null;
	CCircuitUnit@ primaryT2SeaConstructor = null;
	CCircuitUnit@ secondaryT2SeaConstructor = null;

	// HOVER constructors (T1 only)
	CCircuitUnit@ primaryT1HoverConstructor = null;
	CCircuitUnit@ secondaryT1HoverConstructor = null;

	// Lookup which unit a constructor is guarding.
	// Key: constructor unit id as string; Value: CCircuitUnit@ of the guarded unit
	dictionary primaryT1BotConstructorGuards;
	dictionary secondaryT1BotConstructorGuards;
	dictionary primaryT2BotConstructorGuards;
	dictionary secondaryT2BotConstructorGuards;

	// Vehicle guard maps
	dictionary primaryT1VehConstructorGuards;
	dictionary secondaryT1VehConstructorGuards;
	dictionary primaryT2VehConstructorGuards;
	dictionary secondaryT2VehConstructorGuards;

	// Aircraft guard maps
	dictionary primaryT1AirConstructorGuards;
	dictionary secondaryT1AirConstructorGuards;
	dictionary primaryT2AirConstructorGuards;
	dictionary secondaryT2AirConstructorGuards;

	// Sea guard maps
	dictionary primaryT1SeaConstructorGuards;
	dictionary secondaryT1SeaConstructorGuards;
	dictionary primaryT2SeaConstructorGuards;
	dictionary secondaryT2SeaConstructorGuards;

	// Hover guard maps (T1 only)
	dictionary primaryT1HoverConstructorGuards;
	dictionary secondaryT1HoverConstructorGuards;

	// Pool of unassigned workers (builders not currently guarding primary/secondary leaders)
	// Key: worker id as string; Value: CCircuitUnit@ of the worker
	dictionary unassignedWorkers;

	// Map of per-builder current task assignment
	// Key: builder unit id as string; Value: IUnitTask@ currently assigned to that builder
	dictionary builderCurrentTasks;

	// Builders eligible for task tracking (to reduce overhead). We only track
	// primary, secondary, and tactical constructors across categories.
	dictionary trackEligibleBuilders; // key: builder unit id string -> true

	// --- Eligibility helpers (performance) ---
	void _TrackEligibleClearAll()
	{
		array<string>@ keys = trackEligibleBuilders.getKeys();
		if (keys is null) return;
		for (uint i = 0; i < keys.length(); ++i) {
			trackEligibleBuilders.delete(keys[i]);
		}
	}

	void _TrackEligibleSet(CCircuitUnit@ u)
	{
		if (u is null) return;
		string key = "" + u.id;
		// store a dummy bool true (as string) to mark presence
		trackEligibleBuilders.set(key, true);
	}

	bool IsBuilderTrackEligible(CCircuitUnit@ u)
	{
 		if (u is null) return false;
 		string key = "" + u.id;
 		// exists() first. A failed dictionary.get leaves a primitive &out
 		// UNDEFINED - the temporary it is passed through is never initialised
 		// and is copied back regardless of the return value - so the "= false"
 		// here was overwritten with junk for every builder not yet in the table.
 		if (!trackEligibleBuilders.exists(key)) return false;
 		bool present = false;
 		trackEligibleBuilders.get(key, present);
 		return present;
	}

	void RecomputeTrackEligibleBuilders()
	{
		GenericHelpers::LogUtil("[BUILDER] RecomputeTrackEligibleBuilders: enter", 5);
		// Reset and mark all leaders (primary/secondary) and all tacticals
		_TrackEligibleClearAll();
		// Bots
		_TrackEligibleSet(Builder::primaryT1BotConstructor);
		_TrackEligibleSet(Builder::secondaryT1BotConstructor);
		_TrackEligibleSet(Builder::primaryT2BotConstructor);
		_TrackEligibleSet(Builder::secondaryT2BotConstructor);
		// Vehicles
		_TrackEligibleSet(Builder::primaryT1VehConstructor);
		_TrackEligibleSet(Builder::secondaryT1VehConstructor);
		_TrackEligibleSet(Builder::primaryT2VehConstructor);
		_TrackEligibleSet(Builder::secondaryT2VehConstructor);
		// Aircraft
		_TrackEligibleSet(Builder::primaryT1AirConstructor);
		_TrackEligibleSet(Builder::secondaryT1AirConstructor);
		_TrackEligibleSet(Builder::primaryT2AirConstructor);
		_TrackEligibleSet(Builder::secondaryT2AirConstructor);
		// Sea
		_TrackEligibleSet(Builder::primaryT1SeaConstructor);
		_TrackEligibleSet(Builder::secondaryT1SeaConstructor);
		_TrackEligibleSet(Builder::primaryT2SeaConstructor);
		_TrackEligibleSet(Builder::secondaryT2SeaConstructor);
		// Hover (T1 only)
		_TrackEligibleSet(Builder::primaryT1HoverConstructor);
		_TrackEligibleSet(Builder::secondaryT1HoverConstructor);
		// Tacticals (all categories)
		_TrackEligibleSet(Builder::tacticalBotConstructor);
		_TrackEligibleSet(Builder::tacticalVehConstructor);
		_TrackEligibleSet(Builder::tacticalAirConstructor);
		_TrackEligibleSet(Builder::tacticalSeaConstructor);
		_TrackEligibleSet(Builder::tacticalHoverConstructor);

		// Optional cleanup: drop any existing per-unit tracking for builders which are no longer eligible
		array<string>@ tkeys = taskTrackByUnit.getKeys();
		if (tkeys !is null) {
			for (uint i = 0; i < tkeys.length(); ++i) {
				BuilderTaskTrack@ tr = null;
				if (_TaskTrackGet(tkeys[i], @tr) && tr !is null) {
					if (!IsBuilderTrackEligible(tr.unit)) {
						_TaskTrackDelete(tkeys[i]);
						GenericHelpers::LogUtil("[BUILDER] RecomputeTrackEligibleBuilders: cleared tracking for ineligible builder id=" + (tr.unit is null ? "<null>" : "" + tr.unit.id), 6);
					}
				}
			}
		}
	}

	/****************************************************************************

	TASK TRACKING (per-requested builder) – best-effort owner and start estimate

	****************************************************************************/
	class BuilderTaskTrack {
		IUnitTask@ task;          // task handle (as returned by enqueue)
		CCircuitUnit@ unit;       // requesting unit (likely owner)
		bool isTaskAdded;         // set true when AiTaskAdded observes this task
		int createdFrame;         // creation frame
		int graceUntilFrame;      // allow-through window (no gating) until this frame
		int timeoutFrame;         // after this, forget and allow role handlers to proceed
		string defName;           // cached def name at enqueue time (safe for counters)
		int buildTypeVal;         // cached Task::BuildType value at enqueue time

		BuilderTaskTrack() { isTaskAdded = false; createdFrame = 0; graceUntilFrame = 0; timeoutFrame = 0; }

	}

	// Pure helper: does this builder BuildType normally carry a buildDef and represent a construction task?
	bool _IsConstructionBuildType(Task::BuildType bt)
	{
		return (
			bt == Task::BuildType::FACTORY ||  // factory/lab
			bt == Task::BuildType::NANO    ||  // caretaker/buildpower
			bt == Task::BuildType::PYLON   ||
			bt == Task::BuildType::ENERGY  ||
			bt == Task::BuildType::GEO     ||
			bt == Task::BuildType::GEOUP   ||
			bt == Task::BuildType::DEFENCE ||
			bt == Task::BuildType::BUNKER  ||
			bt == Task::BuildType::BIG_GUN ||
			bt == Task::BuildType::RADAR   ||
			bt == Task::BuildType::SONAR   ||
			bt == Task::BuildType::CONVERT ||
			bt == Task::BuildType::MEX     ||
			bt == Task::BuildType::MEXUP
		);
	}

	// Pure helper: safely extract build metadata from a task without risking null derefs
	void ExtractTaskBuildMeta(IUnitTask@ t, string &out defName, int &out buildTypeVal)
	{
		defName = "";
		buildTypeVal = -1;
		if (t is null) return;
		IBuilderTask@ builderTask = cast<IBuilderTask>(t);
		if (builderTask is null) return;
		int btVal = builderTask.GetBuildType();
		buildTypeVal = btVal;
		Task::BuildType bt = Task::BuildType(btVal);
		if (!_IsConstructionBuildType(bt)) return;
		CCircuitDef@ d = builderTask.buildDef;
		if (d !is null) defName = d.GetName();
	}

	// Per-unit tracking (O(1) by builder id)
	dictionary taskTrackByUnit;  // key: builder id string -> BuilderTaskTrack@

	// Safe accessors for taskTrackByUnit (no array copies; guarded and logged)
	array<string>@ _TaskTrackKeys()
	{
		GenericHelpers::LogUtil("[BUILDER] TaskTrackKeys: enter", 6);
		array<string>@ keys = taskTrackByUnit.getKeys();
		if (keys is null) {
			GenericHelpers::LogUtil("[BUILDER] TaskTrackKeys: <null>", 5);
		}
		return keys;
	}

	bool _TaskTrackSet(const string &in key, BuilderTaskTrack@ tr)
	{
		GenericHelpers::LogUtil("[BUILDER] TaskTrackSet: enter", 6);
		if (key.length() == 0) {
			GenericHelpers::LogUtil("[BUILDER] TaskTrackSet: skip empty key", 5);
			return false;
		}
		if (tr is null) {
			GenericHelpers::LogUtil("[BUILDER] TaskTrackSet: skip null track key=" + key, 5);
			return false;
		}
		taskTrackByUnit.set(key, @tr);
		GenericHelpers::LogUtil("[BUILDER] TaskTrackSet key=" + key, 5);
		return true;
	}

	bool _TaskTrackGet(const string &in key, BuilderTaskTrack@ &out tr)
	{
		GenericHelpers::LogUtil("[BUILDER] TaskTrackGet: enter", 6);
		@tr = null;
		if (key.length() == 0) return false;
		bool ok = taskTrackByUnit.get(key, @tr);
		if (!ok || tr is null) {
			GenericHelpers::LogUtil("[BUILDER] TaskTrackGet: miss key=" + key, 5);
			return false;
		}
		return true;
	}

	bool _TaskTrackDelete(const string &in key)
	{
		GenericHelpers::LogUtil("[BUILDER] TaskTrackDelete: enter", 6);
		if (key.length() == 0) return false;
		bool had = false;
		BuilderTaskTrack@ tmp = null;
		if (taskTrackByUnit.get(key, @tmp) && tmp !is null) had = true;
		taskTrackByUnit.delete(key);
		GenericHelpers::LogUtil("[BUILDER] TaskTrackDelete key=" + key + " had=" + (had ? "true" : "false"), 5);
		return had;
	}

	BuilderTaskTrack@ _TaskTrackFindByTask(IUnitTask@ task)
	{
		GenericHelpers::LogUtil("[BUILDER] GetTrackByTask: enter", 6);
		if (task is null) return null;
		array<string>@ keys = _TaskTrackKeys();
		if (keys is null) return null;
		for (uint i = 0; i < keys.length(); ++i) {
			BuilderTaskTrack@ tr = null;
			if (_TaskTrackGet(keys[i], @tr) && tr !is null && tr.task is task) {
				return tr;
			}
		}
		return null;
	}

	bool _TaskTrackMarkAddedByTask(IUnitTask@ task)
	{
		GenericHelpers::LogUtil("[BUILDER] MarkTaskAddedIfTracked: enter", 6);
		if (task is null) return false;
		BuilderTaskTrack@ tr = _TaskTrackFindByTask(task);
		if (tr is null) return false;
		tr.isTaskAdded = true;
		GenericHelpers::LogUtil("[BUILDER] MarkTaskAddedIfTracked: task marked added for builderKey=" + (tr.unit is null ? "<null>" : "" + tr.unit.id), 3);
		return true;
	}

	// Helpers to manage BuilderTaskTrack lifecycle
	void TrackTaskForBuilder(CCircuitUnit@ u, IUnitTask@ t, int graceFrames, int timeoutFrames)
	{
		GenericHelpers::LogUtil("[BUILDER] TrackTaskForBuilder: enter", 5);
		if (u is null || t is null) return;
		string key = "" + u.id;
		GenericHelpers::LogUtil("[BUILDER] TrackTaskForBuilder: key=" + key, 6);
		BuilderTaskTrack@ tr = BuilderTaskTrack();
		@tr.unit = u;
		@tr.task = t;
		tr.createdFrame = ai.frame;
		tr.graceUntilFrame = ai.frame + (graceFrames > 0 ? graceFrames : 0);
		tr.timeoutFrame = ai.frame + (timeoutFrames > 0 ? timeoutFrames : 0);
		// Cache metadata safely via helper to avoid task deref on unsupported types
		GenericHelpers::LogUtil("[BUILDER] TrackTaskForBuilder: cache defName and buildTypeVal", 6);
		ExtractTaskBuildMeta(t, tr.defName, tr.buildTypeVal);
		_TaskTrackSet(key, @tr);
		// Verbose diagnostics
		string dn = tr.defName;
		GenericHelpers::LogUtil("[BUILDER] TrackTaskForBuilder id=" + u.id + " def='" + dn + "' grace=" + graceFrames + " timeout=" + timeoutFrames, 3);
	}

	BuilderTaskTrack@ GetTrackForBuilder(CCircuitUnit@ u)
	{
		GenericHelpers::LogUtil("[BUILDER] GetTrackForBuilder: enter", 6);
		if (u is null) return null;
		string key = "" + u.id;
		BuilderTaskTrack@ tr = null;
		if (!_TaskTrackGet(key, @tr)) return null;
		return tr;
	}

	void ClearTrackByBuilder(CCircuitUnit@ u)
	{
		GenericHelpers::LogUtil("[BUILDER] ClearTrackByBuilder: enter", 6);
		if (u is null) return;
		string key = "" + u.id;
		_TaskTrackDelete(key);
	}

	void ClearTrackByTask(IUnitTask@ task)
	{
		GenericHelpers::LogUtil("[BUILDER] ClearTrackByTask: enter", 6);
		if (task is null) return;
		array<string>@ keys = _TaskTrackKeys();
		if (keys is null) return;
		for (uint i = 0; i < keys.length(); ++i) {
			BuilderTaskTrack@ tr = null;
			if (_TaskTrackGet(keys[i], @tr) && tr !is null && tr.task is task) {
				_TaskTrackDelete(keys[i]);
				break;
			}
		}
	}

	void MarkTaskAddedIfTracked(IUnitTask@ task)
	{
		GenericHelpers::LogUtil("[BUILDER] MarkTaskAddedIfTracked: enter", 6);
		if (!_TaskTrackMarkAddedByTask(task)) {
			GenericHelpers::LogUtil("[BUILDER] MarkTaskAddedIfTracked: no tracked entry for task", 4);
		}
	}

	// Helper: find track by task handle (linear scan; small number of builders)
	BuilderTaskTrack@ GetTrackByTask(IUnitTask@ task)
	{
		GenericHelpers::LogUtil("[BUILDER] GetTrackByTask: enter", 6);
		return _TaskTrackFindByTask(task);
	}

	void ClearBuilderTaskByUnit(CCircuitUnit@ u) {
		GenericHelpers::LogUtil("[BUILDER] ClearBuilderTaskByUnit: enter", 6);
		if (u is null) return;
		string key = "" + u.id;
		builderCurrentTasks.delete(key);
	}

	// Note: AngelScript dictionary only supports string keys; we cannot key directly by task handle.
	// For removal by task, scan over the builderCurrentTasks values and compare handle identity (fast enough for number of builders).
	void ClearBuilderTaskByTask(IUnitTask@ task) {
		GenericHelpers::LogUtil("[BUILDER] ClearBuilderTaskByTask: enter", 6);
		if (task is null) return;
		array<string>@ keys = builderCurrentTasks.getKeys();
		if (keys is null) return;

		for (uint i = 0; i < keys.length(); ++i) {
			IUnitTask@ t = null;
			if (builderCurrentTasks.get(keys[i], @t) && (t !is null) && (t is task)) {
				builderCurrentTasks.delete(keys[i]);
				break;
			}
		}
	}

	// Internal helpers to manage the unassigned pool
	void _UnassignedAdd(CCircuitUnit@ u) {
		GenericHelpers::LogUtil("[BUILDER] _UnassignedAdd: enter", 6);
		if (u is null) return;
		string key = "" + u.id;
		unassignedWorkers.set(key, @u);
	}
	void _UnassignedRemove(CCircuitUnit@ u) {
		GenericHelpers::LogUtil("[BUILDER] _UnassignedRemove: enter", 6);
		if (u is null) return;
		string key = "" + u.id;
		unassignedWorkers.delete(key);
	}

	// Build queue counters/flags
	// T2 bot labs: use a queued counter like fusion/afus
	bool IsFusionQueued = false;
	bool IsAdvancedFusionQueued = false;
	// Counts of queued Fusion/Advanced Fusion build tasks (across all roles)
	int FusionQueuedCount = 0;
	int AdvancedFusionQueuedCount = 0;

	// Build tasks for an in-progress reactor, retained from enqueue time so that
	// spare build power can be redirected onto them. IUnitTask is reference-counted
	// (doc/angelscript-references.md), so these handles are safe to hold across
	// callbacks; they are released in AiTaskRemoved.
	IUnitTask@ FusionBuildTask = null;
	IUnitTask@ AdvancedFusionBuildTask = null;
	// The most recent T1 energy structure this script queued (solar, advanced
	// solar, converter). While it is under construction, spare constructors
	// assist it instead of starting the next one: build power on one structure
	// finishes it sooner, and a constructor whose assist ends with the structure
	// re-plans at once. Released in AiTaskRemoved.
	IUnitTask@ EnergyBuildTask = null;
	array<IUnitTask@> EnergyAssistTasks;  // live assists on EnergyBuildTask's target
	// Counts of queued Gantry (experimental) build tasks
	int LandGantryQueuedCount = 0;
	int WaterGantryQueuedCount = 0;
	// Counts of queued Nuclear Silo build tasks (across all factions)
	int NukeSiloQueuedCount = 0;
	// Track queued states for other factory types similar to IsT2LabQueued

	// Cooldown tracking (frames)
	const int T2_FACTORY_COOLDOWN_FRAMES = 180 * SECOND;   // cooldown for any T2 factory (bot/veh/air/ship)
	const int GANTRY_COOLDOWN_FRAMES     = 120 * SECOND;   // cooldown for gantry
	const int T1_AIR_FACTORY_COOLDOWN_FRAMES = 120 * SECOND; // cooldown for T1 aircraft plant
	const int T1_BOT_LAB_COOLDOWN_FRAMES    = 120 * SECOND; // cooldown for T1 bot lab
	const int T1_HOVER_FACTORY_COOLDOWN_FRAMES = 90 * SECOND; // cooldown for T1 hover plants (land or floating)
	const int T1_SHIPYARD_COOLDOWN_FRAMES = 120 * SECOND;   // cooldown for T1 shipyard
	const int T1_CONVERTER_COOLDOWN_FRAMES = 15 * SECOND;  // cooldown for T1 energy converter
	const int T1_SOLAR_COOLDOWN_FRAMES     = 25 * SECOND;  // cooldown for T1 solar
	// A constructor blocked by a cooldown assists the structure the last one
	// started (up to this many), or guards that builder for this long.
	const int COOLDOWN_ASSIST_MAX             = 3;
	const int COOLDOWN_GUARD_TIMEOUT_FRAMES   = 30 * SECOND;
	// Independent cooldowns for nanos and advanced solars
	const int NANO_BASE_COOLDOWN_FRAMES       = 2 * SECOND;   // base cooldown between nano caretaker enqueues
	const int NANO_LOW_METAL_COOLDOWN_FRAMES  = 30 * SECOND;  // cooldown when metal income is very low
	const int ADV_SOLAR_COOLDOWN_FRAMES       = 30 * SECOND;  // 120s between advanced solar enqueues
	//const int ADV_CONVERTER_COOLDOWN_FRAMES = 60 * SECOND; // 60s between advanced converter enqueues
	// Anti-nuke cooldown: prevent rapid consecutive anti-nuke structure builds
	const int ANTI_NUKE_COOLDOWN_FRAMES  = 180 * SECOND;   // 60s between anti-nuke enqueues
	
	int lastT2FactoryEnqueueFrame = -1000000000; // generic: air/shipyard or legacy
	// Separate cooldown stamps for Bot vs Vehicle T2 labs
	int lastT2BotFactoryEnqueueFrame = -1000000000;
	int lastT2VehFactoryEnqueueFrame = -1000000000;
	int lastGantryEnqueueFrame    = -1000000000; // far in the past
	int lastT1AirFactoryEnqueueFrame = -1000000000;
	int lastT1BotLabEnqueueFrame     = -1000000000;
	int lastT1HoverFactoryEnqueueFrame = -1000000000;
	int lastT1ShipyardEnqueueFrame = -1000000000;
	int lastNanoEnqueueFrame      = -1000000000;
	int lastAdvSolarEnqueueFrame  = -1000000000;
	int lastAdvConverterEnqueueFrame = -1000000000;
	int lastAntiNukeEnqueueFrame  = -1000000000;
	int lastT1ConverterEnqueueFrame = -1000000000;
	int lastT1SolarEnqueueFrame   = -1000000000;
	int lastT1SolarBuilderId      = -1;
	int lastAdvSolarBuilderId     = -1;

	// Cooldown helpers
	// Generic (used for T2 air/shipyard unless specialized)
	bool IsT2FactoryOffCooldown() { return (ai.frame - lastT2FactoryEnqueueFrame) >= T2_FACTORY_COOLDOWN_FRAMES; }
	void MarkT2FactoryEnqueued()  { lastT2FactoryEnqueueFrame = ai.frame; }
	// Specialized: T2 Bot Labs
	bool IsT2BotFactoryOffCooldown() { return (ai.frame - lastT2BotFactoryEnqueueFrame) >= T2_FACTORY_COOLDOWN_FRAMES; }
	void MarkT2BotFactoryEnqueued()  { lastT2BotFactoryEnqueueFrame = ai.frame; }
	// Specialized: T2 Vehicle Plants
	bool IsT2VehFactoryOffCooldown() { return (ai.frame - lastT2VehFactoryEnqueueFrame) >= T2_FACTORY_COOLDOWN_FRAMES; }
	void MarkT2VehFactoryEnqueued()  { lastT2VehFactoryEnqueueFrame = ai.frame; }
	bool IsGantryOffCooldown()    { return (ai.frame - lastGantryEnqueueFrame) >= GANTRY_COOLDOWN_FRAMES; }
	void MarkGantryEnqueued()     { lastGantryEnqueueFrame = ai.frame; }
	bool IsT1AirFactoryOffCooldown() { return (ai.frame - lastT1AirFactoryEnqueueFrame) >= T1_AIR_FACTORY_COOLDOWN_FRAMES; }
	void MarkT1AirFactoryEnqueued()  { lastT1AirFactoryEnqueueFrame = ai.frame; }
	bool IsT1BotLabOffCooldown()     { return (ai.frame - lastT1BotLabEnqueueFrame) >= T1_BOT_LAB_COOLDOWN_FRAMES; }
	void MarkT1BotLabEnqueued()      { lastT1BotLabEnqueueFrame = ai.frame; }
	bool IsT1HoverFactoryOffCooldown() { return (ai.frame - lastT1HoverFactoryEnqueueFrame) >= T1_HOVER_FACTORY_COOLDOWN_FRAMES; }
	void MarkT1HoverFactoryEnqueued()  { lastT1HoverFactoryEnqueueFrame = ai.frame; }
	bool IsT1ShipyardOffCooldown()   { return (ai.frame - lastT1ShipyardEnqueueFrame) >= T1_SHIPYARD_COOLDOWN_FRAMES; }
	void MarkT1ShipyardEnqueued()    { lastT1ShipyardEnqueueFrame = ai.frame; }
	int GetNanoCooldownFrames()
	{
		// When metal income is very low, slow down nano spam to avoid overcommitting buildpower
		float minMetalIncome = Economy::GetMinMetalIncomeLast10s();
		if (minMetalIncome < 30.0f) {
			return NANO_LOW_METAL_COOLDOWN_FRAMES;
		}
		return NANO_BASE_COOLDOWN_FRAMES;
	}

	bool IsNanoOffCooldown()      { return (ai.frame - lastNanoEnqueueFrame) >= GetNanoCooldownFrames(); }
	void MarkNanoEnqueued()       { lastNanoEnqueueFrame = ai.frame; }
	bool IsAdvSolarOffCooldown()  { return (ai.frame - lastAdvSolarEnqueueFrame) >= ADV_SOLAR_COOLDOWN_FRAMES; }

	void MarkAdvSolarEnqueued()   { lastAdvSolarEnqueueFrame = ai.frame; }

	bool IsAntiNukeOffCooldown()  { return (ai.frame - lastAntiNukeEnqueueFrame) >= ANTI_NUKE_COOLDOWN_FRAMES; }
	void MarkAntiNukeEnqueued()   { lastAntiNukeEnqueueFrame = ai.frame; }

	/******************************************************************************
    
	PROMOTION HELPERS
    
	******************************************************************************/
	// Computed getters
	// T2 Lab queued check is not provided here; call Factory::IsT2LabBuildQueued() directly from roles.
	bool IsFusionBuildQueued() { return FusionQueuedCount > 0 || IsFusionQueued; }
	bool IsAdvancedFusionBuildQueued() { return AdvancedFusionQueuedCount > 0 || IsAdvancedFusionQueued; }

	bool IsNukeSiloBuildQueued() { return NukeSiloQueuedCount > 0; }

	// A reactor is "under construction" only once its build task has a target: the
	// structure exists on the map and is being built. A merely queued task has a
	// null target and must not divert build power.
	CCircuitUnit@ _ReactorUnderConstruction(IUnitTask@ t)
	{
		if (t is null) return null;
		IBuilderTask@ bt = cast<IBuilderTask>(t);
		if (bt is null) return null;
		CCircuitUnit@ tgt = bt.target;
		if (tgt is null) return null;
		// CCircuitUnit is asOBJ_NOCOUNT; reacquire a live handle before use.
		return ai.GetTeamUnit(tgt.id);
	}

	CCircuitUnit@ GetEnergyUnderConstruction()
	{
		return _ReactorUnderConstruction(EnergyBuildTask);
	}

	// Put a constructor onto the T1 energy structure already going up, up to
	// maxAssists of them. Null when nothing is under construction or the
	// structure has its share already. Same Repair mechanism as the reactor.
	IUnitTask@ EnqueueAssistEnergy(Task::Priority prio, int timeoutFrames, int maxAssists)
	{
		CCircuitUnit@ target = GetEnergyUnderConstruction();
		if (target is null) return null;
		if (int(EnergyAssistTasks.length()) >= maxAssists) {
			GenericHelpers::LogUtil("[BUILDER] EnqueueAssistEnergy: " + target.circuitDef.GetName() + "(" + target.id
				+ ") already has " + EnergyAssistTasks.length() + " assist(s)", 3);
			return null;
		}
		IUnitTask@ t = aiBuilderMgr.Enqueue(TaskB::Repair(prio, target, timeoutFrames));
		if (t !is null) {
			EnergyAssistTasks.insertLast(t);
			GenericHelpers::LogUtil("[BUILDER] EnqueueAssistEnergy: " + target.circuitDef.GetName() + "(" + target.id
				+ ") assists=" + EnergyAssistTasks.length() + "/" + maxAssists, 1);
		}
		return t;
	}

	void _SetEnergyBuildTask(IUnitTask@ t)
	{
		@EnergyBuildTask = t;
		EnergyAssistTasks.resize(0);
	}

	// Advanced Fusion first: it is the more expensive commitment to finish.
	CCircuitUnit@ GetReactorUnderConstruction()
	{
		CCircuitUnit@ u = _ReactorUnderConstruction(AdvancedFusionBuildTask);
		if (u !is null) return u;
		return _ReactorUnderConstruction(FusionBuildTask);
	}

	// Redirect build power onto an in-progress reactor. Repairing an unfinished
	// structure is the engine's assist mechanism - IBuilderTask::UpdateTarget issues
	// the same CmdRepair to its own assignees - and IRepairTask::SetRepTarget treats
	// an IsBeingBuilt() target as a construction assist.
	IUnitTask@ EnqueueAssistReactor(Task::Priority prio, int timeoutFrames)
	{
		CCircuitUnit@ reactor = GetReactorUnderConstruction();
		if (reactor is null) return null;
		IUnitTask@ t = aiBuilderMgr.Enqueue(TaskB::Repair(prio, reactor, timeoutFrames));
		GenericHelpers::LogUtil("[BUILDER] EnqueueAssistReactor: reactor id=" + reactor.id
			+ " result=" + (t is null ? "null" : "ok"), 2);
		return t;
	}

	// Pick a candidate from a guard map, optionally skipping any in 'avoids'.
	// Returns the chosen CCircuitUnit@ and removes it from the guard map; null if none.
	CCircuitUnit@ PromoteFromGuards(dictionary@ guardMap, array<CCircuitUnit@>@ avoids, const string &in logLabel)
	{
		if (guardMap is null) return null;

		array<string>@ keys = guardMap.getKeys();
		if (keys is null) return null;

		for (uint i = 0; i < keys.length(); ++i) {
			CCircuitUnit@ cand = null;
			if (guardMap.get(keys[i], @cand) && cand !is null) {
				bool skip = false;
				if (avoids !is null) {
					for (uint j = 0; j < avoids.length(); ++j) {
						CCircuitUnit@ av = avoids[j];
						if (av !is null && cand.id == av.id) { skip = true; break; }
					}
				}
				if (skip) continue;
				guardMap.delete(keys[i]);
				GenericHelpers::LogUtil("[BUILDER] Promoted new " + logLabel + " id=" + cand.id, 2);
				return cand;
			}
		}
		return null;
	}

	// Promotion sub-steps split out for clarity and future extension (air/veh)
	void PromotePrimaryT1BotIfNeeded()
	{
		if (primaryT1BotConstructor is null) {
			CCircuitUnit@ p1 = PromoteFromGuards(@primaryT1BotConstructorGuards, null, "primaryT1BotConstructor");
			if (p1 !is null) { @primaryT1BotConstructor = p1; }
		}
	}

	void PromoteSecondaryT1BotIfNeeded()
	{
		array<CCircuitUnit@> avoids;
		if (primaryT1BotConstructor !is null) avoids.insertLast(primaryT1BotConstructor);
		if (secondaryT1BotConstructor is null) {
			CCircuitUnit@ s1 = PromoteFromGuards(@secondaryT1BotConstructorGuards, @avoids, "secondaryT1BotConstructor");
			if (s1 !is null) { @secondaryT1BotConstructor = s1; }
		}
	}

	void PromotePrimaryT2BotIfNeeded()
	{
		if (primaryT2BotConstructor is null) {
			CCircuitUnit@ p2 = PromoteFromGuards(@primaryT2BotConstructorGuards, null, "primaryT2BotConstructor");
			if (p2 !is null) { @primaryT2BotConstructor = p2; }
		}
	}

	void PromoteSecondaryT2BotIfNeeded()
	{
		array<CCircuitUnit@> avoids;
		if (primaryT2BotConstructor !is null) avoids.insertLast(primaryT2BotConstructor);
		if (secondaryT2BotConstructor is null) {
			CCircuitUnit@ s2 = PromoteFromGuards(@secondaryT2BotConstructorGuards, @avoids, "secondaryT2BotConstructor");
			if (s2 !is null) { @secondaryT2BotConstructor = s2; }
		}
	}

	// Vehicle promotions
	void PromotePrimaryT1VehIfNeeded()
	{
		if (primaryT1VehConstructor is null) {
			CCircuitUnit@ p1 = PromoteFromGuards(@primaryT1VehConstructorGuards, null, "primaryT1VehConstructor");
			if (p1 !is null) { @primaryT1VehConstructor = p1; }
		}
	}

	void PromoteSecondaryT1VehIfNeeded()
	{
		array<CCircuitUnit@> avoids;
		if (primaryT1VehConstructor !is null) avoids.insertLast(primaryT1VehConstructor);
		if (secondaryT1VehConstructor is null) {
			CCircuitUnit@ s1 = PromoteFromGuards(@secondaryT1VehConstructorGuards, @avoids, "secondaryT1VehConstructor");
			if (s1 !is null) { @secondaryT1VehConstructor = s1; }
		}
	}

	void PromotePrimaryT2VehIfNeeded()
	{
		if (primaryT2VehConstructor is null) {
			CCircuitUnit@ p2 = PromoteFromGuards(@primaryT2VehConstructorGuards, null, "primaryT2VehConstructor");
			if (p2 !is null) { @primaryT2VehConstructor = p2; }
		}
	}

	void PromoteSecondaryT2VehIfNeeded()
	{
		array<CCircuitUnit@> avoids;
		if (primaryT2VehConstructor !is null) avoids.insertLast(primaryT2VehConstructor);
		if (secondaryT2VehConstructor is null) {
			CCircuitUnit@ s2 = PromoteFromGuards(@secondaryT2VehConstructorGuards, @avoids, "secondaryT2VehConstructor");
			if (s2 !is null) { @secondaryT2VehConstructor = s2; }
		}
	}

	// Aircraft promotions
	void PromotePrimaryT1AirIfNeeded()
	{
		if (primaryT1AirConstructor is null) {
			CCircuitUnit@ p1 = PromoteFromGuards(@primaryT1AirConstructorGuards, null, "primaryT1AirConstructor");
			if (p1 !is null) { @primaryT1AirConstructor = p1; }
		}
	}

	void PromoteSecondaryT1AirIfNeeded()
	{
		array<CCircuitUnit@> avoids;
		if (primaryT1AirConstructor !is null) avoids.insertLast(primaryT1AirConstructor);
		if (secondaryT1AirConstructor is null) {
			CCircuitUnit@ s1 = PromoteFromGuards(@secondaryT1AirConstructorGuards, @avoids, "secondaryT1AirConstructor");
			if (s1 !is null) { @secondaryT1AirConstructor = s1; }
		}
	}

	void PromotePrimaryT2AirIfNeeded()
	{
		if (primaryT2AirConstructor is null) {
			CCircuitUnit@ p2 = PromoteFromGuards(@primaryT2AirConstructorGuards, null, "primaryT2AirConstructor");
			if (p2 !is null) { @primaryT2AirConstructor = p2; }
		}
	}

	void PromoteSecondaryT2AirIfNeeded()
	{
		array<CCircuitUnit@> avoids;
		if (primaryT2AirConstructor !is null) avoids.insertLast(primaryT2AirConstructor);
		if (secondaryT2AirConstructor is null) {
			CCircuitUnit@ s2 = PromoteFromGuards(@secondaryT2AirConstructorGuards, @avoids, "secondaryT2AirConstructor");
			if (s2 !is null) { @secondaryT2AirConstructor = s2; }
		}
	}

	// Sea promotions
	void PromotePrimaryT1SeaIfNeeded()
	{
		if (primaryT1SeaConstructor is null) {
			CCircuitUnit@ p1 = PromoteFromGuards(@primaryT1SeaConstructorGuards, null, "primaryT1SeaConstructor");
			if (p1 !is null) { @primaryT1SeaConstructor = p1; }
		}
	}

	void PromoteSecondaryT1SeaIfNeeded()
	{
		array<CCircuitUnit@> avoids;
		if (primaryT1SeaConstructor !is null) avoids.insertLast(primaryT1SeaConstructor);
		if (secondaryT1SeaConstructor is null) {
			CCircuitUnit@ s1 = PromoteFromGuards(@secondaryT1SeaConstructorGuards, @avoids, "secondaryT1SeaConstructor");
			if (s1 !is null) { @secondaryT1SeaConstructor = s1; }
		}
	}

	void PromotePrimaryT2SeaIfNeeded()
	{
		if (primaryT2SeaConstructor is null) {
			CCircuitUnit@ p2 = PromoteFromGuards(@primaryT2SeaConstructorGuards, null, "primaryT2SeaConstructor");
			if (p2 !is null) { @primaryT2SeaConstructor = p2; }
		}
	}

	void PromoteSecondaryT2SeaIfNeeded()
	{
		array<CCircuitUnit@> avoids;
		if (primaryT2SeaConstructor !is null) avoids.insertLast(primaryT2SeaConstructor);
		if (secondaryT2SeaConstructor is null) {
			CCircuitUnit@ s2 = PromoteFromGuards(@secondaryT2SeaConstructorGuards, @avoids, "secondaryT2SeaConstructor");
			if (s2 !is null) { @secondaryT2SeaConstructor = s2; }
		}
	}

	// Hover promotions (T1 only)
	void PromotePrimaryT1HoverIfNeeded()
	{
		if (primaryT1HoverConstructor is null) {
			CCircuitUnit@ p1 = PromoteFromGuards(@primaryT1HoverConstructorGuards, null, "primaryT1HoverConstructor");
			if (p1 !is null) { @primaryT1HoverConstructor = p1; }
		}
	}

	void PromoteSecondaryT1HoverIfNeeded()
	{
		array<CCircuitUnit@> avoids;
		if (primaryT1HoverConstructor !is null) avoids.insertLast(primaryT1HoverConstructor);
		if (secondaryT1HoverConstructor is null) {
			CCircuitUnit@ s1 = PromoteFromGuards(@secondaryT1HoverConstructorGuards, @avoids, "secondaryT1HoverConstructor");
			if (s1 !is null) { @secondaryT1HoverConstructor = s1; }
		}
	}

	void PromoteIfNeeded()
	{
		GenericHelpers::LogUtil("[BUILDER] Enter PromoteIfNeeded", 4);
		PromotePrimaryT1BotIfNeeded();
		PromoteSecondaryT1BotIfNeeded();
		PromotePrimaryT2BotIfNeeded();
		PromoteSecondaryT2BotIfNeeded();
		// Also consider vehicle and aircraft
		PromotePrimaryT1VehIfNeeded();
		PromoteSecondaryT1VehIfNeeded();
		PromotePrimaryT2VehIfNeeded();
		PromoteSecondaryT2VehIfNeeded();
		PromotePrimaryT1AirIfNeeded();
		PromoteSecondaryT1AirIfNeeded();
		PromotePrimaryT2AirIfNeeded();
		PromoteSecondaryT2AirIfNeeded();
		PromotePrimaryT1SeaIfNeeded();
		PromoteSecondaryT1SeaIfNeeded();
		PromotePrimaryT2SeaIfNeeded();
		PromoteSecondaryT2SeaIfNeeded();
		PromotePrimaryT1HoverIfNeeded();
		PromoteSecondaryT1HoverIfNeeded();
		// Keep tracking eligibility in sync with any promotions performed
		RecomputeTrackEligibleBuilders();
	}

	/******************************************************************************
    
	GUARD ASSIGNMENT HELPERS (moved from RoleTech)
    
	******************************************************************************/
	void AssignGuardByRatio(float primaryRatio, CCircuitUnit@ unit)
	{
		GenericHelpers::LogUtil("[BUILDER] Enter AssignGuardByRatio (T1)", 4);
		AssignGuardByRatio(primaryRatio, unit, 1);
	}

	// Internal generic distributor to enable future constructor classes (bot/veh/air)
	void AssignGuardByRatioMaps(
		float primaryRatio,
		CCircuitUnit@ unit,
		CCircuitUnit@ primary,
		dictionary@ primaryGuards,
		CCircuitUnit@ secondary,
		dictionary@ secondaryGuards,
		// tactical preference for this category
		bool tacticalEnabled,
		CCircuitUnit@ tactical,
		dictionary@ tacticalGuards,
		const string &in logTag,
		// per-category guard caps
		int maxPerLeader,
		int maxPerTacticalLeader
	) {
		// Enforce per-leader guard caps; overflow workers go to unassigned pool.
		if (unit is null) return;
		// Remove it from the unassigned pool while we attempt assignment
		_UnassignedRemove(unit);

		// Prefer category tactical constructor if enabled and available (and not self)
		if (tacticalEnabled && tactical !is null && unit.id != tactical.id) {
			int tCount = GuardHelpers::CountDict(@tacticalGuards);
			if (tCount < maxPerTacticalLeader) {
				GuardHelpers::RemoveFromAllBuckets(unit, {
					GuardHelpers::GuardBucket("tactical", tactical, @tacticalGuards, 1.0f),
					GuardHelpers::GuardBucket("primary", primary, @primaryGuards, 0.0f),
					GuardHelpers::GuardBucket("secondary", secondary, @secondaryGuards, 0.0f)
				});
				string key = "" + unit.id; tacticalGuards.set(key, @unit);
				GenericHelpers::LogUtil("[BUILDER] Assigned guard to tactical (" + logTag + ") id=" + unit.id, 3);
				return;
			}
		}

		// Snapshot counts
		int pCount = GuardHelpers::CountDict(@primaryGuards);
		int sCount = GuardHelpers::CountDict(@secondaryGuards);

		bool pHasRoom = (primary !is null) && (pCount < maxPerLeader);
		bool sHasRoom = (secondary !is null) && (sCount < maxPerLeader);

		// If neither has room, park in unassigned
		if (!pHasRoom && !sHasRoom) {
			_UnassignedAdd(unit);
			GenericHelpers::LogUtil("[BUILDER] Guard cap reached for (" + logTag + ") primary=" + pCount + " secondary=" + sCount + ", parked id=" + unit.id + " in unassigned", 3);
			return;
		}

		// If only one has room, assign there
		if (pHasRoom && !sHasRoom) {
			GuardHelpers::RemoveFromAllBuckets(unit, { GuardHelpers::GuardBucket("primary", primary, @primaryGuards, 1.0f), GuardHelpers::GuardBucket("secondary", secondary, @secondaryGuards, 0.0f) });
			string key = "" + unit.id; primaryGuards.set(key, @unit); return;
		}
		if (!pHasRoom && sHasRoom) {
			GuardHelpers::RemoveFromAllBuckets(unit, { GuardHelpers::GuardBucket("primary", primary, @primaryGuards, 0.0f), GuardHelpers::GuardBucket("secondary", secondary, @secondaryGuards, 1.0f) });
			string key2 = "" + unit.id; secondaryGuards.set(key2, @unit); return;
		}

		// Both have roo m: use ratio distribution
		GuardHelpers::DistributeGuardsByRatio2(
			unit,
			primaryRatio,
			primary, @primaryGuards,
			secondary, @secondaryGuards
		);
	}

	// tier: 1 for T1 constructors, 2 for T2 constructors (currently BOT-only)
	void AssignGuardByRatio(float primaryRatio, CCircuitUnit@ unit, int tier)
	{
		GenericHelpers::LogUtil("[BUILDER] Enter AssignGuardByRatio tier=" + tier, 4);
		if (unit is null) {
			GenericHelpers::LogUtil("[BUILDER] AssignGuardByRatio(tier=" + tier + "): unit is <null>", 1);
			return;
		}

		const int gMax = Global::RoleSettings::BuilderMaxGuardsPerLeader;
		const int gMaxTac = Global::RoleSettings::BuilderMaxGuardsPerTacticalLeader;
		if (tier == 2) {
			AssignGuardByRatioMaps(
				primaryRatio,
				unit,
				Builder::primaryT2BotConstructor, @Builder::primaryT2BotConstructorGuards,
				Builder::secondaryT2BotConstructor, @Builder::secondaryT2BotConstructorGuards,
				TacticalEnabled,
				Builder::tacticalBotConstructor, @Builder::tacticalBotConstructorGuards,
				"bot-t2",
				gMax,
				gMaxTac
			);
		} else {
			AssignGuardByRatioMaps(
				primaryRatio,
				unit,
				Builder::primaryT1BotConstructor, @Builder::primaryT1BotConstructorGuards,
				Builder::secondaryT1BotConstructor, @Builder::secondaryT1BotConstructorGuards,
				TacticalEnabled,
				Builder::tacticalBotConstructor, @Builder::tacticalBotConstructorGuards,
				"bot-t1",
				gMax,
				gMaxTac
			);
		}
	}

	// Vehicle guard assignment wrappers
	void AssignGuardByRatioVehicle(float primaryRatio, CCircuitUnit@ unit) {
		GenericHelpers::LogUtil("[BUILDER] Enter AssignGuardByRatioVehicle (T1)", 4);
		AssignGuardByRatioVehicle(primaryRatio, unit, 1);
	}
	void AssignGuardByRatioVehicle(float primaryRatio, CCircuitUnit@ unit, int tier)
	{
		GenericHelpers::LogUtil("[BUILDER] Enter AssignGuardByRatioVehicle tier=" + tier, 4);
		if (unit is null) return;
	const int gMax = Global::RoleSettings::BuilderMaxGuardsPerLeader;
	const int gMaxTac = Global::RoleSettings::BuilderMaxGuardsPerTacticalLeader;
	if (tier == 2) {
			AssignGuardByRatioMaps(primaryRatio, unit,
				Builder::primaryT2VehConstructor, @Builder::primaryT2VehConstructorGuards,
				Builder::secondaryT2VehConstructor, @Builder::secondaryT2VehConstructorGuards,
		TacticalEnabled,
		Builder::tacticalVehConstructor, @Builder::tacticalVehConstructorGuards,
		"veh-t2",
		gMax,
		gMaxTac);
		} else {
			AssignGuardByRatioMaps(primaryRatio, unit,
				Builder::primaryT1VehConstructor, @Builder::primaryT1VehConstructorGuards,
				Builder::secondaryT1VehConstructor, @Builder::secondaryT1VehConstructorGuards,
		TacticalEnabled,
		Builder::tacticalVehConstructor, @Builder::tacticalVehConstructorGuards,
		"veh-t1",
		gMax,
		gMaxTac);
		}
	}

	// Aircraft guard assignment wrappers
	void AssignGuardByRatioAircraft(float primaryRatio, CCircuitUnit@ unit) {
		GenericHelpers::LogUtil("[BUILDER] Enter AssignGuardByRatioAircraft (T1)", 4);
		AssignGuardByRatioAircraft(primaryRatio, unit, 1);
	}
	void AssignGuardByRatioAircraft(float primaryRatio, CCircuitUnit@ unit, int tier)
	{
		GenericHelpers::LogUtil("[BUILDER] Enter AssignGuardByRatioAircraft tier=" + tier, 4);
		if (unit is null) return;
	const int gMax = Global::RoleSettings::BuilderMaxGuardsPerLeader;
	const int gMaxTac = Global::RoleSettings::BuilderMaxGuardsPerTacticalLeader;
	if (tier == 2) {
			AssignGuardByRatioMaps(primaryRatio, unit,
				Builder::primaryT2AirConstructor, @Builder::primaryT2AirConstructorGuards,
				Builder::secondaryT2AirConstructor, @Builder::secondaryT2AirConstructorGuards,
		TacticalEnabled,
		Builder::tacticalAirConstructor, @Builder::tacticalAirConstructorGuards,
		"air-t2",
		gMax,
		gMaxTac);
		} else {
			AssignGuardByRatioMaps(primaryRatio, unit,
				Builder::primaryT1AirConstructor, @Builder::primaryT1AirConstructorGuards,
				Builder::secondaryT1AirConstructor, @Builder::secondaryT1AirConstructorGuards,
		TacticalEnabled,
		Builder::tacticalAirConstructor, @Builder::tacticalAirConstructorGuards,
		"air-t1",
		gMax,
		gMaxTac);
		}
	}

	// Sea guard assignment wrappers
	void AssignGuardByRatioSea(float primaryRatio, CCircuitUnit@ unit) {
		GenericHelpers::LogUtil("[BUILDER] Enter AssignGuardByRatioSea (T1)", 4);
		AssignGuardByRatioSea(primaryRatio, unit, 1);
	}
	void AssignGuardByRatioSea(float primaryRatio, CCircuitUnit@ unit, int tier)
	{
		GenericHelpers::LogUtil("[BUILDER] Enter AssignGuardByRatioSea tier=" + tier, 4);
		if (unit is null) return;
	const int sMax = Global::RoleSettings::Sea::BuilderMaxGuardsPerLeader;
	const int sMaxTac = Global::RoleSettings::Sea::BuilderMaxGuardsPerTacticalLeader;
	if (tier == 2) {
			AssignGuardByRatioMaps(primaryRatio, unit,
				Builder::primaryT2SeaConstructor, @Builder::primaryT2SeaConstructorGuards,
				Builder::secondaryT2SeaConstructor, @Builder::secondaryT2SeaConstructorGuards,
		TacticalEnabled,
		Builder::tacticalSeaConstructor, @Builder::tacticalSeaConstructorGuards,
		"sea-t2",
		sMax,
		sMaxTac);
		} else {
			AssignGuardByRatioMaps(primaryRatio, unit,
				Builder::primaryT1SeaConstructor, @Builder::primaryT1SeaConstructorGuards,
				Builder::secondaryT1SeaConstructor, @Builder::secondaryT1SeaConstructorGuards,
		TacticalEnabled,
		Builder::tacticalSeaConstructor, @Builder::tacticalSeaConstructorGuards,
		"sea-t1",
		sMax,
		sMaxTac);
		}
	}

	// Hover guard assignment wrappers (T1 only)
	void AssignGuardByRatioHover(float primaryRatio, CCircuitUnit@ unit) {
		GenericHelpers::LogUtil("[BUILDER] Enter AssignGuardByRatioHover (T1)", 4);
		AssignGuardByRatioHover(primaryRatio, unit, 1);
	}
	void AssignGuardByRatioHover(float primaryRatio, CCircuitUnit@ unit, int tier)
	{
		GenericHelpers::LogUtil("[BUILDER] Enter AssignGuardByRatioHover tier=" + tier, 4);
		if (unit is null) return;
		// Only T1 supported for hover
		const int gMax = Global::RoleSettings::BuilderMaxGuardsPerLeader;
		const int gMaxTac = Global::RoleSettings::BuilderMaxGuardsPerTacticalLeader;
		AssignGuardByRatioMaps(primaryRatio, unit,
			Builder::primaryT1HoverConstructor, @Builder::primaryT1HoverConstructorGuards,
			Builder::secondaryT1HoverConstructor, @Builder::secondaryT1HoverConstructorGuards,
			TacticalEnabled,
			Builder::tacticalHoverConstructor, @Builder::tacticalHoverConstructorGuards,
			"hover-t1",
			gMax,
			gMaxTac);
	}

	/******************************************************************************
    
	BUILD ENQUEUE HELPERS (moved from RoleTech)
    
	******************************************************************************/
	// Generic helper: enqueue by unit name and build type
	IUnitTask@ _EnqueueGenericByName(Task::BuildType btype, const string &in defName, const AIFloat3 &in anchor, float shake, int timeoutFrames, Task::Priority prio = Task::Priority::NOW)
	{
		if (defName.length() == 0) return null;
		CCircuitDef@ def = ai.GetCircuitDef(defName);
		if (def is null) return null;
		if (!def.IsAvailable(ai.frame)) return null;
		return aiBuilderMgr.Enqueue(
			TaskB::Common(btype, prio, def, anchor, /*shake*/ shake, /*active*/ true, /*timeout*/ timeoutFrames)
		);
	}

	// --- Static structures (DEFENCE and sensors) ---
	IUnitTask@ EnqueueStaticAALight(const string &in unitSide, const AIFloat3 &in anchor, float shake, int timeoutFrames, Task::Priority prio = Task::Priority::NOW)
	{
		string name = UnitHelpers::GetStaticAALightNameForSide(unitSide);
		GenericHelpers::LogUtil("[BUILDER] Enqueue Static AA Light '" + name + "'", 2);
		return _EnqueueGenericByName(Task::BuildType::DEFENCE, name, anchor, shake, timeoutFrames, prio);
	}

	IUnitTask@ EnqueueStaticAAHeavy(const string &in unitSide, const AIFloat3 &in anchor, float shake, int timeoutFrames, Task::Priority prio = Task::Priority::NOW)
	{
		string name = UnitHelpers::GetStaticAAHeavyNameForSide(unitSide);
		GenericHelpers::LogUtil("[BUILDER] Enqueue Static AA Heavy '" + name + "'", 2);
		return _EnqueueGenericByName(Task::BuildType::DEFENCE, name, anchor, shake, timeoutFrames, prio);
	}

	IUnitTask@ EnqueueStaticAAFlak(const string &in unitSide, const AIFloat3 &in anchor, float shake, int timeoutFrames, Task::Priority prio = Task::Priority::NOW)
	{
		string name = UnitHelpers::GetStaticT2AAFlakNameForSide(unitSide);
		GenericHelpers::LogUtil("[BUILDER] Enqueue Static AA Flak '" + name + "'", 2);
		return _EnqueueGenericByName(Task::BuildType::DEFENCE, name, anchor, shake, timeoutFrames, prio);
	}

	IUnitTask@ EnqueueStaticAARange(const string &in unitSide, const AIFloat3 &in anchor, float shake, int timeoutFrames, Task::Priority prio = Task::Priority::NOW)
	{
		string name = UnitHelpers::GetStaticT2AARangeNameForSide(unitSide);
		GenericHelpers::LogUtil("[BUILDER] Enqueue Static AA Long-Range '" + name + "'", 2);
		return _EnqueueGenericByName(Task::BuildType::DEFENCE, name, anchor, shake, timeoutFrames, prio);
	}

	IUnitTask@ EnqueueStaticLLT(const string &in unitSide, const AIFloat3 &in anchor, float shake, int timeoutFrames, Task::Priority prio = Task::Priority::NOW)
	{
		string name = UnitHelpers::GetStaticLLTNameForSide(unitSide);
		GenericHelpers::LogUtil("[BUILDER] Enqueue LLT '" + name + "'", 2);
		return _EnqueueGenericByName(Task::BuildType::DEFENCE, name, anchor, shake, timeoutFrames, prio);
	}

	IUnitTask@ EnqueueStaticT2MediumTurret(const string &in unitSide, const AIFloat3 &in anchor, float shake, int timeoutFrames, Task::Priority prio = Task::Priority::NOW)
	{
		string name = UnitHelpers::GetStaticT2MediumTurretNameForSide(unitSide);
		GenericHelpers::LogUtil("[BUILDER] Enqueue T2 Medium Turret '" + name + "'", 2);
		return _EnqueueGenericByName(Task::BuildType::DEFENCE, name, anchor, shake, timeoutFrames, prio);
	}

	IUnitTask@ EnqueueStaticT2Artillery(const string &in unitSide, const AIFloat3 &in anchor, float shake, int timeoutFrames, Task::Priority prio = Task::Priority::NOW)
	{
		string name = UnitHelpers::GetStaticT2ArtilleryNameForSide(unitSide);
		GenericHelpers::LogUtil("[BUILDER] Enqueue Static Artillery '" + name + "'", 2);
		return _EnqueueGenericByName(Task::BuildType::DEFENCE, name, anchor, shake, timeoutFrames, prio);
	}

	IUnitTask@ EnqueueStaticTorpT1(const string &in unitSide, const AIFloat3 &in anchor, float shake, int timeoutFrames, Task::Priority prio = Task::Priority::NOW)
	{
		string name = UnitHelpers::GetStaticT1TorpNameForSide(unitSide);
		GenericHelpers::LogUtil("[BUILDER] Enqueue T1 Torpedo Launcher '" + name + "'", 2);
		return _EnqueueGenericByName(Task::BuildType::DEFENCE, name, anchor, shake, timeoutFrames, prio);
	}

	IUnitTask@ EnqueueStaticRadar(const string &in unitSide, const AIFloat3 &in anchor, float shake, int timeoutFrames, Task::Priority prio = Task::Priority::NOW)
	{
		string name = UnitHelpers::GetStaticRadarNameForSide(unitSide);
		GenericHelpers::LogUtil("[BUILDER] Enqueue Radar '" + name + "'", 2);
		return _EnqueueGenericByName(Task::BuildType::RADAR, name, anchor, shake, timeoutFrames, prio);
	}

	IUnitTask@ EnqueueStaticT2Radar(const string &in unitSide, const AIFloat3 &in anchor, float shake, int timeoutFrames, Task::Priority prio = Task::Priority::NOW)
	{
		string name = UnitHelpers::GetStaticT2RadarNameForSide(unitSide);
		GenericHelpers::LogUtil("[BUILDER] Enqueue T2 Radar '" + name + "'", 2);
		return _EnqueueGenericByName(Task::BuildType::RADAR, name, anchor, shake, timeoutFrames, prio);
	}

	IUnitTask@ EnqueueStaticJammer(const string &in unitSide, const AIFloat3 &in anchor, float shake, int timeoutFrames, Task::Priority prio = Task::Priority::NOW)
	{
		string name = UnitHelpers::GetStaticJammerNameForSide(unitSide);
		GenericHelpers::LogUtil("[BUILDER] Enqueue Jammer '" + name + "'", 2);
		// Use DEFENCE build type for jammers until a dedicated type exists
		return _EnqueueGenericByName(Task::BuildType::DEFENCE, name, anchor, shake, timeoutFrames, prio);
	}

	// --- Long range plasma cannons ---
	IUnitTask@ EnqueueLRPC(const string &in unitSide, const AIFloat3 &in anchor, float shake, int timeoutFrames, Task::Priority prio = Task::Priority::NOW)
	{
		string name = UnitHelpers::GetLRPCNameForSide(unitSide);
		GenericHelpers::LogUtil("[BUILDER] Enqueue LRPC '" + name + "'", 2);
		return _EnqueueGenericByName(Task::BuildType::BIG_GUN, name, anchor, shake, timeoutFrames, prio);
	}

	IUnitTask@ EnqueueLRPCHeavy(const string &in unitSide, const AIFloat3 &in anchor, float shake, int timeoutFrames, Task::Priority prio = Task::Priority::NOW)
	{
		string name = UnitHelpers::GetLRPCHeavyNameForSide(unitSide);
		GenericHelpers::LogUtil("[BUILDER] Enqueue Heavy LRPC '" + name + "'", 2);
		return _EnqueueGenericByName(Task::BuildType::BIG_GUN, name, anchor, shake, timeoutFrames, prio);
	}
	
	// (defence enqueue helpers moved to Military)

	IUnitTask@ EnqueueMex(const string &in unitSide, const AIFloat3 &in anchor, float shake, int timeoutFrames, Task::Priority prio = Task::Priority::NOW)
	{
		string name = UnitHelpers::GetObjectiveUnitNameForSide(unitSide, Objectives::BuildingType::T1_MEX);
		GenericHelpers::LogUtil("[BUILDER] Enqueue MEX '" + name + "'", 2);
		return _EnqueueGenericByName(Task::BuildType::MEX, name, anchor, shake, timeoutFrames, prio);
	}

	IUnitTask@ EnqueueGeo(const string &in unitSide, const AIFloat3 &in anchor, float shake, int timeoutFrames, Task::Priority prio = Task::Priority::NOW)
	{
		string name = UnitHelpers::GetObjectiveUnitNameForSide(unitSide, Objectives::BuildingType::T1_GEO);
		GenericHelpers::LogUtil("[BUILDER] Enqueue GEO '" + name + "'", 2);
		return _EnqueueGenericByName(Task::BuildType::GEO, name, anchor, shake, timeoutFrames, prio);
	}
	IUnitTask@ EnqueueT2BotLabIfNeeded(const string &in unitSide, const AIFloat3 &in anchor, float squareSize, int timeoutFrames)
	{
		// Enforce specialized T2 bot lab cooldown (decoupled from vehicle plants)
		if (!IsT2BotFactoryOffCooldown()) {
			GenericHelpers::LogUtil("[BUILDER] Blocked T2 Bot Lab enqueue: cooldown active (remainingFrames=" + (T2_FACTORY_COOLDOWN_FRAMES - (ai.frame - lastT2BotFactoryEnqueueFrame)) + ")", 2);
			return null;
		}

		int t2LabCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2BotLabs());
		GenericHelpers::LogUtil("[BUILDER] T2 Lab def count=" + t2LabCount, 2);

		//if (!IsT2LabQueued()) {
			CCircuitDef@ def = ai.GetCircuitDef(UnitHelpers::GetT2BotLabForSide(unitSide));
			if (def is null) {
				GenericHelpers::LogUtil("[BUILDER] EnqueueT2BotLabIfNeeded: def not found for side='" + unitSide + "'", 2);
				return null;
			}
			if (!def.IsAvailable(ai.frame)) {
				GenericHelpers::LogUtil("[BUILDER] EnqueueT2BotLabIfNeeded: def '" + def.GetName() + "' not available", 3);
				return null;
			}

			GenericHelpers::LogUtil("[BUILDER] Enqueue T2 at (" + anchor.x + "," + anchor.z + ") def=" + (def is null ? "<null>" : def.GetName()), 2);

			IUnitTask@ t = aiBuilderMgr.Enqueue(
				TaskB::Factory(Task::Priority::NOW, def, anchor, def, squareSize, false, true, timeoutFrames)
			);
			GenericHelpers::LogUtil("[BUILDER] Enqueue T2 result=" + (t is null ? "null" : "ok"), 2);
			if (t !is null) { MarkT2BotFactoryEnqueued(); }
			return t;
		//}

		//return null;
	}

	IUnitTask@ EnqueueT1EnergyConverter(const string &in unitSide, const AIFloat3 &in anchor, float squareSize, int timeoutFrames)
	{
		// Enforce a short per-structure cooldown to avoid rapid consecutive T1 converter builds
		int elapsed = ai.frame - lastT1ConverterEnqueueFrame;
		if (elapsed < T1_CONVERTER_COOLDOWN_FRAMES) {
			int remaining = T1_CONVERTER_COOLDOWN_FRAMES - elapsed;
			GenericHelpers::LogUtil("[BUILDER] EnqueueT1EnergyConverter: blocked by cooldown (remainingFrames=" + remaining + ")", 2);
			return null;
		}

		CCircuitDef@ converter = ai.GetCircuitDef(UnitHelpers::GetEnergyConverterNameForSide(unitSide));
		if (converter is null || !converter.IsAvailable(ai.frame)) {
			return null;
		}
		IUnitTask@ t = aiBuilderMgr.Enqueue(
			TaskB::Factory(Task::Priority::NORMAL, converter, anchor, converter, squareSize, false, true, timeoutFrames)
		);
		GenericHelpers::LogUtil("[BUILDER] Enqueue Converter", 2);
		if (t !is null) {
			lastT1ConverterEnqueueFrame = ai.frame;
			_SetEnergyBuildTask(t);
		}
		return t;
	}

	IUnitTask@ EnqueueT1NavalEnergyConverter(const string &in unitSide, const AIFloat3 &in anchor, float squareSize, int timeoutFrames)
	{
		CCircuitDef@ converter = ai.GetCircuitDef(UnitHelpers::GetNavalEnergyConverterNameForSide(unitSide));
		IUnitTask@ t = aiBuilderMgr.Enqueue(
			TaskB::Factory(Task::Priority::NORMAL, converter, anchor, converter, squareSize, false, true, timeoutFrames)
		);
		GenericHelpers::LogUtil("[BUILDER] Enqueue Naval Converter", 2);
		return t;
	}

	// Shared helper: when a structure is on cooldown, optionally redirect this builder to assist the
	// last builder that successfully enqueued that structure (via a guard task), if close enough.
	IUnitTask@ TryAssignBuilderAssistOnCooldown(int builderId, int lastBuilderId, int cooldownFrames, const string &in label)
	{
		// Sentinel or no last builder recorded
		if (builderId < 0 || lastBuilderId < 0) {
			return null;
		}

		CCircuitUnit@ owner = ai.GetTeamUnit(lastBuilderId);
		CCircuitUnit@ guard = ai.GetTeamUnit(builderId);
		if (owner is null || guard is null || owner.id == guard.id) {
			return null;
		}

		// Only assign guard if the assisting builder is reasonably close to the original builder
		AIFloat3 ownerPos = owner.GetPos(ai.frame);
		AIFloat3 guardPos = guard.GetPos(ai.frame);
		if (!MapHelpers::IsInRange(ownerPos, guardPos, 600.0f)) {
			GenericHelpers::LogUtil("[BUILDER] " + label + ": cooldown active but guard too far (range>600)", 4);
			return null;
		}

		// If the last builder's structure is already going up, assist THAT: the
		// task ends with the structure, so this constructor re-plans the moment
		// it completes. A guard on the builder used to run for 200 s, long after
		// the solar was done, which read as a stalled constructor.
		IUnitTask@ assist = EnqueueAssistEnergy(Task::Priority::HIGH, cooldownFrames, COOLDOWN_ASSIST_MAX);
		if (assist !is null) {
			return assist;
		}
		GenericHelpers::LogUtil(
			"[BUILDER] " + label + ": assigning guard to last builder id=" + owner.id +
			" from builder id=" + guard.id,
			3
		);
		// Use shared helper for worker guard assignment (avoids self-guard loops)
		return GuardHelpers::AssignWorkerGuard(guard, owner, Task::Priority::HIGH, true, COOLDOWN_GUARD_TIMEOUT_FRAMES);
	}

	IUnitTask@ EnqueueT1Solar(int builderId, const string &in unitSide, const AIFloat3 &in anchor, float squareSize, int timeoutFrames, Task::Priority prio = Task::Priority::NORMAL)
	{
		// Enforce a short cooldown between T1 solar builds to prevent spamming
		int elapsed = ai.frame - lastT1SolarEnqueueFrame;
		if (elapsed < T1_SOLAR_COOLDOWN_FRAMES) {
			int remaining = T1_SOLAR_COOLDOWN_FRAMES - elapsed;
			GenericHelpers::LogUtil("[BUILDER] EnqueueT1Solar: blocked by cooldown (remainingFrames=" + remaining + ")", 2);
			IUnitTask@ assistTask = TryAssignBuilderAssistOnCooldown(builderId, lastT1SolarBuilderId, T1_SOLAR_COOLDOWN_FRAMES, "EnqueueT1Solar");
			if (assistTask !is null) {
				return assistTask;
			}
			return null;
		}

		if (Global::energyAllowed !is null && !Global::energyAllowed(UnitHelpers::GetSolarNameForSide(unitSide))) return null;   // D-077
		CCircuitDef@ solar = ai.GetCircuitDef(UnitHelpers::GetSolarNameForSide(unitSide));
		if (solar is null || !solar.IsAvailable(ai.frame)) {
			return null;
		}
		IUnitTask@ t = aiBuilderMgr.Enqueue(
			TaskB::Factory(prio, solar, anchor, solar, squareSize, false, true, timeoutFrames)
		);
		GenericHelpers::LogUtil("[BUILDER] Enqueue T1 Solar", 2);
		if (t !is null) {
			lastT1SolarEnqueueFrame = ai.frame;
			lastT1SolarBuilderId = builderId;
			_SetEnergyBuildTask(t);
		}
		return t;
	}

	IUnitTask@ EnqueueT1AdvancedSolar(int builderId, const string &in unitSide, const AIFloat3 &in anchor, float squareSize, int timeoutFrames)
	{
		// Enforce advanced solar cooldown
		if (!IsAdvSolarOffCooldown()) {
			int remaining = ADV_SOLAR_COOLDOWN_FRAMES - (ai.frame - lastAdvSolarEnqueueFrame);
			GenericHelpers::LogUtil("[BUILDER] EnqueueT1AdvancedSolar: blocked by cooldown (remainingFrames=" + remaining + ")", 2);
			IUnitTask@ assistTask = TryAssignBuilderAssistOnCooldown(builderId, lastAdvSolarBuilderId, ADV_SOLAR_COOLDOWN_FRAMES, "EnqueueT1AdvancedSolar");
			if (assistTask !is null) {
				return assistTask;
			}
			return null;
		}
		CCircuitDef@ advancedSolar = ai.GetCircuitDef(UnitHelpers::GetAdvSolarNameForSide(unitSide));
		if (advancedSolar is null || !advancedSolar.IsAvailable(ai.frame)) return null;
		if (Global::energyAllowed !is null && !Global::energyAllowed(advancedSolar.GetName())) return null;   // D-077
		IUnitTask@ t = aiBuilderMgr.Enqueue(
			TaskB::Factory(Task::Priority::NORMAL, advancedSolar, anchor, advancedSolar, squareSize, false, true, timeoutFrames)
		);
		GenericHelpers::LogUtil("[BUILDER] Enqueue Advanced Solar", 2);
		if (t !is null) {
			MarkAdvSolarEnqueued();
			lastAdvSolarBuilderId = builderId;
			_SetEnergyBuildTask(t);
		}
		return t;
	}

	IUnitTask@ EnqueueT1Nano(const string &in unitSide, const AIFloat3 &in anchor, float shake, int timeoutFrames, Task::Priority prio = Task::Priority::NORMAL)
	{
		// Enforce nano cooldown
		if (!IsNanoOffCooldown()) {
			int remaining = GetNanoCooldownFrames() - (ai.frame - lastNanoEnqueueFrame);
			GenericHelpers::LogUtil("[BUILDER] Blocked Nano enqueue: cooldown active (remainingFrames=" + remaining + ")", 2);
			return null;
		}
		CCircuitDef@ nanoDef = ai.GetCircuitDef(UnitHelpers::GetT1NanoNameForSide(unitSide));
		if (nanoDef is null || !nanoDef.IsAvailable(ai.frame)) return null;
		IUnitTask@ t = aiBuilderMgr.Enqueue(
			TaskB::Common(Task::BuildType::NANO, prio, nanoDef, anchor, /*shake*/ shake, /*active*/ true, /*timeout*/ timeoutFrames)
		);
		GenericHelpers::LogUtil("[BUILDER] Enqueue Nano", 2);
		if (t !is null) { MarkNanoEnqueued(); }
		return t;
	}

	IUnitTask@ EnqueueT1NavalNano(const string &in unitSide, const AIFloat3 &in anchor, float shake, int timeoutFrames)
	{
		// Enforce nano cooldown (shared with land nano)
		if (!IsNanoOffCooldown()) {
			int remaining = GetNanoCooldownFrames() - (ai.frame - lastNanoEnqueueFrame);
			GenericHelpers::LogUtil("[BUILDER] Blocked Naval Nano enqueue: cooldown active (remainingFrames=" + remaining + ")", 2);
			return null;
		}
		CCircuitDef@ nanoDef = ai.GetCircuitDef(UnitHelpers::GetT1NavalNanoNameForSide(unitSide));
		if (nanoDef is null || !nanoDef.IsAvailable(ai.frame)) return null;
		IUnitTask@ t = aiBuilderMgr.Enqueue(
			TaskB::Common(Task::BuildType::NANO, Task::Priority::NORMAL, nanoDef, anchor, /*shake*/ shake, /*active*/ true, /*timeout*/ timeoutFrames)
		);
		GenericHelpers::LogUtil("[BUILDER] Enqueue Naval Nano", 2);
		if (t !is null) { MarkNanoEnqueued(); }
		return t;
	}

	IUnitTask@ EnqueueT1Tidal(const string &in unitSide, const AIFloat3 &in anchor, float squareSize, int timeoutFrames, Task::Priority prio = Task::Priority::NORMAL)
	{
		CCircuitDef@ tidal = ai.GetCircuitDef(UnitHelpers::GetTidalNameForSide(unitSide));
		IUnitTask@ t = aiBuilderMgr.Enqueue(
			TaskB::Factory(prio, tidal, anchor, tidal, squareSize, false, true, timeoutFrames)
		);
		GenericHelpers::LogUtil("[BUILDER] Enqueue Tidal", 2);
		return t;
	}

	IUnitTask@ EnqueueSeaplanePlatform(const string &in unitSide, const AIFloat3 &in anchor, float squareSize, int timeoutFrames, Task::Priority prio = Task::Priority::HIGH)
	{
		string platName = UnitHelpers::GetSeaplanePlatformNameForSide(unitSide);
		CCircuitDef@ plat = ai.GetCircuitDef(platName);
		if (plat is null || !plat.IsAvailable(ai.frame)) return null;
		IUnitTask@ t = aiBuilderMgr.Enqueue(
			TaskB::Factory(prio, plat, anchor, plat, squareSize, false, true, timeoutFrames)
		);
		GenericHelpers::LogUtil("[BUILDER] Enqueue Seaplane Platform '" + platName + "'", 2);
		return t;
	}

	// Enqueue a T1 shipyard for a given side. The anchor may be on land (a landlocked
	// Tech base): searchRadius is how far around it the native site search may look,
	// since the footprint itself must be in water.
	IUnitTask@ EnqueueT1Shipyard(const string &in unitSide, const AIFloat3 &in anchor, float searchRadius, int timeoutFrames, Task::Priority prio = Task::Priority::NOW)
	{
		if (!IsT1ShipyardOffCooldown()) {
			int remaining = T1_SHIPYARD_COOLDOWN_FRAMES - (ai.frame - lastT1ShipyardEnqueueFrame);
			GenericHelpers::LogUtil("[BUILDER] EnqueueT1Shipyard: blocked by cooldown (remainingFrames=" + remaining + ")", 2);
			return null;
		}
		string defName = UnitHelpers::GetT1ShipyardForSide(unitSide);
		CCircuitDef@ def = ai.GetCircuitDef(defName);
		if (def is null) {
			GenericHelpers::LogUtil("[BUILDER] EnqueueT1Shipyard: def is <null> for name='" + defName + "'", 3);
			return null;
		}
		if (!def.IsAvailable(ai.frame)) {
			GenericHelpers::LogUtil("[BUILDER] EnqueueT1Shipyard unavailable def='" + defName + "' count=" + def.count + " maxThisUnit=" + def.maxThisUnit + " frame=" + ai.frame, 3);
			return null;
		}
		IUnitTask@ t = aiBuilderMgr.Enqueue(
			TaskB::Factory(prio, def, anchor, def, searchRadius, /*setBase*/ false, /*isPrimary*/ true, timeoutFrames)
		);
		GenericHelpers::LogUtil("[BUILDER] Enqueue T1 Shipyard '" + defName + "' at (" + anchor.x + "," + anchor.z + ") radius=" + searchRadius + " => " + (t is null ? "null" : "ok"), 2);
		if (t !is null) { MarkT1ShipyardEnqueued(); }
		return t;
	}

	IUnitTask@ EnqueueT2Shipyard(const string &in unitSide, const AIFloat3 &in anchor, float squareSize, int timeoutFrames)
	{
		// Enforce global T2 factory cooldown
		if (!IsT2FactoryOffCooldown()) {
			GenericHelpers::LogUtil("[BUILDER] EnqueueT2Shipyard: blocked by cooldown (remainingFrames=" + (T2_FACTORY_COOLDOWN_FRAMES - (ai.frame - lastT2FactoryEnqueueFrame)) + ")", 2);
			return null;
		}

		// Side-aware T2 shipyard name. This used to send Legion to corasy,
		// which no Legion constructor can build: the task was enqueued, never
		// assignable, and Legion SEA never got a T2 shipyard (D-039).
		string defName = UnitHelpers::GetT2ShipyardForSide(unitSide);

		CCircuitDef@ def = (defName.length() == 0 ? null : ai.GetCircuitDef(defName));
		if (def is null) {
			GenericHelpers::LogUtil("[BUILDER] EnqueueT2Shipyard: def not found for side='" + unitSide + "'", 2);
			return null;
		}
		if (!def.IsAvailable(ai.frame)) {
			GenericHelpers::LogUtil("[BUILDER] EnqueueT2Shipyard: def '" + def.GetName() + "' not available", 3);
			return null;
		}

		GenericHelpers::LogUtil("[BUILDER] Enqueue T2 Shipyard at (" + anchor.x + "," + anchor.z + ") repr=" + def.GetName(), 2);
		IUnitTask@ t = aiBuilderMgr.Enqueue(
			TaskB::Factory(Task::Priority::NOW, def, anchor, def, squareSize, false, true, timeoutFrames)
		);
		GenericHelpers::LogUtil("[BUILDER] Enqueue T2 Shipyard result=" + (t is null ? "null" : "ok"), 2);
		if (t !is null) { MarkT2FactoryEnqueued(); }
		return t;
	}

	IUnitTask@ EnqueueT2AirPlant(const string &in unitSide, const AIFloat3 &in anchor, float squareSize, int timeoutFrames)
	{
		// Enforce global T2 factory cooldown
		if (!IsT2FactoryOffCooldown()) {
			GenericHelpers::LogUtil("[BUILDER] EnqueueT2AirPlant: blocked by cooldown (remainingFrames=" + (T2_FACTORY_COOLDOWN_FRAMES - (ai.frame - lastT2FactoryEnqueueFrame)) + ")", 2);
			return null;
		}

		string defName = UnitHelpers::GetT2AirPlantForSide(unitSide);
		CCircuitDef@ def = (defName.length() == 0 ? null : ai.GetCircuitDef(defName));
		if (def is null) {
			GenericHelpers::LogUtil("[BUILDER] EnqueueT2AirPlant: def not found for side='" + unitSide + "'", 2);
			return null;
		}
		if (!def.IsAvailable(ai.frame)) {
			GenericHelpers::LogUtil("[BUILDER] EnqueueT2AirPlant: def '" + def.GetName() + "' not available", 3);
			return null;
		}

		GenericHelpers::LogUtil("[BUILDER] Enqueue T2 Aircraft Plant at (" + anchor.x + "," + anchor.z + ") repr=" + def.GetName(), 2);
		IUnitTask@ t = aiBuilderMgr.Enqueue(
			TaskB::Factory(Task::Priority::NOW, def, anchor, def, squareSize, false, true, timeoutFrames)
		);
		GenericHelpers::LogUtil("[BUILDER] Enqueue T2 Aircraft Plant result=" + (t is null ? "null" : "ok"), 2);
		if (t !is null) { MarkT2FactoryEnqueued(); }
		return t;
	}

	// New helper: enqueue a T2 Vehicle Plant (refactored from inline logic in FRONT role)
	IUnitTask@ EnqueueT2VehiclePlant(const string &in unitSide, const AIFloat3 &in anchor, float squareSize, int timeoutFrames)
	{
		// Enforce vehicle-specific T2 factory cooldown (separate from bot lab cooldown)
		if (!IsT2VehFactoryOffCooldown()) {
			GenericHelpers::LogUtil("[BUILDER] EnqueueT2VehiclePlant: blocked by VEH cooldown (remainingFrames=" + (T2_FACTORY_COOLDOWN_FRAMES - (ai.frame - lastT2VehFactoryEnqueueFrame)) + ")", 2);
			return null;
		}

		// Side-aware mapping (Armada/Cortex/Legion); fallback to first known T2 vehicle lab if side unrecognized
		string defName = "";
		if (unitSide == "armada") defName = "armavp";
		else if (unitSide == "cortex") defName = "coravp";
		else if (unitSide == "legion") defName = "legavp";
		if (defName.length() == 0) {
			array<string> allVeh = UnitHelpers::GetAllT2VehicleLabs();
			if (allVeh.length() > 0) defName = allVeh[0];
		}

		CCircuitDef@ def = (defName.length() == 0 ? null : ai.GetCircuitDef(defName));
		if (def is null) {
			GenericHelpers::LogUtil("[BUILDER] EnqueueT2VehiclePlant: def not found for side='" + unitSide + "'", 2);
			return null;
		}
		if (!def.IsAvailable(ai.frame)) {
			GenericHelpers::LogUtil("[BUILDER] EnqueueT2VehiclePlant: def '" + def.GetName() + "' not available", 3);
			return null;
		}

		GenericHelpers::LogUtil("[BUILDER] Enqueue T2 Vehicle Plant at (" + anchor.x + "," + anchor.z + ") repr=" + def.GetName(), 2);
		IUnitTask@ t = aiBuilderMgr.Enqueue(
			TaskB::Factory(Task::Priority::HIGH, def, anchor, def, squareSize, /*setBase*/ false, /*isPrimary*/ true, timeoutFrames)
		);
		GenericHelpers::LogUtil("[BUILDER] Enqueue T2 Vehicle Plant result=" + (t is null ? "null" : "ok"), 2);
		if (t !is null) { MarkT2VehFactoryEnqueued(); }
		return t;
	}

	IUnitTask@ EnqueueAdvNavalEnergyConverter(const string &in unitSide, const AIFloat3 &in anchor, float squareSize, int timeoutFrames)
	{
		CCircuitDef@ t2NavalConverter = ai.GetCircuitDef(UnitHelpers::GetAdvNavalEnergyConverterNameForSide(unitSide));
		int cnt = (t2NavalConverter is null ? -1 : t2NavalConverter.count);
		GenericHelpers::LogUtil("[BUILDER] t2NavalConverter def=" + (t2NavalConverter is null ? "<null>" : t2NavalConverter.GetName()) + " count=" + cnt, 2);

		if (t2NavalConverter is null) return null;

		GenericHelpers::LogUtil("[BUILDER] Enqueue t2NavalConverter at (" + anchor.x + "," + anchor.z + ") repr=" + (t2NavalConverter is null ? "<null>" : t2NavalConverter.GetName()), 2);

		IUnitTask@ t = aiBuilderMgr.Enqueue(
			TaskB::Factory(Task::Priority::NORMAL, t2NavalConverter, anchor, t2NavalConverter, squareSize, false, true, timeoutFrames)
		);
		GenericHelpers::LogUtil("[BUILDER] Enqueue t2NavalConverter result=" + (t is null ? "null" : "ok"), 2);
		return t;
	}

	IUnitTask@ EnqueueAFUS(const string &in unitSide, const AIFloat3 &in anchor, float squareSize, int timeoutFrames)
	{
		// Never start if any Advanced Fusion is already queued
		if (IsAdvancedFusionBuildQueued()) {
			GenericHelpers::LogUtil("[BUILDER] Blocked AFUS enqueue: another Advanced Fusion is already queued (count=" + AdvancedFusionQueuedCount + ")", 2);
			return null;
		}

		CCircuitDef@ afus = ai.GetCircuitDef(UnitHelpers::GetAdvFusionNameForSide(unitSide));
		int afusCount = (afus is null ? -1 : afus.count);
		GenericHelpers::LogUtil("[BUILDER] afus def=" + (afus is null ? "<null>" : afus.GetName()) + " count=" + afusCount, 2);

		if (afus is null) return null;

		GenericHelpers::LogUtil("[BUILDER] Enqueue AFUS at (" + anchor.x + "," + anchor.z + ") repr=" + (afus is null ? "<null>" : afus.GetName()), 2);

		IUnitTask@ t = aiBuilderMgr.Enqueue(
			TaskB::Common(Task::BuildType::ENERGY, Task::Priority::NORMAL, afus, anchor, /*shake*/ SQUARE_SIZE * 32, /*active*/ true, /*timeout*/ 0)
			//TaskB::Factory(Task::Priority::NOW, afus, anchor, afus, squareSize, false, true, timeoutFrames)
		);
		GenericHelpers::LogUtil("[BUILDER] Enqueue AFUS result=" + (t is null ? "null" : "ok"), 2);
		if (t !is null) @AdvancedFusionBuildTask = t;
		return t;
	}

	IUnitTask@ EnqueueNukeSilo(const string &in unitSide, const AIFloat3 &in anchor, float squareSize, int timeoutFrames)
	{
		// Side-aware nuclear silo unit name
		array<string> allSilos = UnitHelpers::GetAllNukeSilos();
		// Prefer a side-specific name by prefix
		string defName = "";
		if (unitSide == "armada") defName = "armsilo";
		else if (unitSide == "cortex") defName = "corsilo";
		else if (unitSide == "legion") defName = "legsilo";
		// Fallback to the first known silo if side not resolved
		if (defName.length() == 0 && allSilos.length() > 0) defName = allSilos[0];

		CCircuitDef@ silo = (defName.length() == 0 ? null : ai.GetCircuitDef(defName));
		if (silo is null) {
			GenericHelpers::LogUtil("[BUILDER] EnqueueNukeSilo: def not found for side='" + unitSide + "'", 2);
			return null;
		}
		if (!silo.IsAvailable(ai.frame)) {
			GenericHelpers::LogUtil("[BUILDER] EnqueueNukeSilo: def '" + silo.GetName() + "' not available", 3);
			return null;
		}

		GenericHelpers::LogUtil("[BUILDER] Enqueue Nuke Silo at (" + anchor.x + "," + anchor.z + ") repr=" + silo.GetName(), 2);
		IUnitTask@ t = aiBuilderMgr.Enqueue(
			TaskB::Factory(Task::Priority::NOW, silo, anchor, silo, squareSize, false, true, timeoutFrames)
		);
		GenericHelpers::LogUtil("[BUILDER] Enqueue Nuke Silo result=" + (t is null ? "null" : "ok"), 2);
		return t;
	}

	IUnitTask@ EnqueueAntiNuke(const string &in unitSide, const AIFloat3 &in anchor, float squareSize, int timeoutFrames)
	{
		// Cooldown gate
		if (!IsAntiNukeOffCooldown()) {
			int remaining = ANTI_NUKE_COOLDOWN_FRAMES - (ai.frame - lastAntiNukeEnqueueFrame);
			GenericHelpers::LogUtil("[BUILDER] EnqueueAntiNuke: blocked by cooldown (remainingFrames=" + remaining + ")", 2);
			return null;
		}
		// Side-aware anti-nuke unit name
		string defName = UnitHelpers::GetAntiNukeNameForSide(unitSide);
		CCircuitDef@ amd = (defName.length() == 0 ? null : ai.GetCircuitDef(defName));
		if (amd is null) {
			GenericHelpers::LogUtil("[BUILDER] EnqueueAntiNuke: def not found for side='" + unitSide + "'", 2);
			return null;
		}
		if (!amd.IsAvailable(ai.frame)) {
			GenericHelpers::LogUtil("[BUILDER] EnqueueAntiNuke: def '" + amd.GetName() + "' not available", 3);
			return null;
		}

		GenericHelpers::LogUtil("[BUILDER] Enqueue Anti-Nuke at (" + anchor.x + "," + anchor.z + ") repr=" + amd.GetName(), 2);
		IUnitTask@ t = aiBuilderMgr.Enqueue(
			TaskB::Factory(Task::Priority::NOW, amd, anchor, amd, squareSize, false, true, timeoutFrames)
		);
		GenericHelpers::LogUtil("[BUILDER] Enqueue Anti-Nuke result=" + (t is null ? "null" : "ok"), 2);
		if (t !is null) { MarkAntiNukeEnqueued(); }
		return t;
	}

	IUnitTask@ EnqueueFUS(const string &in unitSide, const AIFloat3 &in anchor, float squareSize, int timeoutFrames, Task::Priority prio = Task::Priority::NORMAL)
	{
		// Never start if any Fusion is already queued
		if (IsFusionBuildQueued()) {
			GenericHelpers::LogUtil("[BUILDER] Blocked FUS enqueue: another Fusion is already queued (count=" + FusionQueuedCount + ")", 2);
			return null;
		}

		CCircuitDef@ fus = ai.GetCircuitDef(UnitHelpers::GetFusionNameForSide(unitSide));
		int fusCount = (fus is null ? -1 : fus.count);
		GenericHelpers::LogUtil("[BUILDER] fus def=" + (fus is null ? "<null>" : fus.GetName()) + " count=" + fusCount, 2);

		if (fus is null) return null;

		GenericHelpers::LogUtil("[BUILDER] Enqueue FUS at (" + anchor.x + "," + anchor.z + ") repr=" + (fus is null ? "<null>" : fus.GetName()), 2);

		IUnitTask@ t = aiBuilderMgr.Enqueue(
			TaskB::Common(Task::BuildType::ENERGY, prio, fus, anchor, /*shake*/ SQUARE_SIZE * 32, /*active*/ true, /*timeout*/ 0)
			//TaskB::Factory(Task::Priority::NOW, fus, anchor, fus, squareSize, false, true, timeoutFrames)
		);
		GenericHelpers::LogUtil("[BUILDER] Enqueue FUS result=" + (t is null ? "null" : "ok"), 2);
		if (t !is null) @FusionBuildTask = t;
		return t;
	}

	IUnitTask@ EnqueueNavalFUS(const string &in unitSide, const AIFloat3 &in anchor, float squareSize, int timeoutFrames)
	{
		// Enqueue a sea-capable fusion reactor; no shared fusion queue flags yet for naval-specific variant
		CCircuitDef@ fus = ai.GetCircuitDef(UnitHelpers::GetNavalFusionNameForSide(unitSide));
		int fusCount = (fus is null ? -1 : fus.count);
		GenericHelpers::LogUtil("[BUILDER] naval fus def=" + (fus is null ? "<null>" : fus.GetName()) + " count=" + fusCount, 2);

		if (fus is null || !fus.IsAvailable(ai.frame)) return null;

		GenericHelpers::LogUtil("[BUILDER] Enqueue Naval FUS at (" + anchor.x + "," + anchor.z + ") repr=" + (fus is null ? "<null>" : fus.GetName()), 2);

		IUnitTask@ t = aiBuilderMgr.Enqueue(
			TaskB::Common(Task::BuildType::ENERGY, Task::Priority::NORMAL, fus, anchor, /*shake*/ SQUARE_SIZE * 32, /*active*/ true, /*timeout*/ 0)
		);
		GenericHelpers::LogUtil("[BUILDER] Enqueue Naval FUS result=" + (t is null ? "null" : "ok"), 2);
		return t;
	}

	// Enqueue a T1 aircraft plant for a given side at a preferred location, honoring a short cooldown
	IUnitTask@ EnqueueT1AirFactory(const string &in unitSide, const AIFloat3 &in pos, float shake, int timeoutFrames, Task::Priority prio = Task::Priority::HIGH)
	{
		if (!IsT1AirFactoryOffCooldown()) {
			int remaining = T1_AIR_FACTORY_COOLDOWN_FRAMES - (ai.frame - lastT1AirFactoryEnqueueFrame);
			GenericHelpers::LogUtil("[BUILDER] EnqueueT1AirFactory: blocked by cooldown (remainingFrames=" + remaining + ")", 2);
			return null;
		}
		string airName = UnitHelpers::GetT1AirPlantForSide(unitSide);
		CCircuitDef@ airDef = ai.GetCircuitDef(airName);
		if (airDef is null) {
			GenericHelpers::LogUtil("[BUILDER] EnqueueT1AirFactory: def is <null> for name='" + airName + "'", 3);
			return null;
		}
		if (!airDef.IsAvailable(ai.frame)) {
			GenericHelpers::LogUtil("[BUILDER] EnqueueT1AirFactory unavailable def='" + airName + "' count=" + airDef.count + " maxThisUnit=" + airDef.maxThisUnit + " frame=" + ai.frame, 3);
			return null;
		}
		IUnitTask@ t = aiBuilderMgr.Enqueue(
			TaskB::Factory(prio, airDef, pos, airDef, shake, /*setBase*/ false, /*isPrimary*/ true, timeoutFrames)
		);
		GenericHelpers::LogUtil("[BUILDER] Enqueue T1 Air Factory '" + airName + "' => " + (t is null ? "null" : "ok"), 2);
		if (t !is null) { MarkT1AirFactoryEnqueued(); }
		return t;
	}

	// Enqueue a T1 hover plant (land) for a given side at a preferred location, honoring a 90s cooldown shared with floating variant
	IUnitTask@ EnqueueT1HoverPlant(const string &in unitSide, const AIFloat3 &in pos, float shake, int timeoutFrames, Task::Priority prio = Task::Priority::NOW)
	{
		if (!IsT1HoverFactoryOffCooldown()) {
			int remaining = T1_HOVER_FACTORY_COOLDOWN_FRAMES - (ai.frame - lastT1HoverFactoryEnqueueFrame);
			GenericHelpers::LogUtil("[BUILDER] EnqueueT1HoverPlant: blocked by cooldown (remainingFrames=" + remaining + ")", 2);
			return null;
		}
		string defName = UnitHelpers::GetT1HoverPlantForSide(unitSide);
		CCircuitDef@ def = ai.GetCircuitDef(defName);
		if (def is null) {
			GenericHelpers::LogUtil("[BUILDER] EnqueueT1HoverPlant: def is <null> for name='" + defName + "'", 3);
			return null;
		}
		if (!def.IsAvailable(ai.frame)) {
			GenericHelpers::LogUtil("[BUILDER] EnqueueT1HoverPlant unavailable def='" + defName + "' count=" + def.count + " maxThisUnit=" + def.maxThisUnit + " frame=" + ai.frame, 3);
			return null;
		}
		IUnitTask@ t = aiBuilderMgr.Enqueue(
			TaskB::Factory(prio, def, pos, def, shake, /*setBase*/ false, /*isPrimary*/ true, timeoutFrames)
		);
		GenericHelpers::LogUtil("[BUILDER] Enqueue T1 Hover Plant '" + defName + "' => " + (t is null ? "null" : "ok"), 2);
		if (t !is null) { MarkT1HoverFactoryEnqueued(); }
		return t;
	}

	// Enqueue a floating T1 hover plant for a given side, sharing the same 90s cooldown
	IUnitTask@ EnqueueFloatingHoverPlant(const string &in unitSide, const AIFloat3 &in pos, float shake, int timeoutFrames, Task::Priority prio = Task::Priority::NOW)
	{
		if (!IsT1HoverFactoryOffCooldown()) {
			int remaining = T1_HOVER_FACTORY_COOLDOWN_FRAMES - (ai.frame - lastT1HoverFactoryEnqueueFrame);
			GenericHelpers::LogUtil("[BUILDER] EnqueueFloatingHoverPlant: blocked by cooldown (remainingFrames=" + remaining + ")", 2);
			return null;
		}
		string defName = UnitHelpers::GetFloatingHoverPlantForSide(unitSide);
		CCircuitDef@ def = ai.GetCircuitDef(defName);
		if (def is null) {
			GenericHelpers::LogUtil("[BUILDER] EnqueueFloatingHoverPlant: def is <null> for name='" + defName + "'", 3);
			return null;
		}
		if (!def.IsAvailable(ai.frame)) {
			GenericHelpers::LogUtil("[BUILDER] EnqueueFloatingHoverPlant unavailable def='" + defName + "' count=" + def.count + " maxThisUnit=" + def.maxThisUnit + " frame=" + ai.frame, 3);
			return null;
		}
		IUnitTask@ t = aiBuilderMgr.Enqueue(
			TaskB::Factory(prio, def, pos, def, shake, /*setBase*/ false, /*isPrimary*/ true, timeoutFrames)
		);
		GenericHelpers::LogUtil("[BUILDER] Enqueue Floating Hover Plant '" + defName + "' => " + (t is null ? "null" : "ok"), 2);
		if (t !is null) { MarkT1HoverFactoryEnqueued(); }
		return t;
	}

	// Enqueue a T1 bot lab for a given side at a preferred location, honoring a short cooldown
	IUnitTask@ EnqueueT1BotLab(const string &in unitSide, const AIFloat3 &in pos, float shake, int timeoutFrames, Task::Priority prio = Task::Priority::HIGH)
	{
		if (!IsT1BotLabOffCooldown()) {
			int remaining = T1_BOT_LAB_COOLDOWN_FRAMES - (ai.frame - lastT1BotLabEnqueueFrame);
			GenericHelpers::LogUtil("[BUILDER] EnqueueT1BotLab: blocked by cooldown (remainingFrames=" + remaining + ")", 2);
			return null;
		}
		string labName = UnitHelpers::GetT1BotLabForSide(unitSide);
		CCircuitDef@ labDef = ai.GetCircuitDef(labName);
		if (labDef is null) {
			GenericHelpers::LogUtil("[BUILDER] EnqueueT1BotLab: def is <null> for name='" + labName + "'", 3);
			return null;
		}
		if (!labDef.IsAvailable(ai.frame)) {
			GenericHelpers::LogUtil("[BUILDER] EnqueueT1BotLab unavailable def='" + labName + "' count=" + labDef.count + " maxThisUnit=" + labDef.maxThisUnit + " frame=" + ai.frame, 3);
			return null;
		}
		IUnitTask@ t = aiBuilderMgr.Enqueue(
			TaskB::Factory(prio, labDef, pos, labDef, shake, /*setBase*/ false, /*isPrimary*/ true, timeoutFrames)
		);
		GenericHelpers::LogUtil("[BUILDER] Enqueue T1 Bot Lab '" + labName + "' => " + (t is null ? "null" : "ok"), 2);
		if (t !is null) { MarkT1BotLabEnqueued(); }
		return t;
	}

	// Enqueue a T1 vehicle plant for a given side at a preferred location, honoring a short cooldown
	IUnitTask@ EnqueueT1VehiclePlant(const string &in unitSide, const AIFloat3 &in pos, float shake, int timeoutFrames, Task::Priority prio = Task::Priority::HIGH)
	{
		// Reuse dedicated T1 vehicle factory cooldown once defined; for now share T1 bot lab cooldown semantics
		if (!IsT1BotLabOffCooldown()) {
			int remaining = T1_BOT_LAB_COOLDOWN_FRAMES - (ai.frame - lastT1BotLabEnqueueFrame);
			GenericHelpers::LogUtil("[BUILDER] EnqueueT1VehiclePlant: blocked by cooldown (remainingFrames=" + remaining + ")", 2);
			return null;
		}
		// Map side -> canonical T1 vehicle plant unit name
		string vehName = "";
		if (unitSide == "armada") vehName = "armvp";
		else if (unitSide == "cortex") vehName = "corvp";
		else if (unitSide == "legion") vehName = "legvp";
		// Fallback: if side is unknown, default to first known T1 vehicle lab
		if (vehName == "") {
			array<string> allVeh = UnitHelpers::GetAllT1VehicleLabs();
			if (allVeh.length() > 0) vehName = allVeh[0];
		}

		if (vehName == "") {
			GenericHelpers::LogUtil("[BUILDER] EnqueueT1VehiclePlant: no vehicle plant name resolved for side='" + unitSide + "'", 3);
			return null;
		}

		CCircuitDef@ vehDef = ai.GetCircuitDef(vehName);
		if (vehDef is null) {
			GenericHelpers::LogUtil("[BUILDER] EnqueueT1VehiclePlant: def is <null> for name='" + vehName + "'", 3);
			return null;
		}
		if (!vehDef.IsAvailable(ai.frame)) {
			GenericHelpers::LogUtil("[BUILDER] EnqueueT1VehiclePlant unavailable def='" + vehName + "' count=" + vehDef.count + " maxThisUnit=" + vehDef.maxThisUnit + " frame=" + ai.frame, 3);
			return null;
		}
		IUnitTask@ t = aiBuilderMgr.Enqueue(
			TaskB::Factory(prio, vehDef, pos, vehDef, shake, /*setBase*/ false, /*isPrimary*/ true, timeoutFrames)
		);
		GenericHelpers::LogUtil("[BUILDER] Enqueue T1 Vehicle Plant '" + vehName + "' => " + (t is null ? "null" : "ok"), 2);
		if (t !is null) {
			// Reuse the same cooldown stamp as the bot lab for now
			MarkT1BotLabEnqueued();
		}
		return t;
	}

	// Enqueue building a land gantry for a given side at the preferred factory position
	IUnitTask@ EnqueueLandGantry(const string &in side)
	{
		// Enforce global gantry cooldown
		if (!IsGantryOffCooldown()) {
			GenericHelpers::LogUtil("[BUILDER] EnqueueLandGantry: blocked by cooldown (remainingFrames=" + (GANTRY_COOLDOWN_FRAMES - (ai.frame - lastGantryEnqueueFrame)) + ")", 2);
			return null;
		}
		string name = UnitHelpers::GetLandGantryForSide(side);
		CCircuitDef@ def = ai.GetCircuitDef(name);
		if (def is null) {
			GenericHelpers::LogUtil("[BUILDER] EnqueueLandGantry: def is <null> for name='" + name + "'", 3);
			return null;
		}
		bool available = def.IsAvailable(ai.frame);
		if (!available) {
			// Provide more context to understand availability failure at runtime
			GenericHelpers::LogUtil(
				"[BUILDER] EnqueueLandGantry unavailable def='" + name + "' count=" + def.count + " maxThisUnit=" + def.maxThisUnit + " frame=" + ai.frame,
				3
			);
			return null;
		}
		AIFloat3 pos = Factory::GetPreferredFactoryPos();
		IUnitTask@ t = aiBuilderMgr.Enqueue(
			TaskB::Factory(Task::Priority::NOW, def, pos, def, SQUARE_SIZE * 24, false, true, 600 * SECOND)
		);
		GenericHelpers::LogUtil("[BUILDER] Enqueued Land Gantry '" + name + "'", 2);
		if (t !is null) { MarkGantryEnqueued(); }
		return t;
	}

	// --- Dispatcher: enqueue by Objectives::BuildingType ---
	IUnitTask@ EnqueueByBuildingType(const string &in unitSide, Objectives::BuildingType t, const AIFloat3 &in anchor, float shake, int timeoutFrames, Task::Priority prio = Task::Priority::NOW)
	{
		// Prefer specialized helpers where available
		if (t == Objectives::BuildingType::T1_LIGHT_AA)     return EnqueueStaticAALight(unitSide, anchor, shake, timeoutFrames, prio);
		if (t == Objectives::BuildingType::T1_MEDIUM_AA)    return EnqueueStaticAAHeavy(unitSide, anchor, shake, timeoutFrames, prio);
		if (t == Objectives::BuildingType::T1_LIGHT_TURRET) return EnqueueStaticLLT(unitSide, anchor, shake, timeoutFrames, prio);
		if (t == Objectives::BuildingType::T1_MED_TURRET)   return EnqueueStaticT2MediumTurret(unitSide, anchor, shake, timeoutFrames, prio);
		if (t == Objectives::BuildingType::T1_ARTY)         return EnqueueStaticT2Artillery(unitSide, anchor, shake, timeoutFrames, prio);
		if (t == Objectives::BuildingType::T1_TORP)         return EnqueueStaticTorpT1(unitSide, anchor, shake, timeoutFrames, prio);
		if (t == Objectives::BuildingType::T1_JAMMER)       return EnqueueStaticJammer(unitSide, anchor, shake, timeoutFrames, prio);
		if (t == Objectives::BuildingType::T1_RADAR)        return EnqueueStaticRadar(unitSide, anchor, shake, timeoutFrames, prio);

	if (t == Objectives::BuildingType::T1_ENERGY)       return EnqueueT1Solar(-1, unitSide, anchor, shake, timeoutFrames, prio);
	if (t == Objectives::BuildingType::T1_TIDAL)        return EnqueueT1Tidal(unitSide, anchor, shake, timeoutFrames, prio);
		if (t == Objectives::BuildingType::T1_MEX)          return EnqueueMex(unitSide, anchor, shake, timeoutFrames, prio);
		if (t == Objectives::BuildingType::T1_GEO)          return EnqueueGeo(unitSide, anchor, shake, timeoutFrames, prio);

		if (t == Objectives::BuildingType::SEAPLANE_FACTORY) return EnqueueSeaplanePlatform(unitSide, anchor, shake, timeoutFrames, prio);

		if (t == Objectives::BuildingType::T2_FLAK_AA)     return EnqueueStaticAAFlak(unitSide, anchor, shake, timeoutFrames, prio);
		if (t == Objectives::BuildingType::T2_RANGE_AA)    return EnqueueStaticAARange(unitSide, anchor, shake, timeoutFrames, prio);
		if (t == Objectives::BuildingType::T2_MED_TURRET)  return EnqueueStaticT2MediumTurret(unitSide, anchor, shake, timeoutFrames, prio);
		if (t == Objectives::BuildingType::T2_ARTY)        return EnqueueStaticT2Artillery(unitSide, anchor, shake, timeoutFrames, prio);
		if (t == Objectives::BuildingType::T2_JAMMER)      return EnqueueStaticJammer(unitSide, anchor, shake, timeoutFrames, prio);
		if (t == Objectives::BuildingType::T2_RADAR)       return EnqueueStaticT2Radar(unitSide, anchor, shake, timeoutFrames, prio);
		if (t == Objectives::BuildingType::T2_ENERGY)      return EnqueueFUS(unitSide, anchor, shake, timeoutFrames, prio);

		if (t == Objectives::BuildingType::LRPC)           return EnqueueLRPC(unitSide, anchor, shake, timeoutFrames, prio);
		if (t == Objectives::BuildingType::LRPC_HEAVY)     return EnqueueLRPCHeavy(unitSide, anchor, shake, timeoutFrames, prio);

		// Fallback: resolve by name and use generic DEFENCE build type
		string name = UnitHelpers::GetObjectiveUnitNameForSide(unitSide, t);
		Task::BuildType btype = Task::BuildType::DEFENCE;
		// Basic mapping for known categories
		if (t == Objectives::BuildingType::T1_RADAR || t == Objectives::BuildingType::T2_RADAR) btype = Task::BuildType::RADAR;
		if (t == Objectives::BuildingType::T1_ENERGY || t == Objectives::BuildingType::T2_ENERGY) btype = Task::BuildType::ENERGY;
		if (t == Objectives::BuildingType::T1_MEX) btype = Task::BuildType::MEX;
		if (t == Objectives::BuildingType::T1_GEO) btype = Task::BuildType::GEO;
		if (t == Objectives::BuildingType::SEAPLANE_FACTORY) btype = Task::BuildType::FACTORY;
		if (t == Objectives::BuildingType::LRPC || t == Objectives::BuildingType::LRPC_HEAVY || t == Objectives::BuildingType::T2_ARTY) btype = Task::BuildType::BIG_GUN;
		return _EnqueueGenericByName(btype, name, anchor, shake, timeoutFrames, prio);
	}

	// Called by CBuilderManager::AssignTask() and FallbackTask() right after a
	// builder receives a task (upstream a78e0f6c). Observation only.
	// CCircuitUnit is asOBJ_NOCOUNT (borrowed): do not retain the handle.
	void AiTaskAssigned(CCircuitUnit@ unit)
	{
		if (unit is null) {
			return;
		}
		GenericHelpers::LogUtil("[BUILDER] AiTaskAssigned id=" + unit.id, 4);
	}

	IUnitTask@ AiMakeTask(CCircuitUnit@ u) {
		// Ferry gifts belong to logistics before shared spam/track providers.
		// Returning the hold lets native transfer only this worker; never abort
		// its old shared construction task to park a donated constructor.
		if (Team::Ferry::IsGift(u.id)) return Team::Ferry::GiftTask(u);
		if (Team::Recovery::IsGift(u.id))
			return aiBuilderMgr.Enqueue(TaskB::Wait(2 * SECOND));
		IUnitTask@ t = null;
		GenericHelpers::LogUtil("[BUILDER] AiMakeTask called for builder id=" + u.id, 4);
		// Finish what you started (D-050). Native re-evaluates a builder's task
		// every few seconds by asking for a new one and swapping if the KIND
		// differs. With the energy-assist rung answering "repair the solar"
		// on every ask, a constructor that had begun a nano was swapped to the
		// assist, the nano abandoned (reservation restored), and the next ask
		// started another nano: three half-built turrets and no finished one.
		// A construction task whose structure exists is never swapped here.
		{
			IBuilderTask@ cur = (u.task is null) ? null : cast<IBuilderTask>(u.task);
			if (cur !is null && cur.target !is null && Task::BuildType(cur.GetBuildType()) < Task::BuildType::REPAIR) {
				return null;
			}
		}
		// New gating via BuilderTaskTrack: grace window, then gate if added, else allow; hard timeout clears
		BuilderTaskTrack@ tr = GetTrackForBuilder(u);
		if (tr !is null) {
			if (ai.frame >= tr.timeoutFrame) {
				GenericHelpers::LogUtil("[BUILDER] AiMakeTask: track timeout for builder id=" + u.id + ", clearing", 3);
				ClearTrackByBuilder(u);
			}
			else if (ai.frame <= tr.graceUntilFrame) {
				// Within grace window: allow role handlers to run (no gating)
				// fallthrough
			}
			else if (tr.isTaskAdded) {
				// After grace and confirmed queued: prevent interruption
				string dn = tr.defName;
				GenericHelpers::LogUtil("[BUILDER] AiMakeTask: gate (track added) builder id=" + u.id + " def='" + dn + "'", 3);
				return null;
			}
		}

		RoleConfig@ cfg = (Global::profileController is null) ? null : Global::profileController.RoleCfg;
		@t = SeaCoast::Build(u); // SEA-only lost-water recovery precedes discretionary spam.
		if (t is null) @t = EdgeLanes::BuilderTask(u); // owner, 2026-10-17: two FRONTs build the edge lane labs
		if (t is null) @t = Spam::BuilderMakeTask(u);
		if (t is null && MetalEconomy::Active() && !SeaLayout::Active() && Global::AISettings::Role != AiRole::AIR && Global::AISettings::Role != AiRole::TECH
			&& !UnitHelpers::IsCommander(u.circuitDef) && u.circuitDef.IsMobile()) @t = MetalEconomy::EconomyTask(u);
		if (t is null && cfg !is null && cfg.BuilderAiMakeTaskHandler !is null) {
			@t = cfg.BuilderAiMakeTaskHandler(u);
		}
		// If no role-specific task or handler returned null, fallback to default
		if (t is null) {
			@t = aiBuilderMgr.DefaultMakeTask(u);
			if (SeaLayout::Enabled()) @t = SeaBuild::LayoutTask(u,t);
		}

		// Record tracking for this builder if any (best-effort owner): grace ~3s, timeout ~45s
		if (t !is null) {
			// Only track tasks for eligible builders to avoid perf overhead
			if (IsBuilderTrackEligible(u)) {
				TrackTaskForBuilder(u, t, 90, 45 * SECOND);
			} else {
				GenericHelpers::LogUtil("[BUILDER] AiMakeTask: skip tracking for ineligible builder id=" + u.id, 6);
			}
		}

		return t;
	}

	void AiTaskAdded(IUnitTask@ task)
	{
		if (Global::AISettings::Role == AiRole::TECH && Global::RoleSettings::Tech::ExperimentalBuild)
			Invariants::ConstructionAdmitted(task);
		if (Global::AISettings::Role == AiRole::TECH) TechReclaim::Audit(task);   // D-290: every reclaim of ours, named by path
		if (Global::AISettings::Role == AiRole::AIR && Global::RoleSettings::Air::ExperimentalBuild) AirBuild::Added(task);
		GenericHelpers::LogUtil("[BUILDER] AiTaskAdded called", 4);
		// Mex ownership and upgrade state are role-independent: every role needs
		// them to rank an upgrade against the energy ladder, so the bookkeeping
		// lives here rather than in one role's handler.
		{
			IBuilderTask@ mexTask = cast<IBuilderTask>(task);
			if (mexTask !is null && Task::BuildType(mexTask.GetBuildType()) == Task::BuildType::MEXUP) {
				Economy::MexTracker::MarkUpgradeInProgress(mexTask.GetBuildPos(), true);
			}
		}
		// Mark tracked task as added if present
		MarkTaskAddedIfTracked(task);
		GenericHelpers::LogUtil("[BUILDER] AiTaskAdded: marked tracked task as added if present", 4);
		// Prefer tracked metadata; fall back to task if untracked
		BuilderTaskTrack@ track = GetTrackByTask(task);
		string buildDefName = (track is null ? "" : track.defName);
		Task::BuildType buildType = Task::BuildType(track is null ? -1 : track.buildTypeVal);

		bool hasBuildDef = (buildDefName.length() > 0);
		IBuilderTask@ builderTask = cast<IBuilderTask>(task);
		if (!hasBuildDef && builderTask !is null) {
			CCircuitDef@ buildDef = builderTask.buildDef;
			buildDefName = (buildDef is null ? "" : buildDef.GetName());
			buildType = Task::BuildType(builderTask.GetBuildType());
			hasBuildDef = (buildDefName.length() > 0);
		}

		// Centralize queued-flag setting here based on resolved metadata
		if (hasBuildDef) {
			if (buildType == Task::BuildType::FACTORY) {
					// Set factory T2 queued counters based on specific def (centralized in Factory)
					if (UnitHelpers::IsT2BotLab(buildDefName)) {
						if (!Factory::IsT2LabBuildQueued()) {
							GenericHelpers::LogUtil("[BUILDER] AiTaskAdded: queued T2 Bot Lab '" + buildDefName + "'", 2);
						}
						Factory::T2BotLabQueuedCount++;
						// Update T2 bot-factory specific cooldown timestamp
						MarkT2BotFactoryEnqueued();
					}
					if (UnitHelpers::IsT2VehicleLab(buildDefName)) {
						if (!Factory::IsT2VehPlantBuildQueued()) {
							GenericHelpers::LogUtil("[BUILDER] AiTaskAdded: queued T2 Vehicle Plant '" + buildDefName + "'", 2);
						}
						Factory::T2VehPlantQueuedCount++;
						MarkT2VehFactoryEnqueued();
					}
					if (UnitHelpers::IsT2AircraftPlant(buildDefName)) {
						if (!Factory::IsT2AirPlantBuildQueued()) {
							GenericHelpers::LogUtil("[BUILDER] AiTaskAdded: queued T2 Aircraft Plant '" + buildDefName + "'", 2);
						}
						Factory::T2AirPlantQueuedCount++;
						MarkT2FactoryEnqueued();
					}
					if (UnitHelpers::IsT2Shipyard(buildDefName)) {
						if (!Factory::IsT2ShipyardBuildQueued()) {
							GenericHelpers::LogUtil("[BUILDER] AiTaskAdded: queued T2 Shipyard '" + buildDefName + "'", 2);
						}
						Factory::T2ShipyardQueuedCount++;
						MarkT2FactoryEnqueued();
					}
					// Experimental gantries: increment counters (capped to 1)
						if (UnitHelpers::IsLandGantry(buildDefName)) {
						if (LandGantryQueuedCount == 0) { LandGantryQueuedCount = 1; }
						GenericHelpers::LogUtil("[BUILDER] AiTaskAdded: queued Land Gantry '" + buildDefName + "' count=" + LandGantryQueuedCount, 2);
							MarkGantryEnqueued();
					}
					if (UnitHelpers::IsWaterGantry(buildDefName)) {
						if (WaterGantryQueuedCount == 0) { WaterGantryQueuedCount = 1; }
						GenericHelpers::LogUtil("[BUILDER] AiTaskAdded: queued Water Gantry '" + buildDefName + "' count=" + WaterGantryQueuedCount, 2);
							MarkGantryEnqueued();
					}

					// Nuclear silos: increment queued count across all factions
					{
						array<string> nukes = UnitHelpers::GetAllNukeSilos();
						for (uint ni = 0; ni < nukes.length(); ++ni) {
							if (nukes[ni] == buildDefName) {
								NukeSiloQueuedCount++;
								GenericHelpers::LogUtil("[BUILDER] AiTaskAdded: queued Nuclear Silo '" + buildDefName + "' count=" + NukeSiloQueuedCount, 2);
								break;
							}
						}
					}

					// Robust: also handle fusion/advanced fusion if ever enqueued as FACTORY tasks, and advanced solar
					array<string> fusionReactorNames; fusionReactorNames = UnitHelpers::GetAllFusionReactors();
					for (uint fi = 0; fi < fusionReactorNames.length(); ++fi) {
						if (fusionReactorNames[fi] == buildDefName) {
							FusionQueuedCount++;
							IsFusionQueued = true;
							GenericHelpers::LogUtil("[BUILDER] AiTaskAdded: queued Fusion (FACTORY) '" + buildDefName + "' count=" + FusionQueuedCount, 2);
							break;
						}
					}
					array<string> advancedFusionReactorNames; advancedFusionReactorNames = UnitHelpers::GetAllAdvancedFusionReactors();
					for (uint afi = 0; afi < advancedFusionReactorNames.length(); ++afi) {
						if (advancedFusionReactorNames[afi] == buildDefName) {
							AdvancedFusionQueuedCount++;
							IsAdvancedFusionQueued = true;
							GenericHelpers::LogUtil("[BUILDER] AiTaskAdded: queued Advanced Fusion (FACTORY) '" + buildDefName + "' count=" + AdvancedFusionQueuedCount, 2);
							break;
						}
					}
					// Advanced Solar cooldown stamp if detected as factory task
					{
						string advArm = UnitHelpers::GetAdvSolarNameForSide("armada");
						string advCor = UnitHelpers::GetAdvSolarNameForSide("cortex");
						string advLeg = UnitHelpers::GetAdvSolarNameForSide("legion");
						if (buildDefName == advArm || buildDefName == advCor || buildDefName == advLeg) {
							MarkAdvSolarEnqueued();
							GenericHelpers::LogUtil("[BUILDER] AiTaskAdded: stamped Advanced Solar cooldown (FACTORY) '" + buildDefName + "'", 3);
						}
					}
				}
				else if (buildType == Task::BuildType::ENERGY) {
					// Fusion / Advanced Fusion queued flags
					array<string> fusionReactorNames; fusionReactorNames = UnitHelpers::GetAllFusionReactors();
					for (uint i = 0; i < fusionReactorNames.length(); ++i) {
						if (fusionReactorNames[i] == buildDefName) {
							FusionQueuedCount++;
							IsFusionQueued = true;
							GenericHelpers::LogUtil("[BUILDER] AiTaskAdded: queued Fusion '" + buildDefName + "' count=" + FusionQueuedCount, 2);
							break;
						}
					}
					array<string> advancedFusionReactorNames; advancedFusionReactorNames = UnitHelpers::GetAllAdvancedFusionReactors();
					for (uint j = 0; j < advancedFusionReactorNames.length(); ++j) {
						if (advancedFusionReactorNames[j] == buildDefName) {
							AdvancedFusionQueuedCount++;
							IsAdvancedFusionQueued = true;
							GenericHelpers::LogUtil("[BUILDER] AiTaskAdded: queued Advanced Fusion '" + buildDefName + "' count=" + AdvancedFusionQueuedCount, 2);
							break;
						}
					}
					// Advanced Solar cooldown stamp if detected as ENERGY task
					{
						string advArm = UnitHelpers::GetAdvSolarNameForSide("armada");
						string advCor = UnitHelpers::GetAdvSolarNameForSide("cortex");
						string advLeg = UnitHelpers::GetAdvSolarNameForSide("legion");
						if (buildDefName == advArm || buildDefName == advCor || buildDefName == advLeg) {
							MarkAdvSolarEnqueued();
							GenericHelpers::LogUtil("[BUILDER] AiTaskAdded: stamped Advanced Solar cooldown (ENERGY) '" + buildDefName + "'", 3);
						}
					}
			}
				// NANO builds: stamp nano cooldown on any NANO task with a known nano def
				if (buildType == Task::BuildType::NANO) {
					// We don't maintain per-side lists, so stamp cooldown generically
					MarkNanoEnqueued();
					GenericHelpers::LogUtil("[BUILDER] AiTaskAdded: stamped Nano cooldown", 3);
				}
		}

		GenericHelpers::LogUtil("[BUILDER] AiTaskAdded: completed queued flag processing", 4);

		// RoleConfig@ cfg = (Global::profileController is null) ? null : Global::profileController.RoleCfg;
		// if(cfg !is null && cfg.BuilderAiTaskAddedHandler !is null)
		// 	cfg.BuilderAiTaskAddedHandler(task);
	}

	void AiTaskRemoved(IUnitTask@ task, bool done)
	{
		SeaEconomy::Removed(task);
		MetalEconomy::Removed(task, done);
		{
			IBuilderTask@ mexTask = cast<IBuilderTask>(task);
			if (mexTask !is null) {
				const Task::BuildType mbt = Task::BuildType(mexTask.GetBuildType());
				if (done && mbt == Task::BuildType::MEX) {
					Economy::MexTracker::RegisterMex(mexTask.GetBuildPos());
				} else if (mbt == Task::BuildType::MEXUP) {
					Economy::MexTracker::MarkUpgradeInProgress(mexTask.GetBuildPos(), false);
					if (done) {
						Economy::MexTracker::MarkUpgraded(mexTask.GetBuildPos());
					}
				}
			}
		}
		GenericHelpers::LogUtil("[BUILDER] AiTaskRemoved called done=" + done, 4);

		// Release retained reactor tasks by identity, independent of def-name matching.
		if (FusionBuildTask !is null && FusionBuildTask is task) {
			@FusionBuildTask = null;
			GenericHelpers::LogUtil("[BUILDER] AiTaskRemoved: released Fusion build task", 2);
		}
		if (AdvancedFusionBuildTask !is null && AdvancedFusionBuildTask is task) {
			@AdvancedFusionBuildTask = null;
			GenericHelpers::LogUtil("[BUILDER] AiTaskRemoved: released Advanced Fusion build task", 2);
		}
		if (EnergyBuildTask !is null && EnergyBuildTask is task) {
			_SetEnergyBuildTask(null);
			GenericHelpers::LogUtil("[BUILDER] AiTaskRemoved: released T1 energy build task (done=" + done + ")", 2);
		}
		for (uint i = 0; i < EnergyAssistTasks.length(); ++i) {
			if (EnergyAssistTasks[i] is task) {
				EnergyAssistTasks.removeAt(i);
				break;
			}
		}
		// Resolve metadata BEFORE clearing tracks; prefer tracked
		BuilderTaskTrack@ tr = GetTrackByTask(task);
		string bname = (tr is null ? "" : tr.defName);
		Task::BuildType bt = Task::BuildType(tr is null ? -1 : tr.buildTypeVal);
		bool have = (bname.length() > 0);
		IBuilderTask@ builderTask = cast<IBuilderTask>(task);
		if (!have && builderTask !is null) {
			CCircuitDef@ buildDef = builderTask.buildDef;
			bname = (buildDef is null ? "" : buildDef.GetName());
			bt = Task::BuildType(builderTask.GetBuildType());
			have = (bname.length() > 0);
		}
		GenericHelpers::LogUtil("[BUILDER] AiTaskRemoved: resolved def='" + bname + "' buildType=" + int(bt), 4);
		// Clear per-builder current-task mapping for this task
		ClearBuilderTaskByTask(task);
		GenericHelpers::LogUtil("[BUILDER] AiTaskRemoved: cleared builder-task mapping for task", 4);
		// Clear any BuilderTaskTrack associated with this task
		ClearTrackByTask(task);
		GenericHelpers::LogUtil("[BUILDER] AiTaskRemoved: cleared tracking for task", 4);
		// Clear queued flags when matching tasks are removed/cancelled
		if (have) {
			GenericHelpers::LogUtil("[BUILDER] AiTaskRemoved: processing queued flags for def='" + bname + "' buildType=" + int(bt), 3);
			if (bt == Task::BuildType::FACTORY) {
				bool anyCleared = false;
				if (bname.length() == 0) {
					// Defensive: unknown build def, clear all factory queued counters
					if (Factory::T2BotLabQueuedCount > 0) { Factory::T2BotLabQueuedCount = 0; anyCleared = true; }
					if (Factory::T2VehPlantQueuedCount > 0) { Factory::T2VehPlantQueuedCount = 0; anyCleared = true; }
					if (Factory::T2AirPlantQueuedCount > 0) { Factory::T2AirPlantQueuedCount = 0; anyCleared = true; }
					if (Factory::T2ShipyardQueuedCount > 0) { Factory::T2ShipyardQueuedCount = 0; anyCleared = true; }
					// For safety, do not blindly clear NukeSiloQueuedCount on unknown; keep explicit handling below
				} 
				else 
				{
					if (UnitHelpers::IsT2BotLab(bname)) {
						if (Factory::T2BotLabQueuedCount > 0) Factory::T2BotLabQueuedCount--;
						anyCleared = true;
					}
					if (UnitHelpers::IsT2VehicleLab(bname) && Factory::T2VehPlantQueuedCount > 0) { Factory::T2VehPlantQueuedCount--; anyCleared = true; }
					if (UnitHelpers::IsT2AircraftPlant(bname) && Factory::T2AirPlantQueuedCount > 0) { Factory::T2AirPlantQueuedCount--; anyCleared = true; }
					if (UnitHelpers::IsT2Shipyard(bname) && Factory::T2ShipyardQueuedCount > 0) { Factory::T2ShipyardQueuedCount--; anyCleared = true; }

					// Gantry counters: decrement if this factory task was a gantry
					if (UnitHelpers::IsLandGantry(bname)) {
						if (LandGantryQueuedCount > 0) LandGantryQueuedCount--;
						GenericHelpers::LogUtil("[BUILDER] AiTaskRemoved: Land Gantry '" + bname + "' count=" + LandGantryQueuedCount, 2);
					}

					if (UnitHelpers::IsWaterGantry(bname)) {
						if (WaterGantryQueuedCount > 0) WaterGantryQueuedCount--;
						GenericHelpers::LogUtil("[BUILDER] AiTaskRemoved: Water Gantry '" + bname + "' count=" + WaterGantryQueuedCount, 2);
					}

					// Nuclear silos: decrement queued count if this factory task was a nuke silo
					{
						array<string> nukes = UnitHelpers::GetAllNukeSilos();
						for (uint ni = 0; ni < nukes.length(); ++ni) {
							if (nukes[ni] == bname) {
								if (NukeSiloQueuedCount > 0) NukeSiloQueuedCount--;
								GenericHelpers::LogUtil("[BUILDER] AiTaskRemoved: Nuclear Silo '" + bname + "' count=" + NukeSiloQueuedCount, 2);
								break;
							}
						}
					}

					// Fusion/AFUS counters
					// Robust: also handle fusion/advanced fusion if ever enqueued as FACTORY tasks
					array<string> fF; fF = UnitHelpers::GetAllFusionReactors();
					for (uint fi = 0; fi < fF.length(); ++fi) {
						if (fF[fi] == bname) {
							if (FusionQueuedCount > 0) FusionQueuedCount--;
							IsFusionQueued = (FusionQueuedCount > 0);
							GenericHelpers::LogUtil("[BUILDER] AiTaskRemoved: Fusion (FACTORY) '" + bname + "' count=" + FusionQueuedCount, 2);
							break;
						}
					}
					array<string> afF; afF = UnitHelpers::GetAllAdvancedFusionReactors();
					for (uint afi = 0; afi < afF.length(); ++afi) {
						if (afF[afi] == bname) {
							if (AdvancedFusionQueuedCount > 0) AdvancedFusionQueuedCount--;
							IsAdvancedFusionQueued = (AdvancedFusionQueuedCount > 0);
							GenericHelpers::LogUtil("[BUILDER] AiTaskRemoved: Advanced Fusion (FACTORY) '" + bname + "' count=" + AdvancedFusionQueuedCount, 2);
							break;
						}
					}
				}
				if (anyCleared) GenericHelpers::LogUtil("[BUILDER] Factory build task removed; cleared matching queued flags", 2);
			}
			else if (bt == Task::BuildType::ENERGY) {
				bool updated = false;
				if (bname.length() == 0) {
					// Unknown build def; avoid corrupting counts. No-op.
					GenericHelpers::LogUtil("[BUILDER] AiTaskRemoved: ENERGY with unknown buildDef; leaving fusion counts unchanged", 3);
				} else {
					array<string> f; f = UnitHelpers::GetAllFusionReactors();
					for (uint i = 0; i < f.length(); ++i) {
						if (f[i] == bname) {
							if (FusionQueuedCount > 0) FusionQueuedCount--;
							IsFusionQueued = (FusionQueuedCount > 0);
							updated = true;
							GenericHelpers::LogUtil("[BUILDER] AiTaskRemoved: Fusion '" + bname + "' count=" + FusionQueuedCount, 2);
							break;
						}
					}
					array<string> af; af = UnitHelpers::GetAllAdvancedFusionReactors();
					for (uint j = 0; j < af.length(); ++j) {
						if (af[j] == bname) {
							if (AdvancedFusionQueuedCount > 0) AdvancedFusionQueuedCount--;
							IsAdvancedFusionQueued = (AdvancedFusionQueuedCount > 0);
							updated = true;
							GenericHelpers::LogUtil("[BUILDER] AiTaskRemoved: Advanced Fusion '" + bname + "' count=" + AdvancedFusionQueuedCount, 2);
							break;
						}
					}
				}
				if (updated) GenericHelpers::LogUtil("[BUILDER] Energy build task removed; updated fusion queued counters", 2);
			}
		}

		RoleConfig@ cfg = (Global::profileController is null) ? null : Global::profileController.RoleCfg;
		if(cfg !is null && cfg.BuilderAiTaskRemovedHandler !is null)
			cfg.BuilderAiTaskRemovedHandler(task, done);
	}

	void AiUnitAdded(CCircuitUnit@ unit, Unit::UseAs usage)
	{
		GenericHelpers::LogUtil("[BUILDER] Enter AiUnitAdded", 4);
		if (unit is null) return;

		if (Team::Recovery::OnUnitAdded(unit)) return;

		// Role-independent, like the mex bookkeeping in AiTaskAdded: SEA counts
		// its construction ships here, TACTICAL unlocks its shipyard caps the
		// moment it owns one. Each branch checks its own AiRole.
		Team::SeaAssist::OnUnitAdded(unit);

		const CCircuitDef@ cdef = unit.circuitDef;
		// Construction turrets are the layout's biggest reservation and the one
		// whose absence was reported; one line per finished nano proves them.
		if (cdef !is null && cdef.GetName() == UnitHelpers::GetT1NanoNameForSide(Global::AISettings::Side)) {
			const AIFloat3 np = unit.GetPos(ai.frame);
			GenericHelpers::LogUtil("[BUILDER] nano finished: " + cdef.GetName() + "(" + unit.id + ") at ("
				+ int(np.x) + "," + int(np.z) + ") reserved slots left " + aiTerrainMgr.GetReservationCount(cdef), 1);
		}

		// Log details (id, name, tier, commander)
		LogAiUnitAdded(unit, cdef, usage);

		// Commander registration; if it's a new commander, record and stop
		if (TryRegisterCommander(unit, cdef)) {
			return;
		}

		// Non-builders or commanders get delegated immediately
		if (IsNotBuilderOrCommander(cdef, usage)) {
			DelegateRoleAiUnitAdded(unit, usage);
			return;
		}

		// Handle constructor-specific registration
		int ctorTier = UnitHelpers::GetConstructorTier(cdef);
		string uname = (cdef is null ? "" : cdef.GetName());
		int ctorCat = 0; // 1=bot, 2=veh, 3=air, 4=sea, 5=hover

		// TODO: Consider moving constructor category/tier detection into UnitHelpers
		// Legion T1 sea constructor uses a non-standard suffix ("legnavyconship"); detect explicitly
		if (uname == "legnavyconship") { 
			ctorCat = 4; 
			if (ctorTier == 0) ctorTier = 1; 
		}
		// SEA T2 uses 'acsub' suffix (e.g., armacsub/coracsub) – check long suffixes first
		if (uname.length() >= 5) {
			string suf5 = uname.substr(uname.length() - 5, 5);
			if (suf5 == "acsub") ctorCat = 4; // sea T2 (advanced construction sub)
		}
		if (uname.length() >= 3) {
			string suf3 = uname.substr(uname.length() - 3, 3);
			if (suf3 == "ack") ctorCat = 1; // bot T2
			else if (suf3 == "acv") ctorCat = 2; // veh T2
			else if (suf3 == "aca") ctorCat = 3; // air T2
		}
		if (ctorCat == 0 && uname.length() >= 2) {
			string suf2 = uname.substr(uname.length() - 2, 2);
			if (suf2 == "ck") ctorCat = 1; // bot T1
			else if (suf2 == "cv") ctorCat = 2; // veh T1
			else if (suf2 == "ca") ctorCat = 3; // air T1
			else if (suf2 == "cs") ctorCat = 4; // sea T1 (construction ship)
			else if (suf2 == "ch") ctorCat = 5; // hover T1 (construction hover)
		}
		// For air, UnitHelpers::GetConstructorTier() may return 0; infer from suffix
		if (ctorCat == 3 && ctorTier == 0) {
			ctorTier = (uname.length() >= 3 && uname.substr(uname.length() - 3, 3) == "aca") ? 2 : 1;
		}
		// For sea, infer tier by suffix as well if needed (or explicit legion name above)
		if (ctorCat == 4 && ctorTier == 0) {
			if (uname.length() >= 5 && uname.substr(uname.length() - 5, 5) == "acsub") ctorTier = 2;
			else ctorTier = 1;
		}

		if (ctorTier == 1) {
			if (ctorCat == 1) {
				if (TacticalEnabled && tacticalBotConstructor is null) {
					@tacticalBotConstructor = unit;
					GenericHelpers::LogUtil("[BUILDER] tacticalBotConstructor set to id=" + unit.id + " name=" + uname, 2);
					TryFillAllGuardSlots();
				}
				HandleT1BotConstructorAdded(unit);
			}
			else if (ctorCat == 2) {
				if (TacticalEnabled && tacticalVehConstructor is null) {
					@tacticalVehConstructor = unit;
					GenericHelpers::LogUtil("[BUILDER] tacticalVehConstructor set to id=" + unit.id + " name=" + uname, 2);
					TryFillAllGuardSlots();
				}
				HandleT1VehConstructorAdded(unit);
			}
			else if (ctorCat == 3) {
				if (TacticalEnabled && tacticalAirConstructor is null) {
					@tacticalAirConstructor = unit;
					GenericHelpers::LogUtil("[BUILDER] tacticalAirConstructor set to id=" + unit.id + " name=" + uname, 2);
					TryFillAllGuardSlots();
				}
				HandleT1AirConstructorAdded(unit);
			}
			else if (ctorCat == 4) {
				if (TacticalEnabled && tacticalSeaConstructor is null) {
					@tacticalSeaConstructor = unit;
					GenericHelpers::LogUtil("[BUILDER] tacticalSeaConstructor set to id=" + unit.id + " name=" + uname, 2);
					TryFillAllGuardSlots();
				}
				HandleT1SeaConstructorAdded(unit);
			}
			else if (ctorCat == 5) {
				GenericHelpers::LogUtil("[BUILDER] Detected T1 Hover Constructor id=" + unit.id + " name=" + uname, 2);
				// if (TacticalEnabled && tacticalHoverConstructor is null) {
				// 	@tacticalHoverConstructor = unit;
				// 	GenericHelpers::LogUtil("[BUILDER] tacticalHoverConstructor set to id=" + unit.id + " name=" + uname, 2);
				// 	TryFillAllGuardSlots();
				// }
				HandleT1HoverConstructorAdded(unit);
			}
		}
		if (ctorTier == 2) {
			if (ctorCat == 1) HandleT2BotConstructorAdded(unit);
			else if (ctorCat == 2) HandleT2VehConstructorAdded(unit);
			else if (ctorCat == 3) HandleT2AirConstructorAdded(unit);
			else if (ctorCat == 4) HandleT2SeaConstructorAdded(unit);
		}

		// Allow role-specific adjustments
		DelegateRoleAiUnitAdded(unit, usage);
	}

	// --- Small helpers for AiUnitAdded ---
	void LogAiUnitAdded(CCircuitUnit@ unit, const CCircuitDef@ cdef, Unit::UseAs usage)
	{
		if (cdef is null) {
			GenericHelpers::LogUtil("[BUILDER] AiUnitAdded: cdef=<null> id=" + unit.id, 2);
			return;
		}
		bool isComm = cdef.IsRoleAny(Unit::Role::COMM.mask);
		int ctorTier = UnitHelpers::GetConstructorTier(cdef);
		GenericHelpers::LogUtil(
			"[BUILDER] AiUnitAdded: id=" + unit.id +
			" name=" + cdef.GetName() +
			" usage=" + usage +
			" ctorTier=" + ctorTier +
			" isCommander=" + (isComm ? "true" : "false"),
			2
		);
	}

	bool TryRegisterCommander(CCircuitUnit@ unit, const CCircuitDef@ cdef)
	{
		if (cdef !is null && cdef.IsRoleAny(Unit::Role::COMM.mask) && (Builder::commander is null)) {
			@Builder::commander = unit;
			string name = (cdef is null ? "<null>" : cdef.GetName());
			GenericHelpers::LogUtil("[BUILDER][Commander] Registered commander id=" + unit.id + " name=" + name, 3);
			return true;
		}
		return false;
	}

	bool IsNotBuilderOrCommander(const CCircuitDef@ cdef, Unit::UseAs usage)
	{
		return (usage != Unit::UseAs::BUILDER) || (cdef !is null && cdef.IsRoleAny(Unit::Role::COMM.mask));
	}

	void DelegateRoleAiUnitAdded(CCircuitUnit@ unit, Unit::UseAs usage)
	{
		RoleConfig@ cfg = (Global::profileController is null) ? null : Global::profileController.RoleCfg;
		if (cfg !is null && cfg.BuilderAiUnitAdded !is null) {
			cfg.BuilderAiUnitAdded(unit, usage);
		}
	}

	void HandleT1BotConstructorAdded(CCircuitUnit@ unit)
	{
		if (Builder::primaryT1BotConstructor is null) {
			unit.AddAttribute(Unit::Attr::BASE.type); // only primary gets BASE
			@Builder::primaryT1BotConstructor = unit;
			GenericHelpers::LogUtil("[BUILDER] primaryT1BotConstructor set to id=" + unit.id, 2);
			// When a leader is set, try to fill from unassigned pool
			TryFillAllGuardSlots();
		}
		else if (Builder::secondaryT1BotConstructor is null && unit.id != Builder::primaryT1BotConstructor.id) {
			@Builder::secondaryT1BotConstructor = unit;
			GenericHelpers::LogUtil("[BUILDER] secondaryT1BotConstructor set to id=" + unit.id, 2);
			TryFillAllGuardSlots();
		}
		else {
			AssignGuardByRatio(0.5f, unit, 1);
		}
		// Recompute tracking eligibility after any leader/assignment change
		RecomputeTrackEligibleBuilders();
	}

	void HandleT2BotConstructorAdded(CCircuitUnit@ unit)
	{
		if (Builder::freelanceT2BotConstructor is null) {
			unit.AddAttribute(Unit::Attr::BASE.type);
			@Builder::freelanceT2BotConstructor = unit;
			GenericHelpers::LogUtil("[BUILDER] freelanceT2BotConstructor set to id=" + unit.id, 2);
		}
		else if (Builder::primaryT2BotConstructor is null) {
			unit.AddAttribute(Unit::Attr::BASE.type);
			@Builder::primaryT2BotConstructor = unit;
			GenericHelpers::LogUtil("[BUILDER] primaryT2BotConstructor set to id=" + unit.id, 2);
			TryFillAllGuardSlots();
		}
		else if (Builder::secondaryT2BotConstructor is null && unit.id != Builder::primaryT2BotConstructor.id) {
			@Builder::secondaryT2BotConstructor = unit;
			GenericHelpers::LogUtil("[BUILDER] secondaryT2BotConstructor set to id=" + unit.id, 2);
			TryFillAllGuardSlots();
		}
		else {
			AssignGuardByRatio(0.5f, unit, 2);
		}
		// Recompute tracking eligibility after any leader/assignment change
		RecomputeTrackEligibleBuilders();
	}

	void HandleT1SeaConstructorAdded(CCircuitUnit@ unit)
	{
		if (Builder::primaryT1SeaConstructor is null) {
			unit.AddAttribute(Unit::Attr::BASE.type);
			@Builder::primaryT1SeaConstructor = unit;
			GenericHelpers::LogUtil("[BUILDER] primaryT1SeaConstructor set to id=" + unit.id, 2);
			TryFillAllGuardSlots();
		}
		else if (Builder::secondaryT1SeaConstructor is null && unit.id != Builder::primaryT1SeaConstructor.id) {
			@Builder::secondaryT1SeaConstructor = unit;
			GenericHelpers::LogUtil("[BUILDER] secondaryT1SeaConstructor set to id=" + unit.id, 2);
			TryFillAllGuardSlots();
		}
		else {
			AssignGuardByRatioSea(0.5f, unit, 1);
		}
		// Recompute tracking eligibility after any leader/assignment change
		RecomputeTrackEligibleBuilders();
	}

	void HandleT2SeaConstructorAdded(CCircuitUnit@ unit)
	{
		if (Builder::freelanceT2SeaConstructor is null) {
			unit.AddAttribute(Unit::Attr::BASE.type);
			@Builder::freelanceT2SeaConstructor = unit;
			GenericHelpers::LogUtil("[BUILDER] freelanceT2SeaConstructor set to id=" + unit.id, 2);
		}
		else if (Builder::primaryT2SeaConstructor is null) {
			unit.AddAttribute(Unit::Attr::BASE.type);
			@Builder::primaryT2SeaConstructor = unit;
			GenericHelpers::LogUtil("[BUILDER] primaryT2SeaConstructor set to id=" + unit.id, 2);
			TryFillAllGuardSlots();
		}
		else if (Builder::secondaryT2SeaConstructor is null && unit.id != Builder::primaryT2SeaConstructor.id) {
			@Builder::secondaryT2SeaConstructor = unit;
			GenericHelpers::LogUtil("[BUILDER] secondaryT2SeaConstructor set to id=" + unit.id, 2);
			TryFillAllGuardSlots();
		}
		else {
			AssignGuardByRatioSea(0.5f, unit, 2);
		}
		// Recompute tracking eligibility after any leader/assignment change
		RecomputeTrackEligibleBuilders();
	}

	void HandleT1VehConstructorAdded(CCircuitUnit@ unit)
	{
		if (Builder::primaryT1VehConstructor is null) {
			unit.AddAttribute(Unit::Attr::BASE.type);
			@Builder::primaryT1VehConstructor = unit;
			GenericHelpers::LogUtil("[BUILDER] primaryT1VehConstructor set to id=" + unit.id, 2);
			TryFillAllGuardSlots();
		}
		else if (Builder::secondaryT1VehConstructor is null && unit.id != Builder::primaryT1VehConstructor.id) {
			@Builder::secondaryT1VehConstructor = unit;
			GenericHelpers::LogUtil("[BUILDER] secondaryT1VehConstructor set to id=" + unit.id, 2);
			TryFillAllGuardSlots();
		}
		else {
			AssignGuardByRatioVehicle(0.5f, unit, 1);
		}
		// Recompute tracking eligibility after any leader/assignment change
		RecomputeTrackEligibleBuilders();
	}

	void HandleT1HoverConstructorAdded(CCircuitUnit@ unit)
	{
		if (Builder::tacticalHoverConstructor is null) {
			//unit.AddAttribute(Unit::Attr::BASE.type);
			@Builder::tacticalHoverConstructor = unit;
			GenericHelpers::LogUtil("[BUILDER] tacticalHoverConstructor set to id=" + unit.id, 2);
			TryFillAllGuardSlots();
		}
		else if (Builder::primaryT1HoverConstructor is null && unit.id != Builder::tacticalHoverConstructor.id) {
			unit.AddAttribute(Unit::Attr::BASE.type);
			@Builder::primaryT1HoverConstructor = unit;
			GenericHelpers::LogUtil("[BUILDER] primaryT1HoverConstructor set to id=" + unit.id, 2);
			TryFillAllGuardSlots();
		}
		else if (Builder::secondaryT1HoverConstructor is null && unit.id != Builder::primaryT1HoverConstructor.id && unit.id != Builder::tacticalHoverConstructor.id) {
			@Builder::secondaryT1HoverConstructor = unit;
			GenericHelpers::LogUtil("[BUILDER] secondaryT1HoverConstructor set to id=" + unit.id, 2);
			TryFillAllGuardSlots();
		}
		// else if (Builder::freelanceT1HoverConstructor is null
		// 	&& unit.id != Builder::primaryT1HoverConstructor.id
		// 	&& (Builder::secondaryT1HoverConstructor is null || unit.id != Builder::secondaryT1HoverConstructor.id)) {
		// 	@Builder::freelanceT1HoverConstructor = unit;
		// 	GenericHelpers::LogUtil("[BUILDER] freelanceT1HoverConstructor set to id=" + unit.id, 2);
		// }
		else {
			AssignGuardByRatioHover(0.5f, unit, 1);
		}
		// Recompute tracking eligibility after any leader/assignment change
		RecomputeTrackEligibleBuilders();
	}

	void HandleT2VehConstructorAdded(CCircuitUnit@ unit)
	{
		if (Builder::freelanceT2VehConstructor is null) {
			unit.AddAttribute(Unit::Attr::BASE.type);
			@Builder::freelanceT2VehConstructor = unit;
			GenericHelpers::LogUtil("[BUILDER] freelanceT2VehConstructor set to id=" + unit.id, 2);
		}
		else if (Builder::primaryT2VehConstructor is null) {
			unit.AddAttribute(Unit::Attr::BASE.type);
			@Builder::primaryT2VehConstructor = unit;
			GenericHelpers::LogUtil("[BUILDER] primaryT2VehConstructor set to id=" + unit.id, 2);
			TryFillAllGuardSlots();
		}
		else if (Builder::secondaryT2VehConstructor is null && unit.id != Builder::primaryT2VehConstructor.id) {
			@Builder::secondaryT2VehConstructor = unit;
			GenericHelpers::LogUtil("[BUILDER] secondaryT2VehConstructor set to id=" + unit.id, 2);
			TryFillAllGuardSlots();
		}
		else {
			AssignGuardByRatioVehicle(0.5f, unit, 2);
		}
		// Recompute tracking eligibility after any leader/assignment change
		RecomputeTrackEligibleBuilders();
	}

	void HandleT1AirConstructorAdded(CCircuitUnit@ unit)
	{
		if (Builder::primaryT1AirConstructor is null) {
			unit.AddAttribute(Unit::Attr::BASE.type);
			@Builder::primaryT1AirConstructor = unit;
			GenericHelpers::LogUtil("[BUILDER] primaryT1AirConstructor set to id=" + unit.id, 2);
			TryFillAllGuardSlots();
		}
		else if (Builder::secondaryT1AirConstructor is null && unit.id != Builder::primaryT1AirConstructor.id) {
			@Builder::secondaryT1AirConstructor = unit;
			GenericHelpers::LogUtil("[BUILDER] secondaryT1AirConstructor set to id=" + unit.id, 2);
			TryFillAllGuardSlots();
		}
		else {
			AssignGuardByRatioAircraft(0.5f, unit, 1);
		}
		// Recompute tracking eligibility after any leader/assignment change
		RecomputeTrackEligibleBuilders();
	}

	void HandleT2AirConstructorAdded(CCircuitUnit@ unit)
	{
		if (Builder::freelanceT2AirConstructor is null) {
			unit.AddAttribute(Unit::Attr::BASE.type);
			@Builder::freelanceT2AirConstructor = unit;
			GenericHelpers::LogUtil("[BUILDER] freelanceT2AirConstructor set to id=" + unit.id, 2);
		}
		else if (Builder::primaryT2AirConstructor is null) {
			unit.AddAttribute(Unit::Attr::BASE.type);
			@Builder::primaryT2AirConstructor = unit;
			GenericHelpers::LogUtil("[BUILDER] primaryT2AirConstructor set to id=" + unit.id, 2);
			TryFillAllGuardSlots();
		}
		else if (Builder::secondaryT2AirConstructor is null && unit.id != Builder::primaryT2AirConstructor.id) {
			@Builder::secondaryT2AirConstructor = unit;
			GenericHelpers::LogUtil("[BUILDER] secondaryT2AirConstructor set to id=" + unit.id, 2);
			TryFillAllGuardSlots();
		}
		else {
			AssignGuardByRatioAircraft(0.5f, unit, 2);
		}
		// Recompute tracking eligibility after any leader/assignment change
		RecomputeTrackEligibleBuilders();
	}

	void AiUnitRemoved(CCircuitUnit@ unit, Unit::UseAs usage)
	{
		GenericHelpers::LogUtil("[BUILDER] Enter AiUnitRemoved", 4);
		if (unit is null) return;

		Team::SeaAssist::OnUnitRemoved(unit);

		// Ensure any per-builder task mapping is cleared for this unit
		ClearBuilderTaskByUnit(unit);
		// Also clear any tracked pending task for this unit
		ClearTrackByBuilder(unit);
		Team::Recovery::OnUnitRemoved(unit);

		// Clear tracked references
		if (Builder::commander is unit)                 {
			GenericHelpers::LogUtil("[BUILDER][Commander] Cleared commander handle on removal (id=" + unit.id + ")", 3);
			@Builder::commander = null;
		}
		if (Builder::primaryT1BotConstructor is unit)   { @Builder::primaryT1BotConstructor = null; }
		if (Builder::secondaryT1BotConstructor is unit) { @Builder::secondaryT1BotConstructor = null; }
		if (Builder::primaryT2BotConstructor is unit)   { @Builder::primaryT2BotConstructor = null; }
		if (Builder::secondaryT2BotConstructor is unit) { @Builder::secondaryT2BotConstructor = null; }
		if (Builder::freelanceT2BotConstructor is unit) { @Builder::freelanceT2BotConstructor = null; }
		if (Builder::primaryT1VehConstructor is unit)   { @Builder::primaryT1VehConstructor = null; }
		if (Builder::secondaryT1VehConstructor is unit) { @Builder::secondaryT1VehConstructor = null; }
		if (Builder::primaryT2VehConstructor is unit)   { @Builder::primaryT2VehConstructor = null; }
		if (Builder::secondaryT2VehConstructor is unit) { @Builder::secondaryT2VehConstructor = null; }
		if (Builder::freelanceT2VehConstructor is unit) { @Builder::freelanceT2VehConstructor = null; }
		if (Builder::primaryT1AirConstructor is unit)   { @Builder::primaryT1AirConstructor = null; }
		if (Builder::secondaryT1AirConstructor is unit) { @Builder::secondaryT1AirConstructor = null; }
		if (Builder::primaryT2AirConstructor is unit)   { @Builder::primaryT2AirConstructor = null; }
		if (Builder::secondaryT2AirConstructor is unit) { @Builder::secondaryT2AirConstructor = null; }
		if (Builder::freelanceT2AirConstructor is unit) { @Builder::freelanceT2AirConstructor = null; }
		if (Builder::primaryT1SeaConstructor is unit)   { @Builder::primaryT1SeaConstructor = null; }
		if (Builder::secondaryT1SeaConstructor is unit) { @Builder::secondaryT1SeaConstructor = null; }
		if (Builder::primaryT2SeaConstructor is unit)   { @Builder::primaryT2SeaConstructor = null; }
		if (Builder::secondaryT2SeaConstructor is unit) { @Builder::secondaryT2SeaConstructor = null; }
		if (Builder::freelanceT2SeaConstructor is unit) { @Builder::freelanceT2SeaConstructor = null; }
		if (Builder::freelanceT1HoverConstructor is unit) { @Builder::freelanceT1HoverConstructor = null; }
		if (Builder::primaryT1HoverConstructor is unit) { @Builder::primaryT1HoverConstructor = null; }
		if (Builder::secondaryT1HoverConstructor is unit) { @Builder::secondaryT1HoverConstructor = null; }

		if (Builder::tacticalBotConstructor is unit) { @Builder::tacticalBotConstructor = null; }
		if (Builder::tacticalVehConstructor is unit) { @Builder::tacticalVehConstructor = null; }
		if (Builder::tacticalAirConstructor is unit) { @Builder::tacticalAirConstructor = null; }
		if (Builder::tacticalSeaConstructor is unit) { @Builder::tacticalSeaConstructor = null; }
		if (Builder::tacticalHoverConstructor is unit) { @Builder::tacticalHoverConstructor = null; }
		// Labs tracked by Factory manager; no action needed here

		// Remove from guard maps and unassigned pool
		string key = "" + unit.id;
		Builder::primaryT1BotConstructorGuards.delete(key);
		Builder::secondaryT1BotConstructorGuards.delete(key);
		Builder::primaryT2BotConstructorGuards.delete(key);
		Builder::secondaryT2BotConstructorGuards.delete(key);
		Builder::primaryT1VehConstructorGuards.delete(key);
		Builder::secondaryT1VehConstructorGuards.delete(key);
		Builder::primaryT2VehConstructorGuards.delete(key);
		Builder::secondaryT2VehConstructorGuards.delete(key);
		Builder::primaryT1AirConstructorGuards.delete(key);
		Builder::secondaryT1AirConstructorGuards.delete(key);
		Builder::primaryT2AirConstructorGuards.delete(key);
		Builder::secondaryT2AirConstructorGuards.delete(key);
		Builder::commanderGuards.delete(key);
		Builder::primaryT1SeaConstructorGuards.delete(key);
		Builder::secondaryT1SeaConstructorGuards.delete(key);
		Builder::primaryT2SeaConstructorGuards.delete(key);
		Builder::secondaryT2SeaConstructorGuards.delete(key);
		Builder::primaryT1HoverConstructorGuards.delete(key);
		Builder::secondaryT1HoverConstructorGuards.delete(key);
		Builder::tacticalBotConstructorGuards.delete(key);
		Builder::tacticalVehConstructorGuards.delete(key);
		Builder::tacticalAirConstructorGuards.delete(key);
		Builder::tacticalSeaConstructorGuards.delete(key);
		Builder::tacticalHoverConstructorGuards.delete(key);
		Builder::unassignedWorkers.delete(key);

		// Attempt promotions then try to refill guard slots from unassigned pool
		Builder::PromoteIfNeeded();
		TryFillAllGuardSlots();
		// Recompute tracking eligibility after removals/promotions
		RecomputeTrackEligibleBuilders();

		// Delegate to role-specific
		RoleConfig@ cfg = (Global::profileController is null) ? null : Global::profileController.RoleCfg;
		if (cfg !is null && cfg.BuilderAiUnitRemoved !is null)
			cfg.BuilderAiUnitRemoved(unit, usage);
	}

	/******************************************************************************

	GUARD REFILL FROM UNASSIGNED POOL

	******************************************************************************/
	// Attempt to fill guard slots for a specific leader pair (primary/secondary) using unassigned workers
	void _TryFillGuardSlotsFor(CCircuitUnit@ primary, dictionary@ primaryGuards, CCircuitUnit@ secondary, dictionary@ secondaryGuards, int maxPerLeader)
	{
		int pCount = GuardHelpers::CountDict(@primaryGuards);
		int sCount = GuardHelpers::CountDict(@secondaryGuards);
		if ((primary is null && secondary is null) || (unassignedWorkers.getKeys() is null)) return;

		array<string>@ keys = unassignedWorkers.getKeys();
		for (uint i = 0; i < keys.length(); ++i) {
			if ((primary !is null && pCount < maxPerLeader) || (secondary !is null && sCount < maxPerLeader)) {
				CCircuitUnit@ worker = null;
				if (!unassignedWorkers.get(keys[i], @worker) || worker is null) continue;
				// Prefer filling primary first, then secondary
				if (primary !is null && pCount < maxPerLeader) {
					string k = "" + worker.id;
					primaryGuards.set(k, @worker);
					unassignedWorkers.delete(keys[i]);
					pCount++;
					continue;
				}
				if (secondary !is null && sCount < maxPerLeader) {
					string k2 = "" + worker.id;
					secondaryGuards.set(k2, @worker);
					unassignedWorkers.delete(keys[i]);
					sCount++;
					continue;
				}
			}
		}
	}

	// Fill for all categories
	void TryFillAllGuardSlots()
	{
		const int gMax = Global::RoleSettings::BuilderMaxGuardsPerLeader;
		const int sMax = Global::RoleSettings::Sea::BuilderMaxGuardsPerLeader;
		_TryFillGuardSlotsFor(Builder::primaryT1BotConstructor, @Builder::primaryT1BotConstructorGuards,
			Builder::secondaryT1BotConstructor, @Builder::secondaryT1BotConstructorGuards, gMax);
		_TryFillGuardSlotsFor(Builder::primaryT2BotConstructor, @Builder::primaryT2BotConstructorGuards,
			Builder::secondaryT2BotConstructor, @Builder::secondaryT2BotConstructorGuards, gMax);
		_TryFillGuardSlotsFor(Builder::primaryT1VehConstructor, @Builder::primaryT1VehConstructorGuards,
			Builder::secondaryT1VehConstructor, @Builder::secondaryT1VehConstructorGuards, gMax);
		_TryFillGuardSlotsFor(Builder::primaryT2VehConstructor, @Builder::primaryT2VehConstructorGuards,
			Builder::secondaryT2VehConstructor, @Builder::secondaryT2VehConstructorGuards, gMax);
		_TryFillGuardSlotsFor(Builder::primaryT1AirConstructor, @Builder::primaryT1AirConstructorGuards,
			Builder::secondaryT1AirConstructor, @Builder::secondaryT1AirConstructorGuards, gMax);
		_TryFillGuardSlotsFor(Builder::primaryT2AirConstructor, @Builder::primaryT2AirConstructorGuards,
			Builder::secondaryT2AirConstructor, @Builder::secondaryT2AirConstructorGuards, gMax);
		_TryFillGuardSlotsFor(Builder::primaryT1SeaConstructor, @Builder::primaryT1SeaConstructorGuards,
			Builder::secondaryT1SeaConstructor, @Builder::secondaryT1SeaConstructorGuards, sMax);
		_TryFillGuardSlotsFor(Builder::primaryT2SeaConstructor, @Builder::primaryT2SeaConstructorGuards,
			Builder::secondaryT2SeaConstructor, @Builder::secondaryT2SeaConstructorGuards, sMax);
		_TryFillGuardSlotsFor(Builder::primaryT1HoverConstructor, @Builder::primaryT1HoverConstructorGuards,
			Builder::secondaryT1HoverConstructor, @Builder::secondaryT1HoverConstructorGuards, gMax);
	}

	// Tactical getters/config
	namespace TacticalCategory { const int BOT=1, VEH=2, AIR=3, SEA=4, HOVER=5; }

	// Determine constructor category from unit name suffix (mirrors AiUnitAdded logic)
	int _CtorCategoryFromName(const string &in uname)
	{
		int ctorCat = 0;
		// Legion T1 sea constructor has unique name (no 'cs' suffix)
		if (uname == "legnavyconship") return 4;
		if (uname.length() >= 5) {
			string suf5 = uname.substr(uname.length() - 5, 5);
			if (suf5 == "acsub") ctorCat = 4; // sea T2 (advanced construction sub)
		}
		if (uname.length() >= 3) {
			string suf3 = uname.substr(uname.length() - 3, 3);
			if (suf3 == "ack") ctorCat = 1; // bot T2
			else if (suf3 == "acv") ctorCat = 2; // veh T2
			else if (suf3 == "aca") ctorCat = 3; // air T2
		}
		if (ctorCat == 0 && uname.length() >= 2) {
			string suf2 = uname.substr(uname.length() - 2, 2);
			if (suf2 == "ck") ctorCat = 1; // bot T1
			else if (suf2 == "cv") ctorCat = 2; // veh T1
			else if (suf2 == "ca") ctorCat = 3; // air T1
			else if (suf2 == "cs") ctorCat = 4; // sea T1 (ship)
			else if (suf2 == "ch") ctorCat = 5; // hover T1
		}
		return ctorCat;
	}

	// Find a constructor in unassigned pool for a given category
	CCircuitUnit@ _FindUnassignedByCategory(int category)
	{
		array<string>@ keys = unassignedWorkers.getKeys();
		if (keys is null) return null;
		for (uint i = 0; i < keys.length(); ++i) {
			CCircuitUnit@ u = null;
			if (!unassignedWorkers.get(keys[i], @u) || u is null) continue;
			const CCircuitDef@ cdef = u.circuitDef;
			if (cdef is null) continue;
			string uname = cdef.GetName();
			int cat = _CtorCategoryFromName(uname);
			if (cat == category) {
				return u;
			}
		}
		return null;
	}

	// Assign tactical constructors from unassigned pool only
	void _EnsureTacticalFromUnassignedFor(int category)
	{
		if (!TacticalEnabled) return;
		if (category == TacticalCategory::HOVER && tacticalHoverConstructor is null) {
			CCircuitUnit@ u = _FindUnassignedByCategory(category);
			if (u !is null) { @tacticalHoverConstructor = u; _UnassignedRemove(u); GenericHelpers::LogUtil("[BUILDER] Backfilled tacticalHoverConstructor from unassigned id=" + u.id, 2); return; }
			GenericHelpers::LogUtil("[BUILDER] Tactical enabled but no unassigned hover constructor to backfill", 2);
		}
		if (category == TacticalCategory::BOT && tacticalBotConstructor is null) {
			CCircuitUnit@ u = _FindUnassignedByCategory(category);
			if (u !is null) { @tacticalBotConstructor = u; _UnassignedRemove(u); GenericHelpers::LogUtil("[BUILDER] Backfilled tacticalBotConstructor from unassigned id=" + u.id, 2); return; }
		}
		if (category == TacticalCategory::VEH && tacticalVehConstructor is null) {
			CCircuitUnit@ u = _FindUnassignedByCategory(category);
			if (u !is null) { @tacticalVehConstructor = u; _UnassignedRemove(u); GenericHelpers::LogUtil("[BUILDER] Backfilled tacticalVehConstructor from unassigned id=" + u.id, 2); return; }
		}
		if (category == TacticalCategory::AIR && tacticalAirConstructor is null) {
			CCircuitUnit@ u = _FindUnassignedByCategory(category);
			if (u !is null) { @tacticalAirConstructor = u; _UnassignedRemove(u); GenericHelpers::LogUtil("[BUILDER] Backfilled tacticalAirConstructor from unassigned id=" + u.id, 2); return; }
		}
		if (category == TacticalCategory::SEA && tacticalSeaConstructor is null) {
			CCircuitUnit@ u = _FindUnassignedByCategory(category);
			if (u !is null) { @tacticalSeaConstructor = u; _UnassignedRemove(u); GenericHelpers::LogUtil("[BUILDER] Backfilled tacticalSeaConstructor from unassigned id=" + u.id, 2); return; }
		}
	}

	void _EnsureAllTacticalsFromUnassigned()
	{
		_EnsureTacticalFromUnassignedFor(TacticalCategory::BOT);
		_EnsureTacticalFromUnassignedFor(TacticalCategory::VEH);
		_EnsureTacticalFromUnassignedFor(TacticalCategory::AIR);
		_EnsureTacticalFromUnassignedFor(TacticalCategory::SEA);
		_EnsureTacticalFromUnassignedFor(TacticalCategory::HOVER);
	}

	CCircuitUnit@ GetTacticalFor(int category) {
		if (category == TacticalCategory::BOT) return Builder::tacticalBotConstructor;
		if (category == TacticalCategory::VEH) return Builder::tacticalVehConstructor;
		if (category == TacticalCategory::AIR) return Builder::tacticalAirConstructor;
		if (category == TacticalCategory::SEA) return Builder::tacticalSeaConstructor;
		if (category == TacticalCategory::HOVER) return Builder::tacticalHoverConstructor;
		return null;
	}

	CCircuitUnit@ GetTacticalFor(const string &in categoryName) {
		string c = categoryName; c.toLower();
		if (c == "bot" || c == "bots") return GetTacticalFor(TacticalCategory::BOT);
		if (c == "veh" || c == "vehicle" || c == "vehicles") return GetTacticalFor(TacticalCategory::VEH);
		if (c == "air" || c == "aircraft") return GetTacticalFor(TacticalCategory::AIR);
		if (c == "sea" || c == "naval" || c == "ship") return GetTacticalFor(TacticalCategory::SEA);
		if (c == "hover" || c == "hovers") return GetTacticalFor(TacticalCategory::HOVER);
		return null;
	}

	void SetTacticalEnabled(bool enabled) {
		TacticalEnabled = enabled;
		if (enabled) {
			// Don't try to backfill tacticals at init; there may be no units yet.
			// Defer until at least one unassigned worker exists.
			array<string>@ keys = Builder::unassignedWorkers.getKeys();
			if (keys !is null && keys.length() > 0) {
				_EnsureAllTacticalsFromUnassigned();
			} else {
				GenericHelpers::LogUtil("[BUILDER] Tactical enabled: defer backfill (no unassigned workers yet)", 4);
			}
		} else {
			GenericHelpers::LogUtil("[BUILDER] Tactical disabled", 4);
		}
		// Recompute tracking eligibility after tactical toggle/backfill
		RecomputeTrackEligibleBuilders();
	}
	CCircuitUnit@ GetTacticalConstructor() { return Builder::tacticalHoverConstructor; }

	CCircuitUnit@ GetCommander() { return Builder::commander; }

	void AiLoad(IStream& istream)
	{

	}

	void AiSave(OStream& ostream)
	{
	
	}

}  // namespace Builder
