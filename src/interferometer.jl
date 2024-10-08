using StaticArrays
import PhysicalConstants.CODATA2018: c_0, ε_0, m_e, m_u, e
import QuadGK: quadgk, BatchIntegrand
import IMASggd: interp, get_grid_subset, get_subset_boundary, subset_do, get_TPS_mats

export add_interferometer!, compute_interferometer!, compute_interferometer

default_ifo = "$(@__DIR__)/default_interferometer.json"

"""
    add_interferometer!(
        config::String=default_ifo,
        @nospecialize(ids::IMAS.dd)=IMAS.dd();
        overwrite::Bool=false, verbose::Bool=false, rtol::Float64=1e-3, n_e_gsi::Int=5,
    )::IMAS.dd

Add interferometer to IMAS structure using a JSON file and compute the
line integrated electron density if not present
"""
function add_interferometer!(
    config::String=default_ifo,
    @nospecialize(ids::IMAS.dd)=IMAS.dd();
    overwrite::Bool=false, verbose::Bool=false, rtol::Float64=1e-3, n_e_gsi::Int=5,
)::IMAS.dd
    if endswith(config, ".json")
        config_dict = convert_strings_to_symbols(IMAS.JSON.parsefile(config)) # Use with import IMASdd as IMAS
        # config_dict = convert_strings_to_symbols(IMAS.IMASdd.JSON.parsefile(config)) # Use with using IMAS as IMAS
        add_interferometer!(
            config_dict,
            ids;
            overwrite=overwrite,
            verbose=verbose,
            rtol=rtol,
            n_e_gsi=n_e_gsi,
        )
    else
        error("Only JSON files are supported.")
    end
    return ids
end

"""
    add_interferometer!(
        config::Dict{Symbol, Any},
        @nospecialize(ids::IMAS.dd)=IMAS.dd();
        overwrite::Bool=false, verbose::Bool=false, rtol::Float64=1e-3, n_e_gsi::Int=5,
    )::IMAS.dd

Add interferometer to IMAS structure using a Dict and compute the line integrated
electron density if not present
"""
function add_interferometer!(
    config::Dict{Symbol, Any},
    @nospecialize(ids::IMAS.dd)=IMAS.dd();
    overwrite::Bool=false, verbose::Bool=false, rtol::Float64=1e-3, n_e_gsi::Int=5,
)::IMAS.dd
    # Check for duplicates
    if length(ids.interferometer.channel) > 0
        duplicate_indices = []
        new_channels = Dict(
            ch[:name] => ch[:identifier] for
            ch ∈ config[:interferometer][:channel]
        )
        for (ii, ch) ∈ enumerate(ids.interferometer.channel)
            if ch.name in keys(new_channels) ||
               ch.identifier in values(new_channels)
                append!(duplicate_indices, ii)
            end
        end
        if overwrite
            for ii ∈ reverse(duplicate_indices)
                println(
                    "Overwriting interferometer channel ",
                    "$(ids.interferometer.channel[ii].name)...",
                )
                deleteat!(ids.interferometer.channel, ii)
            end
        else
            if length(duplicate_indices) > 0
                err_msg =
                    "Duplicate interferometer channels found with " *
                    "overlapping names or identifiers.\n" * "Identifier: Name\n"
                for ii ∈ duplicate_indices
                    err_msg *=
                        "$(ids.interferometer.channel[ii].identifier): " *
                        "$(ids.interferometer.channel[ii].name)\n"
                end
                err_msg *= "Use overwrite=true to replace them."
                throw(OverwriteAttemptError(err_msg))
            end
        end
        config[:interferometer] =
            mergewith(
                append!,
                IMAS.imas2dict(ids.interferometer),
                config[:interferometer],
            )
    end
    IMAS.dict2imas(config, ids; verbose=verbose)
    compute_interferometer!(ids; rtol=rtol, n_e_gsi=n_e_gsi)
    return ids
end

"""
    compute_interferometer!(
        @nospecialize(ids::IMAS.dd);
        rtol::Float64=1e-3,
        n_e_gsi::Int=5,
    )

Computed the line integrated electron density from the interferometer data present in
IDS structure for all the chords. The computation is based on the edge profile data
and core profile data present in the IDS structure.
"""
function compute_interferometer!(
    @nospecialize(ids::IMAS.dd);
    rtol::Float64=1e-3,
    n_e_gsi::Int=5,
)
    # Compute phase_to_n_e_line if not present
    for ch ∈ ids.interferometer.channel
        k = @SVector[2π / ch.wavelength[ii].value for ii ∈ 1:2]
        for i1 ∈ 1:2
            lam = ch.wavelength[i1]
            i2 = i1 % 2 + 1
            if IMAS.ismissing(lam, :phase_to_n_e_line)
                # Taken from https://doi.org/10.1063/1.1138037
                lam.phase_to_n_e_line =
                    (
                        2 * m_e * ε_0 * c_0^2 / e^2 * (k[i1] * k[i2]^2) /
                        (k[i2]^2 - k[i1]^2)
                    ).val
            end
        end
    end

    fix_eq_time_idx = length(ids.equilibrium.time_slice) == 1
    fix_ep_grid_ggd_idx = length(ids.edge_profiles.grid_ggd) == 1

    ep_grid_ggd = ids.edge_profiles.grid_ggd[1]
    ep_space = ep_grid_ggd.space[1]
    sep_bnd = get_sep_bnd(ep_grid_ggd)

    epggd = ids.edge_profiles.ggd
    cpp1d = ids.core_profiles.profiles_1d
    nt = length(epggd)

    TPS_mats = get_TPS_mats(ep_grid_ggd, n_e_gsi)

    ep_n_e_list = [
        interp(
            epggd[ii].electrons.density,
            update_TPS_mats(ii, fix_ep_grid_ggd_idx, ids, n_e_gsi, TPS_mats),
            n_e_gsi,
        ) for ii ∈ eachindex(epggd)
    ]
    cp_n_e_list = [
        interp(
            cpp1d[ii].electrons.density,
            cpp1d[ii],
            ids.equilibrium.time_slice[fix_eq_time_idx ? 1 : ii],
        ) for ii ∈ eachindex(epggd)
    ]

    for ch ∈ ids.interferometer.channel
        # Special case when measurement has not been made for some time steps 
        # but edge profile data exists
        proceed =
            (IMAS.ismissing(ch.n_e_line, :time) || IMAS.isempty(ch.n_e_line.time))
        if !proceed
            proceed = length(ch.n_e_line.time) < length(epggd)
        end
        if proceed
            # Check if core_profile is available
            if length(cpp1d) != length(epggd)
                error(
                    "Number of edge profiles time slices does not match number " \
                    "of core profile time slices. Please ensure core profile " \
                    "data for electron density is present in the data structure. " \
                    "You might want to run " \
                    "SD4SOLPS.fill_in_extrapolated_core_profile!" \
                    "(dd, \"electrons.density\"; method=core_method))",
                )
            end

            ch.n_e_line.time = zeros(nt)
            ch.n_e_line_average.time = zeros(nt)
            ch.n_e_line.data = zeros(nt)
            ch.n_e_line_average.data = zeros(nt)
            for lam ∈ ch.wavelength
                lam.phase_corrected.time = zeros(nt)
                lam.phase_corrected.data = zeros(nt)
            end

            # Parametrize line of sight
            fp = rzphi2xyz(ch.line_of_sight.first_point)
            sp = rzphi2xyz(ch.line_of_sight.second_point)
            tp = rzphi2xyz(ch.line_of_sight.third_point)
            if ch.line_of_sight.third_point ==
               IMAS.interferometer__channel___line_of_sight__third_point()
                chord_points = (fp, sp)
            else
                chord_points = (fp, sp, tp)
            end
            core_chord_length =
                get_core_chord_length(sep_bnd, ep_space, chord_points)

            for ii ∈ eachindex(epggd)
                ch.n_e_line.time[ii] = epggd[ii].time
                ch.n_e_line_average.time[ii] = epggd[ii].time
                core_chord_length = update_core_chord_length(
                    ii,
                    fix_ep_grid_ggd_idx,
                    ids,
                    chord_points,
                    core_chord_length,
                )

                integ =
                    let chord_points = chord_points, sep_bnd = sep_bnd,
                        ep_space = ep_space, cp_n_e = cp_n_e_list[ii],
                        ep_n_e = ep_n_e_list[ii]

                        s -> integrand(
                            s,
                            chord_points,
                            sep_bnd,
                            ep_space,
                            cp_n_e,
                            ep_n_e,
                        )
                    end

                ch.n_e_line.data[ii] = quadgk(integ, 0, 1; rtol=rtol)[1]
                ch.n_e_line_average.data[ii] =
                    ch.n_e_line.data[ii] / core_chord_length
                for lam ∈ ch.wavelength
                    lam.phase_corrected.time[ii] = epggd[ii].time
                    lam.phase_corrected.data[ii] =
                        ch.n_e_line.data[ii] / lam.phase_to_n_e_line
                end
            end
        end
    end
end

function integrand(s::Real, chord_points, sep_bnd, ep_space, cp_n_e, ep_n_e)
    r, z = line_of_sight(s, chord_points)
    if (r, z) ∈ (sep_bnd, ep_space)
        return cp_n_e(r, z) * dline(s, chord_points)
    else
        return ep_n_e(r, z) * dline(s, chord_points)
    end
end

function get_sep_bnd(ep_grid_ggd)
    ep_space = ep_grid_ggd.space[1]
    core = get_grid_subset(ep_grid_ggd, 22)
    sol = get_grid_subset(ep_grid_ggd, 23)
    sep_bnd = IMAS.edge_profiles__grid_ggd___grid_subset()
    sep_bnd.element =
        subset_do(
            intersect,
            get_subset_boundary(ep_space, sol),
            get_subset_boundary(ep_space, core),
        )
    return sep_bnd
end

@inline function rzphi2xyz(
    point::Union{IMAS.interferometer__channel___line_of_sight__first_point,
        IMAS.interferometer__channel___line_of_sight__second_point,
        IMAS.interferometer__channel___line_of_sight__third_point},
)
    r, z, phi = point.r, point.z, point.phi
    return r * cos(phi), r * sin(phi), z
end

@inline function line_of_sight(
    s::Real,
    points::Tuple{T, T},
) where {T <: Tuple{Float64, Float64, Float64}}
    fp, sp = points
    x = fp[1] + s * (sp[1] - fp[1])
    y = fp[2] + s * (sp[2] - fp[2])
    z = fp[3] + s * (sp[3] - fp[3])
    return xyz2rz(x, y, z)
end

@inline function line_of_sight(
    s::Real,
    points::Tuple{T, T, T},
) where {T <: Tuple{Float64, Float64, Float64}}
    fp, sp, tp = points
    return if (s <= 0.5)
        line_of_sight(2 * s, (fp, sp))
    else
        line_of_sight(2 * (s - 0.5), (tp, sp))
    end
end

@inline function dline(
    points::Tuple{T, T},
) where {T <: Tuple{Float64, Float64, Float64}}
    fp, sp = points
    return sqrt((sp[1] - fp[1])^2 + (sp[2] - fp[2])^2 + (sp[3] - fp[3])^2)
    # return sqrt(sum((sp[k] - fp[k])^2 for k ∈ eachindex(sp)))
end

@inline function dline(
    s::Real,
    points::Tuple{T, T},
) where {T <: Tuple{Float64, Float64, Float64}}
    fp, sp = points
    return dline(points)
end

@inline function dline(
    s::Real,
    points::Tuple{T, T, T},
) where {T <: Tuple{Float64, Float64, Float64}}
    fp, sp, tp = points
    p2, p1 = (s <= 0.5) ? (sp, fp) : (tp, sp)
    return 2 * dline((p2, p1))
    # return sqrt(2 * sum(((p2[k] - p1[k]))^2 for k ∈ eachindex(p2)))
end

function get_intersections(subset, space, points)
    nodes = space.objects_per_dimension[1].object
    edges = space.objects_per_dimension[2].object
    if length(points) == 2
        fp, sp = points
        three_points = false
    else
        fp, sp, tp = points
        three_points = true
    end
    segs = [0.0]
    for ele ∈ subset.element
        edge = edges[ele.object[1].index]
        e1 = Tuple(nodes[edge.nodes[1]].geometry)
        e2 = Tuple(nodes[edge.nodes[2]].geometry)
        s, s2 = intersection_s(e1, e2, fp, sp)
        if 0 <= s < 1 && 0 <= s2 < 1
            if three_points
                append!(segs, s / 2)
                s, s2 = intersection_s(e1, e2, sp, tp)
                if 0 <= s < 1 && 0 <= s2 < 1
                    append!(segs, s / 2 + 0.5)
                end
            else
                append!(segs, s)
            end
        end
    end
    append!(segs, 1.0)
    sort!(segs)
    filt_segs = Tuple{Float64, Float64}[]
    for ii ∈ 1:length(segs)-1
        check_at = (segs[ii] + segs[ii+1]) / 2
        if line_of_sight(check_at, points) ∈ (subset, space)
            append!(filt_segs, [(segs[ii], segs[ii+1])])
        end
    end
    return filt_segs
end

function intersection_s(
    fp::Tuple{Float64, Float64},
    sp::Tuple{Float64, Float64},
    l1::Tuple{Float64, Float64},
    l2::Tuple{Float64, Float64},
)
    den1 = (sp[1] - fp[1]) * (l2[2] - l1[2]) - (sp[2] - fp[2]) * (l2[1] - l1[1])
    num1 = (sp[1] - fp[1]) * (fp[2] - l1[2]) - (sp[2] - fp[2]) * (fp[1] - l1[1])
    den2 = (l2[1] - l1[1]) * (sp[2] - fp[2]) - (l2[2] - l1[2]) * (sp[1] - fp[1])
    num2 = (l2[1] - l1[1]) * (l1[2] - fp[2]) - (l2[2] - l1[2]) * (l1[1] - fp[1])
    return num1 / den1, num2 / den2
end

function intersection_s(
    fp::Tuple{Float64, Float64, Float64},
    sp::Tuple{Float64, Float64, Float64},
    l1::Tuple{Float64, Float64},
    l2::Tuple{Float64, Float64},
)
    return intersection_s(xyz2rz(fp...), xyz2rz(sp...), l1, l2)
end

function intersection_s(
    fp::Tuple{Float64, Float64},
    sp::Tuple{Float64, Float64},
    l1::Tuple{Float64, Float64, Float64},
    l2::Tuple{Float64, Float64, Float64},
)
    return intersection_s(fp, sp, xyz2rz(l1...), xyz2rz(l2...))
end

function get_core_chord_length(sep_bnd, ep_space, chord_points)
    chord_in_core = get_intersections(sep_bnd, ep_space, chord_points)
    core_chord_length = 0.0
    for seg ∈ chord_in_core
        center_of_seg = (seg[1] + seg[2]) / 2
        core_chord_length += (seg[2] - seg[1]) * dline(center_of_seg, chord_points)
    end
    return core_chord_length
end

function update_core_chord_length(
    ii,
    fix_ep_grid_ggd_idx,
    ids,
    chord_points,
    core_chord_length,
)
    if !fix_ep_grid_ggd_idx
        # If grid_ggd is evolving with time, update boundaries
        ep_grid_ggd = ids.edge_profiles.grid_ggd[ii]
        ep_space = ep_grid_ggd.space[1]
        sep_bnd = get_sep_bnd(ep_grid_ggd)
        return get_core_chord_length(sep_bnd, ep_space, chord_points)
    else
        return core_chord_length
    end
end
