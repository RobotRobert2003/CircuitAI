// Factory configurations for AIR factories (T1/T2 for all factions)
// Each factory exposes all combat roles; response weights + tactical scoring pick roles.
// NOTE: This file is included by factory_production.as - do NOT include it back.

namespace AirConfigs {

    void RegisterAirFactories() {
        GenericHelpers::LogUtil("[FactoryProduction] RegisterAirFactories: Starting registration", 3);

        // Armada T1 Air Plant (armap)
        {
            FactoryProduction::FactoryConfig@ cfg = FactoryProduction::FactoryConfig("armap");
            cfg.AddRole("builder",   array<string> = {"armca"});
            cfg.AddRole("scout",     array<string> = {"armpeep"});
            cfg.AddRole("raider",    array<string> = {"armthund"}); // bomber-as-raider
            cfg.AddRole("riot",      array<string> = {});
            cfg.AddRole("skirmish",  array<string> = {});
            cfg.AddRole("assault",   array<string> = {"armkam"});
            cfg.AddRole("artillery", array<string> = {});
            cfg.AddRole("anti_air",  array<string> = {"armfig"});
            cfg.AddRole("support",   array<string> = {});
            cfg.AddRole("bomber",    array<string> = {"armthund"});

            cfg.SetTierProbabilities(0, array<float> = {0.20f, 0.18f, 0.20f, 0.02f, 0.02f, 0.10f, 0.02f, 0.18f, 0.03f, 0.05f});
            cfg.SetTierProbabilities(1, array<float> = {0.16f, 0.14f, 0.22f, 0.02f, 0.02f, 0.12f, 0.02f, 0.20f, 0.04f, 0.06f});

            FactoryProduction::factoryConfigs.set("armap", @cfg);
            GenericHelpers::LogUtil("[FactoryProduction] RegisterAirFactories: armap registered", 3);
        }

        // Cortex T1 Air Plant (corap)
        {
            FactoryProduction::FactoryConfig@ cfg = FactoryProduction::FactoryConfig("corap");
            cfg.AddRole("builder",   array<string> = {"corca"});
            cfg.AddRole("scout",     array<string> = {"corfink"});
            cfg.AddRole("raider",    array<string> = {"corshad"});
                cfg.AddRole("riot",      array<string> = {});
                cfg.AddRole("skirmish",  array<string> = {});
            cfg.AddRole("assault",   array<string> = {"corbw"});
            cfg.AddRole("artillery", array<string> = {});
            cfg.AddRole("anti_air",  array<string> = {"corveng"});
            cfg.AddRole("support",   array<string> = {});
            cfg.AddRole("bomber",    array<string> = {"corshad"});

            cfg.SetTierProbabilities(0, array<float> = {0.20f, 0.18f, 0.20f, 0.02f, 0.02f, 0.10f, 0.02f, 0.18f, 0.03f, 0.05f});
            cfg.SetTierProbabilities(1, array<float> = {0.16f, 0.14f, 0.22f, 0.02f, 0.02f, 0.12f, 0.02f, 0.20f, 0.04f, 0.06f});

            FactoryProduction::factoryConfigs.set("corap", @cfg);
            GenericHelpers::LogUtil("[FactoryProduction] RegisterAirFactories: corap registered", 3);
        }

        // Armada T2 Air Plant (armaap)
        {
            FactoryProduction::FactoryConfig@ cfg = FactoryProduction::FactoryConfig("armaap");
            cfg.AddRole("builder",   array<string> = {"armaca"});
            cfg.AddRole("scout",     array<string> = {});
            cfg.AddRole("raider",    array<string> = {"armbrawl", "armblade"});
                cfg.AddRole("riot",      array<string> = {});
                cfg.AddRole("skirmish",  array<string> = {});
            cfg.AddRole("assault",   array<string> = {"armstil"});
            cfg.AddRole("artillery", array<string> = {"armpnix", "armliche"});
            cfg.AddRole("anti_air",  array<string> = {"armhawk"});
            cfg.AddRole("support",   array<string> = {"armawac"});
            cfg.AddRole("bomber",    array<string> = {"armpnix", "armliche"});

            cfg.SetTierProbabilities(0, array<float> = {0.18f, 0.06f, 0.18f, 0.04f, 0.04f, 0.10f, 0.12f, 0.14f, 0.08f, 0.06f});
            cfg.SetTierProbabilities(1, array<float> = {0.14f, 0.04f, 0.18f, 0.04f, 0.04f, 0.12f, 0.14f, 0.14f, 0.08f, 0.08f});

            FactoryProduction::factoryConfigs.set("armaap", @cfg);
            GenericHelpers::LogUtil("[FactoryProduction] RegisterAirFactories: armaap registered", 3);
        }

        // Cortex T2 Air Plant (coraap)
        {
            FactoryProduction::FactoryConfig@ cfg = FactoryProduction::FactoryConfig("coraap");
            cfg.AddRole("builder",   array<string> = {"coraca"});
            cfg.AddRole("scout",     array<string> = {});
            cfg.AddRole("raider",    array<string> = {"corape"});
            cfg.AddRole("riot",      array<string> = {});
            cfg.AddRole("skirmish",  array<string> = {});
            cfg.AddRole("artillery", array<string> = {"corhurc", "corcrw"});
            cfg.AddRole("anti_air",  array<string> = {"corvamp"});
            cfg.AddRole("support",   array<string> = {"corawac"});
            cfg.AddRole("bomber",    array<string> = {"corhurc", "corape", "corcrw"});

            cfg.SetTierProbabilities(0, array<float> = {0.18f, 0.06f, 0.18f, 0.04f, 0.04f, 0.08f, 0.14f, 0.16f, 0.06f, 0.06f});
            cfg.SetTierProbabilities(1, array<float> = {0.14f, 0.04f, 0.18f, 0.04f, 0.04f, 0.10f, 0.16f, 0.16f, 0.06f, 0.08f});

            FactoryProduction::factoryConfigs.set("coraap", @cfg);
            GenericHelpers::LogUtil("[FactoryProduction] RegisterAirFactories: coraap registered", 3);
        }

        // Armada Seaplane Platform (armplat)
        {
            FactoryProduction::FactoryConfig@ cfg = FactoryProduction::FactoryConfig("armplat");
            cfg.AddRole("builder",   array<string> = {"armcsa"});
            cfg.AddRole("scout",     array<string> = {});
            cfg.AddRole("raider",    array<string> = {"armsaber"});
            cfg.AddRole("riot",      array<string> = {});
            cfg.AddRole("skirmish",  array<string> = {});
            cfg.AddRole("assault",   array<string> = {});
            cfg.AddRole("artillery", array<string> = {"armsb"});
            cfg.AddRole("anti_air",  array<string> = {"armsfig"});
            cfg.AddRole("support",   array<string> = {"armseap", "armsehak"});
            cfg.AddRole("bomber",    array<string> = {"armsb"});

            cfg.SetTierProbabilities(0, array<float> = {0.18f, 0.06f, 0.18f, 0.04f, 0.04f, 0.08f, 0.14f, 0.12f, 0.10f, 0.06f});
            cfg.SetTierProbabilities(1, array<float> = {0.14f, 0.04f, 0.18f, 0.04f, 0.04f, 0.10f, 0.16f, 0.10f, 0.14f, 0.06f});

            FactoryProduction::factoryConfigs.set("armplat", @cfg);
            GenericHelpers::LogUtil("[FactoryProduction] RegisterAirFactories: armplat registered", 3);
        }

        // Cortex Seaplane Platform (corplat)
        {
            FactoryProduction::FactoryConfig@ cfg = FactoryProduction::FactoryConfig("corplat");
            cfg.AddRole("builder",   array<string> = {"corcsa"});
            cfg.AddRole("scout",     array<string> = {});
            cfg.AddRole("raider",    array<string> = {"corsb"});
            cfg.AddRole("riot",      array<string> = {});
            cfg.AddRole("skirmish",  array<string> = {});
            cfg.AddRole("assault",   array<string> = {});
            cfg.AddRole("artillery", array<string> = {"corcut"});
            cfg.AddRole("anti_air",  array<string> = {"corsfig"});
            cfg.AddRole("support",   array<string> = {"corseap", "corhunt"});
            cfg.AddRole("bomber",    array<string> = {"corsb"});

            cfg.SetTierProbabilities(0, array<float> = {0.18f, 0.06f, 0.18f, 0.04f, 0.04f, 0.08f, 0.14f, 0.12f, 0.10f, 0.06f});
            cfg.SetTierProbabilities(1, array<float> = {0.14f, 0.04f, 0.18f, 0.04f, 0.04f, 0.10f, 0.16f, 0.10f, 0.14f, 0.06f});

            FactoryProduction::factoryConfigs.set("corplat", @cfg);
            GenericHelpers::LogUtil("[FactoryProduction] RegisterAirFactories: corplat registered", 3);
        }

        // TODO: Add Legion air factories.

        // Armada experimental aircraft plant (armapt3)
        {
            FactoryProduction::FactoryConfig@ cfg = FactoryProduction::FactoryConfig("armapt3");
            cfg.AddRole("builder",   array<string> = {"armaca"});
            cfg.AddRole("scout",     array<string> = {});
            cfg.AddRole("raider",    array<string> = {});
            cfg.AddRole("riot",      array<string> = {});
            cfg.AddRole("skirmish",  array<string> = {});
            cfg.AddRole("assault",   array<string> = {"armfepocht4"});
            cfg.AddRole("artillery", array<string> = {"armthundt4", "armlichet4"});
            cfg.AddRole("anti_air",  array<string> = {"armfepocht4"});
            cfg.AddRole("support",   array<string> = {});
            cfg.AddRole("heavy",     array<string> = {"armfepocht4"});

            cfg.SetTierProbabilities(0, array<float> = {0.05f, 0.00f, 0.00f, 0.00f, 0.00f, 0.25f, 0.15f, 0.10f, 0.00f, 0.45f});
            cfg.SetTierProbabilities(1, array<float> = {0.05f, 0.00f, 0.00f, 0.00f, 0.00f, 0.20f, 0.20f, 0.10f, 0.00f, 0.45f});

            FactoryProduction::factoryConfigs.set("armapt3", @cfg);
            GenericHelpers::LogUtil("[FactoryProduction] RegisterAirFactories: armapt3 registered", 3);
        }

        // Cortex experimental aircraft plant (corapt3)
        {
            FactoryProduction::FactoryConfig@ cfg = FactoryProduction::FactoryConfig("corapt3");
            cfg.AddRole("builder",   array<string> = {"coraca"});
            cfg.AddRole("scout",     array<string> = {});
            cfg.AddRole("raider",    array<string> = {});
            cfg.AddRole("riot",      array<string> = {});
            cfg.AddRole("skirmish",  array<string> = {});
            cfg.AddRole("assault",   array<string> = {"corcrwt4", "corfblackhyt4"});
            cfg.AddRole("artillery", array<string> = {"corfblackhyt4"});
            cfg.AddRole("anti_air",  array<string> = {"corcrwt4", "corfblackhyt4"});
            cfg.AddRole("support",   array<string> = {"cordronecarryair"});
            cfg.AddRole("heavy",     array<string> = {"corcrwt4", "corfblackhyt4"});

            cfg.SetTierProbabilities(0, array<float> = {0.05f, 0.00f, 0.00f, 0.00f, 0.00f, 0.25f, 0.15f, 0.15f, 0.15f, 0.25f});
            cfg.SetTierProbabilities(1, array<float> = {0.05f, 0.00f, 0.00f, 0.00f, 0.00f, 0.25f, 0.15f, 0.15f, 0.15f, 0.25f});

            FactoryProduction::factoryConfigs.set("corapt3", @cfg);
            GenericHelpers::LogUtil("[FactoryProduction] RegisterAirFactories: corapt3 registered", 3);
        }

        GenericHelpers::LogUtil("[FactoryProduction] RegisterAirFactories: Completed", 2);
    }
}
