-- nbt.lua: decode item "tag" strings from OC (gzip-compressed NBT)
-- usage: local nbt=dofile("/home/fusion/nbt.lua")
--        local t=nbt.decode(stack.tag)   -- -> Lua table
-- works on Lua 5.2 and 5.3 (no bit ops needed)
local M={}
local P={} do local v=1 for i=0,31 do P[i]=v v=v*2 end end

-- raw deflate (RFC1951), based on zlib's puff.c
local function inflate(data,pos)
  local bitbuf,bitcnt=0,0
  local out={}
  local function bits(n)
    while bitcnt<n do
      local b=data:byte(pos) or error("inflate: out of data")
      pos=pos+1 bitbuf=bitbuf+b*P[bitcnt] bitcnt=bitcnt+8
    end
    local v=bitbuf%P[n] bitbuf=math.floor(bitbuf/P[n]) bitcnt=bitcnt-n
    return v
  end
  local function build(lengths,n)
    local h={count={},symbol={}}
    for i=0,15 do h.count[i]=0 end
    for s=0,n-1 do local l=lengths[s] or 0 h.count[l]=h.count[l]+1 end
    local offs={[1]=0}
    for l=1,14 do offs[l+1]=offs[l]+h.count[l] end
    for s=0,n-1 do local l=lengths[s] or 0
      if l~=0 then h.symbol[offs[l]]=s offs[l]=offs[l]+1 end end
    return h
  end
  local function decode(h)
    local code,first,index=0,0,0
    for l=1,15 do
      code=code+bits(1)
      local count=h.count[l]
      if code-count<first then return h.symbol[index+(code-first)] end
      index=index+count first=(first+count)*2 code=code*2
    end
    error("inflate: bad code")
  end
  local lbase={3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258}
  local lext={0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0}
  local dbase={1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577}
  local dext={0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13}
  local function codes(lh,dh)
    while true do
      local s=decode(lh)
      if s<256 then out[#out+1]=s
      elseif s==256 then return
      else
        s=s-257
        local len=lbase[s+1]+bits(lext[s+1])
        local d=decode(dh)
        local dist=dbase[d+1]+bits(dext[d+1])
        local n=#out
        for i=1,len do out[n+i]=out[n+i-dist] end
      end
    end
  end
  local fixedL,fixedD
  repeat
    local last=bits(1)
    local typ=bits(2)
    if typ==0 then
      bitbuf,bitcnt=0,0
      local len=data:byte(pos)+data:byte(pos+1)*256
      pos=pos+4
      for i=0,len-1 do out[#out+1]=data:byte(pos+i) end
      pos=pos+len
    elseif typ==1 then
      if not fixedL then
        local l={} for s=0,143 do l[s]=8 end for s=144,255 do l[s]=9 end
        for s=256,279 do l[s]=7 end for s=280,287 do l[s]=8 end
        fixedL=build(l,288)
        local d={} for s=0,29 do d[s]=5 end fixedD=build(d,30)
      end
      codes(fixedL,fixedD)
    elseif typ==2 then
      local nlen=bits(5)+257 local ndist=bits(5)+1 local ncode=bits(4)+4
      local order={16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15}
      local l={} for i=0,18 do l[i]=0 end
      for i=1,ncode do l[order[i]]=bits(3) end
      local ch=build(l,19)
      local lens={} local idx=0
      while idx<nlen+ndist do
        local s=decode(ch)
        if s<16 then lens[idx]=s idx=idx+1
        else
          local v,rep=0,0
          if s==16 then v=lens[idx-1] rep=3+bits(2)
          elseif s==17 then rep=3+bits(3)
          else rep=11+bits(7) end
          for i=1,rep do lens[idx]=v idx=idx+1 end
        end
      end
      local ll,dl={}, {}
      for i=0,nlen-1 do ll[i]=lens[i] end
      for i=0,ndist-1 do dl[i]=lens[nlen+i] end
      codes(build(ll,nlen),build(dl,ndist))
    else error("inflate: bad block type") end
  until last==1
  local parts={}
  for i=1,#out,4096 do parts[#parts+1]=string.char(table.unpack(out,i,math.min(i+4095,#out))) end
  return table.concat(parts)
end
M.inflate=inflate

function M.gunzip(s)
  if s:byte(1)~=0x1f or s:byte(2)~=0x8b then return s end -- not gzip
  local flg=s:byte(4) local pos=11
  if flg%8>=4 then pos=pos+2+s:byte(pos)+s:byte(pos+1)*256 end
  if flg%16>=8 then pos=s:find("\0",pos,true)+1 end
  if flg%32>=16 then pos=s:find("\0",pos,true)+1 end
  if flg%4>=2 then pos=pos+2 end
  return inflate(s,pos)
end

-- NBT (big endian). Returns plain Lua tables; compounds keyed by name.
local function parse(s)
  local pos=1
  local function u(n) local v=0 for i=0,n-1 do v=v*256+s:byte(pos+i) end pos=pos+n return v end
  local function sgn(v,n) if v>=P[n*8-1] then return v-P[n*8-1]*2 end return v end
  local function str() local n=u(2) local r=s:sub(pos,pos+n-1) pos=pos+n return r end
  local payload
  payload=function(t)
    if t==1 then return sgn(u(1),1)
    elseif t==2 then return sgn(u(2),2)
    elseif t==3 then return sgn(u(4),4)
    elseif t==4 then local hi=sgn(u(4),4) local lo=u(4) return hi*4294967296+lo
    elseif t==5 then local r=string.unpack and string.unpack(">f",s,pos) pos=pos+4 return r
    elseif t==6 then local r=string.unpack and string.unpack(">d",s,pos) pos=pos+8 return r
    elseif t==7 then local n=sgn(u(4),4) local r={} for i=1,n do r[i]=sgn(u(1),1) end return r
    elseif t==8 then return str()
    elseif t==9 then local et=u(1) local n=sgn(u(4),4) local r={} for i=1,n do r[i]=payload(et) end return r
    elseif t==10 then local r={}
      while true do local tt=u(1) if tt==0 then return r end local k=str() r[k]=payload(tt) end
    elseif t==11 then local n=sgn(u(4),4) local r={} for i=1,n do r[i]=sgn(u(4),4) end return r
    else error("nbt: bad tag type "..tostring(t)) end
  end
  local t=u(1) str() return payload(t)
end
M.parse=parse

function M.decode(tag) return parse(M.gunzip(tag)) end
return M
