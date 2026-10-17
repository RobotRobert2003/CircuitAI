/*
 * FieldEncode.h
 *
 * D-323: the widget file (LuaUI/Config/BARb/field/map.txt) and the one-line
 * summary. Grammar: section 6.4 of
 * rjm.bar.docs/projects/circuitai/battlefield-analysis-implementation.md;
 * the reader is the `field` module of tools/widgets/gui_barb_team_link.lua.
 * Engine-free; runs on the worker that produced the model.
 */

#ifndef SRC_CIRCUIT_TERRAIN_FIELD_FIELDENCODE_H_
#define SRC_CIRCUIT_TERRAIN_FIELD_FIELDENCODE_H_

#include "terrain/field/FieldTypes.h"

#include <cstdint>
#include <string>

namespace circuit::field {

constexpr int kFileFormat = 1;

std::string Encode(const SModel& model, const SSettings& settings, std::uint64_t seq, int frame);
std::string Summary(const SModel& model);

// Header fields of an encoded file, for tests and the service log.
struct SHeader {
	int format = 0, gw = 0, gh = 0, cell = 0, frame = 0;
	std::uint64_t seq = 0, fingerprint = 0;
	std::string mapName;
	bool complete = false;   // the end|<seq> trailer matched
};
bool ParseHeader(const std::string& text, SHeader& out);

} // namespace circuit::field

#endif // SRC_CIRCUIT_TERRAIN_FIELD_FIELDENCODE_H_
