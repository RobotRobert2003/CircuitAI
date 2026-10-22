void test_dictionary_integer_miss_and_conversion_do_not_invent_coverage() {
    dictionary counts;
    for (int i=0;i<1000;++i) {
        counts.set("other",123456789);
        Check(DictIntOr(counts,"missing")==0);
        Check(DictIntOr(counts,"missing",-1)==-1);
        counts.set("hull",DictIntOr(counts,"hull")+1);
        Check(DictIntOr(counts,"hull")==i+1);
    }
    counts.delete("hull");
    Check(DictIntOr(counts,"hull")==0);
    counts.set("wrong type","not an integer");
    Check(DictIntOr(counts,"wrong type",7)==7);
}
