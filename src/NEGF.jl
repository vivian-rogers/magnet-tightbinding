push!(LOAD_PATH,"./")

module NEGF
using LinearAlgebra
using Constants
using Operators
using UsefulFunctions
using SparseArrays
using Electrodes
using Distributed
using ProgressBars
using Random

export NEGF_prep, totalT, DOS, siteDOS, sitePDOS


function NEGF_prep(p::NamedTuple,H::Function, Σks::Vector{Function})
	# some recipe for properly hooking up electrodes???
	#then 
	ntot = p.n*p.nsite*p.norb*2
	Γks = Vector{Function}(undef,size(Σks))
	for i = 1:p.nelectrodes
		function Γ(k::Vector{Float64})
			Σₖ = Σks[i](k)
			function Γₖ(E::Float64)
				Σ = Σₖ(E)
				#return -2*imag(Σ) # weird def in weyl MTJ paper
				return im*(Σ .- Σ')
			end
		end
		Γks[i] = deepcopy(Γ)
	end
	# Gamma matrices are useful too...
	function totΣk(E::Float64,k::Vector{Float64})
		Σs = Vector{Function}(undef,size(Σks))
		for iΣ in eachindex(Σks)
			Σk = Σks[iΣ](k)
			Σs[iΣ] = Σk
		end
		totalΣ = spzeros(ComplexF64,p.n*p.nsite*p.norb*2,p.n*p.nsite*p.norb*2)
		i = 1
		for Σ in Σs
			totalΣ .+= Σ(E)
			i += 1
		end
		return totalΣ
	end
	function genGʳ(k::Vector{Float64})
                function Gʳ(E::Float64)
			Σ = totΣk(E,k)
                        effH = (E + im*p.η)*I(ntot) .- H(k) .- Σ
                        #G = grInv(effH)
			#G = pGrInv(effH,4,"transport")
	                if(p.l_scattering > 0)
			    G = pGrInv(effH,4,false)
                            η_scattering = (ħ/q)*vf/(2*p.l_scattering) 
                            error = 1
                            mixing = 0.5
                            while(error > 10^-6)
                                Gprev = copy(G)
                                #effH = Array((E + im*p.η)*I(ntot) .- H(k) .- Σ .- p.η_scattering*G)
                                effH = (E + im*p.η)*I(ntot) .- H(k) .- Σ .- η_scattering*(I(p.n*p.norb)⊗[1 1; 1 1]).*G
                                G = mixing*pGrInv(effH,4,false) .+ (1-mixing)*G
				#G = grInv(effH)
                                error = norm((G.-Gprev),1)/norm(G,1)
                                println("Error = $error")
                            end
                        end
                        if(p.n_BLAS > 1)
			    G = inv(Array(effH))
                        else
			    G = grInv(effH)
			end
			return G
		end
		return Gʳ
	end
	function genT(k::Vector{Float64}, contact::Int = 2)
	#function genT(E::Float64, contact::Int = 2)
		Gʳ = genGʳ(k)
		Γ₁ = Γks[1](k)
		Γᵢ = Γks[contact](k)
		function Tatk(E)
			GʳE = Gʳ(E)
			#return tr(GʳE*Γ₁(E)*GʳE'*Γᵢ(E))
			return Γ₁(E)*GʳE*Γᵢ(E)*GʳE'
		end
		return Tatk
	end
	function genA(k::Vector{Float64})
		Gʳ = genGʳ(k)
		function A(E::Float64)
			GʳE = Gʳ(E)
                        A = im*(GʳE.-GʳE')
			#Σ = totΣk(E,k)
			#return GʳE*im*(Σ .- Σ')*GʳE'
		end
		return A
	end
	function genScatteredT(k::Vector{Float64}, contact::Int=2)
                Dm = (ħ/q)*vf/(2*p.l_scattering) 
                Dₘ = Dm*I(p.n)⊗(ones(p.norb,p.norb)⊗ones(2,2))
                if(p.l_scattering ≈ 0)
                    return genT(k)
                    #Dₘ = zeros(ntot,ntot)
                end
                fL = fermi(-p.δV/2,p.T); fR = fermi(p.δV/2,p.T);
		function linearConductance(E::Float64)
                    Σ = totΣk(E,k)
                    Gʳ = inv(Array((E + im*p.η)*I(ntot) .- H(k) .- Σ))
                    Γ₁E = sparse(Γks[1](k)(E))
                    ΓᵢE = sparse(Γks[contact](k)(E))
                    # loop to converge Gʳ
                    error = 1
                    mixing = 0.7; cutoff = 10^-6
                    while(error > cutoff)
                        Gʳ0 = copy(Gʳ)
                        Hofk = H(k)
                        println("Dm = $(Dm), size H = $(size(Hofk)), size Σ = $(size(Σ)), size Σ_m = $(size(Dₘ.*Gʳ))")
                        #display(Array(Gʳ))
                        #display(Array(Hofk))
                        #display(Array(Σ))
                        #display(Array(Dₘ.*Gʳ))
                        Gʳ = inv(Array((E + im*p.η)*I(ntot) .- Hofk .- Σ .- Dₘ.*Gʳ))
                        Gʳ = mixing*Gʳ .+ (1-mixing)*Gʳ0
                        error = norm((Gʳ.-Gʳ0),1)/norm(Gʳ,1)
                        println("Gʳ error = $error")
                    end
                    # now loop to converge Gⁿ
                    error = 1
                    Gⁿ = Gʳ*(ΓᵢE*fL .+ Γ₁E*fR)*(Gʳ)'
                    Σin = Dₘ.*Gⁿ
                    while(error > cutoff)
                        Gⁿ0 = copy(Gⁿ)
                        Gⁿ = Gʳ*dropzeros(ΓᵢE*fL .+ Γ₁E*fR .+ Σin)*(Gʳ)'
                        Gⁿ = mixing*Gⁿ .+ (1-mixing)*Gⁿ0
                        Σin = sparse(Dₘ.*Gⁿ)
                        error = norm((Gⁿ.-Gⁿ0),1)/norm(Gⁿ,1)
                        println("Gⁿ error = $error")
                    end
                    A = im*(Gʳ.-Gʳ')
                    Top = (Σin*A .- Γ₁E*Gⁿ)/(fR-fL)
                    return Top
		end
		return linearConductance
	end
	return genGʳ, genT, genA, genScatteredT
end

#function DOS(genA::Function,kvals::Vector{Vector{Float64}},kpts::Vector{Float64},E_samples::Vector{Float64})
#    DOS_samples = pmap(E->tr(genA(E))/π,E_samples)
#
#    return DOS_samples
#end
function DOS(genA::Function,kgrid::Vector{Vector{Float64}},kweights::Vector{Float64},Evals::Vector{Float64},parallelk::Bool=true)
	nE = size(Evals)
	#nkz = maximum([kindex[2] for kindex in kindices])
	#nky = maximum([kindex[1] for kindex in kindices])
	#special slice to map BZ
	nk = size(kweights)[1]
	#Eslice = findnearest(Evals,Eslice) #make it so that we do not have to do a whole nother k loop
	#TmapList = zeros(nk)
	DOS = zeros(nE)
	if(parallelk)
		#BLAS.set_num_threads(1) # disable linalg multithreading and parallelize over k instead
		iter = ProgressBar(1:nk)
		knum = shuffle([i for  i = 1:nk])
                #for ik in iter
                Threads.@threads for ik in iter
                        i = knum[ik] # this is to shuffle the kpt allocations so no processor gets a dense section of grid
                        k = kgrid[i]
                        w = kweights[i]
                        Aₖ = genA(k)
                        for iE in eachindex(Evals)
                                E = Evals[iE]
                                Dₖ = deepcopy(tr(Aₖ(E)))/π
                                #TofE[iE] += real(Dₖ*w)
                                DOS[iE] += real(im*Dₖ*w)
                        end
		end
	else
		#BLAS.set_num_threads(1) # disable linalg multithreading and parallelize over k instead
		knum = shuffle([i for  i = 1:nk])
		for ik = 1:nk
				i = knum[ik] # this is to shuffle the kpt allocations so no processor gets a dense section of grid
				k = kgrid[i]
				#kindex = kindices[i]
				w = kweights[i]
				Aₖ = genA(k)
				iter = ProgressBar(1:size(Evals)[1])
				for iE in iter
				#Threads.@threads for iE in iter
                                    E = Evals[iE]
                                    Dₖ = deepcopy(tr(Aₖ(E)))/π
                                    #DOS[iE] += real(Dₖ*w)
                                    DOS[iE] += real(im*Dₖ*w)
                                    #=if(E≈Eslice)
                                            Tmap[kindex[1],kindex[2]] = real(T)
                                            TmapList[i] = real(T)
                                    end=#
				end
		end
	end
	return DOS
end

function sitePDOS(p::NamedTuple, genGʳ::Function, Os, E::Float64=0.1*eV)
    function DOS(k::Vector{Float64})
            totToSite = sparse(I(p.nx*p.ny*p.nz)⊗(ones(p.norb*2)')) 
            Gʳ = genGʳ(k)(E);
            #SiteGᴿ = totToSite*(diag(Gᴿ))
            #display(Gᴿ); println(""); display(SiteGᴿ); println(""); display(totToSite)
            
            #DOS = (-1/π)*imag.(SiteGᴿ)
            return [Array((-1/π)*imag.(totToSite*diag(O*Gʳ))) for O in Os]
    end
    return DOS
end

function siteDOS(p::NamedTuple, genGᴿ::Function, E::Float64=0.1*eV)
    function DOS(k::Vector{Float64})
        totToSite = sparse(I(p.nx*p.ny*p.nz)⊗(ones(p.norb*2)')) 
		Gᴿ = genGᴿ(k)(E);
		SiteGᴿ = totToSite*(diag(Gᴿ))
		#display(Gᴿ); println(""); display(SiteGᴿ); println(""); display(totToSite)
		DOS = (-1/π)*imag.(SiteGᴿ)
            return Array(DOS)
    end
    return DOS
end


function totalT(genT::Function,kindices::Vector{Vector{Int}},kgrid::Vector{Vector{Float64}},kweights::Vector{Float64},Evals::Vector{Float64},Eslice::Float64,parallel::Bool,Qs::Vector{AbstractMatrix})
	nE = size(Evals)
        nOps = size(Qs)
	nkz = maximum([kindex[2] for kindex in kindices])
	nky = maximum([kindex[1] for kindex in kindices])
	#special slice to map BZ
	nk = size(kweights)[1]
	#Eslice = findnearest(Evals,Eslice) #make it so that we do not have to do a whole nother k loop
	Tmap = zeros(nky,nkz)
	imTmap = zeros(nky,nkz)
	#TmapList = zeros(nk)
	TofE = zeros(nE)
        #for Q in Qs
            if(parallel)
		#BLAS.set_num_threads(1) # disable linalg multithreading and parallelize over k instead
		iter = ProgressBar(1:nk)
		knum = shuffle([i for  i = 1:nk])
		approxIn(E,Evals) = any(map(Ei->Ei≈E,Evals))
		Threads.@threads for ik = 1:nk
		#@distributed for ik in iter
		#Threads.@threads for ik in iter
				i = knum[ik] # this is to shuffle the kpt allocations so no processor gets a dense section of grid
				k = kgrid[i]
				kindex = kindices[i]
				w = kweights[i]
				Tₖ = genT(k)
				if(approxIn(Eslice, Evals))
					for iE in eachindex(Evals)
						E = Evals[iE]
                                                T = tr(Tₖ(E)*Q)
						TofE[iE] += real(T*w)
						if(E≈Eslice)
                                                        Tmap[kindex[1],kindex[2]] = real(T)
						end
					end
				elseif(typeof(Eslice) == Float64) 
					for iE in eachindex(Evals)
						E = Evals[iE]
                                                T = tr(Tₖ(E))
						TofE[iE] += real(T*w)
					end
					Tmap[kindex[1],kindex[2]] = real(Tₖ(Eslice))
				else
					for iE in eachindex(Evals)
						E = Evals[iE]
                                                T = tr(Tₖ(E))
						TofE[iE] += real(T*w)
					end
				end
		end
            else
		#BLAS.set_num_threads(1) # disable linalg multithreading and parallelize over k instead
		knum = shuffle([i for  i = 1:nk])
		for ik = 1:nk
				i = knum[ik] # this is to shuffle the kpt allocations so no processor gets a dense section of grid
				k = kgrid[i]
				kindex = kindices[i]
				w = kweights[i]
				Tₖ = genT(k)
				
				#=TₖofE = real.(pmap(E -> Tₖ(E), Evals))
				TofE .+= TₖofE*w
				=#
				iter = ProgressBar(1:size(Evals)[1])
				for iE = 1:size(Evals)[1]
			        #for iE in iter
				#Threads.@threads for iE in iter
                                    E = Evals[iE]
                                    T = tr((Tₖ(E)))
                                    TofE[iE] += real(T*w)
                                    #=if(E≈Eslice)
                                            Tmap[kindex[1],kindex[2]] = real(T)
                                            TmapList[i] = real(T)
                                    end=#
				end
                                if(nk <= 1)
                                    Tmap[kindex[1],kindex[2]] = TofE[1]
                                else
                                    Tmap[kindex[1],kindex[2]] = real(tr(Tₖ(Eslice)))
                                end
		end
            end
	#end
	return TofE, Tmap
end

			
function DOS(E::Float64,A::Function,Q::Vector = I(size(A(0))[1]))
	return (1/(2*π))*tr(Q*A)
end






function xyztoi(p,ivec, N::Vector{Int} = [0;0;0]) 
	# indexing 0 to N-1
	# in case the A₂ lattice vector != C*[0;1;0]
	diy = Int(round(p.SLa₂[1]/p.a₁[1]))*N[2]
	#ix = ivec[1]; iy = ivec[2]; iz = ivec[3]; isite = ivec[4]; iorb = ivec[5]
	ix = mod(ivec[1],p.nx); iy = mod(ivec[2] + diy,p.ny); iz = mod(ivec[3],p.nz); isite = ivec[4]; iorb = ivec[5]
	#ix = mod(ivec[1],p.nx); iy = mod(ivec[2],p.ny); iz = mod(ivec[3],p.nz); isite = ivec[4]; iorb = ivec[5]
	return iorb + p.norb*isite + p.nsite*p.norb*ix + p.nsite*p.norb*p.nx*iy + p.nsite*p.norb*p.nx*p.ny*iz + 1
end

# Same as above, except returns the corresponding atomic position of each index vector 
# useful for calculating ∫A⋅δR peierls phase
function xyztor(p,ivec)
	ix = ivec[1]; iy = ivec[2]; iz = ivec[3]; isite = ivec[4];
	δdict = Dict(0 => p.A*[0.0; 0.0; 0.0], #In 1 
		     1 => p.A*[0.5; 0.5; 0.5]) #In 2
		     #2 => p.A*[0.0; 0.5; 0.8975-0.5], #Bi 1
		     #3 => p.A*[0.5; 0.0; 1.10248-0.5]) #Bi 2
	δ = δdict[isite]
	R = p.a₁*ix + p.a₂*iy + p.a₃*iz + δ
        #println("ivec = $ivec, Rpos = $R")
        return R
end

function RvalsGen(p)
	N = p.n*p.nsite
	R = Vector{Vector{Float64}}(undef,N)
	for ix = 0:(p.nx-1)
		for iy = 0:(p.ny-1)
			for iz = 0:(p.nz-1)
				for isite = 0:(p.nsite-1)
					iR = Int(1 + isite + ix*p.nsite + iy*p.nx*p.nsite + iz*p.ny*p.nx*p.nsite)
					#println("$ix $iy $iz $isite iR $iR")
					ivec = Int.([ix,iy,iz,isite])
                                        Rval = xyztor(p,ivec)
                                        R[iR] = deepcopy(Rval)
                                        #if(Rval[3] > p.a₃[3]*(p.nz-1))
                                        #    println("ivec = $ivec, Rpos = $Rval")
                                        #end
                                end
			end
		end
	end
        #println("maximum R = $(maximum([pos[3] for pos in R])), expected height = $((p.nz-1)*p.a₃[3])")
	return R # needs ⊗I(p.norb)⊗I(2) for full (spinful) hilbert space
end

# Defines a cᵦ†cₐ term 
mutable struct Hopping
	a::Int # orbital/site index 1
	b::Int # orbital/site index 2 with PBC
	ia # index vector of site A
	ib # index vector of site B without PBC
	ra # location of atom a
	rb # location of atom b
	r # radius from a to b
	t  # hopping parameter affiliated with c†₂c₁ in spin basis. (i.e., t*I(2) or t*σ₊ might make sense)
	edge::Bool # does this hop off the edge of the superlattice?
	N # vector describing the [n₁;n₂;n₃]⋅[a₁;a₂;a₃] superlattice unit cell of site ib
	desc::String
end


function genElectrodes(p,type="weyl")

    return Σ
end

function oldΣgen(p::NamedTuple,H::Matrix,H_coupling::Matrix, cutoff::Float64=10^-7*eV)
    n = p.nsite*p.norb*2
    # so H needs to be instantiated and called outside of the loop
    function Σ(E::Float64)
        Σ_guess = (E*I(n) - H - 0.1*I(n))^-1
        # converge the self energy 
        error = 1
        while error > cutoff
            #println("Σ convergence error: $error")
            Σ_guess0 = deepcopy(Σ_guess)
            Σ_guess = H_coupling'*grInv((E+p.η)*I(n).-H.-Σ_guess)*H_coupling
            error =  norm(Σ_guess-Σ_guess0)
        end
        Σ_surf = H_coupling'*grInv((E+p.η)*I(n).-H.-Σ_guess)*H_coupling
        return Σ_surf
    end
    return Σ
end

# Generate H₀ and make a list of edge bonds for generating H(k)
function nnHoppingMat(NNs,p)
	N = p.n*p.nsite*p.norb
	H = spzeros(ComplexF64,2*N,2*N)
	edgeNNs = Any[]
	for NN in NNs
		if(NN.edge == true)
			push!(edgeNNs,deepcopy(NN))
		else
			H[2*NN.b-1, 2*NN.a-1] += NN.t[1,1]
			H[2*NN.b  , 2*NN.a-1] += NN.t[2,1]
			H[2*NN.b-1, 2*NN.a  ] += NN.t[1,2]
			H[2*NN.b  , 2*NN.a  ] += NN.t[2,2]
		end
	end
	return H, edgeNNs
end

# Add a bond to the list of bonds, given some list of bonds, coefficient in spin basis, index of both sites, and param list
function pushHopping!(NNs::Vector, t, ia::Vector{Int}, ib::Vector{Int}, p) 
	a = xyztoi(p,ia); b = xyztoi(p,ib);
	ra = xyztor(p,ia); rb = xyztor(p,ib); r = rb - ra;
	# for hopping term
	NN = deepcopy(Hopping(a,b,ia,ib,ra,rb,r,t, false, [0;0;0],""))
	push!(NNs,NN)
end

rot(θ) = [cos(θ) -sin(θ); sin(θ) cos(θ)]


function genNNs(p) # all of the terms in the hamiltonian get added here, get back the relevant bonds
	n = p.n
	NNs = Hopping[]
	
	function nextsite(isite::Int)
		return -2*isite + 1
		#if == 0 return 1
		#if == 1 return -1
		#return mod(isite+1,p.nsite)
	end
	orb = 0;
	# loop over each unit cell site in the superlattice
	for iy = 0:(p.ny-1)
		for iz = 0:(p.nz-1)
			for ix = 0:(p.nx-1)
				isite = 0
				for iorb = 0:(p.norb-1)
					ia = copy([ix,iy,iz,isite,iorb]);
					t = 3*nextsite(iorb)*p.t*(I(2))
					pushHopping!(NNs, t, ia, ia, p)
					for ax = 1:3
						for dir = [-1,1]
							# for weyl term in hamiltonian
							di = zeros(5); di[ax] = dir; di[5] = nextsite(iorb); ib = Int.(ia + di)
							Ra = xyztor(p,ia); Rb = xyztor(p,ib); 
							δ = Rb - Ra
							# implement H = +vf*𝐩⋅𝛔 = -vf𝑖ħ ∇ᵣ⋅σ on finite grid
							t = (-im/2)*dir*p.t*σ[ax]
							if(any(isnan,t)==true)
								throw(DomainError(t, "Something broken in hamiltonian definition! Returning NaN"))
								return
							end
							pushHopping!(NNs, t, ia, ib, p)
							# for normal hopping term in hamiltonian
							ib[5] = iorb; 
							
							t = -(1/2)*nextsite(iorb)*p.t*(I(2))
							pushHopping!(NNs, t, ia, ib, p)
						end
					end
				end
			end
		end
	end
	# now fix the designation for the vectors that hop out of the lattice
	# Will connect them around later using bloch's theorem to generate H(k) function
	for NN in NNs
		#println("pre hop ($(NN.ia) to $(NN.ib)) = $(NN.a) to $(NN.b)")
		ib = [NN.ib[1],NN.ib[2],NN.ib[3]]
		# Δ(ib,ib reflected back into 1st lattice)
		pib = ib - [mod(ib[1],p.nx),mod(ib[2],p.ny),mod(ib[3],p.nz)]
		if(pib⋅pib != 0) # if vector is distinctly outside of 1st lattice
			NN.N = Int.([round(pib[1]/(p.nx)),round(pib[2]/p.ny),round(pib[3]/p.nz)])
			NN.b = xyztoi(p,NN.ib, NN.N)
			NN.edge = true
			#println("$(NN.N)")
		end
		#println("NN hop $(NN.a) to $(NN.b) = $(NN.desc)")
		#println("edge? = $(NN.edge)")
	end
	return NNs
end


function pruneHoppings(NNs, type)
	if("x" ∈ type)
		deleteat!(NNs, findall(NN->NN.N[1]!=0,NNs))
	end
	if("y" ∈ type)
		deleteat!(NNs, findall(NN->NN.N[2]!=0,NNs))
	end
	if("z" ∈ type)
		deleteat!(NNs, findall(NN->NN.N[3]!=0,NNs))
	end
	return NNs
end



end
