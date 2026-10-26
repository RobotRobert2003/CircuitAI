/*
 * MultiQueue.hpp
 *
 *  Created on: Aug 28, 2014
 *      Author: rlcevg
 *      Origin: Juan Palacios (https://github.com/juanchopanza/cppblog/blob/master/Concurrency/Queue/Queue.h)
 */

#ifndef SRC_CIRCUIT_UTIL_MULTIQUEUE_H_
#	error "Don't include this file directly, include MultiQueue.h instead"
#endif

#include "util/MultiQueue.h"

namespace circuit {

template <typename T>
void CMultiQueue<T>::PushBefore(const T& item, ConditionFunction before)
{
    std::unique_lock<spring::mutex> lock(_mutex);
    auto it = _queue.begin();
    while (it != _queue.end() && !before(*it)) ++it;
    _queue.insert(it, item);
    lock.unlock();
    _cond.notify_one();
}

template <typename T>
T CMultiQueue<T>::Pop()
{
	std::unique_lock<spring::mutex> mlock(_mutex);
	while (_queue.empty()) {
		_cond.wait(mlock);
	}

	auto val = _queue.front();
	_queue.pop_front();
	return val;
}

template <typename T>
void CMultiQueue<T>::Pop(T& item)
{
	std::unique_lock<spring::mutex> mlock(_mutex);

	_cond.wait(mlock, [this]() { return !_queue.empty(); });

	item = _queue.front();
	_queue.pop_front();
}

template <typename T>
void CMultiQueue<T>::PushBack(const T& item)
{
	std::unique_lock<spring::mutex> mlock(_mutex);
	_queue.push_back(item);
	mlock.unlock();
	_cond.notify_one();
}

template <typename T>
void CMultiQueue<T>::PushFront(const T& item)
{
	std::unique_lock<spring::mutex> mlock(_mutex);
	_queue.push_front(item);
	mlock.unlock();
	_cond.notify_one();
}

template <typename T>
bool CMultiQueue<T>::IsEmpty()
{
	std::lock_guard<spring::mutex> mlock(_mutex);
	return _queue.empty();
}

template <typename T>
size_t CMultiQueue<T>::Size()
{
	std::lock_guard<spring::mutex> mlock(_mutex);
	return _queue.size();
}

template <typename T>
bool CMultiQueue<T>::PopAndProcess(ProcessFunction process)
{
	std::unique_lock<spring::mutex> mlock(_mutex);
	if (!_queue.empty()) {
		auto item = _queue.front();
		_queue.pop_front();
		mlock.unlock();
		process(item);
		return true;
	}
	return false;
}

template <typename T>
void CMultiQueue<T>::PopAndProcessAll(ProcessFunction process)
{
	std::unique_lock<spring::mutex> mlock(_mutex);
	while (!_queue.empty()) {
		auto item = _queue.front();
		_queue.pop_front();
//		mlock.unlock();
		process(item);
//		mlock.lock();
	}
}

template <typename T>
void CMultiQueue<T>::RemoveAllIf(ConditionFunction condition)
{
	std::lock_guard<spring::mutex> mlock(_mutex);
	// Indices survive swap/pop, including removal of the final element.
	// Keep the original unordered removal and predicate evaluation order.
	std::size_t index = 0;
	while (index < _queue.size()) {
		if (condition(_queue[index])) {
			_queue[index] = _queue.back();
			_queue.pop_back();
		} else {
			++index;
		}
	}
}

template <typename T>
void CMultiQueue<T>::Clear()
{
	std::lock_guard<spring::mutex> mlock(_mutex);
	_queue.clear();
}

} // namespace circuit
