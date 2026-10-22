void test_small_screen_stays_over_tech() {
    Check(AirPerimeterMath::CrossCoordinate(4000,12000,128,600,0,0)==3700);
    Check(AirPerimeterMath::CrossCoordinate(4000,12000,128,600,0,1)==4300);
}
void test_map_edge_contains_the_entire_threat_capsule() {
    Check(AirPerimeterMath::SafeInset(128,192)==193);
    Check(AirPerimeterMath::SafeInset(256,192)==256);
    Check(AirPerimeterMath::SafeInset(192,192)>192);
}
void test_mature_screen_reaches_both_map_edges() {
    Check(AirPerimeterMath::CrossCoordinate(900,15360,128,600,1,0)==128);
    Check(AirPerimeterMath::CrossCoordinate(900,15360,128,600,1,1)==15232);
}
void test_adjacent_sectors_share_exact_vertices() {
    for (int index=0;index<8;++index) {
        float left=AirPerimeterMath::CrossCoordinate(600,3072,128,600,1,float(index)/8);
        float right=AirPerimeterMath::CrossCoordinate(600,3072,128,600,1,float(index+1)/8);
        Check(right>left && right-left==352);
    }
}
void test_growth_remains_inside_map_for_edge_tech() {
    for (int step=0;step<=10;++step) for (int index=0;index<=8;++index) {
        float point=AirPerimeterMath::CrossCoordinate(0,1024,128,600,float(step)/10,float(index)/8);
        Check(point>=128 && point<=896);
    }
}
void test_visibility_flicker_and_small_advances_do_not_reissue_patrols() {
    Check(AirPerimeterMath::StableAdvance(2000,400,384,true)==2000);
    Check(AirPerimeterMath::StableAdvance(2000,2300,384,true)==2000);
    Check(AirPerimeterMath::StableAdvance(2000,2500,384,true)==2500);
    Check(AirPerimeterMath::StableAdvance(2000,400,384,false)==400);
}
void test_unsafe_proposal_retains_prior_line_without_blocking_threat_retreat() {
    Check(AirPerimeterMath::RejectUnsafeAdvance(2000,3000,true)==2000);
    Check(AirPerimeterMath::RejectUnsafeAdvance(2000,3000,false)==3000);
    Check(AirPerimeterMath::RejectUnsafeAdvance(2000,1488,true)==1488);
    Check(AirPerimeterMath::RejectUnsafeAdvance(-112,400,true)==-112);
    // Varying LOS candidates must not create varying safe fallback positions.
    for (int candidate=2400;candidate<5000;candidate+=137)
        Check(AirPerimeterMath::RejectUnsafeAdvance(2000,float(candidate),true)==2000);
}
