/*
 * WidgetState.h
 *
 * D-300: eventually consistent AI -> widget state file. Script publishes keyed
 * state and events (ai.SetWidgetState / ai.PushWidgetEvent); this class writes
 * <writeDir>/LuaUI/Config/BARb/state/team<N>.txt a short while after changes,
 * on a worker thread, and the host's widget polls it. See WidgetStateStore.h
 * for the coalescing rule and cost; the widget side is
 * tools/widgets/gui_barb_team_link.lua.
 *
 * Ownership: one per CCircuitAI, main thread only. The flush check is a
 * scheduler job every FLUSH_CHECK_FRAMES; a due write hands an owned string to
 * one worker at a time (newer snapshots replace a queued one, never pile up).
 * The worker touches only the shared SWriter (mutex) and the filesystem.
 */

#ifndef SRC_CIRCUIT_UTIL_WIDGETSTATE_H_
#define SRC_CIRCUIT_UTIL_WIDGETSTATE_H_

#include "util/WidgetStateStore.h"

#include <filesystem>
#include <memory>
#include <mutex>
#include <string>

namespace circuit {

class CCircuitAI;
class IMainJob;

class CWidgetState final {
public:
	explicit CWidgetState(CCircuitAI* circuit);
	~CWidgetState();
	CWidgetState(const CWidgetState&) = delete;
	CWidgetState& operator=(const CWidgetState&) = delete;

	// Resolve the file, delete the previous game's copy, schedule the checks.
	void Start();
	void Stop();

	void SetState(const std::string& key, const std::string& value);
	void PushEvent(const std::string& line);
	void SetTiming(int quietMs, int maxDelayMs) { store.SetTiming(quietMs, maxDelayMs); }

private:
	void Check();
	void Submit(std::string&& text);

	struct SWriter {
		std::mutex mutex;
		std::filesystem::path path;
		std::string queued;     // newest snapshot waiting for the worker
		bool hasQueued = false;
		bool busy = false;      // a worker job owns the file
		bool failed = false;    // last write failed: the owner re-marks dirty
	};

	CCircuitAI* circuit;
	widget_state::CStore store;
	std::shared_ptr<SWriter> writer;
	std::shared_ptr<IMainJob> checkJob;
	bool enabled = false;
};

} // namespace circuit

#endif // SRC_CIRCUIT_UTIL_WIDGETSTATE_H_
