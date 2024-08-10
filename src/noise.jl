import DSP: DSP, AbstractFFTs

export Noise, generate_noise, generate_noise!

"""
    Noise

A structure to represent a noise model. It holds power spectral density of noise and/or
the time series of noise. The power spectral density is stored as a
`DSP.Periodograms.Periodogram` object.

Constructors:

    Noise(time::Vector{Float64}, signal::Vector{Float64}, binwidth::Float64)

Create a noise model from a time series of noise. The power spectral density is
calculated and stored for regenaeration of noise in future.

    Noise(pgram::DSP.Periodograms.Periodogram)

Create a noise model from a power spectral density data given as a
`DSP.Periodograms.Periodogram` object.

    Noise(power_spectrum::Vector{Float64}, freq::AbstractRange)

Create a noise model from a power spectral density data given as a vector along with
frequency values. The power spectral density is stored as a
`DSP.Periodograms.Periodogram` calculated from the input data.
"""
mutable struct Noise
    var"pgram"::DSP.Periodograms.Periodogram
    var"time"::Vector{Float64}
    var"noise"::Vector{Float64}
end

"""
    Noise(time::Vector{Float64}, signal::Vector{Float64}, binwidth::Float64)::Noise

Create a noise model from a time series of noise. The power spectral density is
calculated and stored for regenaeration of noise in future.
"""
function Noise(time::Vector{Float64}, signal::Vector{Float64}, binwidth::Float64)::Noise
    fs = 1 / (time[2] - time[1])
    nperseg = round(Int64, fs / binwidth)
    noverlap = div(nperseg, 2)
    pgram = DSP.Periodograms.welch_pgram(signal, nperseg, noverlap; fs)
    return Noise(pgram, time, signal)
end

"""
    Noise(pgram::DSP.Periodograms.Periodogram)::Noise

Create a noise model from a power spectral density data given as a
`DSP.Periodograms.Periodogram` object.
"""
function Noise(pgram::DSP.Periodograms.Periodogram)::Noise
    return Noise(pgram, zeros(Float64, 0), zeros(Float64, 0))
end

"""
    Noise(power_spectrum::Vector{Float64}, freq::AbstractRange)::Noise

Create a noise model from a power spectral density data given as a vector along with
frequency values. The power spectral density is stored as a
`DSP.Periodograms.Periodogram` calculated from the input data.
"""
function Noise(power_spectral_density::Vector{Float64}, freq::AbstractRange)::Noise
    pgram = DSP.Periodograms.Periodogram(power_spectral_density, freq)
    return Noise(pgram)
end

"""
    generate_noise(n::Noise, t::Vector{Float64})::Vector{Float64}

Generate a noise signal based on the power spectral density stored in the noise model
that corresponds to the time axis `t`. The noise signal is generated by summing up the
cosine waves with uniformly distributed random phase and amplitude based on the power
spectral density.
"""
function generate_noise(n::Noise, t::Vector{Float64})::Vector{Float64}
    signal = zeros(Float64, length(t))
    bw = n.pgram.freq[2] - n.pgram.freq[1]
    amp_spec = sqrt.(n.pgram.power * 2 * bw)
    for (ii, ff) ∈ enumerate(n.pgram.freq)
        signal .+= amp_spec[ii] .* cos.(2π .* (ff .* t .+ randn()))
    end
    return signal
end

"""
    generate_noise!(n::Noise, t::Vector{Float64})::Noise

In-place version of [`generate_noise()`](@ref).
"""
function generate_noise!(n::Noise, t::Vector{Float64})::Noise
    signal = generate_Noise(n, t)
    n.time = t
    n.noise = signal
    return n
end
