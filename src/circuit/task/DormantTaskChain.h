#ifndef CIRCUIT_DORMANT_TASK_CHAIN_H
#define CIRCUIT_DORMANT_TASK_CHAIN_H

namespace circuit {

// The chain owns each dormant link's initial reference, not its whole lifetime:
// TaskAdded can expose that link to script before activation. Detach and mark
// every abandoned link dead before releasing ownership. Retained handles remain
// readable until their own Release. No manager callbacks during destruction.
// O(links), O(1) scratch/stack; avoids recursive deletion of long chains.
// Regression: dormant_task_chain_test (retention, activation and cancellation).
template<class Task>
void ReleaseDormantTaskChain(Task*& head)
{
    while (head != nullptr) {
        Task* current = head;
        head = current->GetNextTask();
        current->SetNextTask(nullptr);
        current->Dead();
        current->ClearRelease();
    }
}

} // namespace circuit

#endif
