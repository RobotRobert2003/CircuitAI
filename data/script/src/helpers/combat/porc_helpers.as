#include "../../define.as"
#include "../../global.as"
#include "../common/generic_helpers.as"

/******************************************************************************

PORCUPINE CHAIN

The porcupine chain is the ordered list of static defences a metal cluster
works through; native CMilitaryManager::DefaultMakeDefence walks it and builds
as far down as the income budget for that point allows. It is seeded per side
from the "porcupine" block of build_chain.json (and build_chain_leg.json for
Legion), where "unit" is an ordered per-side list and "land"/"water" are arrays
of indices into it.

That default is a single ordering shared by every role and frozen at config
load. This layer lets the active role rewrite it at setup:

    array<string>@ chain = aiMilitaryMgr.GetPorcChain(side, false);   // land
    ... splice ...
    aiMilitaryMgr.SetPorcChain(side, false, chain);

Two things drive a rewrite.

ROLE. A defensive role wants heavier statics earlier; an aggressive one wants
the cheap deterrent and nothing more. A role supplies a PorcChainDelegate and
gets the default chain to edit; roles that supply none keep the JSON order.

MOD OPTIONS. Content options gate whole unit tiers. Legion is already handled
by the config fragment system - build_chain_leg.json supplies the legion side
list - but the Extra Units Pack is not: it adds a tier of statics that exists
in no chain. When experimentalextraunits is on those units are buildable, and
the natural handling is additive, appending the new tier after the vanilla one
rather than replacing anything. Scavenger content is treated the same way.

Everything here is data plus two native calls, so a chain change needs no
rebuild - only a refresh of the deployed script tree.

******************************************************************************/
namespace PorcHelpers {

	// Extra Units Pack statics, appended when experimentalextraunits is on.
	// A genuine extra tier rather than replacements: T2 pop-up walls and the
	// T3 shields. Sea entries go on the water chain only. See doc/extra_units.md.
	//
	// The pack's mini long-range plasma pieces - armminivulc, corminibuzz and
	// legministarfall - belong here too and are deliberately absent: they exist
	// in BAR but not in the shared unit cache, so
	// tools/knowledge/check_unit_helpers.py cannot validate them and rejects the
	// ids. Add them once the cache covers the pack; SetPorcChain skips and logs
	// any def that is not loaded, so a premature entry is safe but silent.
	dictionary ExtraUnitsLand = {
		{"armada", array<string> = {"armlwall", "armgatet3"}},
		{"cortex", array<string> = {"cormwall", "corgatet3"}},
		{"legion", array<string> = {"legrwall", "leggatet3"}}
	};
	dictionary ExtraUnitsWater = {
		{"armada", array<string> = {"armgplat", "armfrock"}},
		{"cortex", array<string> = {"corgplat", "corfrock"}},
		{"legion", array<string> = {}}
	};

	// Appended when scavunitsforplayers is on. Empty by default: the scavenger
	// statics worth porcing with have not been picked yet, and an empty list
	// keeps the hook visible without inventing content.
	dictionary ScavUnitsLand = {
		{"armada", array<string> = {}},
		{"cortex", array<string> = {}},
		{"legion", array<string> = {}}
	};

	// The Juno, and the ranged tactical launcher that sits at the far end of the
	// same chain. Both are T2 statics reached from the porcupine chain and
	// nowhere else; the superweapon block only lists anti-nukes and silos.
	//
	// The launchers occupy chain positions 16 and 25, which need a cumulative
	// ~24k and ~48k of porc budget at one defence point. A cluster never gets
	// near that: maxCost is amountFactor (32-48) x metal income, so position 16
	// wants an income around 600. In practice these entries are unreachable and
	// the class is never built at all. Position 7 - the Juno - is the last
	// entry a well-funded cluster actually reaches, which is why swapping there
	// is the only way to get a launcher onto the map.
	dictionary Junos = {
		{"armada", "armjuno"},
		{"cortex", "corjuno"},
		{"legion", "legjuno"}
	};

	// Armada Paralyzer (EMP Missile Launcher, 1600M), Cortex Catalyst (Tactical
	// Missile Launcher, 1200M), Legion Perdition (Long Range Napalm Launcher,
	// 1250M). Different damage types, one role: a stockpiled ranged strike on a
	// static target, which is what a defensive economic role can use and a Juno
	// - whose only targets are radar, jammers, mines and scout spam - is not.
	dictionary TacticalLaunchers = {
		{"armada", "armemp"},
		{"cortex", "cortron"},
		{"legion", "legperdition"}
	};

	// A side's entry from one of the tables above, or "" when the side is not
	// listed. Callers treat "" as "this side has no such unit; change nothing".
	string ForSide(const dictionary@ table, const string &in side)
	{
		if (table is null) return "";
		string name;
		// if/else rather than a ternary: a non-primitive ?: is a compile risk
		// this tree cannot test for without loading a game.
		if (table.get(side, name)) {
			return name;
		}
		return "";
	}

	// Public: role handlers use it to avoid adding a def the chain already has.
	bool Contains(const array<string>@ list, const string &in name)
	{
		for (uint i = 0; i < list.length(); ++i) {
			if (list[i] == name) return true;
		}
		return false;
	}

	// Append every entry of `add` not already present. Additive by design: a
	// content option adds a tier, it does not reorder what was already there.
	void AppendTier(array<string>@ chain, const dictionary@ table, const string &in side, const string &in why)
	{
		if (chain is null || table is null) return;
		array<string>@ add = null;
		if (!table.get(side, @add) || add is null || add.length() == 0) return;
		uint added = 0;
		for (uint i = 0; i < add.length(); ++i) {
			if (Contains(chain, add[i])) continue;
			chain.insertLast(add[i]);
			++added;
		}
		if (added > 0) {
			GenericHelpers::LogUtil("[Porc] " + side + ": appended " + added + " def(s) for " + why, 2);
		}
	}

	// The default chain for a side and terrain: the JSON order, plus whatever
	// the active content options add. A role that wants nothing more than this
	// supplies no delegate and never calls it.
	array<string>@ DefaultChain(const string &in side, bool isWater)
	{
		array<string>@ chain = aiMilitaryMgr.GetPorcChain(side, isWater);
		if (chain is null) {
			array<string> empty;
			return empty;
		}
		if (Global::ModOptions::ExperimentalExtraUnits) {
			// if/else rather than a ternary: handle-typed ternaries are a
			// compile risk this tree cannot test for without loading a game.
			if (isWater) {
				AppendTier(@chain, @ExtraUnitsWater, side, "experimentalextraunits");
			} else {
				AppendTier(@chain, @ExtraUnitsLand, side, "experimentalextraunits");
			}
		}
		if (Global::ModOptions::ScavUnitsForPlayers && !isWater) {
			AppendTier(@chain, @ScavUnitsLand, side, "scavunitsforplayers");
		}
		return chain;
	}

	// Push the default chain for both terrains. Roles with no opinion use this.
	void ApplyDefaultChains(const string &in side)
	{
		aiMilitaryMgr.SetPorcChain(side, false, DefaultChain(side, false));
		aiMilitaryMgr.SetPorcChain(side, true, DefaultChain(side, true));
	}

	// Substitute every occurrence of `from` with `to`, in place. Unlike Remove
	// plus insertLast this keeps the position, which is the whole point when
	// position is priority: the replacement is reached exactly as often as the
	// entry it displaced. Returns how many were swapped, so a caller can log
	// the no-op case rather than guess.
	uint Replace(array<string>@ chain, const string &in from, const string &in to)
	{
		if (chain is null || from.length() == 0 || to.length() == 0) return 0;
		uint n = 0;
		for (uint i = 0; i < chain.length(); ++i) {
			if (chain[i] == from) {
				chain[i] = to;
				++n;
			}
		}
		return n;
	}

	/**************************************************************************
	 Entry point. Called from Setup after the role's InitHandler, so a role's
	 delegate sees its own start limits already applied.
	 **************************************************************************/
	void ApplyForRole()
	{
		const string side = Global::AISettings::Side;
		if (side.length() == 0) {
			GenericHelpers::LogUtil("[Porc] No side resolved; keeping the config chain", 2);
			return;
		}
		RoleConfig@ cfg = (Global::profileController is null) ? null : Global::profileController.RoleCfg;
		if (cfg is null || cfg.PorcChainHandler is null) {
			ApplyDefaultChains(side);
			GenericHelpers::LogUtil("[Porc] " + side + ": default chain (no role override)", 2);
			return;
		}
		cfg.PorcChainHandler(side);
		GenericHelpers::LogUtil("[Porc] " + side + ": chain set by role " + Global::AISettings::Role, 1);
	}

}  // namespace PorcHelpers
