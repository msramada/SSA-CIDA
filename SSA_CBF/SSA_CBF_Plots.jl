include("SSA_CBF_main.jl")

using LaTeXStrings


function circleShape(h,k,r)
    θ = LinRange(0,2*pi,500)
    h .+ r*sin.(θ), k.+r*cos.(θ)
end





anim = @animate for t = 1:K-1
     plot(state[1,t,:], state[2,t,:],
          seriestype=:scatter, 
          ms = 1.0, 
          label = false, 
          mc =:black, 
          z_order=:front)
     plot!((xstar[1,t], xstar[2,t]), 
          seriestype=:scatter, 
          ms = 3.50, 
          label=L"Candidate State $x^{\star}$",
          legend =:topleft, 
          mc=:blue, 
          z_order=:front)
     plot!(circleShape(r0[1],r0[2],dmin), seriestype = [:shape,], lw=0.5,
          linecolor =:black, ls=:dash, c =:red,
          label = false, aspect_ratio =1,
          z_order=:back)
     plot!(circleShape(r_goal[1],r_goal[2],0.25), seriestype = [:shape,], lw=0.5,
          c =:green, linecolor =:black,
          label = false, aspect_ratio =1, z_order=:back)
     xlims!(-1.5, 4.0)
     ylims!(-1.5, 4.0)
end

gif(anim, "SSA_CBF.gif",fps=10)