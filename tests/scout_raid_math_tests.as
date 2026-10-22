void test_score_prefers_weight_cost_depth_and_proximity() {
    Check(ScoutRaidMath::Score(0,500,3,0)==0);
    Check(ScoutRaidMath::Score(-1,500,3,0)==0);
    Check(ScoutRaidMath::Score(4,100,1,1000)>ScoutRaidMath::Score(3,100,1,1000));
    Check(ScoutRaidMath::Score(3,200,1,1000)>ScoutRaidMath::Score(3,100,1,1000));
    Check(ScoutRaidMath::Score(3,100,2,1000)>ScoutRaidMath::Score(3,100,1,1000));
    Check(ScoutRaidMath::Score(3,100,1,500)>ScoutRaidMath::Score(3,100,1,1000));
    Check(ScoutRaidMath::Score(3,-50,1,-10)==ScoutRaidMath::Score(3,0,1,0));
}
void test_rear_is_bounded_and_monotone() {
    Check(ScoutRaidMath::Rear(-1,-1)==1);
    Check(ScoutRaidMath::Rear(0,-1)==2);
    Check(ScoutRaidMath::Rear(0,3000)==3);
    Check(ScoutRaidMath::Rear(0,100000)==3);
    Check(ScoutRaidMath::Rear(500,0)>ScoutRaidMath::Rear(5000,0));
    Check(ScoutRaidMath::Rear(1000,2000)>ScoutRaidMath::Rear(1000,1000));
}
void test_compaction_keeps_turns_reversals_and_spacing() {
    Check(!ScoutRaidMath::Keep(64,0,64,0,64,192));     // straight, short
    Check(ScoutRaidMath::Keep(64,0,64,0,192,192));     // spacing reached
    Check(ScoutRaidMath::Keep(64,0,64,64,64,192));     // diagonal turn
    Check(ScoutRaidMath::Keep(64,0,-64,0,64,192));     // reversal
    Check(!ScoutRaidMath::Keep(64,64,64,64,128,192));  // straight diagonal
}
void test_hazard_overdue_only_without_a_queued_replan() {
    Check(!ScoutRaidMath::HazardOverdue(-1,1000,120,60,false));
    Check(!ScoutRaidMath::HazardOverdue(0,180,120,60,false));
    Check(ScoutRaidMath::HazardOverdue(0,181,120,60,false));
    Check(!ScoutRaidMath::HazardOverdue(0,10000,120,60,true));
}
