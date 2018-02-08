export convGEMMKernel,Amv,ATmv,transposeTest,getConvGEMMKernel

mutable struct convGEMMKernel{T} <: AbstractConvKernel{T}
    nImg :: Array{Int,1}
    sK   :: Array{Int,1}
end
function getConvGEMMKernel(TYPE::Type,nImg,sK)
	return convGEMMKernel{TYPE}(copy(nImg),copy(sK));
end

function Amv(this::convGEMMKernel{T},theta::Array{T},Y::Array{T}) where {T<:Number}
    ## We assume that the data Y is held in the order XYCN.
	sK = this.sK;
	nImg = this.nImg;
	nex   = div(numel(Y),prod(nImgIn(this)))
    # compute convolution
	Y     = reshape(Y,nImg[1],nImg[2],this.sK[3],nex);
    AY    = Array{T, 3}(nImg[1]*nImg[2],this.sK[4],nex);
	aux   = zeros(T,nImg[1],nImg[2],this.sK[3]);
    AYk   = zeros(T,nImg[1]*nImg[2],this.sK[4]);
	### reshape the kernels for gemm!:
	K = reshape(theta, sK[1], sK[2], sK[3], sK[4])
	KK = Array{Array{T,2}}(sK[1],sK[2]);
	for k1 = 1:sK[1]
		for k2 = 1:sK[2]
			@inbounds KK[k1,k2] = K[k1,k2,:,:]';
		end
	end
	shiftX = [0;-1;0;0;1;0];
	shiftT = [1;0;0;0;0;-1];

    for k = 1:nex
		AYk = multConv2Dblock(Y,KK, AYk,aux,shiftX,shiftT,k);
		@inbounds AY[:,:,k] = AYk;
		AYk[:] = zero(T)
	end
    AY_out = reshape(AY,:,nex);
    return AY_out
end

function ATmv(this::convGEMMKernel{T},theta::Array{T},Zin::Array{T}) where {T<:Number}
	nImg  = this.nImg;
	sK    = this.sK;
    nex   =  div(numel(Zin),prod(nImgOut(this)));
    K     = reshape(theta, sK[1], sK[2], sK[3], sK[4]);
	Z     = reshape(Zin,nImg[1],nImg[2],sK[4],nex);
	aux     = zeros(T,nImg[1],nImg[2],sK[4]);
	ATZ   = zeros(T,nImg[1]*nImg[2],sK[3],nex);
	ATZk  = zeros(T,nImg[1]*nImg[2],sK[3]);

	### reshape the kernels for gemm!:
	KK = Array{Array{T,2}}(sK[1],sK[2]);
	for k1 = 1:sK[1]
		for k2 = 1:sK[2]
			@inbounds KK[k1,k2] = K[k1,k2,:,:];
		end
	end
	## flipping:
	KK = flipdim(flipdim(KK,2),1);
	shiftX = [0;-1;0;0;1;0];
	shiftT = [1;0;0;0;0;-1];
    for k = 1:nex
		ATZk = multConv2Dblock(Z,KK, ATZk,aux,shiftX,shiftT,k);
		@inbounds ATZ[:,:,k] = ATZk;
		ATZk[:] = zero(T)
	end
    ATZ_out = reshape(ATZ,:,nex);
    return ATZ_out
end

function Jthetamv(this::convGEMMKernel{T},dtheta::Array{T},dummy::Array{T},Y::Array{T},temp=nothing) where {T<:Number}
    nex    =  div(numel(Y),nFeatIn(this));
    Z      = Amv(this,dtheta,Y);
    return Z
end

function JthetaTmv(this::convGEMMKernel{T}, Zin::Array{T}, dummy::Array{T}, Yin::Array{T}) where {T<:Number}
     # derivative of Z*(A(theta)*Y) w.r.t. theta
	sK = this.sK
	nImg = this.nImg
	nex   = div(numel(Yin),prod(nImgIn(this)))
    # compute convolution
	Y     = reshape(Yin, nImg[1], nImg[2], this.sK[3], nex)
	Z	  = reshape(Zin, nImg[1]*nImg[2], this.sK[4], nex)
	Zk    = zeros(T, nImg[1]*nImg[2], this.sK[4])
	aux     = zeros(T, nImg[1], nImg[2], this.sK[3])

	### reshape the kernels for gemm!:
	dtheta = zeros(T, sK[1], sK[2], sK[3], sK[4])
	KK = Array{Array{T, 2}}(sK[1], sK[2])
	for k1 = 1:sK[1]
		for k2 = 1:sK[2]
			@inbounds KK[k1, k2] = zeros(T, sK[3], sK[4])
		end
	end
	shiftX = [0;-1;0;0;1;0]
	shiftT = [1;0;0;0;0;-1]
    for k = 1:nex
		getColumn!(Z, Zk, k)
		multConv2Dblock(Y, KK,  Zk, aux, shiftX, shiftT, k, doDerivative = 1)
	end
	### Assemble the kernels from gemm!:
	for k1 = 1:sK[1]
		for k2 = 1:sK[2]
			@inbounds dtheta[k1, k2, :, :] = KK[k1, k2]
		end
	end
    dtheta_out = reshape(dtheta, sK[1], sK[2], sK[3], sK[4])
    return dtheta_out
end



function getColumn!(Z::Array{T},Zk::Array{T},k::Int64) where {T<:Number}
for c=1:size(Z,2)
	for j=1:size(Z,1)
		@inbounds	Zk[j,c] = Z[j,c,k];
	end
end
end

function multConv2Dblock(x::Array{T},K::Array{Array{T,2},2}, y::Array{T}, tin::Array{T},shiftX,shiftT,imIdx;doDerivative = 0) where {T<:Number}
	## y = K*x
	## K - 3X3 array of Arrays
	## x - a vector of length |nImgag+2|*cin (zero padded)
	## y - a vector of length |nImgag|*cout

	nImg1 = size(x,1);
	nImg2 = size(x,2);
	cin = size(x,3);
	cout = size(y,2);
	OneType = one(T);
	
	kernelWidth = size(K,1);
	# y = reshape(y,nImg1*nImg2,cout); # it is supposed to be of this shape...
	k=1;
	jt=0;it=0;jt=0;jx=0;
	for p = 1:2:2*kernelWidth
		for q = 1:2:2*kernelWidth
			t = reshape(tin,nImg1,nImg2,cin);
			lower = nImg2+shiftT[p+1]  # Move outside of the forloop for increased speed
			upper = nImg1+shiftT[q+1]  # Move outside of the forloop for increased speed
			for cc = 1:cin
				jx = 1+shiftX[p];  # Moving these outside didn't seem to help
				jt = 1+shiftT[p];
				if jt > 1
					@inbounds t[:,1:(jt-1),cc] = 0.0;	
				end
				while jt <= lower 
					it = 1+shiftT[q];
					ix = 1+shiftX[q];
					if it > 1
						for ii = 1:(it-1)
							@inbounds t[ii,jt,cc] = zero(T)   #@inbounds t[1:(it-1),jt,cc] = 0.0 - faster unvectorized
						end							
					end
					while it <= upper
						@inbounds t[it,jt,cc] = x[ix,jx,cc,imIdx];
						it+=1;ix+=1;
					end
					if it <= nImg1
						for ii = it:nImg1
							@inbounds t[ii,jt,cc] = zero(T)	#@inbounds t[it:nImg1,jt,cc] = 0.0 - faster unvectorized
						end
					end
					jt+=1;jx+=1;

				end
				if jt <= nImg2
					@inbounds t[:,jt:nImg2,cc] = 0.0;				
				end
			end
			tin = reshape(t,nImg1*nImg2,cin);
			if doDerivative == 0
				BLAS.gemm!('N','T',OneType,tin,K[k],OneType,y);
			else
				BLAS.gemm!('T','N',OneType,tin,y,OneType,K[k]);
			end
			k+=1;
		end
	end
	return y;
end


# function transposeTest()
# 	nImage = [16,16];
# 	sK = [3,3,2,4];
# 	TYPE = Float64;
# 	K = randn(TYPE,tuple(sK...));
# 	Y = randn(TYPE,nImage[1],nImage[2],sK[3],2);
# 	Z = randn(TYPE,nImage[1],nImage[2],sK[4],2);
# 	Kernel2 = convGEMMKernel(nImage,sK);
# 	AY = Amv(Kernel2,K,Y);
# 	ATZ = ATmv(Kernel2,K,Z);
# 	println(vecdot(Z,AY));
# 	println(vecdot(ATZ,Y));
#
# 	println(vecdot(Z,Jthetamv(Kernel2,K,[],Y)));
# 	println(vecdot(K,JthetaTmv(Kernel2,Z,[],Y)));
#
# end
