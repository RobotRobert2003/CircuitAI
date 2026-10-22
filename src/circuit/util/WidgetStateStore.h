/*
 * WidgetStateStore.h
 *
 * D-300: engine-free core of the AI -> widget state file. BAR's user-widget
 * sandbox (BAR PRs #9547/#9658/#9660) left no way for a user widget to receive
 * RecvSkirmishAIMessage, so the AI publishes its widget-facing state as a small
 * file in the write directory and the widget polls it (eventually consistent).
 *
 * The store keeps the latest value per key and a bounded ring of recent events.
 * A change marks it dirty; a write becomes due once changes have been quiet for
 * `quiet` or `maxDelay` after the first unwritten change, whichever is sooner, so
 * back-to-back changes coalesce into one write and a stream of changes cannot
 * postpone it forever. Times are wall clock (std::chrono::steady_clock): the
 * reader is a person, and game-frame delays would shrink 20x at speed 20.
 *
 * Cost: SetState is O(log K + |value|) (map lookup + equality test that skips
 * unchanged values); PushEvent is O(|line|) amortised; Serialize is O(total
 * bytes) and runs only when a write is due. K (keys) is a handful per AI,
 * events are capped at kMaxEvents. No engine callbacks; owned by one CCircuitAI
 * and used on its main thread only. WriteFileAtomically runs on a worker with
 * an owned copy of the text. Tests: tests/widget_state_test.cpp.
 */

#ifndef SRC_CIRCUIT_UTIL_WIDGETSTATESTORE_H_
#define SRC_CIRCUIT_UTIL_WIDGETSTATESTORE_H_

#include <chrono>
#include <cstdint>
#include <deque>
#include <filesystem>
#include <fstream>
#include <map>
#include <string>
#include <system_error>
#include <utility>

namespace circuit {
namespace widget_state {

using Clock = std::chrono::steady_clock;

// File format version; bump when the line grammar changes (the widget checks it).
constexpr int kFormat = 1;
constexpr std::size_t kMaxEvents = 64;
// A layout snapshot is the largest value (tens of KB); refuse anything absurd.
constexpr std::size_t kMaxValueBytes = 512 * 1024;

// One line per record: strip the record separators so a value cannot forge lines.
inline std::string Sanitize(const std::string& s)
{
	std::string out(s.size() < kMaxValueBytes ? s : s.substr(0, kMaxValueBytes));
	for (char& c : out) {
		if (c == '\n' || c == '\r') {
			c = ' ';
		}
	}
	return out;
}

class CStore final {
public:
	void SetTiming(int quietMs, int maxDelayMs) {
		quiet = std::chrono::milliseconds(quietMs < 0 ? 0 : quietMs);
		maxDelay = std::chrono::milliseconds(maxDelayMs < quietMs ? quietMs : maxDelayMs);
	}

	// Empty value removes the key. Returns true when the stored state changed.
	bool SetState(const std::string& key, const std::string& value, Clock::time_point now) {
		if (key.empty()) {
			return false;
		}
		const std::string k = Sanitize(key);
		if (value.empty()) {
			if (states.erase(k) == 0) {
				return false;
			}
		} else {
			std::string v = Sanitize(value);
			auto it = states.find(k);
			if (it != states.end()) {
				if (it->second == v) {
					return false;  // unchanged: no write
				}
				it->second = std::move(v);
			} else {
				states.emplace(k, std::move(v));
			}
		}
		Touch(now);
		return true;
	}

	void PushEvent(const std::string& line, Clock::time_point now) {
		events.emplace_back(nextEventId++, Sanitize(line));
		while (events.size() > kMaxEvents) {
			events.pop_front();
		}
		Touch(now);
	}

	// A failed write leaves the file stale: write again once due.
	void MarkDirty(Clock::time_point now) { Touch(now); }

	bool IsDirty() const { return dirty; }
	bool IsDue(Clock::time_point now) const {
		return dirty && ((now - lastChange >= quiet) || (now - firstChange >= maxDelay));
	}

	// Snapshot for the widget; clears dirty. The last line repeats the sequence
	// so a reader can reject a torn file even if the rename was not atomic.
	std::string Serialize(int teamId, int allyTeamId, int frame) {
		++sequence;
		dirty = false;
		std::string out;
		std::size_t bytes = 64;
		for (const auto& kv : states) bytes += kv.first.size() + kv.second.size() + 4;
		for (const auto& e : events) bytes += e.second.size() + 16;
		out.reserve(bytes);
		out += "barbstate|" + std::to_string(kFormat) + "|" + std::to_string(teamId) + "|"
				+ std::to_string(allyTeamId) + "|" + std::to_string(sequence) + "|" + std::to_string(frame) + "\n";
		for (const auto& kv : states) {
			out += "s|" + kv.first + "|" + kv.second + "\n";
		}
		for (const auto& e : events) {
			out += "e|" + std::to_string(e.first) + "|" + e.second + "\n";
		}
		out += "end|" + std::to_string(sequence) + "\n";
		return out;
	}

	std::uint64_t GetSequence() const { return sequence; }

private:
	void Touch(Clock::time_point now) {
		if (!dirty) {
			firstChange = now;
			dirty = true;
		}
		lastChange = now;
	}

	std::map<std::string, std::string> states;  // ordered: deterministic output
	std::deque<std::pair<std::uint64_t, std::string>> events;
	std::uint64_t nextEventId = 1;
	std::uint64_t sequence = 0;
	bool dirty = false;
	Clock::time_point firstChange{}, lastChange{};
	std::chrono::milliseconds quiet{500}, maxDelay{3000};
};

// Write `text` to `path` through a temporary file and a rename, so a reader
// sees the old or the new file. On Windows a rename onto a file the reader has
// open can fail: return false and let the caller retry on its next flush.
// Never throws.
inline bool WriteFileAtomically(const std::filesystem::path& path, const std::string& text)
{
	std::error_code ec;
	std::filesystem::create_directories(path.parent_path(), ec);
	std::filesystem::path tmp = path;
	tmp += ".tmp";
	{
		std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
		if (!out) {
			return false;
		}
		out.write(text.data(), static_cast<std::streamsize>(text.size()));
		if (!out) {
			return false;
		}
	}
	std::filesystem::rename(tmp, path, ec);
	if (ec) {
		// Not every runtime replaces an existing target; the trailer guards the
		// short gap in which the file is missing.
		std::filesystem::remove(path, ec);
		std::filesystem::rename(tmp, path, ec);
	}
	return !ec;
}

} // namespace widget_state
} // namespace circuit

#endif // SRC_CIRCUIT_UTIL_WIDGETSTATESTORE_H_
