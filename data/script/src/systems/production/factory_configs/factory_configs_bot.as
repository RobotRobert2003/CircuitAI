// Factory configurations for BOT factories (T1/T2 for all factions)
// Each factory exposes all combat roles; response weights + tactical scoring pick roles.
// NOTE: This file is included by factory_production.as - do NOT include it back.

namespace BotConfigs {

    void RegisterBotFactories() {
        GenericHelpers::LogUtil("[FactoryProduction] RegisterBotFactories: Starting registration", 3);

        // Armada T1 Bot Lab (armlab)
        {
            FactoryProduction::FactoryConfig@ cfg = FactoryProduction::FactoryConfig("armlab");
            // Roles: builder, scout, raider, riot, skirmish, assault, artillery, anti_air, support, heavy
            cfg.AddRole("builder",   array<string> = {"armck"});
            cfg.AddRole("scout",     array<string> = {"armflea"});
            cfg.AddRole("raider",    array<string> = {"armpw"});
            cfg.AddRole("riot",      array<string> = {"armham"});
            cfg.AddRole("skirmish",  array<string> = {"armrock"});
            cfg.AddRole("assault",   array<string> = {"armwar"});
            cfg.AddRole("artillery", array<string> = {}); // no true arty at T1 lab
            cfg.AddRole("anti_air",  array<string> = {"armjeth"});
            cfg.AddRole("support",   array<string> = {"armrectr"});
            cfg.AddRole("heavy",     array<string> = {});

            // 4 economic tiers: 0..3, role probabilities kept broad; response + scoring refine within role
            cfg.SetTierProbabilities(0, array<float> = {0.16f, 0.20f, 0.30f, 0.05f, 0.05f, 0.10f, 0.02f, 0.07f, 0.03f, 0.02f});
            cfg.SetTierProbabilities(1, array<float> = {0.10f, 0.15f, 0.28f, 0.08f, 0.10f, 0.15f, 0.02f, 0.08f, 0.03f, 0.01f});
            cfg.SetTierProbabilities(2, array<float> = {0.08f, 0.12f, 0.25f, 0.08f, 0.12f, 0.20f, 0.02f, 0.10f, 0.02f, 0.01f});
            cfg.SetTierProbabilities(3, array<float> = {0.05f, 0.08f, 0.20f, 0.07f, 0.15f, 0.25f, 0.03f, 0.12f, 0.03f, 0.02f});

            FactoryProduction::factoryConfigs.set("armlab", @cfg);
            GenericHelpers::LogUtil("[FactoryProduction] RegisterBotFactories: armlab registered", 3);
        }

        // Cortex T1 Bot Lab (corlab)
        {
            FactoryProduction::FactoryConfig@ cfg = FactoryProduction::FactoryConfig("corlab");
            cfg.AddRole("builder",   array<string> = {"corck"});
            cfg.AddRole("scout",     array<string> = {"corak"});
            cfg.AddRole("raider",    array<string> = {"corak"});
            cfg.AddRole("riot",      array<string> = {"corthud"});
            cfg.AddRole("skirmish",  array<string> = {"corstorm"});
            cfg.AddRole("assault",   array<string> = {});
            cfg.AddRole("artillery", array<string> = {});
            cfg.AddRole("anti_air",  array<string> = {"corcrash"});
            cfg.AddRole("support",   array<string> = {"cornecro"});
            cfg.AddRole("heavy",     array<string> = {});

            cfg.SetTierProbabilities(0, array<float> = {0.16f, 0.20f, 0.30f, 0.06f, 0.08f, 0.08f, 0.02f, 0.06f, 0.03f, 0.01f});
            cfg.SetTierProbabilities(1, array<float> = {0.10f, 0.15f, 0.28f, 0.08f, 0.12f, 0.10f, 0.02f, 0.08f, 0.05f, 0.02f});
            cfg.SetTierProbabilities(2, array<float> = {0.08f, 0.12f, 0.26f, 0.08f, 0.15f, 0.12f, 0.03f, 0.08f, 0.06f, 0.02f});
            cfg.SetTierProbabilities(3, array<float> = {0.05f, 0.08f, 0.22f, 0.07f, 0.18f, 0.15f, 0.03f, 0.10f, 0.08f, 0.04f});

            FactoryProduction::factoryConfigs.set("corlab", @cfg);
            GenericHelpers::LogUtil("[FactoryProduction] RegisterBotFactories: corlab registered", 3);
        }

        // Armada T2 Bot Lab (armalab)
        {
            FactoryProduction::FactoryConfig@ cfg = FactoryProduction::FactoryConfig("armalab");
            // Roles: builder, scout, raider, riot, skirmish, assault, artillery, anti_air, support, heavy
            cfg.AddRole("builder",   array<string> = {"armack"});
            cfg.AddRole("scout",     array<string> = {"armfast"});
            cfg.AddRole("raider",    array<string> = {"armfast", "armspy"});
            cfg.AddRole("riot",      array<string> = {"armfboy"});
            cfg.AddRole("skirmish",  array<string> = {"armfido", "armsptk", "armsnipe"});
            cfg.AddRole("assault",   array<string> = {"armzeus", "armmav"});
            cfg.AddRole("artillery", array<string> = {});
            cfg.AddRole("anti_air",  array<string> = {"armaak"});
            cfg.AddRole("support",   array<string> = {"armfark", "armmark", "armamph"});
            cfg.AddRole("heavy",     array<string> = {});

            cfg.SetTierProbabilities(0, array<float> = {0.18f, 0.16f, 0.16f, 0.06f, 0.10f, 0.12f, 0.04f, 0.06f, 0.08f, 0.04f});
            cfg.SetTierProbabilities(1, array<float> = {0.14f, 0.12f, 0.16f, 0.06f, 0.12f, 0.16f, 0.04f, 0.06f, 0.08f, 0.06f});

            FactoryProduction::factoryConfigs.set("armalab", @cfg);
            GenericHelpers::LogUtil("[FactoryProduction] RegisterBotFactories: armalab registered", 3);
        }

        // Cortex T2 Bot Lab (coralab)
        {
            FactoryProduction::FactoryConfig@ cfg = FactoryProduction::FactoryConfig("coralab");
            cfg.AddRole("builder",   array<string> = {"corack"});
            cfg.AddRole("scout",     array<string> = {"corfast"});
            cfg.AddRole("raider",    array<string> = {"corpyro"});
            cfg.AddRole("riot",      array<string> = {"corsumo", "cortermite"});
            cfg.AddRole("skirmish",  array<string> = {"cormort", "corhrk"});
            cfg.AddRole("assault",   array<string> = {"corcan", "cormando"});
            cfg.AddRole("artillery", array<string> = {});
            cfg.AddRole("anti_air",  array<string> = {"coraak"});
            cfg.AddRole("support",   array<string> = {"corvoyr", "coramph"});
            cfg.AddRole("heavy",     array<string> = {"corsktl"});

            cfg.SetTierProbabilities(0, array<float> = {0.18f, 0.14f, 0.16f, 0.08f, 0.10f, 0.12f, 0.04f, 0.06f, 0.06f, 0.06f});
            cfg.SetTierProbabilities(1, array<float> = {0.14f, 0.10f, 0.16f, 0.08f, 0.12f, 0.14f, 0.04f, 0.06f, 0.06f, 0.10f});

            FactoryProduction::factoryConfigs.set("coralab", @cfg);
            GenericHelpers::LogUtil("[FactoryProduction] RegisterBotFactories: coralab registered", 3);
        }

        // ARMADA Gantry (armshltx)
        {
            FactoryProduction::FactoryConfig@ cfg = FactoryProduction::FactoryConfig("armshltx");
            cfg.AddRole("builder",   array<string> = {"armack"});
            cfg.AddRole("scout",     array<string> = {});
            cfg.AddRole("raider",    array<string> = {});
            cfg.AddRole("riot",      array<string> = {});
            cfg.AddRole("skirmish",  array<string> = {});
            cfg.AddRole("assault",   array<string> = {"armmar", "armraz", "armvang", "armbanth"});
            cfg.AddRole("artillery", array<string> = {});
            cfg.AddRole("anti_air",  array<string> = {});
            cfg.AddRole("support",   array<string> = {});
            cfg.AddRole("heavy",     array<string> = {"armbanth"});

            cfg.SetTierProbabilities(0, array<float> = {0.10f, 0.02f, 0.02f, 0.02f, 0.04f, 0.50f, 0.04f, 0.04f, 0.02f, 0.20f});
            cfg.SetTierProbabilities(1, array<float> = {0.08f, 0.02f, 0.02f, 0.02f, 0.04f, 0.46f, 0.04f, 0.04f, 0.02f, 0.26f});

            FactoryProduction::factoryConfigs.set("armshltx", @cfg);
            GenericHelpers::LogUtil("[FactoryProduction] RegisterBotFactories: armshltx registered", 3);
        }

        // ARMADA Underwater Gantry (armshltxuw)
        {
            FactoryProduction::FactoryConfig@ cfg = FactoryProduction::FactoryConfig("armshltxuw");
            cfg.AddRole("builder",   array<string> = {"armack"});
            cfg.AddRole("scout",     array<string> = {});
            cfg.AddRole("raider",    array<string> = {});
            cfg.AddRole("riot",      array<string> = {});
            cfg.AddRole("skirmish",  array<string> = {});
            cfg.AddRole("assault",   array<string> = {"armmar", "armcroc", "armbanth"});
            cfg.AddRole("artillery", array<string> = {});
            cfg.AddRole("anti_air",  array<string> = {});
            cfg.AddRole("support",   array<string> = {});
            cfg.AddRole("heavy",     array<string> = {"armbanth"});

            cfg.SetTierProbabilities(0, array<float> = {0.10f, 0.02f, 0.02f, 0.02f, 0.04f, 0.50f, 0.04f, 0.04f, 0.02f, 0.20f});
            cfg.SetTierProbabilities(1, array<float> = {0.08f, 0.02f, 0.02f, 0.02f, 0.04f, 0.46f, 0.04f, 0.04f, 0.02f, 0.26f});

            FactoryProduction::factoryConfigs.set("armshltxuw", @cfg);
            GenericHelpers::LogUtil("[FactoryProduction] RegisterBotFactories: armshltxuw registered", 3);
        }

        // CORTEX Gantry (corgant)
        {
            FactoryProduction::FactoryConfig@ cfg = FactoryProduction::FactoryConfig("corgant");
            cfg.AddRole("builder",   array<string> = {"coracv"});
            // cfg.AddRole("scout",     array<string> = {});
            // cfg.AddRole("raider",    array<string> = {});
            // cfg.AddRole("riot",      array<string> = {});
            // cfg.AddRole("skirmish",  array<string> = {});
            cfg.AddRole("assault",   array<string> = {"corshiva", "corjugg"});
            cfg.AddRole("artillery", array<string> = {"corcat"});
            cfg.AddRole("anti_air",  array<string> = {});
            cfg.AddRole("support",   array<string> = {});
            cfg.AddRole("heavy",     array<string> = {"corkarg", "corkorg"});

            cfg.SetTierProbabilities(0, array<float> = {0.10f, 0.02f, 0.02f, 0.02f, 0.04f, 0.46f, 0.08f, 0.04f, 0.04f, 0.18f});
            cfg.SetTierProbabilities(1, array<float> = {0.08f, 0.02f, 0.02f, 0.02f, 0.04f, 0.42f, 0.08f, 0.04f, 0.04f, 0.24f});

            FactoryProduction::factoryConfigs.set("corgant", @cfg);
            GenericHelpers::LogUtil("[FactoryProduction] RegisterBotFactories: corgant registered", 3);
        }

        // CORTEX Underwater Gantry (corgantuw)
        {
            FactoryProduction::FactoryConfig@ cfg = FactoryProduction::FactoryConfig("corgantuw");
            cfg.AddRole("builder",   array<string> = {"coracv"});
            cfg.AddRole("scout",     array<string> = {});
            cfg.AddRole("raider",    array<string> = {});
            cfg.AddRole("riot",      array<string> = {});
            cfg.AddRole("skirmish",  array<string> = {});
            cfg.AddRole("assault",   array<string> = {"corshiva", "corsala"});
            // cfg.AddRole("artillery", array<string> = {});
            // cfg.AddRole("anti_air",  array<string> = {});
            // cfg.AddRole("support",   array<string> = {});
            cfg.AddRole("heavy",     array<string> = {"corkorg"});

            cfg.SetTierProbabilities(0, array<float> = {0.10f, 0.02f, 0.02f, 0.02f, 0.04f, 0.50f, 0.04f, 0.04f, 0.02f, 0.20f});
            cfg.SetTierProbabilities(1, array<float> = {0.08f, 0.02f, 0.02f, 0.02f, 0.04f, 0.46f, 0.04f, 0.04f, 0.02f, 0.26f});

            FactoryProduction::factoryConfigs.set("corgantuw", @cfg);
            GenericHelpers::LogUtil("[FactoryProduction] RegisterBotFactories: corgantuw registered", 3);
        }

        // Legion T1 Bot Lab (leglab)
        {
            FactoryProduction::FactoryConfig@ cfg = FactoryProduction::FactoryConfig("leglab");
            // Roles: builder, scout, raider, riot, skirmish, assault, artillery, anti_air, support, heavy
            // JSON units: ["legck", "leglob", "legrezbot", "legbal", "legcen", "legkark", "legaabot", "leggob"]
            cfg.AddRole("builder",   array<string> = {"legck"});
            cfg.AddRole("scout",     array<string> = {"leggob"});
            cfg.AddRole("raider",    array<string> = {"leglob"});
            cfg.AddRole("riot",      array<string> = {"legbal"});
            cfg.AddRole("skirmish",  array<string> = {"legcen"});
            cfg.AddRole("assault",   array<string> = {"legkark"});
            cfg.AddRole("artillery", array<string> = {});
            cfg.AddRole("anti_air",  array<string> = {});
            cfg.AddRole("support",   array<string> = {"legrezbot"});
            cfg.AddRole("heavy",     array<string> = {"legaabot"});

            // Roughly derived from factory_leg.json land/air weights; kept broad and role-based
            cfg.SetTierProbabilities(0, array<float> = {0.10f, 0.20f, 0.30f, 0.10f, 0.10f, 0.08f, 0.02f, 0.00f, 0.08f, 0.02f});
            cfg.SetTierProbabilities(1, array<float> = {0.10f, 0.18f, 0.28f, 0.10f, 0.12f, 0.10f, 0.02f, 0.00f, 0.08f, 0.02f});
            cfg.SetTierProbabilities(2, array<float> = {0.08f, 0.16f, 0.26f, 0.10f, 0.14f, 0.12f, 0.02f, 0.00f, 0.08f, 0.04f});
            cfg.SetTierProbabilities(3, array<float> = {0.06f, 0.14f, 0.22f, 0.10f, 0.16f, 0.14f, 0.04f, 0.00f, 0.08f, 0.06f});

            FactoryProduction::factoryConfigs.set("leglab", @cfg);
            GenericHelpers::LogUtil("[FactoryProduction] RegisterBotFactories: leglab registered", 3);
        }

        // Legion T2 Bot Lab (legalab)
        {
            FactoryProduction::FactoryConfig@ cfg = FactoryProduction::FactoryConfig("legalab");
            // JSON units: ["legack", "legaceb", "legdecom", "legaspy", "legaradk", "legajamk", "legstr", "leghrk", "legbart", "leginfestor", "legsrail", "legshot", "leginc", "legsnapper", "legamph", "legadvaabot"]
            cfg.AddRole("builder",   array<string> = {"legack"});
            cfg.AddRole("scout",     array<string> = {"legaspy"});
            cfg.AddRole("raider",    array<string> = {"legstr", "legsnapper"});
            cfg.AddRole("riot",      array<string> = {"legshot"});
            cfg.AddRole("skirmish",  array<string> = {"leghrk"});
            cfg.AddRole("assault",   array<string> = {"leginc", "legamph"});
            cfg.AddRole("artillery", array<string> = {"legbart", "legsrail"});
            cfg.AddRole("anti_air",  array<string> = {});
            // D-293: leginfestor omitted. Its only build option is itself, so native routes it to
            // BuilderManager as a worker (counted as build power, given assist/guard tasks) and
            // MilitaryManager never commands it: neither combat nor useful build power. Once
            // legaradk/legajamk reached their limit of 1 it was the only unit left in this slot, so
            // every support pick became a batch of Infestors. behaviour_leg.json also sets limit 0.
            cfg.AddRole("support",   array<string> = {"legaceb", "legdecom", "legaradk", "legajamk"});
            cfg.AddRole("heavy",     array<string> = {"legadvaabot"});

            // Role-level approximation of factory_leg.json land tiers 0-5
            cfg.SetTierProbabilities(0, array<float> = {0.08f, 0.02f, 0.35f, 0.05f, 0.02f, 0.05f, 0.02f, 0.02f, 0.25f, 0.14f});
            cfg.SetTierProbabilities(1, array<float> = {0.06f, 0.02f, 0.38f, 0.05f, 0.05f, 0.08f, 0.04f, 0.02f, 0.20f, 0.10f});
            cfg.SetTierProbabilities(2, array<float> = {0.05f, 0.02f, 0.32f, 0.05f, 0.08f, 0.10f, 0.06f, 0.02f, 0.20f, 0.10f});
            cfg.SetTierProbabilities(3, array<float> = {0.04f, 0.02f, 0.24f, 0.05f, 0.08f, 0.12f, 0.08f, 0.02f, 0.20f, 0.15f});
            cfg.SetTierProbabilities(4, array<float> = {0.04f, 0.02f, 0.18f, 0.05f, 0.08f, 0.14f, 0.10f, 0.02f, 0.17f, 0.20f});
            cfg.SetTierProbabilities(5, array<float> = {0.04f, 0.02f, 0.10f, 0.05f, 0.08f, 0.16f, 0.12f, 0.02f, 0.15f, 0.26f});

            FactoryProduction::factoryConfigs.set("legalab", @cfg);
            GenericHelpers::LogUtil("[FactoryProduction] RegisterBotFactories: legalab registered", 3);
        }

        GenericHelpers::LogUtil("[FactoryProduction] RegisterBotFactories: Completed", 2);
    }
}
