/*
 * FieldLandmarks.h
 *
 * Part B1 of the field (rjm.bar.docs/projects/circuitai/field-landmarks-proposal.md):
 * after the Part A stages, the same worker job derives one position per
 * playing team (from the start script, otherwise predicted from the start
 * boxes), each position's territory and features, the game's job word for it
 * (front, sea, pond, geo, air, tech ...), its opening factory class and
 * energy opener, and the generic strategic landmarks of both sides. Every
 * threshold, count and factory id is a field.json lever (SMarkSettings).
 * Engine-free; reads the Part A scratch grids through SFieldView and writes
 * only the Part B1 members of SModel. Deterministic: ties break by index.
 */

#ifndef SRC_CIRCUIT_TERRAIN_FIELD_FIELDLANDMARKS_H_
#define SRC_CIRCUIT_TERRAIN_FIELD_FIELDLANDMARKS_H_

#include "terrain/field/FieldGrid.h"
#include "terrain/field/FieldTypes.h"

#include <atomic>
#include <vector>

namespace circuit::field {

// Borrowed, read-only views of the Part A grids; valid for the call only.
struct SFieldView {
	const SGridShape& g;
	int cell;
	const std::vector<float>& hMean;
	const std::vector<unsigned char>* mob;          // [_CLASSES_] mobility per cell
	const std::vector<int>& theatreOf;
	const std::vector<int>& sideOf;
	const std::vector<int>& regionOf;
	const std::vector<std::vector<float>>& boxDist; // per side, travel cost in cells
	const std::vector<std::vector<int>>& sideSeeds; // per side, box cells
	const std::vector<int>& waterClr;               // chamfer thirds to non-water
	const std::vector<float>& regionRise;
};

// Throws Cancelled when `cancel` becomes true between stages.
void BuildMarks(const SInput& in, const SSettings& st, const SFieldView& v, const std::atomic<bool>* cancel, SModel& m);

const char* OpeningName(int opening);
const char* LabelName(int label);
const char* SubLabelName(int sub);
const char* EnergyName(int energy);
const char* MarkGroupName(int group);
const char* MarkKindName(int kind);

} // namespace circuit::field

#endif // SRC_CIRCUIT_TERRAIN_FIELD_FIELDLANDMARKS_H_
