

// get(?&out) may use a conversion temporary. A failed lookup does not promise
// to preserve the caller's initializer; choose the fallback AFTER the call.
// One read-only lookup: expected O(1) with the shipped C++11 hash dictionary
// (linear worst case); older map-backed add-on builds use O(log N).
int DictIntOr(const dictionary &in d, const string &in key, int fallback=0)
{
    int value=0;
    return d.get(key,value) ? value : fallback;
}
