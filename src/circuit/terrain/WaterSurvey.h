#ifndef CIRCUIT_WATER_SURVEY_H
#define CIRCUIT_WATER_SURVEY_H

namespace circuit::survey {
// Negative means never observed. Requiring both layers in the same sample
// prevents old surface vision plus unrelated sonar from proving empty water.
inline int Observe(int previous, int frame, bool surface, bool underwater) {
    return surface && underwater ? frame : previous;
}
inline bool Fresh(int observed, int frame, int lifetime) {
    return observed >= 0 && lifetime >= 0 && frame >= observed && frame - observed <= lifetime;
}
} // namespace circuit::survey
#endif
