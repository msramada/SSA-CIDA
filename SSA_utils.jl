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
function gpu_generate_Xi(L :: Int64, n :: Int64, μ)
    # Gaussian Density with mean vector μ_x0 and covariance matrix Σ_x0
    μ_x0 = CuArray(μ)
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
function launch_master_kernel!(SSA_limits, T, M, state, u, sampled_cost, state_violation_count, i)
    kernel = @cuda launch=false master_kernel!(SSA_limits, T, M, state, u, sampled_cost, state_violation_count, i)
    config = launch_configuration(kernel.fun)
    threads = min(M, config.threads)
    blocks = cld(M, threads)

    CUDA.@sync begin
        kernel(SSA_limits, T, M, state, u, sampled_cost, state_violation_count, i; threads, blocks)
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
    cost = fill(0.0f0, L)
    sampled_costs = CUDA.fill(0.0f0, M,N)
    state_violation_count = CUDA.fill(0.0f0, M,N)
    sampled_state_violations = CUDA.fill(0.0f0,L,N)
    sampled_control_violations = CUDA.fill(0.0f0,L,N)
    total_state_violations = fill(false,L)
    total_control_violations = fill(false,L)
    state_2prime = CUDA.fill(0.0f0, (n,M,N))


    Ξ = CuArray(Ξ)
    # iterate through each particle in Ξ and run M monte carlo simulations for each particle 
    for i = 1:L
        
        # calculate x'' trajectories
        CUDA.@sync launch_xk2prime_kernel!(SSA_params, Ξ, state_2prime, u, w2, i)

        # calculate cost and state/control violation rates
        CUDA.@sync launch_master_kernel!(SSA_limits, N, M, state_2prime, u, sampled_costs, state_violation_count, i)

        # sum the sampled cost to calculate the cost of each L particles
        cost[i] = sum(sampled_costs)

        # sum the violation counts to make an [L x N] array, which contains the total violations of each trajectory
        sampled_state_violations[i,:] = sum(state_violation_count, dims=1)

        # indicate which particles satisfy state constraints
        total_state_violations[i] = all(sampled_state_violations[i,:]/M .< α)
        # total_control_violations[i] = all(sampled_control_violations[i,:]/M .< α)
    end


    # mask for feasible states
    feasibility_mask = total_state_violations

    u = Array(u)

    
    if(sum(feasibility_mask)==0) # if there are no feasible states, the feasible set is empty and SSA cannot proceed
        println("Feasible set is empty!")
        cost_val,candidate_index = findmin(cost)
        return Array(Ξ)[:,candidate_index], u[candidate_index,1], candidate_index, feasibility_mask
    else # otherwise, find feasible state with minimum cost
        cost_val, candidate_index = findmin(cost[feasibility_mask])
        # println(cost_val,candidate_index, Array(Ξ)[:,candidate_index])
        return Array(Ξ)[:,candidate_index], u[candidate_index,1], candidate_index, feasibility_mask
    end
    return
end


## function: run_simulation(T)
# input:
#       T - run simulation for T time steps
# objective: run the bootstrap particle filter in conjunction with the SSA for T time steps
function run_simulation(T)

    sim_data = fill(0.0f0, (n,L,T))
    x_true = fill(0.0f0, (n,T))
    violation_rate = fill(0.0f0,T)
    x_candidate = fill(0.0f0, (n,T))


    # initialize dynamics
    Q = Matrix{Float64}(I, 2, 2)
    R = v
    dynamics = Model(f,h,u,Q,R)
    x_true = Array{Float64}(undef, n, T+1)

    # generate state density Xi according to Gaussian parameters
    (Ξ_gaussian, W_gaussian, V_gaussian) = init_gaussians()
    Ξ = gpu_generate_Xi(SSA_params.L, SSA_params.n,μ)


    # initialize particle filter
    likelihoods = Vector(fill(1,(L)))
    pf = Particle_Filter(dynamics, TimeUpdate, MeasurementUpdate!, Resampler, likelihoods, Array(Ξ))
    x_true[:,1] = μ.+ sqrt(Σ)*randn(2)

    for t = 1:T

        sim_data[:,:,t] = pf.particles

        if(RUN_SSA) # run the state selection algorithm for the particle density
            CUDA.@sync candidate_state, u_star, candidate_index, feasibility_mask = state_selection_algorithm(pf.particles,SSA_params,SSA_limits)
            # violation_rate[t] = (L-sum(feasibility_mask))/L
            x_candidate[:,t] = pf.particles[:,candidate_index]
            if(isinf(u_star)||isnan(u_star))
                println("Feasible Set is Empty!!")
                break
            end
        elseif(RUN_CM) # choose the conditional mean as the state estimates
            x_candidate[:,t] = mean(pf.particles, dims = 2)
            candidate_state = x_candidate[:,t]
        else
            error("Please choose a state selection type to simulate")
        end

        violation_rate[t] = sum(check_constraints(pf.particles))/L

        println(violation_rate[t])

        # controller based on selected_state
        u_star = dynamics.u(candidate_state)
    
        ### run bootstrap particle filter
        w = Array(gpu_sample_gaussian_distribution(0, ω, (n,L,1)))
        w_true = sqrt(ω)*randn(2)
    
        # propagate particle density
        pf.particles = pf.TimeUpdate(pf.particles, dynamics, u_star, w)
       
        x_true[:,t+1] = dynamics.f(x_true[:,t], u_star, w_true)
    
        # take measurement
        y = dynamics.h(x_true[:,t+1], sqrt(v)*randn())
    
        # calculate likelihoods
        pf.MeasurementUpdate(pf,dynamics,y)
    
        pf.Resampler(pf)
    end

    return x_candidate, sim_data, violation_rate
end

function check_constraints(x)

    constraint_count = fill(0.0f0,L)

    for i = 1:L
        in_region1 = (x1_lowerlim < x[1,i] < x1_upperlim) && (y1_lowerlim < x[2,i] < y1_upperlim)
        in_region2 = (x2_lowerlim < x[1,i] < x2_upperlim) && (y2_lowerlim < x[2,i] < y2_upperlim)

        if(in_region1||in_region2)
            constraint_count[i] = 1
        end
    end

    return constraint_count
end