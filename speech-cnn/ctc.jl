# using Flux: gpu
using CuArrays
using Memoize

function ctc(ŷ, y)

    """
        logadd(a, b)

    Adds log-space `a` and `b` such that the result equals `log(exp(a)+exp(b))`

    Currently, it relies on the fact that `exp(-Inf)` is 0 to handle when `a` or
    `b`  is 0s, which is less than ideal because that behavior of `log(0)` that
    produced the ``-Inf` value may not always be defined as such.
    """
    function logadd(a, b)
        if isinf(a) || isinf(b)
            return log(exp(a) + exp(b))
        end
        return a + log(1+exp(b-a))
    end

    """
        logsum(a)

    Sums the elements in `a` such that the result equals `log(sum(exp.(a)))`
    """
    function logsum(a)
        local s
        s = a[1]
        for item in a[2:end]
            s = logadd(s, item)
        end
        return s
    end

    """
        F(A)

    Removes blanks and repetitions in the sequence `A`

    This is the function `F` as defined in Graves (2012)
    """
    function F(A)
        prev = A[1]
        z = [prev]
        for curr in A[2:end]
            if curr != prev && curr != blank
                push!(z, curr)
    ``        end
            prev = curr
        end
        return z
    end

    """
        addBlanks(z)

    Adds blanks to the start and end of `z`, and between item in `z`
    """
    function addBlanks(z)

        z′ = [blank]
        for label in z
            push!(z′, label)
            push!(z′, blank)
        end
        return z′
    end

    blank = length(ŷ[1])

    lgŷ = [CUDAnative.log.(ŷI) for ŷI in ŷ]
    z = F(indmax.(y))
    z′ = addBlanks(z)
    T = length(ŷ)
    U′ = length(z′)

    """
        α(t, u)

    Calculates the α coefficient for time `t` and label `u`
    """
    @memoize function α(t, u)

        if t == u == 1
            return lgŷ[t][blank]
        end

        if t == 1 && u == 2
            return lgŷ[t][Flux.Tracker.data(z[1])]
        end

        if t == 1 && u > 2
            return log(0)
        end

        if u < U′ - 2(T - t) - 1
            return log(0)
        end

        idx = u - 2
        idx += z′[u] == blank || (u > 2 && z′[u-2] == z′[u])
        idx = max(1, idx)

        vals = [α(t-1, i) for i=idx:u]

        return lgŷ[t][Flux.Tracker.data(z′[u])] + logsum(vals)
    end

    """
        β(t, u)

    Calculates the β coefficient at time `t` and label `u`
    """
    @memoize function β(t, u)
        if t == T && u >= U′ -1
            return log(1)
        end

        if t == T && u < U′ - 1
            return log(0)
        end

        if u > 2t || u > U′ + 1
            return log(0)
        end

        idx = u+2
        idx -= z′[u] == blank || (idx < U′ && z′[u+2] == z′[u])
        idx = min(idx, U′)

        vals = [β(t+1, i) + lgŷ[t+1][Flux.Tracker.data(z′[i])] for i=u:idx]

        return logsum(vals)
    end

    s = logsum([α(1, u) + β(1, u) for u in 1:U′])
    for t=2:length(ŷ)
        s += logsum([α(t, u) + β(t, u) for u in 1:U′])
    end

    s = -s
    return s
end
