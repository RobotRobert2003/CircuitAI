/*
 * FieldAnalysis.h
 *
 * D-323: Analyse() turns the captured map input into the field model:
 * mobility per class, sides from the start boxes, theatres (land, sea, pond),
 * regions cut at chokes (a clearance watershed, the BWEM idea on our grid),
 * boundary runs classified as crossings or barriers from the slope map,
 * landings with their inland reach, standoff contours, avenues per class,
 * and key terrain. Engine-free; runs on a worker with an owned SInput and a
 * cancel flag that is tested between stages. Deterministic: the same input
 * gives the same model and fingerprint, whichever AI ran it.
 */

#ifndef SRC_CIRCUIT_TERRAIN_FIELD_FIELDANALYSIS_H_
#define SRC_CIRCUIT_TERRAIN_FIELD_FIELDANALYSIS_H_

#include "terrain/field/FieldTypes.h"

#include <atomic>
#include <memory>

namespace circuit::field {

// Throws Cancelled when `cancel` becomes true between stages.
std::shared_ptr<SModel> Analyse(const SInput& input, const SSettings& settings, const std::atomic<bool>* cancel);

// Degrees from the engine's slope value (1 - cos(angle)).
float SlopeDegrees(float oneMinusCos);
float SlopeValue(float degrees);

} // namespace circuit::field

#endif // SRC_CIRCUIT_TERRAIN_FIELD_FIELDANALYSIS_H_
