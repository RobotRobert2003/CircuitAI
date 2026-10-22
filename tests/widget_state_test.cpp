// D-300: the AI -> widget state store (src/circuit/util/WidgetStateStore.h).
// Coalescing, the hard max delay, unchanged-value suppression, the bounded
// event ring, record sanitising, the trailer, and the atomic file replace.
#include "circuit/util/WidgetStateStore.h"

#include <cassert>
#include <chrono>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>

using namespace circuit::widget_state;
using namespace std::chrono_literals;

static int Count(const std::string& text, const std::string& what)
{
	int n = 0;
	for (std::size_t at = text.find(what); at != std::string::npos; at = text.find(what, at + 1)) {
		++n;
	}
	return n;
}

int main()
{
	const Clock::time_point t0 = Clock::now();
	CStore store;
	store.SetTiming(500, 3000);
	assert(!store.IsDirty() && !store.IsDue(t0 + 10s));

	// Back-to-back changes coalesce: due only after 500 ms of quiet.
	assert(store.SetState("roster", "barb|roster|1|0|self|r", t0));
	assert(store.SetState("aggression", "barb|aggression|1|0|0|0", t0 + 200ms));
	assert(!store.IsDue(t0 + 600ms));
	assert(store.IsDue(t0 + 700ms));
	std::string text = store.Serialize(1, 0, 900);
	assert(!store.IsDirty());
	assert(text.rfind("barbstate|1|1|0|1|900\n", 0) == 0);
	assert(Count(text, "\ns|") == 2 && text.find("\nend|1\n") != std::string::npos);

	// An unchanged value is not a change: no write.
	assert(!store.SetState("roster", "barb|roster|1|0|self|r", t0 + 1s));
	assert(!store.IsDirty());

	// A steady stream of changes cannot postpone the write past maxDelay.
	const Clock::time_point t1 = t0 + 10s;
	for (int i = 0; i < 40; ++i) {
		store.SetState("layout", "plan" + std::to_string(i), t1 + std::chrono::milliseconds(100 * i));
		if (i * 100 < 3000) {
			assert(!store.IsDue(t1 + std::chrono::milliseconds(100 * i)));
		}
	}
	assert(store.IsDue(t1 + 3s));
	text = store.Serialize(1, 0, 1200);
	assert(text.find("s|layout|plan39\n") != std::string::npos);

	// Removing a key is a change; removing a missing key is not.
	assert(store.SetState("layout", "", t1 + 5s));
	assert(!store.SetState("layout", "", t1 + 5s));
	text = store.Serialize(1, 0, 1300);
	assert(text.find("layout") == std::string::npos);

	// Events: increasing ids, the ring keeps the latest kMaxEvents.
	for (int i = 0; i < 70; ++i) {
		store.PushEvent("barb|ferry|1|0|req|" + std::to_string(i), t1 + 6s);
	}
	text = store.Serialize(1, 0, 1400);
	assert(Count(text, "\ne|") == static_cast<int>(kMaxEvents));
	assert(text.find("\ne|7|") != std::string::npos && text.find("\ne|6|") == std::string::npos);
	assert(text.find("\ne|70|barb|ferry|1|0|req|69\n") != std::string::npos);

	// A value cannot forge a record line.
	store.SetState("roster", "a\nend|999\ns|x|y", t1 + 7s);
	text = store.Serialize(1, 0, 1500);
	assert(text.find("\nend|999") == std::string::npos && text.find("\ns|x|y") == std::string::npos);

	// The file is replaced whole, also when it already exists.
	const std::filesystem::path dir = std::filesystem::temp_directory_path() / "circuit_widget_state_test";
	std::filesystem::remove_all(dir);
	const std::filesystem::path file = dir / "LuaUI" / "Config" / "BARb" / "state" / "team1.txt";
	assert(WriteFileAtomically(file, "first\n"));
	assert(WriteFileAtomically(file, text));
	std::ifstream in(file, std::ios::binary);
	std::stringstream read;
	read << in.rdbuf();
	in.close();
	assert(read.str() == text);
	assert(!std::filesystem::exists(file.string() + ".tmp"));
	std::filesystem::remove_all(dir);

	std::puts("widget_state_test: OK");
	return 0;
}
