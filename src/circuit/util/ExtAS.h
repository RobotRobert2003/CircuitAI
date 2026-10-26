/*
 * ExtAS.h
 *
 *  Created on: Jul 7, 2026
 *      Author: rlcevg
 */

#ifndef SRC_CIRCUIT_UTIL_EXTAS_H_
#define SRC_CIRCUIT_UTIL_EXTAS_H_

#ifdef DEBUG
	#include <cassert>
	#define ASSERT(x)	assert(x)
#else
	#include <exception>
	// Registration failure is fatal in release builds too; do not rethrow an
	// unrelated active exception when registration runs during unwinding.
	#define ASSERT(x)	do { if (!(x)) std::terminate(); } while (false)
#endif

#define asMETHOD2PR(c,b,m,p,r) asSMethodPtr<sizeof(void (c::*)())>::Convert(AS_METHOD_AMBIGUITY_CAST(r (c::*)p)(&b::m))

#endif /* SRC_CIRCUIT_UTIL_EXTAS_H_ */
