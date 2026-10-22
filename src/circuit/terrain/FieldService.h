/*
 * FieldService.h
 *
 * D-323: the battlefield map analysis, computed once per process and shared
 * by every AI. Owned by CGameAttribute (one per game, like CTerrainData).
 *
 * Start(circuit) is called by every AI's Init; the first AI whose profile
 * enables the field (field.json "enabled") becomes the owner: it captures the
 * input on the main thread (height and slope maps CTerrainData already holds,
 * start boxes, metal clusters, geothermal spots), runs ONE worker job
 * (field::Analyse) under the D-127 lane-job contract (the work lambda owns an
 * immutable snapshot and a cancel flag, never `this` or the engine; the
 * completion runs on the main thread behind a weak state pointer and a job
 * gate), publishes the immutable model, and writes the widget file
 * <writeDir>/LuaUI/Config/BARb/field/map.txt once through the D-300 atomic
 * writer on another worker. Later AIs find it started and pay one branch.
 *
 * If the owner is released before the job finishes, DelegateAuthority (the
 * CTerrainData pattern) moves the completion poll to another initialised AI;
 * the last AI leaving sets the cancel flag. Nothing is saved: a loaded game
 * recomputes from the map.
 *
 * No manager, task or script role reads the model in Part A
 * (tools/knowledge/check_field_isolation.py); the widget reads the file.
 */

#ifndef SRC_CIRCUIT_TERRAIN_FIELDSERVICE_H_
#define SRC_CIRCUIT_TERRAIN_FIELDSERVICE_H_

#include "terrain/field/FieldTypes.h"

#include <atomic>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <string>

namespace circuit {

class CCircuitAI;
class CGameAttribute;

namespace field {

class CFieldService final {
public:
	CFieldService();
	~CFieldService();
	CFieldService(const CFieldService&) = delete;
	CFieldService& operator=(const CFieldService&) = delete;

	// Starts the one analysis if this AI's config enables it and none has
	// started yet; otherwise returns at once. Main thread, during Init.
	void Start(CCircuitAI* circuit, CGameAttribute* gameAttribute);
	// Called by the last AI's teardown (CGameAttribute destructor): cancel a
	// running job; the worker drops its result.
	void Shutdown();

	bool IsStarted() const { return started; }
	bool IsReady() const { return model != nullptr; }
	std::shared_ptr<const SModel> GetModel() const { return model; }
	const SSettings& GetSettings() const { return settings; }
	const std::string& GetSummary() const { return summary; }
	int GetOwnerTeam() const { return ownerTeam; }

private:
	struct SResult {
		std::shared_ptr<SModel> model;
		std::exception_ptr error;
		double queueMs = 0, analyseMs = 0;
		int teams = 0;                      // playing teams in the input (Part B1 log)
		std::atomic<bool> started{false};   // the worker picked the job up (D-327: a queued job dies with its owner's scheduler)
		std::atomic<bool> done{false};
	};
	// The completion's target: outlives any owner AI (it is held by this
	// service inside CGameAttribute) and is reached only through a weak_ptr.
	struct SState {
		CFieldService* service = nullptr;
	};

	bool ReadSettings(CCircuitAI* circuit);
	bool Capture(CCircuitAI* circuit, SInput& out) const;
	void Launch(CCircuitAI* circuit);
	void Complete(CCircuitAI* circuit);
	void Publish(CCircuitAI* circuit, int frame);
	void DelegateAuthority(CCircuitAI* leaving);
	void ArmPoll(CCircuitAI* circuit);

	CGameAttribute* gameAttribute = nullptr;
	bool started = false, enabled = false, publishFile = true, dumpInput = false;
	int ownerTeam = -1;
	SSettings settings;
	std::shared_ptr<SState> state;
	std::shared_ptr<SResult> result;
	std::shared_ptr<std::atomic<bool>> cancel;
	std::shared_ptr<const SModel> model;
	std::string summary;
	std::filesystem::path filePath;
	std::filesystem::path marksPath;      // Part B1: landmarks.txt beside map.txt
	std::uint64_t seq = 0;
	double captureMs = 0;
	bool published = false;
};

} // namespace field
} // namespace circuit

#endif // SRC_CIRCUIT_TERRAIN_FIELDSERVICE_H_
