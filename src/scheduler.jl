#
# Copyright (c) 2021 Tobias Thummerer, Lars Mikelsons
# Licensed under the MIT license. See LICENSE file in the project root for details.
#

import Printf
using Colors

abstract type BatchScheduler end

# ToDo: DocString update.
"""
    Computes all batch element losses. Picks the batch element with the greatest loss as next training element.
"""
mutable struct WorstElementScheduler <: BatchScheduler

    ### mandatory ###
    step::Integer
    elementIndex::Integer
    applyStep::Integer
    plotStep::Integer
    batch::Any
    neuralFMU::NeuralFMU
    losses::Vector{Float64}
    logLoss::Bool

    ### type specific ###
    lossFct::Any
    runkwargs::Any
    printMsg::String
    updateStep::Integer
    excludeIndices::Any

    function WorstElementScheduler(
        neuralFMU::NeuralFMU,
        batch,
        lossFct = mse;
        applyStep::Integer = 1,
        plotStep::Integer = 1,
        updateStep::Integer = 1,
        excludeIndices = nothing,
    )
        inst = new()
        inst.neuralFMU = neuralFMU
        inst.step = 0
        inst.elementIndex = 0
        inst.batch = batch
        inst.lossFct = lossFct
        inst.applyStep = applyStep
        inst.plotStep = plotStep
        inst.losses = []
        inst.logLoss = false

        inst.printMsg = ""
        inst.updateStep = updateStep
        inst.excludeIndices = excludeIndices

        return inst
    end
end

# ToDo: DocString update.
"""
    Computes all batch element losses. Picks the batch element with the greatest accumulated loss as next training element. If picked, accumulated loss is resetted.
    (Prevents starvation of batch elements with little loss)
"""
mutable struct LossAccumulationScheduler <: BatchScheduler

    ### mandatory ###
    step::Integer
    elementIndex::Integer
    applyStep::Integer
    plotStep::Integer
    batch::Any
    neuralFMU::NeuralFMU
    losses::Vector{Float64}
    logLoss::Bool

    ### type specific ###
    lossFct::Any
    runkwargs::Any
    printMsg::String
    lossAccu::Array{<:Real}
    updateStep::Integer

    function LossAccumulationScheduler(
        neuralFMU::NeuralFMU,
        batch,
        lossFct = mse;
        applyStep::Integer = 1,
        plotStep::Integer = 1,
        updateStep::Integer = 1,
    )
        inst = new()
        inst.neuralFMU = neuralFMU
        inst.step = 0
        inst.elementIndex = 0
        inst.batch = batch
        inst.lossFct = lossFct
        inst.applyStep = applyStep
        inst.plotStep = plotStep
        inst.updateStep = updateStep
        inst.losses = []
        inst.logLoss = false

        inst.printMsg = ""
        inst.lossAccu = zeros(length(batch))

        return inst
    end
end

# ToDo: DocString update.
"""
    Computes all batch element losses. Picks the batch element with the greatest grow in loss (derivative) as next training element.
"""
mutable struct WorstGrowScheduler <: BatchScheduler

    ### mandatory ###
    step::Integer
    elementIndex::Integer
    applyStep::Integer
    plotStep::Integer
    batch::Any
    neuralFMU::NeuralFMU
    losses::Vector{Float64}
    logLoss::Bool

    ### type specific ###
    lossFct::Any
    runkwargs::Any
    printMsg::String

    function WorstGrowScheduler(
        neuralFMU::NeuralFMU,
        batch,
        lossFct = mse;
        applyStep::Integer = 1,
        plotStep::Integer = 1,
    )
        inst = new()
        inst.neuralFMU = neuralFMU
        inst.step = 0
        inst.elementIndex = 0
        inst.batch = batch
        inst.lossFct = lossFct
        inst.applyStep = applyStep
        inst.plotStep = plotStep
        inst.losses = []
        inst.logLoss = true # this is because this scheduler estimates derivatives

        inst.printMsg = ""

        return inst
    end
end

# ToDo: DocString update.
"""
    Picks a random batch element as next training element.
"""
mutable struct RandomScheduler <: BatchScheduler

    ### mandatory ###
    step::Integer
    elementIndex::Integer
    applyStep::Integer
    plotStep::Integer
    batch::Any
    neuralFMU::NeuralFMU
    losses::Vector{Float64}
    logLoss::Bool

    ### type specific ###
    printMsg::String

    function RandomScheduler(
        neuralFMU::NeuralFMU,
        batch;
        applyStep::Integer = 1,
        plotStep::Integer = 1,
    )
        inst = new()
        inst.neuralFMU = neuralFMU
        inst.step = 0
        inst.elementIndex = 0
        inst.batch = batch
        inst.applyStep = applyStep
        inst.plotStep = plotStep
        inst.losses = []
        inst.logLoss = false

        inst.printMsg = ""

        return inst
    end
end

# ToDo: DocString update.
"""
    Sequentially runs over all elements.
"""
mutable struct SequentialScheduler <: BatchScheduler

    ### mandatory ###
    step::Integer
    elementIndex::Integer
    applyStep::Integer
    plotStep::Integer
    batch::Any
    neuralFMU::NeuralFMU
    losses::Vector{Float64}
    logLoss::Bool

    ### type specific ###
    printMsg::String

    function SequentialScheduler(
        neuralFMU::NeuralFMU,
        batch;
        applyStep::Integer = 1,
        plotStep::Integer = 1,
    )
        inst = new()
        inst.neuralFMU = neuralFMU
        inst.step = 0
        inst.elementIndex = 0
        inst.batch = batch
        inst.applyStep = applyStep
        inst.plotStep = plotStep
        inst.losses = []
        inst.logLoss = false

        inst.printMsg = ""

        return inst
    end
end

# ToDo: DocString update.
"""
    Picks a random batch element by doing the following two steps:
    - given a vector (a) of vectors (b), a random vector from (a) is picked 
    - a random value from the random vector (b) is picked
"""
mutable struct TwoStageRandomScheduler <: BatchScheduler

    ### mandatory ###
    step::Integer
    elementIndex::Integer
    applyStep::Integer
    plotStep::Integer
    batch::Any
    neuralFMU::NeuralFMU
    losses::Vector{Float64}
    logLoss::Bool

    ### type specific ###
    printMsg::String
    indices::AbstractVector{<:AbstractVector{<:Int64}}

    function TwoStageRandomScheduler(
        neuralFMU::NeuralFMU,
        batch,
        indices;
        applyStep::Integer = 1,
        plotStep::Integer = 1,
    )
        inst = new()
        inst.neuralFMU = neuralFMU
        inst.indices = indices
        inst.step = 0
        inst.elementIndex = 0
        inst.batch = batch
        inst.applyStep = applyStep
        inst.plotStep = plotStep
        inst.losses = []
        inst.logLoss = false

        inst.printMsg = ""

        return inst
    end
end

function initialize!(scheduler::BatchScheduler; print::Bool = true, runkwargs...)

    lastIndex = 0
    scheduler.step = 0
    scheduler.elementIndex = 0

    if hasfield(typeof(scheduler), :runkwargs)
        scheduler.runkwargs = runkwargs
    end

    scheduler.elementIndex = apply!(scheduler; print = print)

    if scheduler.plotStep > 0
        plot(scheduler, lastIndex)
    end
end

function update!(scheduler::BatchScheduler; print::Bool = true)

    lastIndex = scheduler.elementIndex

    scheduler.step += 1

    if scheduler.applyStep > 0 && scheduler.step % scheduler.applyStep == 0
        scheduler.elementIndex = apply!(scheduler; print = print)
    end

    # max/avg error 
    num = length(scheduler.batch)
    losssum = 0.0
    avgsum = 0.0
    maxe = 0.0
    for i = 1:num
        l = nominalLoss(scheduler.batch[i])
        l = l == Inf ? 0.0 : l

        losssum += l
        avgsum += l / num

        if l > maxe
            maxe = l
        end
    end
    push!(scheduler.losses, losssum)

    if print
        scheduler.printMsg = "AVG: $(roundToLength(avgsum, 8)) | MAX: $(roundToLength(maxe, 8)) | SUM: $(roundToLength(losssum, 8))"
        @info scheduler.printMsg
    end

    if scheduler.plotStep > 0 && scheduler.step % scheduler.plotStep == 0
        plot(scheduler, lastIndex)
    end
end

"""
    Rounds a given `number` to a string with a maximum length of `len`.
    Exponentials are used if suitable.
"""
function roundToLength(number::Real, len::Integer)

    @assert len >= 5 "`len` must be at least `5`."

    if number == 0.0
        return "0.0"
    end

    isneg = false
    if number < 0.0
        isneg = true
        number = -number
        len -= 1 # we need one digit for the "-"
    end

    expLen = 0

    if abs(number) <= 1.0
        expLen = Integer(floor(log10(1.0 / number))) + 1
    else
        expLen = Integer(floor(log10(number))) + 1
    end

    len -= 4 # spaces needed for "+" (or "-"), "e", "." and leading number
    if expLen >= 100
        len -= 3 # 3 spaces needed for large exponent
    else
        len -= 2 # 2 spaces needed for regular exponent
    end

    if isneg
        number = -number
    end

    return Printf.format(Printf.Format("%.$(len)e"), number)
end

function apply!(scheduler::WorstElementScheduler; print::Bool = true)

    avgsum = 0.0
    losssum = 0.0

    maxe = 0.0
    maxind = 0

    updateAll = (scheduler.step % scheduler.updateStep == 0)

    num = length(scheduler.batch)
    for i = 1:num

        l = (nominalLoss(scheduler.batch[i]) != Inf ? nominalLoss(scheduler.batch[i]) : 0.0)

        if updateAll
            FMIFlux.run!(scheduler.neuralFMU, scheduler.batch[i]; scheduler.runkwargs...)
            FMIFlux.loss!(
                scheduler.batch[i],
                scheduler.lossFct;
                logLoss = scheduler.logLoss,
            )
            l = nominalLoss(scheduler.batch[i])
        end

        losssum += l
        avgsum += l / num

        if isnothing(scheduler.excludeIndices) || i ∉ scheduler.excludeIndices
            if l > maxe
                maxe = l
                maxind = i
            end
        end

    end

    return maxind
end

function apply!(scheduler::LossAccumulationScheduler; print::Bool = true)

    avgsum = 0.0
    losssum = 0.0

    maxe = 0.0
    nextind = 1

    # reset current accu loss
    if scheduler.elementIndex > 0
        scheduler.lossAccu[scheduler.elementIndex] = 0.0
    end

    updateAll = (scheduler.step % scheduler.updateStep == 0)

    num = length(scheduler.batch)
    for i = 1:num

        l = (nominalLoss(scheduler.batch[i]) != Inf ? nominalLoss(scheduler.batch[i]) : 0.0)

        if updateAll
            FMIFlux.run!(scheduler.neuralFMU, scheduler.batch[i]; scheduler.runkwargs...)
            FMIFlux.loss!(
                scheduler.batch[i],
                scheduler.lossFct;
                logLoss = scheduler.logLoss,
            )
            l = nominalLoss(scheduler.batch[i])
        end

        scheduler.lossAccu[i] += l

        losssum += l
        avgsum += l / num

        if l > maxe
            maxe = l
        end
    end

    # find largest accumulated loss
    for i = 1:num
        if scheduler.lossAccu[i] > scheduler.lossAccu[nextind]
            nextind = i
        end
    end

    return nextind
end

function apply!(scheduler::WorstGrowScheduler; print::Bool = true)

    avgsum = 0.0
    losssum = 0.0

    maxe = 0.0
    maxe_der = -Inf
    maxind = 0

    num = length(scheduler.batch)
    for i = 1:num

        FMIFlux.run!(scheduler.neuralFMU, scheduler.batch[i]; scheduler.runkwargs...)
        l = FMIFlux.loss!(
            scheduler.batch[i],
            scheduler.lossFct;
            logLoss = scheduler.logLoss,
        )

        l_der = l # fallback for first run (greatest error)
        if length(scheduler.batch[i].losses) >= 2
            l_der = (l - nominalLoss(scheduler.batch[i].losses[end-1]))
        end

        losssum += l
        avgsum += l / num

        if l > maxe
            maxe = l
        end

        if l_der > maxe_der
            maxe_der = l_der
            maxind = i
        end

    end

    return maxind
end

function apply!(scheduler::RandomScheduler; print::Bool = true)

    next = rand(1:length(scheduler.batch))

    if print
        @info "Current step: $(scheduler.step) | Current element=$(scheduler.elementIndex) | Next element=$(next)"
    end

    return next
end

function apply!(scheduler::TwoStageRandomScheduler; print::Bool = true)

    nextStack = rand(scheduler.indices)
    next = rand(nextStack)

    if print
        @info "Current step: $(scheduler.step) | Current element=$(scheduler.elementIndex) | Next element=$(next)"
    end

    return next
end

function apply!(scheduler::SequentialScheduler; print::Bool = true)

    next = scheduler.elementIndex + 1
    if next > length(scheduler.batch)
        next = 1
    end

    if print
        @info "Current step: $(scheduler.step) | Current element=$(scheduler.elementIndex) | Next element=$(next)"
    end

    return next
end
