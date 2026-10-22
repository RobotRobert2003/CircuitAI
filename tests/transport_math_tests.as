void test_transport_pool_follows_income_and_retains_capacity() {
    Check(TransportMath::DesiredCount(19,20,40,100,0) == 0);
    Check(TransportMath::DesiredCount(20,20,40,100,0) == 1);
    Check(TransportMath::DesiredCount(139,20,40,100,1) == 1);
    Check(TransportMath::DesiredCount(140,20,40,100,1) == 2);
    Check(TransportMath::DesiredCount(340,20,40,100,2) == 4);
    Check(TransportMath::DesiredCount(10,20,40,100,4) == 4);
    Check(TransportMath::DesiredCount(500,20,40,0,2) == 2);
}
void test_transport_arrival_does_not_transfer_loaded_cargo() {
    Check(TransportMath::Arrived(240*240,240,false));
    Check(!TransportMath::Arrived(241*241,240,false));
    Check(!TransportMath::Arrived(0,240,true));
    Check(!TransportMath::Arrived(0,0,false));
}
