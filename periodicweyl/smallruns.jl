push!(LOAD_PATH, "./")
push!(LOAD_PATH, "../src/")
push!(LOAD_PATH, "./periodicweyl/")
push!(LOAD_PATH, "./src/")

module runs
using InBi
using SLutils
using Driver
using Constants
using UsefulFunctions
using LinearAlgebra
using PlotStuff
using SaveStuff
using Dates
#main(params)

#nx = 10; ny = 10; nz = 10; 
nx = 100; ny = 1; nz = 1; 
#nx = 12; ny = 1; nz = 1; 
# superlattice basis vectors, in basis of a_1, a_2, a_3
SL1 = [nx; 0; 0]; SL2 = [0; ny; 0]; SL3 = [0; 0; nz]

saving = true;
runparams = (

             # fermi energy, σ of background disorder
             μ = 0.0*eV, μ_disorder = 0.025*eV, 
             
             # energy range for transport 
             E_samples = [0.1],
             nk = 100, # half of brillouin zone used in transport
             
             # info for saving output of runs
             path = "../outputs/testrunstacc/" * Dates.format(Dates.now(), "e-dd-u-yyyy--HH.MM.SS/"), savedata=true, save=true,
             
             # exchange splitting, name of field pattern, A or β (vector pot or exchange), finite-time broadenings
             β = 0.25*eV, runtype = "blochlattice", fieldtype = "β", η = 1*10^-4, ηD = 10^-4, l_scattering = 0*nm, #dephasing 
             
             # run parameters`
             parallel="k", n_BLAS=1, transport=true, verbose = false, plotfield = true, bands=true, mixedDOS=true, θ=360.0, sweep="none",
            
             # things to return 
             returnvals = ["transmission"],
             # materials used in the device
             electrodeMagnetization=true,electrodeMaterial="weyl",
             deviceMagnetization=true,deviceMaterial="weyl",
             
             # if defining stripe domain superlattice       # penetration depth 
             #startDWs = -6*nm,
             #startDWs = 36*nm, 
             startDWs = -5*nm, DWwidth = 9*nm, DWspacing = 15*nm, λ = 2*nm,
             #startDWs = 30*nm, DWwidth = 3*nm, DWspacing = 10*nm, 
             # if using proximity-magnetized profile
             #electrodeMagnetization=true,electrodeMaterial="mtjweyl",
             #deviceMagnetization=false,deviceMaterial="ins",
             # will prune periodic boundaries in "x","y","z"
             prune=[]
            )

parms = merge(params,runparams)
p = genSL(parms, nx, ny, nz, SL1, SL3, SL3, parms.runtype, parms.fieldtype) # generate SL params

BLAS.set_num_threads(p.n_BLAS)

function runFieldTexture(p::NamedTuple)
    if(p.fieldtype=="A")
            A = Agen(p,p.runtype,10^8*4*μₑ)
    else
            A = βgen(p,p.runtype,p.β,p.θ,p.startDWs)
    end
    return main(p,A)
end

function nxtoArg(nx::Int)
    SL1 = [nx; 0; 0]
    return genSL(parms, nx, ny, nz, SL1, SL3, SL3, parms.runtype, parms.fieldtype) # generate SL params
end

function startDWstoArg(startDWs::Float64)
    return merge(p, (sweep = "T(Stripe Domain Position,E)", startDWs = startDWs, path = p.path*"startdw=$(round(startDWs*10^9,sigdigits=3))/"))
end

function θtoArg(θ::Float64)
    return merge(p, (sweep = "T(DW angle,E)", θ = θ))
end


mkpath(p.path)

#=
# for recreating WMTJ
WMTJparams = nxtoArg(3); WMTJparams = merge(WMTJparams, (electrodeMagnetization=true,electrodeMaterial="mtjweyl", deviceMagnetization=false,deviceMaterial="ins"));
@time runFieldTexture(WMTJparams)

# for recreating araki hamiltonian
#bandsp = nxtoArg(20); bandsp = merge(bandsp, (startDWs=10*nm, bands=true, parallel="k", DWspacing=30*nm));
#

#bandsp = nxtoArg(50); bandsp = merge(bandsp, (runtype="blochlattice", parallel="k"));
#@time runFieldTexture(bandsp)

=#
#Get the bands for the supercell
bandsp = nxtoArg(50); bandsp = merge(bandsp, (bands=true, runtype = "blochlattice", parallel="k", path = p.path*"runtype=blochlattice/"));
@time runFieldTexture(bandsp)

bandsp = nxtoArg(50); bandsp = merge(bandsp, (runtype="neellattice", bands=true, parallel="k", path = p.path*"startdw=neellattice/" ));
@time runFieldTexture(bandsp)



#(x,y, fig) = Sweep1DSurf(runFieldTexture,startDWstoArg,[DWstart for DWstart = -1.0*p.DWwidth:(3*nm):(p.SLa₁[1] - 2*p.DWwidth)],p.E_samples,"Stripe DW start position (nm)", "Energy (eV)","T (e²/h)",(1/nm),false, p.parallel)
#SavePlots(fig,p.path,"transmissionsweep")


#mkdelim(p.path*"dwsweep.txt",[x y])

#Sweep1DSurf(runFieldTexture,θtoArg,[θ for θ = 0:10.0:180],p.E_samples,"θ DW angle (degrees)", "Energy (eV)", "T (e²/h)")
#(x,y) = Sweep1DSurf(runFieldTexture,startDWstoArg,[DWstart for DWstart = 2*p.DWwidth:(4*nm):4*p.DWwidth],p.E_samples,"Stripe DW start position (nm)", "Energy (eV)","T (e²/h)",(1/nm),false)

#Sweep1DSurf((T -> log10.(T))∘runFieldTexture,startDWstoArg,[DWstart for DWstart = -5*nm:(5*nm):(30*nm)],p.E_samples,"Stripe DW start position (nm)", "Energy (eV)","T (e²/h)",(1/nm),false)
#Sweep1DSurf((T -> log10.(T))∘runFieldTexture,θtoArg,[θ for θ = 0.0:10.0:180.0],p.E_samples,"θ DW angle (degrees)", "Energy (eV)","log₁₀(T) (e²/h)",false)

end
