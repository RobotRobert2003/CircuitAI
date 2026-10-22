// Pure state/ownership rules: time is in frames, distances are squared.
namespace SeaCoastMath {
    bool Lost(bool heldWater, bool foothold, int absentFrames, int confirmFrames) {
        return heldWater && !foothold && absentFrames >= confirmFrames;
    }
    bool Retaken(bool foothold, int heldFrames, int confirmFrames) {
        return foothold && heldFrames >= confirmFrames;
    }
    bool OwnBeach(float ownDistance, float allyDistance, int ownTeam, int allyTeam) {
        return ownDistance < allyDistance || (ownDistance == allyDistance && ownTeam < allyTeam);
    }
    bool TechFunded(float metalIncome, float energyIncome, float metalBank, float energyBank,
                    float metalCost, float energyCost, float minimumMetalIncome, float minimumEnergyIncome) {
        return (metalIncome >= minimumMetalIncome && energyIncome >= minimumEnergyIncome)
            || (metalBank >= metalCost && energyBank >= energyCost);
    }
}
