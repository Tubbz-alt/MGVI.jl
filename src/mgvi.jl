# This file is a part of MGVInference.jl, licensed under the MIT License (MIT).

abstract type MGVISolvers end

struct NewtonAvgModelFisher{T<:Real} <: MGVISolvers
    speed::T
end

rs_default_options=(;)
optim_default_options = Optim.Options()
optim_default_solver = LBFGS()

function _get_residual_sampler(f::Function, center_p::Vector;
                               residual_sampler::Type{RS}=ImplicitResidualSampler,
                               jacobian_func::Type{JF}=FwdDerJacobianFunc,
                               residual_sampler_options::NamedTuple
                              ) where RS <: AbstractResidualSampler where JF <: AbstractJacobianFunc
    fisher_map, jac_map = fisher_information_components(f, center_p; jacobian_func=jacobian_func)
    residual_sampler(fisher_map, jac_map; residual_sampler_options...)
end

function mgvi_kl(f::Function, data, residual_samples::Array, center_p)
    res = 0.
    for residual_sample in eachcol(residual_samples)
        p = center_p + residual_sample
        res += -logpdf(f(p), data) + dot(p, p)/2
    end
    res/size(residual_samples, 2)
end

function _generate_residual_samples(rng::AbstractRNG,
                                    f::Function, center_p::Vector;
                                    num_residuals,
                                    residual_sampler::Type{RS},
                                    jacobian_func::Type{JF},
                                    residual_sampler_options::NamedTuple=rs_default_options
                                   ) where RS <: AbstractResidualSampler where JF <: AbstractJacobianFunc
    estimated_dist = _get_residual_sampler(f, center_p;
                                           residual_sampler=residual_sampler,
                                           jacobian_func=jacobian_func,
                                           residual_sampler_options=residual_sampler_options)
    residual_samples = rand(rng, estimated_dist, num_residuals)
    residual_samples = hcat(residual_samples, -residual_samples)
    residual_samples
end

_fill_grad(f::Function, grad_f::Function) = function (res::AbstractVector, x::AbstractVector)
    res[:] = grad_f(f, x)
end

function mgvi_kl_optimize_step(rng::AbstractRNG,
                               f::Function, data, center_p::Vector,
                               optim_solver::Optim.AbstractOptimizer;
                               num_residuals=15,
                               residual_sampler::Type{RS},
                               jacobian_func::Type{JF},
                               residual_sampler_options::NamedTuple=rs_default_options,
                               optim_options::Optim.Options=optim_default_options
                              ) where RS <: AbstractResidualSampler where JF <: AbstractJacobianFunc
    residual_samples = _generate_residual_samples(rng,
                                                  f, center_p;
                                                  num_residuals=num_residuals,
                                                  residual_sampler=residual_sampler,
                                                  jacobian_func=jacobian_func,
                                                  residual_sampler_options=residual_sampler_options)
    mgvi_kl_simple(params::Vector) = mgvi_kl(f, data, residual_samples, params)
    mgvi_kl_grad! =  _fill_grad(mgvi_kl_simple, first ∘ gradient)
    res = optimize(mgvi_kl_simple, mgvi_kl_grad!,
                   center_p, optim_solver, optim_options)
    updated_p = Optim.minimizer(res)

    (result=updated_p, optimized=res, samples=residual_samples .+ updated_p)
end

function _avg_fisher_hessian(f, samples; jacobian_func)
    res = []
    for sample in eachcol(samples)
        components = fisher_information_components(f, Vector(sample); jacobian_func=jacobian_func)
        information = assemble_fisher_information(components...)
        push!(res, information)
    end
    sum(res)/length(res) + I
end

function mgvi_kl_optimize_step(rng::AbstractRNG,
                               f::Function, data, center_p::Vector,
                               optim_solver::NewtonAvgModelFisher{T};
                               num_residuals=15,
                               residual_sampler::Type{RS},
                               jacobian_func::Type{JF},
                               residual_sampler_options::NamedTuple=rs_default_options,
                               optim_options::Optim.Options=optim_default_options
                              ) where RS <: AbstractResidualSampler where JF <: AbstractJacobianFunc where T
    residual_samples = _generate_residual_samples(rng,
                                                  f, center_p;
                                                  num_residuals=num_residuals,
                                                  jacobian_func=jacobian_func,
                                                  residual_sampler=residual_sampler,
                                                  residual_sampler_options=residual_sampler_options)
    est_hessian = _avg_fisher_hessian(f, residual_samples; jacobian_func=jacobian_func)

    pos = center_p
    for _ in 1:optim_options.iterations
        grad = gradient(p -> mgvi_kl(f, data, residual_samples, p), pos)[1]
        if (optim_options.g_abstol > 0 && norm(grad) < optim_options.g_abstol)
            if (optim_options.show_trace)
                @info "MGVI KL Optim iteration stop. G-tol reached" pos grad
            end
            break
        end
        shift = cg(est_hessian, grad; verbose=optim_options.show_trace)*optim_solver.speed
        if (optim_options.x_abstol > 0 && norm(shift) < optim_options.x_abstol)
            if (optim_options.show_trace)
                @info "MGVI KL Optim iteration stop. G-tol reached" pos grad shift
            end
            break
        end
        pos = pos - shift
        if (optim_options.show_trace)
            @info "MGVI KL Optim iteration" pos grad shift
        end
    end

    (result=pos, samples=residual_samples .+ pos)
end

function mgvi_kl_optimize_step(rng::AbstractRNG,
                               f::Function, data, center_p::Vector;
                               num_residuals=15,
                               residual_sampler::Type{RS},
                               jacobian_func::Type{JF},
                               residual_sampler_options::NamedTuple=rs_default_options,
                               optim_options::Optim.Options=optim_default_options
                              ) where RS <: AbstractResidualSampler where JF <: AbstractJacobianFunc where T
    mgvi_kl_optimize_step(rng, f, data, center_p, optim_default_solver;
                          num_residuals=num_residuals,
                          residual_sampler=residual_sampler,
                          jacobian_func=jacobian_func,
                          residual_sampler_options=residual_sampler_options,
                          optim_options=optim_options)
end

export mgvi_kl_optimize_step, NewtonAvgModelFisher
