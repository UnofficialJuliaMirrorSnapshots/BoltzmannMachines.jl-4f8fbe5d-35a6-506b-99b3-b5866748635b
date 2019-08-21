"""
`Particles` are an array of matrices.
The i'th matrix contains in each row the vector of states of the nodes
of the i'th layer of an RBM or a DBM. The set of rows with the same index define
an activation state in a Boltzmann Machine.
Therefore, the size of the i'th matrix is
(number of samples/particles, number of nodes in layer i).
"""
const Particles = Array{Array{Float64,2},1}

const Particle = Array{Array{Float64,1},1}


function alloc_h_for_v(rbm::AbstractRBM, v::AbstractArray{Float64, 1})
   Vector{Float64}(undef, nhiddennodes(rbm))
end

function alloc_h_for_v(rbm::AbstractRBM, v::AbstractArray{Float64, 2})
   nsamples = size(v, 1)
   Matrix{Float64}(undef, nsamples, nhiddennodes(rbm))
end


function alloc_v_for_h(rbm::AbstractRBM, h::AbstractArray{Float64, 1})
   Vector{Float64}(undef, nvisiblenodes(rbm))
end

function alloc_v_for_h(rbm::AbstractRBM, h::AbstractArray{Float64, 2})
   nsamples = size(h, 1)
   Matrix{Float64}(undef, nsamples, nvisiblenodes(rbm))
end


function bernoulli!(x::M) where{M <:AbstractArray{Float64}}
   for i in eachindex(x)
      @inbounds x[i] = float(rand() < x[i])
   end
   x
end


function binomial2!(x::M) where{M <:AbstractArray{Float64}}
   for i in eachindex(x)
      @inbounds x[i] = float(rand() < x[i]) + float(rand() < x[i])
   end
   x
end


"""
    gibbssample!(particles, bm, nsteps)
Performs Gibbs sampling on the `particles` in the Boltzmann machine model
`bm` for `nsteps` steps. (See also: `Particles`.)
When sampling in multimodal deep Boltzmann machines,
in-between layers are assumed to contain only Bernoulli-distributed nodes.
"""
function gibbssample!(particles::Particles, rbm::AbstractRBM, nsteps::Int = 5,
      upfactor::Float64 = 1.0, downfactor::Float64 = 1.0)

   for i = 1:nsteps
      samplevisible!(particles[1], rbm, particles[2], downfactor)
      samplehidden!(particles[2], rbm, particles[1], upfactor)
   end
   particles
end

function gibbssample!(particles::Particles, dbm::MultimodalDBM, nsteps::Int = 5)

   input = newparticleslike(particles)
   input2 = newparticleslike(particles)

   tmp = Particles(undef, length(dbm) + 1)

   for step in 1:nsteps
      # first layer gets input only from layer above
      samplevisible!(input[1], dbm[1], particles[2])

      # intermediate layers get input from layers above and below
      for i = 2:(length(particles) - 1)
         visibleinput!(input[i], dbm[i], particles[i+1])
         hiddeninput!(input2[i], dbm[i-1], particles[i-1])
         input[i] .+= input2[i]
         sigm_bernoulli!(input[i]) # Bernoulli-sample from total input
      end

      # last layer gets only input from layer below
      samplehidden!(input[end], dbm[end], particles[end-1])

      # swap input and particles
      tmp .= particles
      particles .= input
      input .= tmp
   end

   particles
end


"""
    gibbssamplecond!(particles, bm, cond, nsteps)
Conditional Gibbs sampling on the `particles` in the `bm` for `nsteps`
Gibbs sampling steps.

The variables that are marked in the indexing vector `cond` are fixed
to the initial values in `particles` during sampling. This way, conditional
sampling is performed on these variables.

See also: `Particles`, `initparticles`
"""
function gibbssamplecond!(particles::Particles, bm::AbstractBM,
      fixedvars,
      nsteps::Int = 5)

   varmask = falses(size(particles[1], 2))
   varmask[fixedvars] .= true
   gibbssamplecond!(particles, bm, varmask, nsteps)
end

function gibbssamplecond!(particles::Particles, rbm::AbstractRBM,
      varmask::AbstractVector{Bool},
      nsteps::Int = 5)

   nsamples = size(particles[1], 1)
   mask = repeat(varmask', nsamples)
   origvisibles = deepcopy(particles[1])

   for i = 1:nsteps
      samplevisible!(particles[1], rbm, particles[2])
      particles[1][mask] = origvisibles[mask]
      samplehidden!(particles[2], rbm, particles[1])
   end
   particles
end

function gibbssamplecond!(particles::Particles, dbm::MultimodalDBM,
      varmask::AbstractVector{Bool},
      nsteps::Int = 5)

   input = newparticleslike(particles)
   input2 = newparticleslike(particles)

   tmp = Particles(undef, length(dbm) + 1)
   nsamples = size(particles[1], 1)
   mask = repeat(varmask', nsamples)
   origvisibles = deepcopy(particles[1])

   for step in 1:nsteps
      # first layer gets input only from layer above
      samplevisible!(input[1], dbm[1], particles[2])

      # reset visible nodes to original values
      input[1][mask] = origvisibles[mask]

      # intermediate layers get input from layers above and below
      for i = 2:(length(particles) - 1)
         visibleinput!(input[i], dbm[i], particles[i+1])
         hiddeninput!(input2[i], dbm[i-1], particles[i-1])
         input[i] .+= input2[i]
         sigm_bernoulli!(input[i]) # Bernoulli-sample from total input
      end

      # last layer gets only input from layer below
      samplehidden!(input[end], dbm[end], particles[end-1])

      # swap input and particles
      tmp .= particles
      particles .= input
      input .= tmp
   end

   particles
end


"""
    hiddeninput(rbm, v)
Computes the total input of the hidden units in the AbstractRBM `rbm`,
given the activations of the visible units `v`.
`v` may be a vector or a matrix that contains the samples in its rows.
"""
function hiddeninput(rbm::AbstractRBM, v::M) where {M <: AbstractArray{Float64}}
   hiddeninput!(alloc_h_for_v(rbm, v), rbm, v)
end


"""
    hiddeninput!(h, rbm, v)
Like `hiddeninput`, but stores the returned result in `h`.
"""
function hiddeninput!(h::M, rbm::Union{BernoulliRBM, Softmax0BernoulliRBM}, v::M
      ) where{M <: AbstractArray{Float64,1}}

   mul!(h, transpose(rbm.weights), v)
   h .+= rbm.hidbias
end

function hiddeninput!(hh::M, rbm::Union{BernoulliRBM, Softmax0BernoulliRBM}, vv::M
      ) where{M <: AbstractArray{Float64,2}}

   mul!(hh, vv, rbm.weights)
   broadcast!(+, hh, hh, rbm.hidbias')
end

function hiddeninput!(h::M, rbm::Binomial2BernoulliRBM, v::M,
      ) where{M <: AbstractArray{Float64,1}}

   # Hidden input is implicitly doubled
   # because the visible units range from 0 to 2,
   # same code for Binomial2BernoulliRBM as for BernoulliRBM.
   mul!(h, transpose(rbm.weights), v)
   h .+= rbm.hidbias
end

function hiddeninput!(hh::M, rbm::Binomial2BernoulliRBM, vv::M,
      ) where{M <: AbstractArray{Float64,2}}

   # again same code for Binomial2BernoulliRBM as for BernoulliRBM
   mul!(hh, vv, rbm.weights)
   broadcast!(+, hh, hh, rbm.hidbias')
end

function hiddeninput!(h::M, gbrbm::GaussianBernoulliRBM, v::M,
      ) where{M <: AbstractArray{Float64,1}}

   scaledweights = broadcast(/, gbrbm.weights, gbrbm.sd)
   mul!(h, transpose(scaledweights), v)
   h .+= gbrbm.hidbias
end

function hiddeninput!(hh::M, gbrbm::GaussianBernoulliRBM, vv::M,
      ) where{M <: AbstractArray{Float64,2}}

   scaledweights = broadcast(/, gbrbm.weights, gbrbm.sd)
   mul!(hh, vv, scaledweights)
   broadcast!(+, hh, hh, gbrbm.hidbias')
end

function hiddeninput!(h::M, gbrbm::GaussianBernoulliRBM2, v::M,
      ) where{M <: AbstractArray{Float64,1}}

   scaledweights = broadcast(/, gbrbm.weights, gbrbm.sd.^2)
   mul!(h, transpose(scaledweights), v)
   h .+= gbrbm.hidbias
end

function hiddeninput!(hh::M, gbrbm::GaussianBernoulliRBM2, vv::M,
      ) where{M <: AbstractArray{Float64,2}}

   scaledweights = broadcast(/, gbrbm.weights, gbrbm.sd.^2)
   mul!(hh, vv, scaledweights)
   broadcast!(+, hh, hh, gbrbm.hidbias')
end

function hiddeninput!(h::M, prbm::PartitionedRBM, v::M,
      ) where{M <: AbstractArray{Float64,1}}

   for i in eachindex(prbm.rbms)
      visrange = prbm.visranges[i]
      hidrange = prbm.hidranges[i]
      hiddeninput!(view(h, hidrange), prbm.rbms[i], view(v, visrange))
   end
   h
end

function hiddeninput!(hh::M, prbm::PartitionedRBM, vv::M,
      ) where{M <: AbstractArray{Float64,2}}

   for i in eachindex(prbm.rbms)
      visrange = prbm.visranges[i]
      hidrange = prbm.hidranges[i]
      hiddeninput!(view(hh, :, hidrange), prbm.rbms[i], view(vv, :, visrange))
   end
   hh
end


"""
    hiddenpotential(rbm, v)
    hiddenpotential(rbm, v, factor)
Returns the potential for activations of the hidden nodes in the AbstractRBM
`rbm`, given the activations `v` of the visible nodes.
`v` may be a vector or a matrix that contains the samples in its rows.
The potential is a deterministic value to which sampling can be applied to get
the activations.
In RBMs with Bernoulli distributed hidden units, the potential of the hidden
nodes is the vector of probabilities for them to be turned on.

The total input can be scaled with the `factor`. This is needed when pretraining
the `rbm` as part of a DBM.
"""
function hiddenpotential(rbm::AbstractRBM, v::M, factor::Float64 = 1.0
      ) where {M <: AbstractArray{Float64}}

   hiddenpotential!(alloc_h_for_v(rbm, v), rbm, v, factor)
end


"""
    hiddenpotential!(hh, rbm, vv)
    hiddenpotential!(hh, rbm, vv, factor)
Like `hiddenpotential`, but stores the returned result in `hh`.
"""
function hiddenpotential!(hh::M, rbm::AbstractXBernoulliRBM, vv::M,
      factor::Float64 = 1.0) where{M <: AbstractArray{Float64}}

   hiddeninput!(hh, rbm, vv)
   if factor != 1.0
      hh .*= factor
   end
   sigm!(hh)
end

function hiddenpotential!(h::M, bgrbm::BernoulliGaussianRBM, v::M,
      factor::Float64 = 1.0) where{M <: AbstractArray{Float64,1}}

   mul!(h, transpose(bgrbm.weights), v)
   h .+= bgrbm.hidbias
   if factor != 1.0
      h .*= factor
   end
   h
end

function hiddenpotential!(hh::M, bgrbm::BernoulliGaussianRBM, vv::M,
      factor::Float64 = 1.0) where{M <: AbstractArray{Float64,2}}

   mul!(hh, vv, bgrbm.weights)
   broadcast!(+, hh, hh, bgrbm.hidbias')
   if factor != 1.0
      hh .*= factor
   end
   hh
end

function hiddenpotential!(hh::M, prbm::PartitionedRBM, vv::M,
      factor::Float64 = 1.0) where{M <: AbstractArray{Float64,2}}

   for i in eachindex(prbm.rbms)
      visrange = prbm.visranges[i]
      hidrange = prbm.hidranges[i]
      hiddenpotential!(view(hh, :, hidrange), prbm.rbms[i], view(vv, :, visrange),
         factor)
   end
   hh
end


"""
    initparticles(bm, nparticles; biased = false)
Creates particles for Gibbs sampling in an Boltzmann machine
`bm`. (See also: `Particles`)

For Bernoulli distributed nodes, the particles are initialized with
Bernoulli(p) distributed values. If `biased == false`, p is 0.5,
otherwise the results of applying the sigmoid function to the bias values
are used as values for the nodes' individual p's.

Gaussian nodes are sampled from a normal distribution if `biased == false`.
If `biased == true` the mean of the Gaussian distribution is shifted by the
bias vector and the standard deviation of the nodes is used for sampling.
"""
function initparticles(rbm::AbstractRBM, nparticles::Int; biased::Bool = false)
   particles = Particles(undef, 2)
   particles[1] = Matrix{Float64}(undef, nparticles, nvisiblenodes(rbm))
   particles[2] = Matrix{Float64}(undef, nparticles, nhiddennodes(rbm))
   initvisiblenodes!(particles[1], rbm, biased)
   inithiddennodes!(particles[2], rbm, biased)
   particles
end

function initparticles(dbm::MultimodalDBM, nparticles::Int; biased::Bool = false)
   nlayers = length(dbm) + 1
   particles = Particles(undef, nlayers)
   particles[1] = Matrix{Float64}(undef, nparticles, nvisiblenodes(dbm[1]))
   initvisiblenodes!(particles[1], dbm[1], biased)

   for i in 2:nlayers
      particles[i] = Matrix{Float64}(undef, nparticles, nhiddennodes(dbm[i-1]))
      inithiddennodes!(particles[i], dbm[i-1], biased)
   end
   particles
end

function inithiddennodes!(h::M, rbm::AbstractXBernoulliRBM, biased::Bool
      ) where{M <: AbstractArray{Float64}}

   if biased
      h .= sigm.(rbm.hidbias)'
      bernoulli!(h)
   else
      rand!(h, [0.0 1.0])
   end
   h
end

function inithiddennodes!(h::M, rbm::BernoulliGaussianRBM, biased::Bool
   ) where{M <: AbstractArray{Float64}}

   randn!(h)
   if biased
      h .+= rbm.hidbias'
   end
   h
end

function inithiddennodes!(h::M, prbm::PartitionedRBM, biased::Bool
      ) where{M <: AbstractArray{Float64}}

   for i in eachindex(prbm.rbms)
      hidrange = prbm.hidranges[i]
      inithiddennodes!(view(h, :, hidrange), prbm.rbms[i], biased)
   end
   h
end

function initvisiblenodes!(v::M, rbm::BernoulliRBM, biased::Bool
      ) where{M <: AbstractArray{Float64, 2}}

   if biased
      for k in 1:size(v, 2)
         v[:,k] .= sigm(rbm.visbias[k])
      end
      bernoulli!(v)
   else
      rand!(v, [0.0 1.0])
   end
   v
end

function initvisiblenodes!(v::M, b2brbm::Binomial2BernoulliRBM, biased::Bool
   ) where{M <: AbstractArray{Float64, 2}}

   if biased
      for k in 1:size(v, 2)
         v[:,k] .= sigm(b2brbm.visbias[k])
      end
      binomial2!(v)
   else
      rand!(v, [0.0 1.0 1.0 2.0])
   end
   v
end

function initvisiblenodes!(v::M, rbm::GaussianBernoulliRBM, biased::Bool
      ) where{M <: AbstractArray{Float64, 2}}

   randn!(v)
   if biased
      broadcast!(*, v, v, rbm.sd')
      broadcast!(+, v, v, rbm.visbias')
   end
   v
end

function initvisiblenodes!(v::M, rbm::GaussianBernoulliRBM2, biased::Bool
      ) where{M <: AbstractArray{Float64, 2}}

   randn!(v)
   if biased
      v .+= rbm.visbias'
   end
   v
end

function initvisiblenodes!(v::M, rbm::Softmax0BernoulliRBM, biased::Bool
      ) where{M <: AbstractArray{Float64, 2}}

   if biased
      v .= softmax0!(copy(rbm.visbias'), rbm.varranges)
      samplevisiblepotential!(v, rbm)
   else
      v .= 0.0
      nsamples, nvariables = size(v)
      for i in 1:nsamples
         for varrange in rbm.varranges
            k1 = rand(-1:(length(varrange) - 1))
            if k1 >= 0
               v[i, varrange[1] + k1] = 1.0
            end
         end
      end
   end
   v
end

function initvisiblenodes!(v::M, prbm::PartitionedRBM, biased::Bool
      ) where{M <: AbstractArray{Float64, 2}}

   for i in eachindex(prbm.rbms)
      visrange = prbm.visranges[i]
      initvisiblenodes!(view(v, :, visrange), prbm.rbms[i], biased)
   end
   v
end


"""
    nvisiblenodes(rbm)
Returns the number of visible nodes for an RBM.
"""
function nvisiblenodes(rbm::AbstractRBM)
   length(rbm.visbias)
end

function nvisiblenodes(prbm::PartitionedRBM)
   prbm.visranges[end][end]
end


"""
    nhiddennodes(rbm)
Returns the number of visible nodes for an RBM.
"""
function nhiddennodes(rbm::AbstractRBM)
   length(rbm.hidbias)
end

function nhiddennodes(prbm::PartitionedRBM)
   prbm.hidranges[end][end]
end


"""
    samplehidden(rbm, v)
    samplehidden(rbm, v, factor)
Returns activations of the hidden nodes in the AbstractRBM `rbm`, sampled
from the state `v` of the visible nodes.
`v` may be a vector or a matrix that contains the samples in its rows.
For the `factor`, see `hiddenpotential(rbm, v, factor)`.
"""
function samplehidden(rbm::AbstractXBernoulliRBM, v::M,
      factor::Float64 = 1.0) where{M <: AbstractArray{Float64}}
   bernoulli!(hiddenpotential(rbm, v, factor))
end

function samplehidden(bgrbm::BernoulliGaussianRBM, v::M,
      factor::Float64 = 1.0) where{M <: AbstractArray{Float64}}
   h = hiddenpotential(bgrbm, v, factor)
   h .+ randn(size(h))
end


"""
    samplehidden!(h, rbm, v)
    samplehidden!(h, rbm, v, factor)
Like `samplehidden`, but stores the returned result in `h`.
"""
function samplehidden!(h, rbm::AbstractRBM, v::M,
      factor::Float64 = 1.0) where{M <: AbstractArray{Float64}}

   samplehiddenpotential!(hiddenpotential!(h, rbm, v, factor), rbm)
end


"""
    samplehiddenpotential!(h, rbm)
Samples the activation of the hidden nodes from the potential `h`
and stores the returned result in `h`.
"""
function samplehiddenpotential!(h::M, rbm::AbstractXBernoulliRBM
      ) where{M <: AbstractArray{Float64}}

   bernoulli!(h)
end

function samplehiddenpotential!(h::M, rbm::BernoulliGaussianRBM
      ) where{M <: AbstractArray{Float64}}

   h .+= randn(size(h))
end

function samplehiddenpotential!(h::M, prbm::PartitionedRBM
      ) where{M <: AbstractArray{Float64,1}}

   for i in eachindex(prbm.rbms)
      hidrange = prbm.hidranges[i]
      samplehiddenpotential!(view(h, hidrange), prbm.rbms[i])
   end
   h
end

function samplehiddenpotential!(hh::M, prbm::PartitionedRBM
      ) where{M <: AbstractArray{Float64,2}}

   for i in eachindex(prbm.rbms)
      hidrange = prbm.hidranges[i]
      samplehiddenpotential!(view(hh, :, hidrange), prbm.rbms[i])
   end
   hh
end


"""
    sampleparticles(bm, nparticles, burnin)
Samples in the Boltzmann Machine model `bm` by running `nparticles` parallel,
randomly initialized Gibbs chains for `burnin` steps.
Returns particles containing `nparticles` generated samples.
See also: `Particles`.
"""
function sampleparticles(bm::AbstractBM, nparticles::Int, burnin::Int = 10)
   particles = initparticles(bm, nparticles)
   gibbssample!(particles, bm, burnin)
   particles
end


"""
    samples(bm, nsamples; ...)
Generates `nsamples` samples from a Boltzmann machine model `bm` by running
a Gibbs sampler.
This can also be used for sampling from a *conditional distribution*
(see argument `conditions` below.)

# Optional keyword arguments:
* `burnin`: Number of Gibbs sampling steps, defaults to 50.
* `conditions`: `Vector{Pair{Int,Float64}}`, containing pairs of variables
  and their values that are to be conditioned on. E. g. `[1 => 1.0, 3 => 0.0]`
* `samplelast`: boolean to indicate whether to sample in last step (true, default)
  or whether to use the activation potential.
"""
function samples(bm::AbstractBM, nsamples::Int;
      burnin::Int = 50,
      conditions::Vector{Pair{Int,Float64}} = Vector{Pair{Int,Float64}}(),
      samplelast::Bool = true)

   particles = initparticles(bm, nsamples)

   firstlayer(rbm::AbstractRBM) = rbm
   firstlayer(dbm::MultimodalDBM) = dbm[1]

   if !samplelast
      burnin = burnin - 1
   end

   if isempty(conditions)
      gibbssample!(particles, bm, burnin)
      if !samplelast
         visiblepotential!(particles[1], firstlayer(bm), particles[2])
      end
   else
      varmask = falses(size(particles[1], 2))
      for condition in conditions
         varmask[condition[1]] = true
         particles[1][:, condition[1]] .= condition[2]
      end
      gibbssamplecond!(particles, bm, varmask, burnin)
      if !samplelast
         visiblepotential!(particles[1], bm[1], particles[2])
         for condition in conditions
            particles[1][:, condition[1]] .= condition[2]
         end
      end
   end

   # return the visible layer's activations
   particles[1]
end


function samples(rbm::AbstractRBM, init::Matrix{Float64};
      burnin::Int = 50,
      samplelast::Bool = true)

   particles = Particles(2)
   particles[2] = Matrix{Float64}(size(init, 1), size(rbm.weights, 2))
   particles[1] = copy(init)

   nsamplingsteps = samplelast ? burnin : burnin - 1

   gibbssample!(particles, rbm, nsamplingsteps)

   if !samplelast
      samplehidden!(particles[2], rbm, particles[1])
      visiblepotential!(particles[1], rbm, particles[2])
   end

   particles[1]
end


"""
    samplevisible(rbm, h)
    samplevisible(rbm, h, factor)
Returns activations of the visible nodes in the AbstractRBM `rbm`, sampled
from the state `h` of the hidden nodes.
`h` may be a vector or a matrix that contains the samples in its rows.
For the `factor`, see `visiblepotential(rbm, h, factor)`.
"""
function samplevisible(rbm::AbstractRBM, h::M,
      factor::Float64 = 1.0) where{M <: AbstractArray{Float64}}

   samplevisible!(alloc_v_for_h(rbm, h), rbm, h, factor)
end


"""
    samplevisible!(v, rbm, h)
    samplevisible!(v, rbm, h, factor)
Like `samplevisible`, but stores the returned result in `v`.
"""
function samplevisible!(v::M, rbm::AbstractRBM, h::M,
      factor::Float64 = 1.0) where{M <: AbstractArray{Float64}}

   samplevisiblepotential!(visiblepotential!(v, rbm, h, factor), rbm)
end

# TODO specialize for Binomial2BernoulliRBM to avoid multiplication and division by 2

"""
    samplehiddenpotential!(v, rbm)
Samples the activation of the visible nodes from the potential `v`
and stores the returned result in `v`.
"""
function samplevisiblepotential!(v::M,
      rbm::Union{BernoulliRBM, BernoulliGaussianRBM},
      ) where{M <: AbstractArray{Float64}}

   bernoulli!(v)
end

function samplevisiblepotential!(v::M, b2brbm::Binomial2BernoulliRBM
      ) where{M <: AbstractArray{Float64}}
   v ./= 2
   binomial2!(v)
end

function samplevisiblepotential!(v::M,
      gbrbm::Union{GaussianBernoulliRBM, GaussianBernoulliRBM2}
      ) where{M <: AbstractArray{Float64, 1}}

   gaussiannoise = randn(length(v))
   gaussiannoise .*= gbrbm.sd
   v .+= gaussiannoise
end

function samplevisiblepotential!(v::M,
      gbrbm::Union{GaussianBernoulliRBM, GaussianBernoulliRBM2}
      ) where{M <: AbstractArray{Float64, 2}}

   gaussiannoise = randn(size(v))
   gaussiannoise .*= gbrbm.sd'
   v .+= gaussiannoise
end

function samplevisiblepotential!(vv::M, prbm::PartitionedRBM
      ) where{M <: AbstractArray{Float64,2}}

   for i in eachindex(prbm.rbms)
      visrange = prbm.visranges[i]
      samplevisiblepotential!(view(vv, :, visrange), prbm.rbms[i])
   end
end

function samplevisiblepotential!(vv::M,
      s0brbm::Softmax0BernoulliRBM
      ) where{M <: AbstractArray{Float64, 2}}

   for varrange in s0brbm.varranges
      for i in 1:size(vv, 1)
         probsum = 0.0
         p = rand()
         for k in varrange
            probsum += vv[i, k]
            if p <= probsum
               vv[i, k] = 1.0
               vv[i, (k+1):varrange[end]] .= 0.0
               break
            else
               vv[i, k] = 0.0
            end
         end
      end
   end
   vv
end


function sigm(x::Float64)
   1 ./ (1 + exp(-x))
end


function sigm!(x::M) where{M <:AbstractArray{Float64}}
   for i in eachindex(x)
      @inbounds x[i] = 1.0/(1.0 + exp(-x[i]))
   end
   x
end


function sigm_bernoulli!(input::Particles)
   for i in eachindex(input)
      sigm_bernoulli!(input[i])
   end
   input
end

# const pgrid = collect(linspace(0.00001,0.99999,99999))
# const etagrid = log.(pgrid./(1.0-pgrid))

function sigm_bernoulli!(input::Matrix{Float64})
   for i in eachindex(input)
      @inbounds input[i] = 1.0*(rand() < 1.0/(1.0 + exp(-input[i])))
      # @inbounds input[i] = 1.0*(etagrid[Int(round(rand()*99998.0+1))] < input[i])
   end
   input
end


"""
    softmax0!(x)
    softmax0!(x, varranges)
If `x` is a vector, `softmax0!(x)` will apply the softmax transformation
to the  vector `[x; 0.0]` and store the results for the values of `x` in `x`.
(The value for 0.0 is omitted since it is determined by `1 - sum(softmax!(x))`).

If `x` is a matrix, the transformation will be applied to all rows of `x`.
If an additional vector `varranges` with `UnitRange`s of column indices is
specified, the transformation will be applied to the groups of columns separately.
"""
function softmax0!(x::V) where {V <: AbstractArray{Float64,1}}
   m = maximum(x)
   x .= exp.(x .- m)
   # divide through sum, account for zero element
   x ./= sum(x) + exp(-m)
   x
end

function softmax0!(x::M) where {M <: AbstractArray{Float64,2}}
   for i in 1:size(x, 1)
      @inbounds softmax0!(view(x, i, :))
   end
   x
end

function softmax0!(x::M, varranges::Vector{UnitRange{Int}}
      ) where {M <: AbstractArray{Float64,2}}

   for varrange in varranges
      softmax0!(view(x, :, varrange))
   end
   x
end


"""
    visibleinput(rbm, h)
Returns activations of the visible nodes in the AbstractXBernoulliRBM `rbm`,
sampled from the state `h` of the hidden nodes.
`h` may be a vector or a matrix that contains the samples in its rows.
"""
function visibleinput(rbm::AbstractRBM, h::M) where {M <: AbstractArray{Float64}}

   visibleinput!(alloc_v_for_h(rbm, h), rbm, h)
end


"""
    visibleinput!(v, rbm, h)
Like `visibleinput` but stores the returned result in `v`.
"""
function visibleinput!(v::M,
      rbm::Union{BernoulliRBM, BernoulliGaussianRBM,
            Binomial2BernoulliRBM, Softmax0BernoulliRBM},
      h::M) where {M <:AbstractArray{Float64,1}}

   mul!(v, rbm.weights, h)
   v .+= rbm.visbias
end

function visibleinput!(vv::M,
      rbm::Union{BernoulliRBM, BernoulliGaussianRBM,
            Binomial2BernoulliRBM, Softmax0BernoulliRBM},
      hh::M) where {M <:AbstractArray{Float64,2}}

   mul!(vv, hh, transpose(rbm.weights))
   broadcast!(+, vv, vv, rbm.visbias')
end

function visibleinput!(v::M, prbm::PartitionedRBM, h::M
      ) where{M <: AbstractArray{Float64,1}}

   for i in eachindex(pbrbm.rbms)
      visrange = prbm.visranges[i]
      hidrange = prbm.hidranges[i]
      visibleinput!(view(v, visrange), prbm.rbms[i], view(h, hidrange))
   end
   v
end

function visibleinput!(v::M, prbm::PartitionedRBM, h::M
      ) where{M <: AbstractArray{Float64,2}}

   for i in eachindex(prbm.rbms)
      visrange = prbm.visranges[i]
      hidrange = prbm.hidranges[i]
      visibleinput!(view(v, :, visrange), prbm.rbms[i], view(h, :, hidrange))
   end
   v
end


"""
    visiblepotential(rbm, h)
    visiblepotential(rbm, h, factor)
Returns the potential for activations of the visible nodes in the AbstractRBM
`rbm`, given the activations `h` of the hidden nodes.
`h` may be a vector or a matrix that contains the samples in its rows.
The potential is a deterministic value to which sampling can be applied to get
the activations.

The total input can be scaled with the `factor`. This is needed when pretraining
the `rbm` as part of a DBM.

In RBMs with Bernoulli distributed visible units, the potential of the visible
nodes is the vector of probabilities for them to be turned on.

For a Binomial2BernoulliRBM, the visible units are sampled from a
Binomial(2,p) distribution in the Gibbs steps. In this case, the potential is
the vector of values for 2p.
(The value is doubled to get a value in the same range as the sampled one.)

For GaussianBernoulliRBMs, the potential of the visible nodes is the vector of
means of the Gaussian distributions for each node.
"""
function visiblepotential(rbm::AbstractRBM, h::M,
      factor::Float64 = 1.0) where {M <: AbstractArray{Float64}}

   visiblepotential!(alloc_v_for_h(rbm, h), rbm, h, factor)
end


"""
    visiblepotential!(v, rbm, h)
Like `visiblepotential` but stores the returned result in `v`.
"""
function visiblepotential!(v::M, rbm::Union{BernoulliRBM, BernoulliGaussianRBM},
      h::M, factor::Float64 = 1.0) where {M <: AbstractArray{Float64}}

   visibleinput!(v, rbm, h)
   if factor != 1.0
      v .*= factor
   end
   sigm!(v)
end

function visiblepotential!(v::M, rbm::Binomial2BernoulliRBM, h::M,
      factor::Float64 = 1.0) where{M <: AbstractArray{Float64}}

   visibleinput!(v, rbm, h)
   if factor != 1.0
      v .*= factor
   end
   sigm!(v)
   v .*= 2.0
end

function visiblepotential!(v::M, gbrbm::GaussianBernoulliRBM,
      h::M, factor::Float64 = 1.0
      ) where{M <: AbstractArray{Float64,1}}

   mul!(v, gbrbm.weights, h)
   v .*= gbrbm.sd
   v .+= gbrbm.visbias
end

function visiblepotential!(v::M, gbrbm::GaussianBernoulliRBM, h::M,
      factor::Float64 = 1.0) where{M <: AbstractArray{Float64,2}}

   mul!(v, h, transpose(gbrbm.weights))
   broadcast!(*, v, v, gbrbm.sd')
   broadcast!(+, v, v, gbrbm.visbias')
end

function visiblepotential!(v::M,
      gbrbm::GaussianBernoulliRBM2,
      h::M, factor::Float64 = 1.0
      ) where{M <: AbstractArray{Float64,1}}

   mul!(v, gbrbm.weights, h)
   v .+= gbrbm.visbias
end

function visiblepotential!(v::M,
      gbrbm::GaussianBernoulliRBM2, h::M,
      factor::Float64 = 1.0) where{M <: AbstractArray{Float64,2}}

   mul!(v, h, transpose(gbrbm.weights))
   broadcast!(+, v, v, gbrbm.visbias')
end

function visiblepotential!(v::M, rbm::Softmax0BernoulliRBM,
      h::M, factor::Float64 = 1.0) where {M <: AbstractArray{Float64,1}}

   visibleinput!(v, rbm, h)
   if factor != 1.0
      v .*= factor
   end
   for varrange in rbm.varranges
      softmax0!(view(v, varrange))
   end
   v
end

function visiblepotential!(vv::M, rbm::Softmax0BernoulliRBM,
      hh::M, factor::Float64 = 1.0) where {M <: AbstractArray{Float64,2}}

   visibleinput!(vv, rbm, hh)
   if factor != 1.0
      vv .*= factor
   end
   softmax0!(vv, rbm.varranges)
   vv
end

function visiblepotential!(v::M, prbm::PartitionedRBM, h::M,
      factor::Float64 = 1.0) where{M <: AbstractArray{Float64,2}}

   for i in eachindex(prbm.rbms)
      visrange = prbm.visranges[i]
      hidrange = prbm.hidranges[i]
      visiblepotential!(view(v, :, visrange), prbm.rbms[i], view(h, :, hidrange))
   end
   v
end
