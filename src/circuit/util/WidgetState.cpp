/*
 * WidgetState.cpp
 *
 * D-300: see WidgetState.h and WidgetStateStore.h.
 */

#include "util/WidgetState.h"
#include "CircuitAI.h"
#include "scheduler/Scheduler.h"
#include "spring/SpringCallback.h"
#include "util/Utils.h"

#include "DataDirs.h"
#include "Log.h"
#include "Roots.h"

#include <system_error>
#include <utility>

namespace circuit {

using namespace springai;

// The check is a bool test and a clock read; at speed 20 six frames are 10 ms
// of wall time, so the wall-clock quiet/max delays decide the write rate.
static constexpr int FLUSH_CHECK_FRAMES = FRAMES_PER_SEC / 5;

CWidgetState::CWidgetState(CCircuitAI* circuit)
		: circuit(circuit)
		, writer(std::make_shared<SWriter>())
{
}

CWidgetState::~CWidgetState()
{
	Stop();
}

void CWidgetState::Start()
{
	if (enabled) {
		return;
	}
	// Root-relative so the widget can read it without knowing the AI's short
	// name or version: VFS.LoadFile("LuaUI/Config/BARb/state/team<N>.txt", VFS.RAW).
	const std::string relPath = "LuaUI/Config/BARb/state/team" + std::to_string(circuit->GetTeamId()) + ".txt";
	DataDirs* dataDirs = circuit->GetCallback()->GetDataDirs();
	Roots* roots = dataDirs->GetRoots();
	static constexpr int absPath_sizeMax = 2048;
	char absPath[absPath_sizeMax] = {'\0'};
	const bool located = roots->LocatePath(absPath, absPath_sizeMax, relPath.c_str(), true /*writeable*/, true /*create*/, false /*dir*/);
	delete roots;
	delete dataDirs;
	if (!located || absPath[0] == '\0') {
		circuit->LOG("[WidgetState] no writable path for %s: widget state disabled", relPath.c_str());
		return;
	}
	{
		std::lock_guard<std::mutex> lock(writer->mutex);
		writer->path = std::filesystem::path(absPath);
	}
	// A previous game's file must not be shown as this game's state.
	std::error_code ec;
	std::filesystem::remove(writer->path, ec);

	enabled = true;
	checkJob = CScheduler::GameJob(&CWidgetState::Check, this);
	circuit->GetScheduler()->RunJobEvery(checkJob, FLUSH_CHECK_FRAMES, circuit->GetSkirmishAIId() % FLUSH_CHECK_FRAMES);
}

void CWidgetState::Stop()
{
	if (!enabled) {
		return;
	}
	enabled = false;
	const std::shared_ptr<CScheduler>& scheduler = circuit->GetScheduler();
	if (scheduler != nullptr && checkJob != nullptr) {
		scheduler->RemoveJob(checkJob);
	}
	checkJob = nullptr;
}

void CWidgetState::SetState(const std::string& key, const std::string& value)
{
	if (enabled) {
		store.SetState(key, value, widget_state::Clock::now());
	}
}

void CWidgetState::PushEvent(const std::string& line)
{
	if (enabled) {
		store.PushEvent(line, widget_state::Clock::now());
	}
}

void CWidgetState::Check()
{
	const widget_state::Clock::time_point now = widget_state::Clock::now();
	{
		std::lock_guard<std::mutex> lock(writer->mutex);
		if (writer->failed) {
			writer->failed = false;
			store.MarkDirty(now);  // retry the failed write on a later check
		}
	}
	if (!store.IsDue(now)) {
		return;
	}
	Submit(store.Serialize(circuit->GetTeamId(), circuit->GetAllyTeamId(), circuit->GetLastFrame()));
}

void CWidgetState::Submit(std::string&& text)
{
	bool start = false;
	{
		std::lock_guard<std::mutex> lock(writer->mutex);
		writer->queued = std::move(text);  // a newer snapshot replaces a queued one
		writer->hasQueued = true;
		if (!writer->busy) {
			writer->busy = true;
			start = true;
		}
	}
	if (!start) {
		return;
	}
	// The job owns a reference to the writer only: no `this`, no engine calls.
	std::shared_ptr<SWriter> w = writer;
	circuit->GetScheduler()->RunBackgroundJob(CScheduler::WorkJob([w]() {
		for (;;) {
			std::string text;
			std::filesystem::path path;
			{
				std::lock_guard<std::mutex> lock(w->mutex);
				if (!w->hasQueued) {
					w->busy = false;
					break;
				}
				text.swap(w->queued);
				w->hasQueued = false;
				path = w->path;
			}
			const bool ok = widget_state::WriteFileAtomically(path, text);
			std::lock_guard<std::mutex> lock(w->mutex);
			w->failed = !ok && !w->hasQueued;
		}
		return std::shared_ptr<IMainJob>();
	}));
}

} // namespace circuit
