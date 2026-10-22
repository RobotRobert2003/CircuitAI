/*
 * FactoryTask.h
 *
 *  Created on: Jan 30, 2015
 *      Author: rlcevg
 */

#ifndef SRC_CIRCUIT_TASK_FACTORYTASK_H_
#define SRC_CIRCUIT_TASK_FACTORYTASK_H_

#include "task/builder/BuilderTask.h"

namespace circuit {

class CBFactoryTask final: public IBuilderTask {
public:
	CBFactoryTask(ITaskModule* mgr, Priority priority,
				  CCircuitDef* buildDef, CCircuitDef* reprDef, const springai::AIFloat3& position,
				  SResource cost, float shake, bool isPlop, int timeout);
	CBFactoryTask(ITaskModule* mgr);  // Load
	virtual ~CBFactoryTask();

	CCircuitDef* GetReprDef() const { return reprDef; }
	bool IsPlop() const { return isPlop; }
	void PreferFacing(int value) { preferredFacing = value >= 0 && value < 4 ? value : -1; }
	void SetPosition(const springai::AIFloat3& pos) { position = pos; }

	virtual void Start(CCircuitUnit* unit) override;
	virtual void Update() override;
protected:
	virtual void Cancel() override;

public:
	virtual void Activate() override;

private:
	virtual void FindBuildSite(CCircuitUnit* builder, const springai::AIFloat3& pos, float searchRadius) override;

	virtual bool Load(std::istream& is) override;
	virtual void Save(std::ostream& os) const override;

	CCircuitDef* reprDef;
	bool isPlop;
	int preferredFacing = -1; // transient script preference, opening yard only
};

} // namespace circuit

#endif // SRC_CIRCUIT_TASK_FACTORYTASK_H_
