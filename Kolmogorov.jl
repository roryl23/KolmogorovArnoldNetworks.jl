module Kolmogorov
    export KANLinear, KAN, update_grid!, regularization_loss

    using Flux: sigmoid
    using Statistics
    using LinearAlgebra

    function b_splines(x, grid, spline_order)
        bases = (x .>= grid[:, 1:end-1]) .& (x .< grid[:, 2:end])
        for k in 1:spline_order
            bases = (x .- grid[:, 1:end-k-1]) ./ (grid[:, k+1:end-1] .- grid[:, 1:end-k-1]) .* bases[:, 1:end-1] +
                    (grid[:, k+2:end] .- x) ./ (grid[:, k+2:end] .- grid[:, 2:end-k]) .* bases[:, 2:end]
        end
        return bases
    end

    function curve2coeff(x, y, grid, spline_order)
        bases = b_splines(x, grid, spline_order)'
        solution = bases \ y'
        return permutedims(solution, (3, 2, 1))
    end

    struct KANLinear
        base_weight::Matrix{Float64}
        spline_weight::Array{Float64, 3}
        spline_scaler::Union{Matrix{Float64}, Nothing}
        grid::Matrix{Float32}
        grid_size::Int
        spline_order::Int
        base_activation::Function
        scale_base::Float32
        scale_spline::Float32
        scale_noise::Float32
        grid_eps::Float32
        enable_standalone_scale_spline::Bool
    end

    function KANLinear(in_features, out_features; grid_size=5, spline_order=3, scale_noise=0.1, scale_base=1.0,
                        scale_spline=1.0, enable_standalone_scale_spline=true, base_activation=sigmoid, grid_eps=0.02, grid_range=(-1, 1))
        h = (grid_range[2] - grid_range[1]) / grid_size
        grid = [i * h + grid_range[1] for i in -spline_order:grid_size+spline_order+1]
        grid = reshape(collect(repeat(grid, in_features)), in_features, :)

        base_weight = randn(out_features, in_features) * sqrt(5) * scale_base
        spline_weight = randn(out_features, in_features, grid_size + spline_order)
        spline_scaler = enable_standalone_scale_spline ? randn(out_features, in_features) * sqrt(5) * scale_spline : nothing

        KANLinear(base_weight, spline_weight, spline_scaler, grid, grid_size, spline_order, base_activation, scale_base, scale_spline, scale_noise, grid_eps, enable_standalone_scale_spline)
    end

    function (layer::KANLinear)(x)
        base_output = layer.base_activation(layer.base_weight * x')
        bases = b_splines(x, layer.grid, layer.spline_order)
        spline_output = (reshape(bases, size(bases, 1), -1) * reshape(layer.spline_weight .* coalesce(layer.spline_scaler, 1.0), size(layer.spline_weight, 1), -1))'
        return base_output + spline_output
    end

    struct KAN
        layers::Vector{KANLinear}
    end

    function KAN(layers_hidden; grid_size=5, spline_order=3, scale_noise=0.1, scale_base=1.0, scale_spline=1.0, base_activation=sigmoid, grid_eps=0.02, grid_range=(-1, 1))
        layers = [KANLinear(inf, outf; grid_size=grid_size, spline_order=spline_order, scale_noise=scale_noise, scale_base=scale_base, scale_spline=scale_spline, base_activation=base_activation, grid_eps=grid_eps, grid_range=grid_range) for (inf, outf) in zip(layers_hidden[1:end-1], layers_hidden[2:end])]
        KAN(layers)
    end

    function update_grid!(layer::KANLinear, x; margin=0.01)
        batch = size(x, 1)
        splines = b_splines(x, layer.grid, layer.spline_order)
        orig_coeff = permutedims(layer.spline_weight .* coalesce(layer.spline_scaler, 1.0), (2, 3, 1))
        unreduced_spline_output = permutedims(splines * orig_coeff, (2, 1, 3))

        x_sorted = sortslices(x, dims=1)
        grid_adaptive = x_sorted[round.(Int64, LinRange(1, batch, layer.grid_size + 1)), :]

        uniform_step = (maximum(x_sorted) - minimum(x_sorted) + 2 * margin) / layer.grid_size
        grid_uniform = collect(0:layer.grid_size) .* uniform_step .+ minimum(x_sorted) - margin
        grid_uniform = reshape(grid_uniform, :, 1)

        grid = layer.grid_eps .* grid_uniform .+ (1 - layer.grid_eps) .* grid_adaptive
        grid = vcat(
            grid[1:1] .- uniform_step .* collect(layer.spline_order:-1:1),
            grid,
            grid[end:end] .+ uniform_step .* collect(1:layer.spline_order)
        )

        layer.grid[:] = grid'
        layer.spline_weight .= curve2coeff(x, unreduced_spline_output, layer.grid, layer.spline_order)
    end

    function regularization_loss(layer::KANLinear; regularize_activation=1.0, regularize_entropy=1.0)
        l1_fake = mean(abs, layer.spline_weight, dims=3)
        reg_loss_activation = sum(l1_fake)
        p = l1_fake / reg_loss_activation
        reg_loss_entropy = -sum(p .* log.(p))
        return regularize_activation * reg_loss_activation + regularize_entropy * reg_loss_entropy
    end

    function regularization_loss(model::KAN; regularize_activation=1.0, regularize_entropy=1.0)
        return sum(regularization_loss(layer; regularize_activation, regularize_entropy) for layer in model.layers)
    end

    function (model::KAN)(x; update_grid=false)
        for layer in model.layers
            if update_grid
                update_grid!(layer, x)
            end
            x = layer(x)
        end
        return x
    end
end