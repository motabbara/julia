function _tablesz(i::Int)
    if i < 16
        return 16
    end
    if i&(i-1) == 0
        return i
    end
    while (i&(i-1) != 0)
        i = i&(i-1)
    end
    return i<<1
end

type IdTable
    ht::Array{Any,1}
    IdTable(sz::Int) = new(cell(2*_tablesz(sz)))
    IdTable() = IdTable(0)
end

idtable(sz::Int) = IdTable(sz)
idtable() = IdTable(0)

function assign(t::IdTable, v::ANY, k::ANY)
    t.ht = ccall(:jl_eqtable_put,
                 Any, (Any, Any, Any), t.ht, k, v)::Array{Any,1}
    t
end

get(t::IdTable, key::ANY, default::ANY) =
    ccall(:jl_eqtable_get, Any, (Any, Any, Any), t.ht, key, default)

del(t::IdTable, key::ANY) =
    (ccall(:jl_eqtable_del, Int32, (Any, Any), t.ht, key); t)

del_all(t::IdTable) = (t.ht = cell(length(t.ht)); t)

_secret_table_token_ = (:BOO,)

start(t::IdTable) = 0
done(t::IdTable, i) = is(next(t,i),())
next(t::IdTable, i) = ccall(:jl_eqtable_next, Any, (Any, Uint32), t.ht, uint32(i))

isempty(t::IdTable) = is(next(t,0),())

# hashing

bitmix(a::Union(Int32,Uint32), b::Union(Int32,Uint32)) =
    ccall(:int64to32hash, Uint32, (Uint64,),
          or_int(shl_int(zext64(unbox32(a)),unbox32(32)), zext64(unbox32(b))))

bitmix(a::Union(Int64,Uint64), b::Union(Int64, Uint64)) =
    ccall(:int64hash, Uint64, (Uint64,),
          xor_int(unbox64(a), or_int(lshr_int(unbox64(b),unbox32(32)),
                                     shl_int(unbox64(b),unbox32(32)))))

_jl_hash64(x::Union(Int64,Uint64,Float64)) =
    ccall(:int64hash, Uint64, (Uint64,), boxui64(unbox64(x)))

hash(x::Float64) = isnan(x) ? _jl_hash64(NaN) : _jl_hash64(x)
hash(x::Float32) = hash(float64(x))

function hash(x::Int)
    const m = int(maxintfloat())
    !isfinite(x) || -m <= x <= m ? hash(float64(x)) : _jl_hash64(x)
end

hash(s::Symbol) = ccall(:jl_hash_symbol, Ulong, (Any,), s)

function hash(t::Tuple)
    h = int64(0)
    for i=1:length(t)
        h = bitmix(h,hash(t[i]))
    end
    h
end

function hash(a::Array)
    h = hash(size(a))+1
    for i=1:length(a)
        h = bitmix(h,hash(a[i]))
    end
    h
end

hash(x::Any) = uid(x)
hash(s::ByteString) = ccall(:memhash32, Uint32, (Ptr{Void}, Size), s.data, length(s.data))

# hash table

type HashTable{K,V}
    keys::Array{K,1}
    vals::Array{V,1}
    used::IntSet
    deleted::IntSet
    deleter::Function

    HashTable() = HashTable{K,V}(0)
    HashTable(n) = (n = _tablesz(n);
                    new(Array(K,n), Array(V,n), IntSet(n+1), IntSet(n+1),
                        identity))
    function HashTable(ks::Tuple, vs::Tuple)
        n = length(ks)
        h = HashTable{K,V}(n)
        for i=1:n
            h[ks[i]] = vs[i]
        end
        return h
    end
end
HashTable() = HashTable(0)
HashTable(n::Int) = HashTable{Any,Any}(n)

# syntax entry point
hashtable{K,V}(ks::(K...), vs::(V...)) = HashTable{K,V}    (ks, vs)
hashtable{K}  (ks::(K...), vs::Tuple ) = HashTable{K,Any}  (ks, vs)
hashtable{V}  (ks::Tuple , vs::(V...)) = HashTable{Any,V}  (ks, vs)
hashtable     (ks::Tuple , vs::Tuple)  = HashTable{Any,Any}(ks, vs)

hashindex(key, sz) = (long(hash(key)) & (sz-1)) + 1

function rehash{K,V}(h::HashTable{K,V}, newsz)
    oldk = h.keys
    oldv = h.vals
    oldu = h.used
    oldd = h.deleted
    newht = HashTable{K,V}(newsz)

    for i = oldu
        if !has(oldd,i)
            newht[oldk[i]] = oldv[i]
        end
    end

    h.keys = newht.keys
    h.vals = newht.vals
    h.used = newht.used
    h.deleted = newht.deleted
    h
end

function del_all{K,V}(h::HashTable{K,V})
    sz = length(h.keys)
    newht = HashTable{K,V}(sz)
    h.keys = newht.keys
    h.vals = newht.vals
    h.used = newht.used
    h.deleted = newht.deleted
    h
end

function assign{K,V}(h::HashTable{K,V}, v, key)
    sz = length(h.keys)

    if numel(h.deleted) >= ((3*sz)>>2)
        rehash(h, sz)
    end

    iter = 0
    maxprobe = sz>>3
    index = hashindex(key, sz)
    orig = index

    while true
        if !has(h.used,index)
            h.keys[index] = key
            h.vals[index] = v
            add(h.used, index)
            return h
        end
        if has(h.deleted,index)
            h.keys[index] = key
            h.vals[index] = v
            del(h.deleted, index)
            return h
        end

        if isequal(key, h.keys[index])
            h.vals[index] = v
            return h
        end

        index = (index & (sz-1)) + 1
        iter+=1
        if iter > maxprobe || index==orig
            break
        end
    end

    rehash(h, sz*2)

    assign(h, v, key)
end

# get the index where a key is stored, or -1 if not present
function ht_keyindex(h::HashTable, key)
    sz = length(h.keys)
    iter = 0
    maxprobe = sz>>3
    index = hashindex(key, sz)
    orig = index

    while true
        if !has(h.used,index)
            break
        end
        if !has(h.deleted,index) && isequal(key, h.keys[index])
            return index
        end

        index = (index & (sz-1)) + 1
        iter+=1
        if iter > maxprobe || index==orig
            break
        end
    end

    return -1
end

function get(h::HashTable, key, deflt)
    index = ht_keyindex(h, key)
    return (index<0) ? deflt : h.vals[index]
end

function key(h::HashTable, key, deflt)
    index = ht_keyindex(h, key)
    return (index<0) ? deflt : h.keys[index]
end

function del(h::HashTable, key)
    index = ht_keyindex(h, key)
    if index > 0
        add(h.deleted, index)
    end
    h
end

function skip_deleted(used, deleted, i)
    while !done(used, i)
        (i, ip1) = next(used, i)
        if !has(deleted,i)
            break
        end
        i = ip1
    end
    return i
end

start(t::HashTable) = skip_deleted(t.used, t.deleted, 0)
done(t::HashTable, i) = done(t.used, i)
next(t::HashTable, i) = ((n, nxt) = next(t.used, i);
                         ((t.keys[n],t.vals[n]),
                          skip_deleted(t.used,t.deleted,nxt)))

isempty(t::HashTable) = done(t, start(t))
length(t::HashTable) = length(t.used)-length(t.deleted)

function ref(t::Union(IdTable,HashTable), key)
    v = get(t, key, _secret_table_token_)
    if is(v,_secret_table_token_)
        throw(KeyError(key))
    end
    return v
end

has(t::Union(IdTable,HashTable), key) =
    !is(get(t, key, _secret_table_token_),
        _secret_table_token_)

function add_weak_key(t::HashTable, k, v)
    if is(t.deleter, identity)
        t.deleter = x->del(t, x)
    end
    t[WeakRef(k)] = v
    finalizer(k, t.deleter)
    t
end

function add_weak_value(t::HashTable, k, v)
    t[k] = WeakRef(v)
    finalizer(v, x->del(t, k))
    t
end

function show(t::Union(IdTable,HashTable))
    if isempty(t)
        print(typeof(t).name.name,"()")
    else
        print("{")
        for (k, v) = t
            show(k)
            print("=>")
            show(v)
            print(",")
        end
        print("}")
    end
end

type WeakKeyHashTable{K,V}
    ht::HashTable{K,V}

    WeakKeyHashTable() = new(HashTable{K,V}())
end
WeakKeyHashTable() = WeakKeyHashTable{Any,Any}()

assign(wkh::WeakKeyHashTable, v, key) = add_weak_key(wkh.ht, key, v)

function key(wkh::WeakKeyHashTable, kk, deflt)
    k = key(wkh.ht, kk, _secret_table_token_)
    if is(k, _secret_table_token_)
        return deflt
    end
    return k.value
end

get(wkh::WeakKeyHashTable, key, deflt) = get(wkh.ht, key, deflt)
del(wkh::WeakKeyHashTable, key) = del(wkh.ht, key)
del_all(wkh::WeakKeyHashTable)  = (del_all(wkh.ht); wkh)
has(wkh::WeakKeyHashTable, key) = has(wkh.ht, key)
ref(wkh::WeakKeyHashTable, key) = ref(wkh.ht, key)
isempty(wkh::WeakKeyHashTable) = isempty(wkh.ht)

start(t::WeakKeyHashTable) = start(t.ht)
done(t::WeakKeyHashTable, i) = done(t.ht, i)
next(t::WeakKeyHashTable, i) = next(t.ht, i)
