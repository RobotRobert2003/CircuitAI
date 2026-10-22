// A 8,100 M / 178,500 BP project needs 956.4 BP to spend +43.4 M/s.
void test_nuke_refund_keeps_income_spending() { Check(NukeMath::RefundHasSparePower(43.4f,8100,178500,1740,300)); }
void test_nuke_refund_allows_short_local_approach() { Check(NukeMath::LocalRefundWorker(154*154,145,64)); Check(!NukeMath::LocalRefundWorker(154*154,145,0)); }
void test_nuke_refund_rejects_distant_or_invalid_worker() { Check(!NukeMath::LocalRefundWorker(210*210,145,64)); Check(!NukeMath::LocalRefundWorker(-1,145,64)); Check(!NukeMath::LocalRefundWorker(0,0,64)); }
void test_nuke_refund_cannot_remove_needed_assistance() { Check(!NukeMath::RefundHasSparePower(43.4f,8100,178500,1200,300)); }
void test_nuke_refund_accounts_for_donated_income() { Check(!NukeMath::RefundHasSparePower(100,8100,178500,1740,300)); }
void test_nuke_refund_exact_budget_boundary() { Check(NukeMath::RefundHasSparePower(10,100,1000,160,60)); Check(!NukeMath::RefundHasSparePower(10,100,1000,159,60)); }
void test_nuke_refund_invalid_cost_fails_closed() { Check(!NukeMath::RefundHasSparePower(10,0,1000,160,60)); Check(!NukeMath::RefundHasSparePower(-1,100,1000,160,60)); }
void test_nuke_budget_ends_on_actual_stockpile() { Check(!NukeMath::KeepFirstStockpileBudget(true,1,200,900)); Check(NukeMath::KeepFirstStockpileBudget(true,0,899,900)); }
void test_nuke_budget_cannot_latch_after_loss_or_timeout() { Check(!NukeMath::KeepFirstStockpileBudget(false,0,200,900)); Check(!NukeMath::KeepFirstStockpileBudget(true,0,900,900)); }
