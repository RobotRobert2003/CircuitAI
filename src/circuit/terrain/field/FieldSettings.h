/*
 * FieldSettings.h
 *
 * Part B1: reads the landmark levers ("landmarks_enabled" and the
 * "positions", "labels", "openings" and "landmarks" blocks inside field.json
 * "field") into SMarkSettings. Shared by CFieldService and the native replay
 * (tests/field_analysis_test.cpp --config), so a lever is read one way only.
 * Engine-free; jsoncpp only.
 */

#ifndef SRC_CIRCUIT_TERRAIN_FIELD_FIELDSETTINGS_H_
#define SRC_CIRCUIT_TERRAIN_FIELD_FIELDSETTINGS_H_

#include "terrain/field/FieldTypes.h"

namespace Json { class Value; }

namespace circuit::field {

// `root` is the merged profile config (the object that holds "field").
// Absent keys keep the SMarkSettings defaults; factory ids and the "second"
// texts have no default in C++ (policy lives in JSON).
void ReadMarkSettings(const Json::Value& root, SMarkSettings& ms);

} // namespace circuit::field

#endif // SRC_CIRCUIT_TERRAIN_FIELD_FIELDSETTINGS_H_
