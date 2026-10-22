// Pure recovery admission rules: no engine callbacks, scans or unit orders.
namespace RecoveryMath {
    // Named policy/geometry constants preserve the original arithmetic and types.
    // Zero/One are integer identities; ZeroValue/UnitValue are float identities.
    const int Zero = 0;

    bool NeedsRequest(int constructors, bool hadConstructor, bool commanderAlive,
                      bool commanderCounts, int currentFrame, int openingGraceFrames) {
        if (constructors > Zero || (commanderCounts && commanderAlive)) return false;
        return hadConstructor || (!commanderAlive && currentFrame >= openingGraceFrames);
    }
    bool Due(int currentFrame, int previous, int intervalFrames) {
        return previous < Zero || currentFrame - previous >= intervalFrames;
    }
    bool AcceptEpisode(int token, int lastCancelled) {
        return token >= Zero && token > lastCancelled;
    }
}
