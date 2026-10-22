void test_sustained_income_is_required_and_energy_stall_blocks() {
    Check(SpamMath::Funded(60,1500,false,false,0,60,1500,30,1000,false,.7f));
    Check(!SpamMath::Funded(59,1500,false,false,0,60,1500,30,1000,false,.7f));
    Check(!SpamMath::Funded(60,1499,false,false,0,60,1500,30,1000,false,.7f));
    Check(!SpamMath::Funded(600,15000,true,true,10000,60,1500,30,1000,true,.7f));
}
void test_donations_do_not_require_positive_net_income() {
    Check(SpamMath::Funded(30,1500,false,true,1000,60,1500,30,1000,false,.7f));
    Check(!SpamMath::Funded(30,1500,false,true,999,60,1500,30,1000,false,.7f));
    Check(!SpamMath::Funded(29,1500,false,true,10000,60,1500,30,1000,false,.7f));
}
void test_hysteresis_and_factory_scaling_boundaries() {
    Check(SpamMath::Funded(42,1050,false,false,0,60,1500,30,1000,true,.7f));
    Check(!SpamMath::Funded(41,1050,false,false,0,60,1500,30,1000,true,.7f));
    Check(SpamMath::Labs(59,60,100,6)==0);
    Check(SpamMath::Labs(60,60,100,6)==1);
    Check(SpamMath::Labs(159,60,100,6)==1);
    Check(SpamMath::Labs(160,60,100,6)==2);
    Check(SpamMath::Labs(10000,60,100,6)==6);
    Check(SpamMath::Labs(10000,60,0,6)==0);
}
