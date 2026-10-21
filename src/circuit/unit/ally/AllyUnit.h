/*
 * AllyUnit.h
 *
 *  Created on: Nov 10, 2017
 *      Author: rlcevg
 */

#ifndef SRC_CIRCUIT_UNIT_ALLY_ALLYUNIT_H_
#define SRC_CIRCUIT_UNIT_ALLY_ALLYUNIT_H_

#include "unit/CoreUnit.h"
#include <cstdint>

namespace circuit {

class CCircuitDef;
class IUnitTask;

class CAllyUnit: public ICoreUnit {
public:
	CAllyUnit(const CAllyUnit& that) = delete;
	CAllyUnit& operator=(const CAllyUnit&) = delete;
	CAllyUnit(Id unitId, springai::Unit* unit, CCircuitDef* cdef);
	virtual ~CAllyUnit();

	CCircuitDef* GetCircuitDef() const { return circuitDef; }
	IUnitTask* GetTask() const { return task; }
	IUnitTask* GetLiveTask() const;
	const springai::AIFloat3& GetPos(int frame);
	const springai::AIFloat3& GetLastPos() const { return position; }

protected:
	bool SetOwnedTask(IUnitTask* replacement);
	CCircuitDef* circuitDef;
	IUnitTask* task;  // nullptr - ally or no handler (unable to control).
	std::uint64_t taskGeneration = 0;

	int posFrame;
	springai::AIFloat3 position;
};

} // namespace circuit

#endif // SRC_CIRCUIT_UNIT_ALLY_ALLYUNIT_H_
