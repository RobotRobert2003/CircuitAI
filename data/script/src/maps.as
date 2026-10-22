
#include "helpers/common/generic_helpers.as"

//Maps
#include "maps/default_map_config.as"
#include "maps/swirly_rock.as"
#include "maps/all_that_glitters.as"
#include "maps/supreme_isthmus.as"
#include "maps/eight_horses.as"
#include "maps/flats_and_forests.as"
#include "maps/glacial_gap.as"
#include "maps/forge.as"
#include "maps/red_river_estuary.as"
#include "maps/serene_caldera.as"
#include "maps/shore_to_shore.as"
#include "maps/koom_valley.as"
#include "maps/acidic_quarry.as"
#include "maps/tempest.as"
#include "maps/tundra_continents.as"
#include "maps/raptor_crater.as"
#include "maps/sinkhole_network.as"
#include "maps/ancient_bastion_remake.as"
#include "maps/mediterraneum.as"
#include "maps/pinewood_derby.as"

// Additional configs generated from the BAR map-list export: the popular16p pool
// and every other map with a player count of 12 or more.
#include "maps/all_that_simmers.as"
#include "maps/all_that_smolders.as"
#include "maps/angel_crossing.as"
#include "maps/ascendancy.as"
#include "maps/azurite_shores.as"
#include "maps/baryon_tar_lake.as"
#include "maps/bismuth_valley.as"
#include "maps/carrot_mountains.as"
#include "maps/cells.as"
#include "maps/coastlines_dry.as"
#include "maps/darkside.as"
#include "maps/deeploria_fields.as"
#include "maps/delta_siege_dry.as"
#include "maps/entrenched_plains.as"
#include "maps/erebos_lakes.as"
#include "maps/esker_creek.as"
#include "maps/failed_negotiations.as"
#include "maps/hades_ponds.as"
#include "maps/hellas_basin.as"
#include "maps/hera_planum.as"
#include "maps/hotlips_remake.as"
#include "maps/ice_scream.as"
#include "maps/kings_assault.as"
#include "maps/kolmogorov_remake.as"
#include "maps/mariposa_island.as"
#include "maps/melting_glacier.as"
#include "maps/mescaline.as"
#include "maps/moonshine_run.as"
#include "maps/nuclear_winter_bar.as"
#include "maps/otago.as"
#include "maps/pawn_retreat.as"
#include "maps/pinch_point.as"
#include "maps/plains_and_passes.as"
#include "maps/project_sd_129.as"
#include "maps/proving_grounds.as"
#include "maps/pyroclast.as"
#include "maps/riverrun.as"
#include "maps/rosetta.as"
#include "maps/rustcrown_canyon.as"
#include "maps/salmiakki.as"
#include "maps/salt_reef.as"
#include "maps/scylla_and_charybdis.as"
#include "maps/sector_318c.as"
#include "maps/seven_rivers.as"
#include "maps/starwatcher.as"
#include "maps/stronghold.as"
#include "maps/sulphur_springs.as"
#include "maps/sunderance.as"
#include "maps/the_rock.as"
#include "maps/the_rock_jungle.as"
#include "maps/the_tartar_steppe.as"
#include "maps/thermal_shock.as"
#include "maps/twin_lakes_park_redux.as"
#include "maps/white_fire_remake.as"
#include "maps/tropical_assault.as"

namespace Maps {
    MapConfigManager@ mapManager = MapConfigManager(DEFAULT_MAP_CONFIG);

    void registerMaps() {
        GenericHelpers::LogUtil("Registering map configurations...", 1);
        
		// Initialize per-map extras (objectives, etc.) before registration
		SupremeIsthmus::registerObjectives();

		mapManager.RegisterMapConfig(SupremeIsthmus::config);
		mapManager.RegisterMapConfig(PinewoodDerby::config);
		mapManager.RegisterMapConfig(AllThatGlitters::config);
        mapManager.RegisterMapConfig(EightHorses::config);
        mapManager.RegisterMapConfig(FlatsAndForests::config);
        mapManager.RegisterMapConfig(GlacialGap::config);
        mapManager.RegisterMapConfig(Forge::config);
        mapManager.RegisterMapConfig(RedRiverEstuary::config);
        mapManager.RegisterMapConfig(SereneCaldera::config);
        mapManager.RegisterMapConfig(ShoreToShore::config);
        mapManager.RegisterMapConfig(SwirlyRock::config);
        mapManager.RegisterMapConfig(KoomValley::config);
        mapManager.RegisterMapConfig(AcidicQuarry::config);
        mapManager.RegisterMapConfig(Tempest::config);
        mapManager.RegisterMapConfig(TundraContinents::config);
        mapManager.RegisterMapConfig(RaptorCrater::config);
        mapManager.RegisterMapConfig(SinkholeNetwork::config);
        mapManager.RegisterMapConfig(AncientBastionRemake::config);
        mapManager.RegisterMapConfig(Mediterraneum::config);

        // popular16p pool and 12p-and-up maps
        mapManager.RegisterMapConfig(AllThatSimmers::config);
        mapManager.RegisterMapConfig(AllThatSmolders::config);
        mapManager.RegisterMapConfig(AngelCrossing::config);
        mapManager.RegisterMapConfig(Ascendancy::config);
        mapManager.RegisterMapConfig(AzuriteShores::config);
        mapManager.RegisterMapConfig(BaryonTarLake::config);
        mapManager.RegisterMapConfig(BismuthValley::config);
        mapManager.RegisterMapConfig(CarrotMountains::config);
        mapManager.RegisterMapConfig(Cells::config);
        mapManager.RegisterMapConfig(CoastlinesDry::config);
        mapManager.RegisterMapConfig(Darkside::config);
        mapManager.RegisterMapConfig(DeeploriaFields::config);
        mapManager.RegisterMapConfig(DeltaSiegeDry::config);
        mapManager.RegisterMapConfig(EntrenchedPlains::config);
        mapManager.RegisterMapConfig(ErebosLakes::config);
        mapManager.RegisterMapConfig(EskerCreek::config);
        mapManager.RegisterMapConfig(FailedNegotiations::config);
        mapManager.RegisterMapConfig(HadesPonds::config);
        mapManager.RegisterMapConfig(HellasBasin::config);
        mapManager.RegisterMapConfig(HeraPlanum::config);
        mapManager.RegisterMapConfig(HotlipsRemake::config);
        mapManager.RegisterMapConfig(IceScream::config);
        mapManager.RegisterMapConfig(KingsAssault::config);
        mapManager.RegisterMapConfig(KolmogorovRemake::config);
        mapManager.RegisterMapConfig(MariposaIsland::config);
        mapManager.RegisterMapConfig(MeltingGlacier::config);
        mapManager.RegisterMapConfig(Mescaline::config);
        mapManager.RegisterMapConfig(MoonshineRun::config);
        mapManager.RegisterMapConfig(NuclearWinterBar::config);
        mapManager.RegisterMapConfig(Otago::config);
        mapManager.RegisterMapConfig(PawnRetreat::config);
        mapManager.RegisterMapConfig(PinchPoint::config);
        mapManager.RegisterMapConfig(PlainsAndPasses::config);
        mapManager.RegisterMapConfig(ProjectSD129::config);
        mapManager.RegisterMapConfig(ProvingGrounds::config);
        mapManager.RegisterMapConfig(Pyroclast::config);
        mapManager.RegisterMapConfig(Riverrun::config);
        mapManager.RegisterMapConfig(Rosetta::config);
        mapManager.RegisterMapConfig(RustcrownCanyon::config);
        mapManager.RegisterMapConfig(Salmiakki::config);
        mapManager.RegisterMapConfig(SaltReef::config);
        mapManager.RegisterMapConfig(ScyllaAndCharybdis::config);
        mapManager.RegisterMapConfig(Sector318C::config);
        mapManager.RegisterMapConfig(SevenRivers::config);
        mapManager.RegisterMapConfig(Starwatcher::config);
        mapManager.RegisterMapConfig(Stronghold::config);
        mapManager.RegisterMapConfig(SulphurSprings::config);
        mapManager.RegisterMapConfig(Sunderance::config);
        mapManager.RegisterMapConfig(TheRock::config);
        mapManager.RegisterMapConfig(TheRockJungle::config);
        mapManager.RegisterMapConfig(TheTartarSteppe::config);
        mapManager.RegisterMapConfig(ThermalShock::config);
        mapManager.RegisterMapConfig(TwinLakesParkRedux::config);
        mapManager.RegisterMapConfig(WhiteFireRemake::config);
        mapManager.RegisterMapConfig(TropicalAssault::config);

        GenericHelpers::LogUtil("Finished registering map configurations: " +
            mapManager.mapConfigs.length() + " map configs available.", 1);
    }
}
