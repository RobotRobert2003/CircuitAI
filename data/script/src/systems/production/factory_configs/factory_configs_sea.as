// Factory configurations for SEA factories (shipyards)
// Part of the dynamic factory production system
// NOTE: This file is included by factory_production.as - do NOT include it back

namespace SeaConfigs {
    
    void RegisterSeaFactories() {
    GenericHelpers::LogUtil("[FactoryProduction] RegisterSeaFactories: Starting registration", 3);

    // Armada T1 Shipyard (armsy)
        GenericHelpers::LogUtil("[FactoryProduction] RegisterSeaFactories: Registering armsy", 3);
        {
            FactoryProduction::FactoryConfig@ cfg = FactoryProduction::FactoryConfig("armsy");
            cfg.AddRole("builder", array<string> = {"armcs"});
            cfg.AddRole("scout", array<string> = {"armpt"});
            cfg.AddRole("raider", array<string> = {"armsub"});
            cfg.AddRole("assault", array<string> = {"armroy"});
            cfg.AddRole("anti_sub", array<string> = {"armpt"});
            cfg.AddRole("support", array<string> = {"armrecl"});

            // Tier 0: early game (< 20 metal income)
            cfg.SetTierProbabilities(0, array<float> = {0.15f, 0.25f, 0.35f, 0.15f, 0.05f, 0.05f});
            // Tier 1: mid game (20-40 income)
            cfg.SetTierProbabilities(1, array<float> = {0.10f, 0.15f, 0.30f, 0.30f, 0.10f, 0.05f});
            // Tier 2: late T1 (40-80 income)
            cfg.SetTierProbabilities(2, array<float> = {0.08f, 0.12f, 0.25f, 0.35f, 0.15f, 0.05f});
            // Tier 3: high income (80+ income)
            cfg.SetTierProbabilities(3, array<float> = {0.05f, 0.10f, 0.20f, 0.40f, 0.20f, 0.05f});

            FactoryProduction::factoryConfigs.set("armsy", @cfg);
            GenericHelpers::LogUtil("[FactoryProduction] RegisterSeaFactories: armsy registered", 3);
        }

    // Cortex T1 Shipyard (corsy)
        GenericHelpers::LogUtil("[FactoryProduction] RegisterSeaFactories: Registering corsy", 3);
        {
            FactoryProduction::FactoryConfig@ cfg = FactoryProduction::FactoryConfig("corsy");
            cfg.AddRole("builder", array<string> = {"corcs"});
            cfg.AddRole("scout", array<string> = {"corpt"});
            cfg.AddRole("raider", array<string> = {"corsub"});
            cfg.AddRole("assault", array<string> = {"corroy"});
            cfg.AddRole("anti_sub", array<string> = {"corpt"});
            cfg.AddRole("support", array<string> = {"correcl"});

            cfg.SetTierProbabilities(0, array<float> = {0.15f, 0.25f, 0.35f, 0.15f, 0.05f, 0.05f});
            cfg.SetTierProbabilities(1, array<float> = {0.10f, 0.15f, 0.30f, 0.30f, 0.10f, 0.05f});
            cfg.SetTierProbabilities(2, array<float> = {0.08f, 0.12f, 0.25f, 0.35f, 0.15f, 0.05f});
            cfg.SetTierProbabilities(3, array<float> = {0.05f, 0.10f, 0.20f, 0.40f, 0.20f, 0.05f});

            FactoryProduction::factoryConfigs.set("corsy", @cfg);
            GenericHelpers::LogUtil("[FactoryProduction] RegisterSeaFactories: corsy registered", 3);
        }

    // Legion T1 Shipyard (legsy)
        GenericHelpers::LogUtil("[FactoryProduction] RegisterSeaFactories: Registering legsy", 3);
        {
            FactoryProduction::FactoryConfig@ cfg = FactoryProduction::FactoryConfig("legsy");
            // Roles derived from factory_leg.json + behaviour_leg.json
            // unit list: [legnavyconship, legnavyrezsub, legnavyaaship, legnavyscout, legnavyfrigate, legnavydestro, legnavyartyship, legnavysub]
            cfg.AddRole("builder",   array<string> = {"legnavyconship"});
            cfg.AddRole("support",   array<string> = {"legnavyrezsub"});
            cfg.AddRole("anti_air",  array<string> = {"legnavyaaship"});
            cfg.AddRole("scout",     array<string> = {"legnavyscout"});
            cfg.AddRole("skirmish",  array<string> = {"legnavyfrigate"});
            cfg.AddRole("assault",   array<string> = {"legnavydestro"});
            cfg.AddRole("artillery", array<string> = {"legnavyartyship"});
            cfg.AddRole("raider",    array<string> = {"legnavysub"});

            // Map legacy tier weights (land/air) onto a single set for sea dynamic production.
            // Order matches roles above.
            cfg.SetTierProbabilities(0, array<float> = {
                0.09f, // builder   (conship)
                0.01f, // support   (rezsub)
                0.26f, // anti_air  (AA ship)
                0.23f, // scout     (scout)
                0.14f, // skirmish  (frigate)
                0.18f, // assault   (destro)
                0.09f, // artillery (artyship)
                0.09f  // raider    (sub)
            });
            cfg.SetTierProbabilities(1, array<float> = {
                0.09f,
                0.01f,
                0.26f,
                0.23f,
                0.14f,
                0.18f,
                0.09f,
                0.09f
            });

            FactoryProduction::factoryConfigs.set("legsy", @cfg);
            GenericHelpers::LogUtil("[FactoryProduction] RegisterSeaFactories: legsy registered", 3);
        }

        // Armada Advanced Shipyard (armasy)
        GenericHelpers::LogUtil("[FactoryProduction] RegisterSeaFactories: Registering armassy", 3);
        {
            FactoryProduction::FactoryConfig@ cfg = FactoryProduction::FactoryConfig("armasy");
            cfg.AddRole("builder",   array<string> = {"armacsub"});
            cfg.AddRole("scout",     array<string> = {"armpship"});
            cfg.AddRole("raider",    array<string> = {"armcrus"});
            cfg.AddRole("assault",   array<string> = {"armbats"});
            cfg.AddRole("anti_sub",  array<string> = {"armpship"});
            cfg.AddRole("support",   array<string> = {"armrech"});

            // Two coarse tiers for T2 sea factories: mid and late game
            cfg.SetTierProbabilities(0, array<float> = {0.16f, 0.18f, 0.26f, 0.24f, 0.08f, 0.08f});
            cfg.SetTierProbabilities(1, array<float> = {0.12f, 0.16f, 0.24f, 0.30f, 0.08f, 0.10f});

            FactoryProduction::factoryConfigs.set("armasy", @cfg);
            GenericHelpers::LogUtil("[FactoryProduction] RegisterSeaFactories: armassy registered", 3);
        }

        // Cortex Advanced Shipyard (corasy)
        GenericHelpers::LogUtil("[FactoryProduction] RegisterSeaFactories: Registering corasy", 3);
        {
            FactoryProduction::FactoryConfig@ cfg = FactoryProduction::FactoryConfig("corasy");
            cfg.AddRole("builder",   array<string> = {"coracsub"});
            cfg.AddRole("scout",     array<string> = {"corpship"});
            cfg.AddRole("raider",    array<string> = {"corshark"});
            cfg.AddRole("assault",   array<string> = {"corbats"});
            cfg.AddRole("anti_sub",  array<string> = {"corpship"});
            cfg.AddRole("support",   array<string> = {"correch"});

            cfg.SetTierProbabilities(0, array<float> = {0.16f, 0.18f, 0.26f, 0.24f, 0.08f, 0.08f});
            cfg.SetTierProbabilities(1, array<float> = {0.12f, 0.16f, 0.24f, 0.30f, 0.08f, 0.10f});

            FactoryProduction::factoryConfigs.set("corasy", @cfg);
            GenericHelpers::LogUtil("[FactoryProduction] RegisterSeaFactories: corasy registered", 3);
        }

        // Legion Advanced Shipyard (legadvshipyard)
        {
            FactoryProduction::FactoryConfig@ cfg = FactoryProduction::FactoryConfig("legadvshipyard");
            cfg.AddRole("builder",   array<string> = {"leganavyconsub", "leganavyengineer"});
            cfg.AddRole("support",   array<string> = {"leganavyradjamship", "leganavyantinukecarrier"});
            cfg.AddRole("anti_air",  array<string> = {"leganavyaaship"});
            cfg.AddRole("scout",     array<string> = {});
            cfg.AddRole("raider",    array<string> = {"leganavybattlesub"});
            cfg.AddRole("skirmish",  array<string> = {"leganavycruiser", "leganavymissileship"});
            cfg.AddRole("assault",   array<string> = {"leganavyheavysub", "leganavybattleship", "leganavyflagship"});
            cfg.AddRole("artillery", array<string> = {"leganavyartyship", "leganavymissileship"});
            cfg.AddRole("anti_sub",  array<string> = {"leganavyheavysub", "leganavybattlesub"});
            cfg.AddRole("riot",      array<string> = {"leganavyantiswarm"});
            cfg.AddRole("heavy",     array<string> = {"leganavybattleship", "leganavyflagship"});

            cfg.SetTierProbabilities(0, array<float> = {0.10f, 0.10f, 0.10f, 0.00f, 0.08f, 0.12f, 0.20f, 0.10f, 0.08f, 0.05f, 0.07f});
            cfg.SetTierProbabilities(1, array<float> = {0.07f, 0.10f, 0.08f, 0.00f, 0.05f, 0.10f, 0.20f, 0.12f, 0.08f, 0.05f, 0.15f});

            FactoryProduction::factoryConfigs.set("legadvshipyard", @cfg);
            GenericHelpers::LogUtil("[FactoryProduction] RegisterSeaFactories: legadvshipyard registered", 3);
        }

        GenericHelpers::LogUtil("[FactoryProduction] RegisterSeaFactories: Completed SEA factory registration", 2);
    }
}
