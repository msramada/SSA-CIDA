# import Packages
using CUDA
using Test
using BenchmarkTools
using Random
using LinearAlgebra
using Distributions

include("SSA_kernels.jl")

# TODO: have all parameters (covariances, particles, etc...) set from JSON file

# function: init_gaussians() = initialize particle cloud, process noise, 
# and measurement noise gaussian distributions for random sampling during SSA
# 
# input: none
# output: tuple of Normal objects from Distributons Pkg 
function init_gaussians()
    μ = 7.5
    Σ = 0.5

    # process noise ωₖ and scalar measurement noise vₖ
    ω = 0.5
    v = 0.5

    Ξ_gaussian = Normal(μ, sqrt(Σ))
    W_gaussian = Normal(0,sqrt(0.5))
    V_gaussian = Normal(0,sqrt(0.5))

    return (Ξ_gaussian, W_gaussian, V_gaussian)
end

####
# function: gpu_generate_Xi
# input: L = number of particles
# output: Ξ₀ = Array of randomly sampled states, size: [2 x L]
###
function gpu_generate_Xi(L :: Int64, n :: Int64)
    # Gaussian Density with mean vector μ_x0 and covariance matrix Σ_x0
    μ_x0 = CuArray([7.5,-7.5])
    Σ_x0 = (0.5*I)

    # randomly sample initial states Ξ following Gaussian density
    Ξ₀ = CuArray{Float64}(undef,n,L)
    Ξ₀ = μ_x0.+sqrt(Σ_x0)*CUDA.randn(n,L)
    return (Ξ₀)
end

function gpu_sample_gaussian_distribution(mean, var, dims)
    w = CuArray{Float64}(undef, dims[1],dims[2],dims[3])
    w = mean.+sqrt(var)*CUDA.randn(dims[1],dims[2],dims[3])
    return w
end

# function: cpu_generate_Xi
# version of gpu_generate_Xi to run on cpu for benchmark comparisons
function cpu_generate_Xi(L :: Int64)
    # Gaussian Density with mean vector μ_x0 and covariance matrix Σ_x0
    μ_x0 = ([7.5,-7.5])
    Σ_x0 = (0.5*I)

    # randomly sample initial states Ξ following Gaussian density
    Ξ₀ = Array{Float64}(undef,2,L)
    Ξ₀ = μ_x0.+sqrt(Σ_x0)*randn(2,L)
    return Array(Ξ₀)
end

# function: launch_xprime_kernel
# inputs: 
#   state - [2 x L x N] state array
#   T - propagate up to time T
#   w - randomly generated noise
# 
# objective: configure and launch the xprime kernel function
function launch_xprime_kernel!(state, T, w, u)
    kernel = @cuda launch=false xprime_kernel_function!(state, T, w, u)
    config = launch_configuration(kernel.fun)
    threads = min(length(state), config.threads)
    blocks = cld(length(state), threads)

    CUDA.@sync begin
        kernel(state, T, w, u; threads, blocks)
    end
end


## function: launch_xk2prime_kernel! - compute M number x'' sequences for one particle
# inputs: T - time steps, M - sample number, state - initial state density, i - iterator through L
#  u - input, w2 - randomly generated noise
#
# output: updated state array 
function launch_xk2prime_kernel!(SSA_params, Ξ, state, u, w2, i)

    L = SSA_params.L
    M = SSA_params.M 
    N = SSA_params.N

    # for each particle in the state density, randomly sample M particles
    local mc_sample_index = (rand(1:L, M))
    state[:,:,1] = Ξ[:,mc_sample_index]

    # calculate M sampled trajectories
    kernel = @cuda launch=false monte_carlo_sampling_kernel!(N, M, Ξ, state, u, w2, i)
    config = launch_configuration(kernel.fun)
    threads = min(length(state), config.threads)
    blocks = cld(length(state), threads)

    CUDA.@sync begin
        kernel(N, M, Ξ, state, u, w2, i; threads, blocks)
    end
end

# function: launch_master_kernel!
# objective: launch kernel for cost and violation rate calculation
function launch_master_kernel!(SSA_limits, T, M, state, u, cost, state_violation_rate, control_violation_rate, i)
    kernel = @cuda launch=false master_kernel!(SSA_limits, T,M,state,u,cost,state_violation_rate, control_violation_rate,i)
    config = launch_configuration(kernel.fun)
    threads = min(M, config.threads)
    blocks = cld(M, threads)

    CUDA.@sync begin
        kernel(SSA_limits, T,M,state,u,cost,state_violation_rate, control_violation_rate, i; threads, blocks)
    end
end


# function: state_selection_algorithm
# inputs:
# - Ξ: particle density
# - SSA_params: struct of parameters
# - SSA_limits: struct of state and input constraints
function state_selection_algorithm(Ξ,SSA_params,SSA_limits)
    n = SSA_params.n
    # intialize state array
    state = CUDA.fill(1.0f0, (n,L,N))
    # fill state array with intial particle density
    state[:,:,1] = Ξ

    # initalize input array
    u = CUDA.fill(0.0f0, L,N)

    # generate random noise sequence Wprime for time horizon N for 
    # state density with num particles L
    w = (gpu_sample_gaussian_distribution(0, ω, (n,L,N)))
    w2 = ((gpu_sample_gaussian_distribution(0, ω, (n,L,N))))

    # ### First, lets generate the x' trajectories for time horizon N for each particle in state density Xi ###
    CUDA.@sync launch_xprime_kernel!(state, N, w, u)


    # declare vectors for x'' trajectories, cost, and constraint violation rate calculations
    cost = CUDA.fill(0.0f0, L)
    state_violation_rate = CUDA.fill(0.0f0,L)
    control_violation_rate = CUDA.fill(0.0f0,L)
    state_2prime = CUDA.fill(0.0f0, (n,M,N))

    # iterate through each particle in Ξ and run M monte carlo simulations for each particle 
    for i = 1:L
        
        # calculate x'' trajectories
        CUDA.@sync launch_xk2prime_kernel!(SSA_params, Ξ, state_2prime, u, w2, i)

        # calculate cost and state/control violation rates
        CUDA.@sync launch_master_kernel!(SSA_limits, N, M, state_2prime, u, cost, state_violation_rate, control_violation_rate, i)
    end

    # sample-average violation rate counts
    state_violation_rate /= M
    control_violation_rate /= M

    state_feasibility_mask = state_violation_rate .< α
    control_feasibility_mask = control_violation_rate .< α

    # mask for feasible states
    feasibility_mask = state_feasibility_mask .& control_feasibility_mask

    u = Array(u)

    # find feasible state with minimum cost
    cost_val, candidate_index = findmin(cost[feasibility_mask])
    return Array(Ξ)[:,candidate_index,1], u[candidate_index,1], candidate_index
end