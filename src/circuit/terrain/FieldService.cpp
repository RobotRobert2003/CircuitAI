/*
 * FieldService.cpp
 *
 * D-323: see FieldService.h.
 */

#include "terrain/FieldService.h"
#include "terrain/field/FieldAnalysis.h"
#include "terrain/field/FieldEncode.h"
#include "terrain/field/FieldLandmarks.h"
#include "terrain/field/FieldSettings.h"
#include "CircuitAI.h"
#include "scheduler/Scheduler.h"
#include "setup/SetupData.h"
#include "setup/SetupManager.h"
#include "spring/SpringCallback.h"
#include "spring/SpringMap.h"
#include "unit/ally/AllyTeam.h"
#include "util/GameAttribute.h"
#include "util/WidgetStateStore.h"
#include "util/Utils.h"

#include "json/json.h"
#include "DataDirs.h"
#include "Log.h"
#include "Roots.h"

#include <chrono>
#include <cstring>
#include <fstream>
#include <system_error>

namespace circuit {
namespace field {

using namespace springai;

namespace {

using Clock = std::chrono::steady_clock;

double Ms(Clock::time_point since)
{
	return std::chrono::duration<double, std::milli>(Clock::now() - since).count();
}

// Delegated completion: a poll every second on another AI while the owner is gone.
constexpr int POLL_FRAMES = FRAMES_PER_SEC;

std::filesystem::path LocateWritable(CCircuitAI* circuit, const std::string& relPath)
{
	DataDirs* dataDirs = circuit->GetCallback()->GetDataDirs();
	Roots* roots = dataDirs->GetRoots();
	static constexpr int absPath_sizeMax = 2048;
	char absPath[absPath_sizeMax] = {'\0'};
	const bool located = roots->LocatePath(absPath, absPath_sizeMax, relPath.c_str(), true /*writeable*/, true /*create*/, false /*dir*/);
	delete roots;
	delete dataDirs;
	if (!located || absPath[0] == '\0') return std::filesystem::path();
	return std::filesystem::path(absPath);
}

// Raw dump of the input for the native test harness (ints and floats, little endian).
std::string DumpInput(const SInput& in)
{
	std::string out;
	auto putI = [&](int v) { out.append(reinterpret_cast<const char*>(&v), sizeof(v)); };
	auto putF = [&](float v) { out.append(reinterpret_cast<const char*>(&v), sizeof(v)); };
	out.append("FLD2", 4);
	putI(in.mapWidth); putI(in.mapHeight); putI(in.heightStride); putI(in.heightRows); putI(in.slopeStride); putI(in.slopeRows);
	putI(in.waterHarmful ? 1 : 0);
	putI((int)in.boxes.size()); putI((int)in.geos.size()); putI((int)in.clusters.size());
	putI((int)in.height.size());
	for (float v : in.height) putF(v);
	putI((int)in.slope.size());
	for (float v : in.slope) putF(v);
	for (const SBoxInput& b : in.boxes) { putI(b.allyTeam); putF(b.left); putF(b.right); putF(b.top); putF(b.bottom); }
	for (const SPoint& p : in.geos) { putF(p.x); putF(p.z); }
	for (const SClusterInput& c : in.clusters) { putF(c.x); putF(c.z); putF(c.income); }
	putI((int)in.mapName.size());
	out += in.mapName;
	// FLD2: Part B1 inputs
	putF(in.minWind); putF(in.maxWind); putF(in.tidal);
	putI((int)in.teams.size());
	for (const STeamInput& t : in.teams) { putI(t.team); putI(t.allyTeam); putI(t.known ? 1 : 0); putF(t.x); putF(t.z); }
	return out;
}

} // namespace

CFieldService::CFieldService()
		: state(std::make_shared<SState>())
{
	state->service = this;
}

CFieldService::~CFieldService()
{
	Shutdown();
	state->service = nullptr;
}

void CFieldService::Shutdown()
{
	if (cancel != nullptr) cancel->store(true, std::memory_order_relaxed);
}

bool CFieldService::ReadSettings(CCircuitAI* circuit)
{
	const Json::Value* root = circuit->GetSetupManager()->GetScriptConfig();
	if (root == nullptr) return false;
	const Json::Value& f = (*root)["field"];
	if (!f.isObject()) return false;
	enabled = f.get("enabled", false).asBool();
	settings.cellSize = f.get("cell_size", settings.cellSize).asInt();
	settings.regionMinCells = f.get("region_min_cells", settings.regionMinCells).asInt();
	settings.waterMinCells = f.get("water_min_cells", settings.waterMinCells).asInt();
	settings.chokeFraction = f.get("choke_fraction", settings.chokeFraction).asFloat();
	settings.highGroundRise = f.get("high_ground_rise", settings.highGroundRise).asFloat();
	settings.beachDepth = f.get("beach_depth", settings.beachDepth).asFloat();
	settings.crossingMinLength = f.get("crossing_min_length", settings.crossingMinLength).asInt();
	settings.landingMerge = f.get("landing_merge", settings.landingMerge).asInt();
	settings.avenueDetour = f.get("avenue_detour", settings.avenueDetour).asFloat();
	settings.avenueMax = f.get("avenue_max", settings.avenueMax).asInt();
	settings.seaReach = f.get("sea_reach", settings.seaReach).asFloat();
	settings.pondMaxShare = f.get("pond_max_share", settings.pondMaxShare).asFloat();
	ReadMarkSettings(*root, settings.marks);
	publishFile = f.get("publish_file", true).asBool();
	dumpInput = f.get("dump_input", false).asBool();
	return enabled;
}

bool CFieldService::Capture(CCircuitAI* circuit, SInput& out) const
{
	CMap* map = circuit->GetMap();
	out.mapName = map->GetName();
	out.mapWidth = map->GetWidth() * SQUARE_SIZE;
	out.mapHeight = map->GetHeight() * SQUARE_SIZE;
	terrain::CTerrainData& td = gameAttribute->GetTerrainData();
	if (!td.IsInitialized()) return false;
	const terrain::SAreaData* area = td.pAreaData.load();
	out.height = area->heightMap;
	out.heightStride = std::max(1, area->heightMapXSize);
	out.heightRows = (int)(out.height.size() / out.heightStride);
	out.slope = td.GetSlopeMap();
	out.slopeStride = std::max(1, td.GetSlopeMapXSize());
	out.slopeRows = (int)(out.slope.size() / out.slopeStride);
	out.waterHarmful = td.waterIsHarmful;
	if (out.height.empty() || out.slope.empty()) return false;
	// start boxes: one per ally team; a box covering nearly the whole map is no box
	CSetupData& setup = gameAttribute->GetSetupData();
	const float mapArea = (float)out.mapWidth * (float)out.mapHeight;
	for (int i = 0; i < setup.GetAllyTeamCount(); ++i) {
		// boxes are keyed by ally team for the engine's start rectangles; a team
		// without one (or a non-BAR polygon set) is simply skipped
		const geom::CRegion* region = setup.GetStartBox(i);
		if (region == nullptr) continue;
		const geom::SBox& box = region->GetBox();
		const float area2 = std::max(0.f, box.right - box.left) * std::max(0.f, box.bottom - box.top);
		if (area2 <= 0.f || area2 >= 0.9f * mapArea) continue;
		SBoxInput b;
		b.allyTeam = i;
		b.left = box.left; b.right = box.right; b.top = box.top; b.bottom = box.bottom;
		out.boxes.push_back(b);
	}
	if (out.boxes.empty()) {
		// Fixed or chosen starts without boxes (the playtest harness, some lobbies):
		// a side is the padded bounding box of each ally team's start positions
		// from the start script (D-127 parsing). Only two groups are known here,
		// this AI's allies and its enemies, so with three or more ally teams the
		// enemies share one side.
		CSetupManager* setupMgr = circuit->GetSetupManager();
		const int own = circuit->GetAllyTeamId();
		int enemy = -1;
		for (int i = 0; i < setup.GetAllyTeamCount() && enemy < 0; ++i) if (i != own) enemy = i;
		constexpr float kPad = 512.f;
		SBoxInput ally, foe;
		ally.allyTeam = own; foe.allyTeam = enemy;
		bool anyAlly = false, anyFoe = false;
		for (int i = 0; i < setupMgr->GetScriptStartCount(); ++i) {
			const AIFloat3 pos = setupMgr->GetScriptStart(i);
			SBoxInput& b = setupMgr->IsScriptStartEnemy(i) ? foe : ally;
			bool& any = setupMgr->IsScriptStartEnemy(i) ? anyFoe : anyAlly;
			if (!any) { b.left = b.right = pos.x; b.top = b.bottom = pos.z; any = true; }
			b.left = std::min(b.left, pos.x); b.right = std::max(b.right, pos.x);
			b.top = std::min(b.top, pos.z); b.bottom = std::max(b.bottom, pos.z);
		}
		for (SBoxInput* b : {&ally, &foe}) {
			if (b == &ally ? !anyAlly : !anyFoe) continue;
			b->left = std::max(0.f, b->left - kPad); b->top = std::max(0.f, b->top - kPad);
			b->right = std::min((float)out.mapWidth, b->right + kPad); b->bottom = std::min((float)out.mapHeight, b->bottom + kPad);
			out.boxes.push_back(*b);
		}
		if (anyAlly && anyFoe) circuit->LOG("FIELD: no start boxes in the script; sides from the %i script start positions", setupMgr->GetScriptStartCount());
	}
	// Part B1: every playing team (not this AI's view), wind range and tidal strength
	for (const CSetupManager::SScriptTeam& t : circuit->GetSetupManager()->GetScriptTeams()) {
		STeamInput ti;
		ti.team = t.team; ti.allyTeam = t.allyTeam; ti.known = t.known; ti.x = t.pos.x; ti.z = t.pos.z;
		out.teams.push_back(ti);
	}
	out.minWind = map->GetMinWind();
	out.maxWind = map->GetMaxWind();
	out.tidal = map->GetTidalStrength();
	for (const AIFloat3& geo : gameAttribute->GetEnergyData().GetSpots()) out.geos.push_back({geo.x, geo.z});
	for (const CMetalData::SCluster& cl : gameAttribute->GetMetalData().GetClusters()) {
		out.clusters.push_back({cl.position.x, cl.position.z, cl.income});
	}
	return true;
}

void CFieldService::Start(CCircuitAI* circuit, CGameAttribute* ga)
{
	if (started) return;
	gameAttribute = ga;
	if (!ReadSettings(circuit)) return;   // this AI's profile does not enable the field; a later one may
	started = true;
	ownerTeam = circuit->GetTeamId();
	seq = 1;
	if (publishFile) {
		filePath = LocateWritable(circuit, "LuaUI/Config/BARb/field/map.txt");
		if (filePath.empty()) {
			circuit->LOG("FIELD: no writable path for the widget file; analysis runs without publishing");
			publishFile = false;
		} else {
			std::error_code ec;
			std::filesystem::remove(filePath, ec);   // a previous game's map must not be shown as this one
			marksPath = filePath.parent_path() / "landmarks.txt";
			std::filesystem::remove(marksPath, ec);
		}
	}
	Launch(circuit);
	circuit->GetScheduler()->RunOnRelease(CScheduler::GameJob(&CFieldService::DelegateAuthority, this, circuit));
}

void CFieldService::Launch(CCircuitAI* circuit)
{
	const auto begin = Clock::now();
	auto input = std::make_shared<SInput>();
	if (!Capture(circuit, *input)) {
		circuit->LOG("FIELD: input capture failed (terrain data not ready); the field is disabled this game");
		return;
	}
	captureMs = Ms(begin);
	if (dumpInput) {
		const std::filesystem::path dump = LocateWritable(circuit, "LuaUI/Config/BARb/field/input.bin");
		if (!dump.empty()) {
			std::string text = DumpInput(*input);
			circuit->GetScheduler()->RunBackgroundJob(CScheduler::WorkJob([dump, text = std::move(text)]() {
				widget_state::WriteFileAtomically(dump, text);
				return std::shared_ptr<IMainJob>();
			}));
		}
	}
	cancel = std::make_shared<std::atomic<bool>>(false);
	result = std::make_shared<SResult>();
	// The completion owns nothing of the AI: it locks the service's state block
	// (null once CGameAttribute is gone) and finds the AI through the circuits
	// the attribute still registers. The result's `done` flag is the handoff
	// for a delegated poll; the scheduler's finish queue is the normal one.
	std::weak_ptr<SState> weak = state;
	auto res = result;
	res->teams = (int)input->teams.size();
	auto complete = CScheduler::GameJob([weak, res]() {
		const auto s = weak.lock();
		if (!s || s->service == nullptr) return;
		CFieldService* self = s->service;
		if (self->result != res || self->model != nullptr) return;
		for (CCircuitAI* ai : self->gameAttribute->GetCircuits()) {
			if (ai->IsInitialized()) { self->Complete(ai); return; }
		}
	});
	auto cancelFlag = cancel;
	const SSettings st = settings;
	auto work = [input, st, res, cancelFlag, complete, queued = Clock::now()]() -> std::shared_ptr<IMainJob> {
		res->started.store(true, std::memory_order_release);
		res->queueMs = Ms(queued);
		const auto start = Clock::now();
		try {
			res->model = Analyse(*input, st, cancelFlag.get());
		} catch (...) {
			res->error = std::current_exception();   // includes cooperative cancellation
		}
		res->analyseMs = Ms(start);
		res->done.store(true, std::memory_order_release);
		return complete;
	};
	circuit->GetScheduler()->RunBackgroundJob(CScheduler::WorkJob(std::move(work)));
}

void CFieldService::Complete(CCircuitAI* circuit)
{
	if (result == nullptr || !result->done.load(std::memory_order_acquire) || model != nullptr) return;
	if (cancel != nullptr && cancel->load(std::memory_order_relaxed)) return;
	if (result->error) {
		try { std::rethrow_exception(result->error); }
		catch (const std::exception& e) { circuit->LOG("FIELD: worker failed: %s", e.what()); }
		catch (...) { circuit->LOG("FIELD: worker failed: unknown exception"); }
		result.reset();
		return;
	}
	model = result->model;
	summary = Summary(*model);
	for (const std::string& f : model->checkFailures) circuit->LOG("FIELD: check failed: %s", f.c_str());
	const STimings& t = model->timings;
	circuit->LOG("FIELD_PERF owner=%i team=%i cells=%i capture_ms=%.1f queue_ms=%.1f analyse_ms=%.1f grid=%.1f mobility=%.1f sides=%.1f theatres=%.1f regions=%.1f boundaries=%.1f landings=%.1f avenues=%.1f key=%.1f theatres=%i regions=%i boundaries=%i chokes=%i avenues=%i landings=%i fingerprint=%llu",
		ownerTeam, circuit->GetTeamId(), model->gw * model->gh, captureMs, result->queueMs, result->analyseMs,
		t.gridMs, t.mobilityMs, t.sidesMs, t.theatresMs, t.regionsMs, t.boundariesMs, t.landingsMs, t.avenuesMs, t.keyMs,
		(int)model->theatres.size(), (int)model->regions.size(), (int)model->boundaries.size(), (int)model->chokes.size(),
		(int)model->avenues.size(), (int)model->landings.size(), static_cast<unsigned long long>(model->fingerprint));
	circuit->LOG("[Field] summary: %s", summary.c_str());
	if (model->marksBuilt) {
		for (const std::string& f : model->marksFailures) circuit->LOG("MARKS: check failed: %s", f.c_str());
		circuit->LOG("MARKS_PERF owner=%i positions_ms=%.1f territory_ms=%.1f labels_ms=%.1f marks_ms=%.1f total_ms=%.1f teams=%i positions=%i marks=%i fingerprint=%llu",
			ownerTeam, t.positionsMs, t.territoryMs, t.labelsMs, t.marksMs, t.marksTotalMs, result->teams,
			(int)model->positions.size(), (int)model->marks.size(), static_cast<unsigned long long>(model->marksFingerprint));
		circuit->LOG("[Marks] summary: %s", MarksSummary(*model).c_str());
	}
	result.reset();
	if (publishFile && !published) Publish(circuit, circuit->GetLastFrame());
}

void CFieldService::Publish(CCircuitAI* circuit, int frame)
{
	if (model == nullptr || filePath.empty()) return;
	published = true;
	const auto begin = Clock::now();
	std::string text = Encode(*model, settings, seq, frame);
	const double encodeMs = Ms(begin);
	circuit->LOG("FIELD: publishing %s (%zu bytes, encode_ms=%.1f)", filePath.string().c_str(), text.size(), encodeMs);
	const std::filesystem::path path = filePath;
	// The job owns the text and the path only: no `this`, no engine calls.
	std::string marks;
	std::filesystem::path marksFile;
	if (model->marksBuilt && !marksPath.empty()) {
		const auto marksBegin = Clock::now();
		marks = EncodeMarks(*model, settings, seq, frame);
		marksFile = marksPath;
		circuit->LOG("MARKS: publishing %s (%zu bytes, encode_ms=%.1f)", marksPath.string().c_str(), marks.size(), Ms(marksBegin));
	}
	// One job writes both files in order, so landmarks.txt never precedes the
	// map.txt whose fingerprint it carries.
	circuit->GetScheduler()->RunBackgroundJob(CScheduler::WorkJob([path, text = std::move(text), marksFile, marks = std::move(marks)]() {
		widget_state::WriteFileAtomically(path, text);
		if (!marksFile.empty()) widget_state::WriteFileAtomically(marksFile, marks);
		return std::shared_ptr<IMainJob>();
	}));
}

void CFieldService::DelegateAuthority(CCircuitAI* leaving)
{
	if (model != nullptr || result == nullptr) return;   // nothing pending
	for (CCircuitAI* circuit : gameAttribute->GetCircuits()) {
		if (circuit->IsInitialized() && circuit != leaving) {
			if (!result->started.load(std::memory_order_acquire)) {
				// D-327: the leaving AI's scheduler drops its queued work with it, so a
				// job the worker has not picked up yet would never run and a poll would
				// wait all game. Capture again from the AI that takes over and relaunch.
				if (cancel) cancel->store(true, std::memory_order_relaxed);
				result.reset();
				circuit->LOG("FIELD: owner team %i left before the analysis started; this team relaunches it", leaving->GetTeamId());
				Launch(circuit);
				if (result != nullptr) {
					ownerTeam = circuit->GetTeamId();
					circuit->GetScheduler()->RunOnRelease(CScheduler::GameJob(&CFieldService::DelegateAuthority, this, circuit));
				}
				return;
			}
			ArmPoll(circuit);
			return;
		}
	}
	Shutdown();   // the last AI is leaving: the worker drops its result
}

void CFieldService::ArmPoll(CCircuitAI* circuit)
{
	// The owner's finish queue died with it; poll the result here instead.
	auto poll = std::make_shared<std::shared_ptr<IMainJob>>();
	std::weak_ptr<SState> weak = state;
	*poll = CScheduler::GameJob([weak, circuit, poll]() {
		const auto s = weak.lock();
		if (!s || s->service == nullptr) return;
		CFieldService* self = s->service;
		auto finish = [&]() {   // RemoveJob, then drop the self-reference so the job is freed
			circuit->GetScheduler()->RemoveJob(*poll);
			poll->reset();
		};
		if (self->result == nullptr || self->model != nullptr) { finish(); return; }
		if (self->result->done.load(std::memory_order_acquire)) {
			self->Complete(circuit);
			finish();
		}
	});
	circuit->GetScheduler()->RunJobEvery(*poll, POLL_FRAMES);
	circuit->GetScheduler()->RunOnRelease(CScheduler::GameJob(&CFieldService::DelegateAuthority, this, circuit));
}

} // namespace field
} // namespace circuit
