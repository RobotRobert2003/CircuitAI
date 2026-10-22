// Factory configurations for VEHICLE factories (T1/T2 for all factions)
// Each factory exposes all combat roles; response weights + tactical scoring pick roles.
// NOTE: This file is included by factory_production.as - do NOT include it back.

namespace VehicleConfigs {

    void RegisterVehicleFactories() {
        GenericHelpers::LogUtil("[FactoryProduction] RegisterVehicleFactories: Starting registration", 3);

        // Armada T1 Vehicle Plant (armvp)
        {
            FactoryProduction::FactoryConfig@ cfg = FactoryProduction::FactoryConfig("armvp");
            cfg.AddRole("builder",   array<string> = {"armcv"});
            cfg.AddRole("scout",     array<string> = {"armfav"});
            cfg.AddRole("raider",    array<string> = {"armflash"});
            cfg.AddRole("riot",      array<string> = {"armpincer"});
            cfg.AddRole("skirmish",  array<string> = {"armstump"});
            cfg.AddRole("assault",   array<string> = {});
            cfg.AddRole("artillery", array<string> = {"armart"});
            cfg.AddRole("anti_air",  array<string> = {"armsam"});
            cfg.AddRole("support",   array<string> = {});
            cfg.AddRole("heavy",     array<string> = {"armjanus"});

            cfg.SetTierProbabilities(0, array<float> = {0.14f, 0.16f, 0.30f, 0.06f, 0.08f, 0.05f, 0.05f, 0.06f, 0.06f, 0.04f});
            cfg.SetTierProbabilities(1, array<float> = {0.10f, 0.12f, 0.26f, 0.07f, 0.10f, 0.07f, 0.08f, 0.08f, 0.07f, 0.05f});
            cfg.SetTierProbabilities(2, array<float> = {0.08f, 0.10f, 0.22f, 0.07f, 0.12f, 0.09f, 0.10f, 0.08f, 0.08f, 0.06f});
            cfg.SetTierProbabilities(3, array<float> = {0.06f, 0.08f, 0.18f, 0.06f, 0.15f, 0.10f, 0.12f, 0.08f, 0.09f, 0.08f});

            FactoryProduction::factoryConfigs.set("armvp", @cfg);
            GenericHelpers::LogUtil("[FactoryProduction] RegisterVehicleFactories: armvp registered", 3);
        }

        // Cortex T1 Vehicle Plant (corvp)
        {
            FactoryProduction::FactoryConfig@ cfg = FactoryProduction::FactoryConfig("corvp");
            cfg.AddRole("builder",   array<string> = {"corcv"});
            cfg.AddRole("scout",     array<string> = {"corfav"});
            cfg.AddRole("raider",    array<string> = {"corgator"});
            cfg.AddRole("riot",      array<string> = {"corgarp"});
            cfg.AddRole("skirmish",  array<string> = {"corlevlr"});
            cfg.AddRole("assault",   array<string> = {"corraid"});
            cfg.AddRole("artillery", array<string> = {"corwolv"});
            cfg.AddRole("anti_air",  array<string> = {"cormist"});
            cfg.AddRole("support",   array<string> = {});
            cfg.AddRole("heavy",     array<string> = {});

            cfg.SetTierProbabilities(0, array<float> = {0.14f, 0.16f, 0.30f, 0.05f, 0.08f, 0.08f, 0.05f, 0.06f, 0.05f, 0.03f});
            cfg.SetTierProbabilities(1, array<float> = {0.10f, 0.12f, 0.26f, 0.06f, 0.10f, 0.10f, 0.07f, 0.08f, 0.07f, 0.04f});
            cfg.SetTierProbabilities(2, array<float> = {0.08f, 0.10f, 0.22f, 0.06f, 0.12f, 0.12f, 0.08f, 0.08f, 0.08f, 0.06f});
            cfg.SetTierProbabilities(3, array<float> = {0.06f, 0.08f, 0.18f, 0.06f, 0.14f, 0.14f, 0.10f, 0.08f, 0.08f, 0.08f});

            FactoryProduction::factoryConfigs.set("corvp", @cfg);
            GenericHelpers::LogUtil("[FactoryProduction] RegisterVehicleFactories: corvp registered", 3);
        }

        // Armada T2 Vehicle Plant (armavp)
        {
            FactoryProduction::FactoryConfig@ cfg = FactoryProduction::FactoryConfig("armavp");
            cfg.AddRole("builder",   array<string> = {"armacv"});
            cfg.AddRole("scout",     array<string> = {"armseer"});
            cfg.AddRole("raider",    array<string> = {"armlatnk"});
            cfg.AddRole("riot",      array<string> = {"armbull"});
            cfg.AddRole("skirmish",  array<string> = {"armmart"});
            cfg.AddRole("assault",   array<string> = {"armmanni"});
            cfg.AddRole("artillery", array<string> = {"armmerl"});
            cfg.AddRole("anti_air",  array<string> = {"armyork"});
            cfg.AddRole("support",   array<string> = {"armgremlin"});
            cfg.AddRole("heavy",     array<string> = {});

            cfg.SetTierProbabilities(0, array<float> = {0.18f, 0.10f, 0.18f, 0.10f, 0.10f, 0.10f, 0.08f, 0.08f, 0.06f, 0.02f});
            cfg.SetTierProbabilities(1, array<float> = {0.14f, 0.08f, 0.18f, 0.10f, 0.10f, 0.14f, 0.08f, 0.08f, 0.06f, 0.04f});

            FactoryProduction::factoryConfigs.set("armavp", @cfg);
            GenericHelpers::LogUtil("[FactoryProduction] RegisterVehicleFactories: armavp registered", 3);
        }

        // Cortex T2 Vehicle Plant (coravp)
        {
            FactoryProduction::FactoryConfig@ cfg = FactoryProduction::FactoryConfig("coravp");
            cfg.AddRole("builder",   array<string> = {"coracv"});
            cfg.AddRole("scout",     array<string> = {"corvrad"});
            cfg.AddRole("raider",    array<string> = {"correap"});
            cfg.AddRole("riot",      array<string> = {"corgol"});
            cfg.AddRole("skirmish",  array<string> = {"cormart"});
            cfg.AddRole("assault",   array<string> = {"corsent"});
            cfg.AddRole("artillery", array<string> = {"corvroc", "cortrem"});
            cfg.AddRole("anti_air",  array<string> = {});
            cfg.AddRole("support",   array<string> = {});
            cfg.AddRole("heavy",     array<string> = {"corban"});

            cfg.SetTierProbabilities(0, array<float> = {0.18f, 0.10f, 0.18f, 0.10f, 0.10f, 0.10f, 0.08f, 0.04f, 0.04f, 0.08f});
            cfg.SetTierProbabilities(1, array<float> = {0.14f, 0.08f, 0.18f, 0.10f, 0.10f, 0.12f, 0.08f, 0.04f, 0.04f, 0.08f});

            FactoryProduction::factoryConfigs.set("coravp", @cfg);
            GenericHelpers::LogUtil("[FactoryProduction] RegisterVehicleFactories: coravp registered", 3);
        }

        // Legion T1 Vehicle Plant (legvp)
        {
            FactoryProduction::FactoryConfig@ cfg = FactoryProduction::FactoryConfig("legvp");
            cfg.AddRole("builder",   array<string> = {"legcv"});
            cfg.AddRole("scout",     array<string> = {"legscout"});
            cfg.AddRole("raider",    array<string> = {"leghades"});
            cfg.AddRole("riot",      array<string> = {"leghelios"});
            cfg.AddRole("skirmish",  array<string> = {"leggat"});
            cfg.AddRole("assault",   array<string> = {"legbar"});
            cfg.AddRole("artillery", array<string> = {"legrail"});
            cfg.AddRole("anti_air",  array<string> = {});
            cfg.AddRole("support",   array<string> = {"legmlv", "legotter"});
            cfg.AddRole("heavy",     array<string> = {"legamphtank"});

            // Map JSON land tier probabilities to role-order used above:
            // [builder, scout, raider, riot, skirmish, assault, artillery, anti_air, support, heavy]
            cfg.SetTierProbabilities(0, array<float> = {0.05f, 0.65f, 0.30f, 0.00f, 0.00f, 0.00f, 0.00f, 0.00f, 0.00f, 0.00f});
            cfg.SetTierProbabilities(1, array<float> = {0.05f, 0.50f, 0.45f, 0.00f, 0.00f, 0.00f, 0.00f, 0.00f, 0.00f, 0.00f});
            cfg.SetTierProbabilities(2, array<float> = {0.05f, 0.10f, 0.60f, 0.25f, 0.00f, 0.00f, 0.00f, 0.00f, 0.00f, 0.00f});
            cfg.SetTierProbabilities(3, array<float> = {0.05f, 0.00f, 0.30f, 0.40f, 0.25f, 0.00f, 0.00f, 0.00f, 0.00f, 0.00f});
            cfg.SetTierProbabilities(4, array<float> = {0.05f, 0.00f, 0.10f, 0.30f, 0.55f, 0.00f, 0.00f, 0.00f, 0.00f, 0.00f});
            cfg.SetTierProbabilities(5, array<float> = {0.05f, 0.00f, 0.00f, 0.00f, 0.60f, 0.00f, 0.35f, 0.00f, 0.00f, 0.00f});

            FactoryProduction::factoryConfigs.set("legvp", @cfg);
            GenericHelpers::LogUtil("[FactoryProduction] RegisterVehicleFactories: legvp registered", 3);
        }

        // Legion T2 Vehicle Plant (legavp)
        {
            FactoryProduction::FactoryConfig@ cfg = FactoryProduction::FactoryConfig("legavp");
            cfg.AddRole("builder",   array<string> = {"legacv", "legafcv"});
            cfg.AddRole("scout",     array<string> = {"legavrad"});
            cfg.AddRole("raider",    array<string> = {});
            cfg.AddRole("riot",      array<string> = {"legmrv"});
            cfg.AddRole("skirmish",  array<string> = {"legaskirmtank"});
            cfg.AddRole("assault",   array<string> = {"legmed"});
            cfg.AddRole("artillery", array<string> = {"legavroc", "legamcluster"});
            cfg.AddRole("anti_air",  array<string> = {"legvflak"});
            cfg.AddRole("support",   array<string> = {"legavjam", "legvcarry", "legfloat"});
            cfg.AddRole("heavy",     array<string> = {"leginf", "legaheattank"});

            // Weights normalized approx to 1.0 based on factory_leg.json
            // Tier 0 (Early T2)
            cfg.SetTierProbabilities(0, array<float> = {0.30f, 0.01f, 0.00f, 0.24f, 0.33f, 0.00f, 0.07f, 0.04f, 0.01f, 0.00f});
            // Tier 1
            cfg.SetTierProbabilities(1, array<float> = {0.33f, 0.01f, 0.00f, 0.00f, 0.45f, 0.00f, 0.16f, 0.04f, 0.01f, 0.00f});
            // Tier 2
            cfg.SetTierProbabilities(2, array<float> = {0.30f, 0.01f, 0.00f, 0.00f, 0.35f, 0.00f, 0.30f, 0.04f, 0.01f, 0.00f});
            // Tier 3
            cfg.SetTierProbabilities(3, array<float> = {0.30f, 0.01f, 0.00f, 0.00f, 0.20f, 0.07f, 0.19f, 0.04f, 0.08f, 0.11f});
            // Tier 4
            cfg.SetTierProbabilities(4, array<float> = {0.31f, 0.01f, 0.00f, 0.00f, 0.00f, 0.12f, 0.25f, 0.04f, 0.08f, 0.19f});
            // Tier 5
            cfg.SetTierProbabilities(5, array<float> = {0.31f, 0.01f, 0.00f, 0.00f, 0.00f, 0.12f, 0.25f, 0.04f, 0.01f, 0.27f});

            FactoryProduction::factoryConfigs.set("legavp", @cfg);
            GenericHelpers::LogUtil("[FactoryProduction] RegisterVehicleFactories: legavp registered", 3);
        }

        GenericHelpers::LogUtil("[FactoryProduction] RegisterVehicleFactories: Completed", 2);
    }
}
