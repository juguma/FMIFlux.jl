#
# Copyright (c) 2021 Tobias Thummerer, Lars Mikelsons
# Licensed under the MIT license. See LICENSE file in the project root for details.
#

# checks gradient determination for all available sensitivity configurations, see:
# https://docs.sciml.ai/SciMLSensitivity/stable/manual/differential_equation_sensitivities/
using FMISensitivity.SciMLSensitivity

function checkSensalgs!(loss, neuralFMU::Union{ME_NeuralFMU, CS_NeuralFMU}; 
                        gradients=(:ReverseDiff, :Zygote, :ForwardDiff), # :FiniteDiff is slow ...
                        max_msg_len=192, chunk_size=DEFAULT_CHUNK_SIZE, 
                        OtD_autojacvecs=(false, true, TrackerVJP(), ZygoteVJP(), ReverseDiffVJP(false), ReverseDiffVJP(true)), # EnzymeVJP() deadlocks in the current release xD
                        OtD_sensealgs=(BacksolveAdjoint, InterpolatingAdjoint, QuadratureAdjoint),
                        OtD_checkpointings=(true, false),
                        DtO_sensealgs=(ReverseDiffAdjoint, ForwardDiffSensitivity, TrackerAdjoint), # TrackerAdjoint, ZygoteAdjoint freeze the REPL
                        multiObjective::Bool=false,
                        bestof::Int=2,
                        timeout_seconds::Real=60.0,
                        kwargs...)

    params = Flux.params(neuralFMU)   
    initial_sensalg = neuralFMU.fmu.executionConfig.sensealg

    best_timing = Inf
    best_gradient = nothing 
    best_sensealg = nothing

    printstyled("Mode: Optimize-then-Discretize\n")
    for gradient ∈ gradients
        printstyled("\tGradient: $(gradient)\n")
        
        for sensealg ∈ OtD_sensealgs
            printstyled("\t\tSensealg: $(sensealg)\n")
            for checkpointing ∈ OtD_checkpointings
                printstyled("\t\t\tCheckpointing: $(checkpointing)\n")

                if sensealg == QuadratureAdjoint && checkpointing 
                    printstyled("\t\t\t\tQuadratureAdjoint doesn't implement checkpointing, skipping ...\n")
                    continue 
                end

                for autojacvec ∈ OtD_autojacvecs
                    printstyled("\t\t\t\tAutojacvec: $(autojacvec)\n")
                
                    if sensealg ∈ (BacksolveAdjoint, InterpolatingAdjoint)
                        neuralFMU.fmu.executionConfig.sensealg = sensealg(; autojacvec=autojacvec, chunk_size=chunk_size, checkpointing=checkpointing)
                    else
                        neuralFMU.fmu.executionConfig.sensealg = sensealg(; autojacvec=autojacvec, chunk_size=chunk_size)
                    end

                    call = () -> _tryrun(loss, params, gradient, chunk_size, 5, max_msg_len, multiObjective; timeout_seconds=timeout_seconds)
                    for i in 1:bestof
                        timing = call()

                        if timing < best_timing
                            best_timing = timing
                            best_gradient = gradient 
                            best_sensealg = neuralFMU.fmu.executionConfig.sensealg
                        end
                    end

                end
            end
        end
    end

    printstyled("Mode: Discretize-then-Optimize\n")
    for gradient ∈ gradients
        printstyled("\tGradient: $(gradient)\n")
        for sensealg ∈ DtO_sensealgs
            printstyled("\t\tSensealg: $(sensealg)\n")

            if sensealg == ForwardDiffSensitivity
                neuralFMU.fmu.executionConfig.sensealg = sensealg(; chunk_size=chunk_size, convert_tspan=true)
            else 
                neuralFMU.fmu.executionConfig.sensealg = sensealg()
            end

            call = () -> _tryrun(loss, params, gradient, chunk_size, 3, max_msg_len, multiObjective; timeout_seconds=timeout_seconds)
            for i in 1:bestof
                timing = call()

                if timing < best_timing
                    best_timing = timing
                    best_gradient = gradient 
                    best_sensealg = neuralFMU.fmu.executionConfig.sensealg
                end
            end

        end
    end

    neuralFMU.fmu.executionConfig.sensealg = initial_sensalg

    printstyled("------------------------------\nBest time: $(best_timing)\nBest gradient: $(best_gradient)\nBest sensealg: $(best_sensealg)\n", color=:blue)

    return nothing
end

# Thanks to:
# https://discourse.julialang.org/t/help-writing-a-timeout-macro/16591/11
function timeout(f, arg, seconds, fail)
    tsk = @task f(arg...)
    schedule(tsk)
    Timer(seconds) do timer
        istaskdone(tsk) || Base.throwto(tsk, InterruptException())
    end
    try
        fetch(tsk)
    catch _;
        fail
    end
end

function runGrads(loss, params, gradient, chunk_size, multiObjective)
    tstart = time()

    grads = nothing
    if multiObjective
        dim = loss(params[1])
        grads = zeros(Float64, length(params[1]), length(dim))
    else
        grads = zeros(Float64, length(params[1])) 
    end

    computeGradient!(grads, loss, params[1], gradient, chunk_size, multiObjective)
    
    timing = time() - tstart

    if length(grads[1]) == 1
        grads = [grads]
    end

    return grads, timing
end

function _tryrun(loss, params, gradient, chunk_size, ts, max_msg_len, multiObjective::Bool=false; print_stdout::Bool=true, print_stderr::Bool=true, timeout_seconds::Real=60.0)

    spacing = ""
    for t in ts 
        spacing *= "\t"
    end

    message = "" 
    color = :black 
    timing = Inf

    original_stdout = stdout
    original_stderr = stderr
    (rd_stdout, wr_stdout) = redirect_stdout();
    (rd_stderr, wr_stderr) = redirect_stderr();

    try
       
        #grads, timing = timeout(runGrads, (loss, params, gradient, chunk_size, multiObjective), timeout_seconds, ([Inf], -1.0))
        grads, timing = runGrads(loss, params, gradient, chunk_size, multiObjective)

        if timing == -1.0
            message = spacing * "TIMEOUT\n"
            color = :red
        else
            val = collect(sum(abs.(grad)) for grad in grads)
            message = spacing * "SUCCESS | $(round(timing; digits=3))s | GradAbsSum: $(round.(val; digits=6))\n"
            color = :green
        end

    catch e 
        msg = "$(e)"
        if length(msg) > max_msg_len
            msg = join(collect(msg)[1:max_msg_len]) * "..."
        end
        
        message = spacing * "$(msg)\n"
        color = :red
    end

    redirect_stdout(original_stdout)
    redirect_stderr(original_stderr)
    close(wr_stdout)
    close(wr_stderr)

    if print_stdout
        msg = read(rd_stdout, String)
        if length(msg) > 0
            if length(msg) > max_msg_len
                msg = join(collect(msg)[1:max_msg_len]) * "..."
            end
            printstyled(spacing * "STDOUT: $(msg)\n", color=:yellow)
        end
    end

    if print_stderr
        msg = read(rd_stderr, String)
        if length(msg) > 0
            if length(msg) > max_msg_len
                msg = join(collect(msg)[1:max_msg_len]) * "..."
            end
            printstyled(spacing * "STDERR: $(msg)\n", color=:yellow)
        end
    end

    printstyled(message, color=color)

    return timing
end