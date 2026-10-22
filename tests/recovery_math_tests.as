void test_opening_is_not_a_loss() {
    Check(!RecoveryMath::NeedsRequest(0,false,true,false,1,1800));
    Check(!RecoveryMath::NeedsRequest(0,false,true,false,99999,1800));
}
void test_any_role_can_recover_while_commander_survives() {
    Check(RecoveryMath::NeedsRequest(0,true,true,false,900,1800));
    Check(!RecoveryMath::NeedsRequest(0,true,true,true,900,1800));
}
void test_last_constructor_of_either_tier_prevents_request() {
    Check(!RecoveryMath::NeedsRequest(1,true,false,false,99999,1800));
    Check(!RecoveryMath::NeedsRequest(12,true,true,false,99999,1800));
}
void test_commander_lost_before_first_constructor_recovers_after_grace() {
    Check(!RecoveryMath::NeedsRequest(0,false,false,false,1799,1800));
    Check(RecoveryMath::NeedsRequest(0,false,false,false,1800,1800));
}
void test_heartbeat_does_not_poll_every_frame() {
    Check(RecoveryMath::Due(30,-1,600));
    Check(!RecoveryMath::Due(629,30,600));
    Check(RecoveryMath::Due(630,30,600));
}
void test_late_heartbeat_cannot_resurrect_cancelled_episode() {
    Check(RecoveryMath::AcceptEpisode(900,-1));
    Check(!RecoveryMath::AcceptEpisode(900,900));
    Check(!RecoveryMath::AcceptEpisode(899,900));
    Check(RecoveryMath::AcceptEpisode(901,900));
    Check(!RecoveryMath::AcceptEpisode(-1,-1));
}
