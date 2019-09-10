abstract type AbstractFixedEffectMatrix end

"""

Solve a least square problem for a set of FixedEffects

`solve_residuals!(y, fes, weights; method = :lsmr, maxiter = 10000, tol = 1e-8)`

### Arguments
* `y` : A `AbstractVector`
* `fes`: A `Vector{<:FixedEffect}`
* `weights`: A `AbstractWeights`
* `method` : A `Symbol` for the method. Choices are :lsmr, :lsmr_threads, :lsmr_parallel, :qr and :cholesky
* `maxiter` : Maximum number of iterations
* `tol` : Tolerance


### Returns
* `res` :  Residual of the least square problem
* `iterations`: Number of iterations
* `converged`: Did the algorithm converge?

### Examples
```julia
using  FixedEffects
p1 = repeat(1:5, inner = 2)
p2 = repeat(1:5, outer = 2)
solve_residuals!(rand(10), [FixedEffect(p1), FixedEffect(p2)])
solve_residuals!(rand(10, 5), [FixedEffect(p1), FixedEffect(p2)])
```
"""
function solve_residuals!(y::Union{AbstractVector, AbstractMatrix}, fes::Vector{<: FixedEffect}, weights::AbstractWeights = Weights(Ones{eltype(y)}(size(y, 1))); method::Symbol = :lsmr, maxiter::Integer = 10000, tol::Real = 1e-8)
    any(ismissing.(fes)) && error("Some FixedEffect has a missing value for reference or interaction")
    sqrtw = sqrt.(weights.values)
    y .= y .* sqrtw
    fep = FixedEffectMatrix(fes, sqrtw, Val{method})
    y, iteration, converged = solve_residuals!(y, fep; maxiter = maxiter, tol = tol)
    y .= y ./ sqrtw
    return y, iteration, converged
end

##############################################################################
##
## Get fixed effects
##
## Fixed effects are generally not identified
## We standardize the solution in the following way :
## Mean within connected component of all fixed effects except the first
## is zero
##
## Unique solution with two components, not really with more
##
## Connected component : Breadth-first search
## components is an array of component
## A component is an array of set (length is number of values taken)
##
##############################################################################

"""
Solve a least square problem for a set of FixedEffects

`solve_coefficients!(y, fes, weights; method = :lsmr, maxiter = 10000, tol = 1e-8)`

### Arguments
* `y` : A `AbstractVector` 
* `fes`: A `Vector{<:FixedEffect}`
* `weights`: A `AbstractWeights`
* `method` : A `Symbol` for the method. Choices are :lsmr, :lsmr_threads, :lsmr_parallel, :qr and :cholesky
* `maxiter` : Maximum number of iterations
* `tol` : Tolerance


### Returns
* `b` : Solution of the least square problem
* `iterations`: Number of iterations
* `converged`: Did the algorithm converge?

### Examples
```julia
using  FixedEffects
p1 = repeat(1:5, inner = 2)
p2 = repeat(1:5, outer = 2)
x = rand(10)
solve_coefficients!(rand(10), [FixedEffect(p1), FixedEffect(p2)])
```
"""
function solve_coefficients!(y::AbstractVector, fes::Vector{<: FixedEffect}, weights::AbstractWeights  = Weights(Ones{eltype(y)}(length(y))); method::Symbol = :lsmr, maxiter::Integer = 10000, tol::Real = 1e-8)
    any(ismissing.(fes)) && error("Some FixedEffect has a missing value for reference or interaction")
    sqrtw = sqrt.(weights.values)
    y .= y .* sqrtw
    fep = FixedEffectMatrix(fes, sqrtw, Val{method})
    newfes, iteration, converged = solve_coefficients!(y, fep; maxiter = maxiter, tol = tol)
    return newfes, iteration, converged
end



function solve_coefficients!(b::AbstractVector, fep::AbstractFixedEffectMatrix; kwargs...)
    # solve Ax = b
    x, iterations, converged = _solve_coefficients!(b, fep; kwargs...)
    if !converged 
       warn("getfe did not converge")
    end
    # The solution is generally not unique. Find connected components and scale accordingly
    findintercept = findall(fe -> isa(fe.interaction, Ones), get_fes(fep))
    if length(findintercept) >= 2
        components = connectedcomponent(view(get_fes(fep), findintercept))
        rescale!(x, fep, findintercept, components)
    end

    fes = get_fes(fep)
    newfes = [zeros(length(b)) for j in 1:length(fes)]
    for j in 1:length(fes)
        newfes[j] = x[j][fes[j].refs]
    end
    return newfes, iterations, converged
end


function connectedcomponent(fes::AbstractVector{<:FixedEffect})
    # initialize
    where = initialize_where(fes)
    refs = initialize_refs(fes)
    nobs = size(refs, 2)
    visited = fill(false, nobs)
    components = Vector{Set{Int}}[]
    # start
    for i in 1:nobs
        if !visited[i]
            component = Set{Int}[Set{Int}() for fe in fes]
            connectedcomponent!(component, visited, i, refs, where)
            push!(components, component)
        end
    end
    return components
end

function initialize_where(fes::AbstractVector{<:FixedEffect})
    where = Vector{Set{Int}}[]
    for j in 1:length(fes)
        fe = fes[j]
        wherej = Set{Int}[Set{Int}() for i in 1:fe.n]
        for i in 1:length(fe.refs)
            push!(wherej[fe.refs[i]], i)
        end
        push!(where, wherej)
    end
    return where
end

function initialize_refs(fes::AbstractVector{<:FixedEffect})
    nobs = length(fes[1].refs)
    refs = fill(zero(Int), length(fes), nobs)
    for j in 1:length(fes)
        refs[j, :] = fes[j].refs
    end
    return refs
end

# Breadth-first search
function connectedcomponent!(component::Vector{Set{N}}, visited::Vector{Bool}, 
    i::Integer, refs::AbstractMatrix{N}, where::Vector{Vector{Set{N}}})  where {N}
    tovisit = Set{N}(i)
    while !isempty(tovisit)
        i = pop!(tovisit)
        visited[i] = true
        # for each fixed effect
        for j in 1:size(refs, 1)
            ref = refs[j, i]
            # if category has not been encountered
            if !(ref in component[j])
                # mark category as encountered
                push!(component[j], ref)
                # add other observations with same component in list to visit
                for k in where[j][ref]
                    if !visited[k]
                        push!(tovisit, k)
                    end
                end
            end
        end
    end
end

function rescale!(fev::Vector{Vector{T}}, fep::AbstractFixedEffectMatrix, 
                  findintercept,
                  components::Vector{Vector{Set{N}}}) where {T, N}
    fes = get_fes(fep)
    adj1 = zero(T)
    i1 = findintercept[1]
    for component in components
        for i in reverse(findintercept)
            # demean all fixed effects except the first
            if i != 1
                adji = zero(T)
                for j in component[i]
                    adji += fev[i][j]
                end
                adji = adji / length(component[i])
                for j in component[i]
                    fev[i][j] -= adji
                end
                adj1 += adji
            else
                # rescale the first fixed effects
                for j in component[i1]
                    fev[i1][j] += adj1
                end
            end
        end
    end
end