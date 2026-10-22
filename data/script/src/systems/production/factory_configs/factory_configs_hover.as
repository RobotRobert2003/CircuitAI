// Factory configurations for HOVER factories (land and floating)
// Part of the dynamic factory production system
// NOTE: This file is included by factory_production.as - do NOT include it back

namespace HoverConfigs {
    
    void RegisterHoverFactories() {
        GenericHelpers::LogUtil("[FactoryProduction] RegisterHoverFactories: Starting registration", 3);
        
        // ========== ARMADA ==========
        
        // Armada T1 Land Hover Plant (armhp)
        GenericHelpers::LogUtil("[FactoryProduction] RegisterHoverFactories: Registering armhp", 3);
        {
            FactoryProduction::FactoryConfig@ cfg = FactoryProduction::FactoryConfig("armhp");
            cfg.AddRole("builder", array<string> = {"armch"});
            cfg.AddRole("scout", array<string> = {"armsh"});
            cfg.AddRole("raider", array<string> = {"armthovr", "armanac"});
            cfg.AddRole("assault", array<string> = {"armmh"});
            cfg.AddRole("support", array<string> = {"armah"});

            // Tier 0: early game (< 20 metal income)
            cfg.SetTierProbabilities(0, array<float> = {0.15f, 0.30f, 0.40f, 0.10f, 0.05f});
            // Tier 1: mid game (20-40 income)
            cfg.SetTierProbabilities(1, array<float> = {0.10f, 0.20f, 0.35f, 0.25f, 0.10f});
            // Tier 2: late T1 (40-80 income)
            cfg.SetTierProbabilities(2, array<float> = {0.08f, 0.15f, 0.30f, 0.35f, 0.12f});
            // Tier 3: high income (80+ income)
            cfg.SetTierProbabilities(3, array<float> = {0.05f, 0.10f, 0.25f, 0.45f, 0.15f});

            FactoryProduction::factoryConfigs.set("armhp", @cfg);
            GenericHelpers::LogUtil("[FactoryProduction] RegisterHoverFactories: armhp registered", 3);
        }

        // Armada T1 Floating Hover Plant (armfhp)
        GenericHelpers::LogUtil("[FactoryProduction] RegisterHoverFactories: Registering armfhp", 3);
        {
            FactoryProduction::FactoryConfig@ cfg = FactoryProduction::FactoryConfig("armfhp");
            // Same units/roles as land version since hovercrafts work on both land and water
            cfg.AddRole("builder", array<string> = {"armch"});
            cfg.AddRole("scout", array<string> = {"armsh"});
            cfg.AddRole("raider", array<string> = {"armthovr", "armanac"});
            cfg.AddRole("assault", array<string> = {"armmh"});
            cfg.AddRole("support", array<string> = {"armah"});

            cfg.SetTierProbabilities(0, array<float> = {0.15f, 0.30f, 0.40f, 0.10f, 0.05f});
            cfg.SetTierProbabilities(1, array<float> = {0.10f, 0.20f, 0.35f, 0.25f, 0.10f});
            cfg.SetTierProbabilities(2, array<float> = {0.08f, 0.15f, 0.30f, 0.35f, 0.12f});
            cfg.SetTierProbabilities(3, array<float> = {0.05f, 0.10f, 0.25f, 0.45f, 0.15f});

            FactoryProduction::factoryConfigs.set("armfhp", @cfg);
            GenericHelpers::LogUtil("[FactoryProduction] RegisterHoverFactories: armfhp registered", 3);
        }

        // ========== CORTEX ==========
        
        // Cortex T1 Land Hover Plant (corhp)
        GenericHelpers::LogUtil("[FactoryProduction] RegisterHoverFactories: Registering corhp", 3);
        {
            FactoryProduction::FactoryConfig@ cfg = FactoryProduction::FactoryConfig("corhp");
            cfg.AddRole("builder", array<string> = {"corch"});
            cfg.AddRole("scout", array<string> = {"corsh"});
            cfg.AddRole("raider", array<string> = {"corthovr", "corsnap"});
            cfg.AddRole("assault", array<string> = {"cormh", "corah", "corhal"});
            cfg.AddRole("support", array<string> = {"corah"});

            // Tier 0: early game (< 20 metal income)
            cfg.SetTierProbabilities(0, array<float> = {0.15f, 0.30f, 0.40f, 0.10f, 0.05f});
            // Tier 1: mid game (20-40 income)
            cfg.SetTierProbabilities(1, array<float> = {0.10f, 0.20f, 0.35f, 0.25f, 0.10f});
            // Tier 2: late T1 (40-80 income)
            cfg.SetTierProbabilities(2, array<float> = {0.08f, 0.15f, 0.30f, 0.35f, 0.12f});
            // Tier 3: high income (80+ income)
            cfg.SetTierProbabilities(3, array<float> = {0.05f, 0.10f, 0.25f, 0.45f, 0.15f});

            FactoryProduction::factoryConfigs.set("corhp", @cfg);
            GenericHelpers::LogUtil("[FactoryProduction] RegisterHoverFactories: corhp registered", 3);
        }

        // Cortex T1 Floating Hover Plant (corfhp)
        GenericHelpers::LogUtil("[FactoryProduction] RegisterHoverFactories: Registering corfhp", 3);
        {
            FactoryProduction::FactoryConfig@ cfg = FactoryProduction::FactoryConfig("corfhp");
            cfg.AddRole("builder", array<string> = {"corch"});
            cfg.AddRole("scout", array<string> = {"corsh"});
            cfg.AddRole("raider", array<string> = {"corthovr", "corsnap"});
            cfg.AddRole("assault", array<string> = {"cormh", "corah", "corhal"});
            cfg.AddRole("support", array<string> = {"corah"});

            cfg.SetTierProbabilities(0, array<float> = {0.15f, 0.30f, 0.40f, 0.10f, 0.05f});
            cfg.SetTierProbabilities(1, array<float> = {0.10f, 0.20f, 0.35f, 0.25f, 0.10f});
            cfg.SetTierProbabilities(2, array<float> = {0.08f, 0.15f, 0.30f, 0.35f, 0.12f});
            cfg.SetTierProbabilities(3, array<float> = {0.05f, 0.10f, 0.25f, 0.45f, 0.15f});

            FactoryProduction::factoryConfigs.set("corfhp", @cfg);
            GenericHelpers::LogUtil("[FactoryProduction] RegisterHoverFactories: corfhp registered", 3);
        }

        // ========== LEGION ==========
        
        // Legion T1 Land Hover Plant (leghp)
        GenericHelpers::LogUtil("[FactoryProduction] RegisterHoverFactories: Registering leghp", 3);
        {
            FactoryProduction::FactoryConfig@ cfg = FactoryProduction::FactoryConfig("leghp");
            cfg.AddRole("builder", array<string> = {"legch"});
            cfg.AddRole("scout", array<string> = {"legsh"});
            cfg.AddRole("raider", array<string> = {"legner"});
            cfg.AddRole("assault", array<string> = {"legmh", "legah", "legcar"});
            cfg.AddRole("support", array<string> = {"legah"});

            // Tier 0: early game (< 20 metal income)
            cfg.SetTierProbabilities(0, array<float> = {0.15f, 0.30f, 0.40f, 0.10f, 0.05f});
            // Tier 1: mid game (20-40 income)
            cfg.SetTierProbabilities(1, array<float> = {0.10f, 0.20f, 0.35f, 0.25f, 0.10f});
            // Tier 2: late T1 (40-80 income)
            cfg.SetTierProbabilities(2, array<float> = {0.08f, 0.15f, 0.30f, 0.35f, 0.12f});
            // Tier 3: high income (80+ income)
            cfg.SetTierProbabilities(3, array<float> = {0.05f, 0.10f, 0.25f, 0.45f, 0.15f});

            FactoryProduction::factoryConfigs.set("leghp", @cfg);
            GenericHelpers::LogUtil("[FactoryProduction] RegisterHoverFactories: leghp registered", 3);
        }

        // Legion T1 Floating Hover Plant (legfhp)
        GenericHelpers::LogUtil("[FactoryProduction] RegisterHoverFactories: Registering legfhp", 3);
        {
            FactoryProduction::FactoryConfig@ cfg = FactoryProduction::FactoryConfig("legfhp");
            cfg.AddRole("builder", array<string> = {"legch"});
            cfg.AddRole("scout", array<string> = {"legsh"});
            cfg.AddRole("raider", array<string> = {"legner"});
            cfg.AddRole("assault", array<string> = {"legmh", "legah", "legcar"});
            cfg.AddRole("support", array<string> = {"legah"});

            cfg.SetTierProbabilities(0, array<float> = {0.15f, 0.30f, 0.40f, 0.10f, 0.05f});
            cfg.SetTierProbabilities(1, array<float> = {0.10f, 0.20f, 0.35f, 0.25f, 0.10f});
            cfg.SetTierProbabilities(2, array<float> = {0.08f, 0.15f, 0.30f, 0.35f, 0.12f});
            cfg.SetTierProbabilities(3, array<float> = {0.05f, 0.10f, 0.25f, 0.45f, 0.15f});

            FactoryProduction::factoryConfigs.set("legfhp", @cfg);
            GenericHelpers::LogUtil("[FactoryProduction] RegisterHoverFactories: legfhp registered", 3);
        }

        GenericHelpers::LogUtil("[FactoryProduction] RegisterHoverFactories: Registered 6 HOVER factory configs (armhp, armfhp, corhp, corfhp, leghp, legfhp)", 2);
    }
}
