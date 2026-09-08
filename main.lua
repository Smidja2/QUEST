local mod = ...

local MOD_ID = "QUEST_GEN1_IMPORTER"
local VERSION = "0.6.7"

local function log(level, fmt, ...)
  if not mod.log then return end
  local fn = mod.log[level]
  if type(fn)=="function" then pcall(fn, mod.log, fmt, ...) end
end

local function loadSibling(rel)
  local src = mod:read(rel)
  if not src then return nil, "missing "..rel end
  local chunk, err = load(src, "@"..mod.path.."/"..rel)
  if not chunk then return nil, "compile error in "..rel..": "..tostring(err) end
  local ok, value = pcall(chunk)
  if not ok then return nil, "runtime error in "..rel..": "..tostring(value) end
  return value
end

local okR, rumbleHost = pcall(mod.find, "RUMBLE_MAIN")
if not okR or not rumbleHost then error(MOD_ID..": RUMBLE_MAIN not found",0) end
local API = rumbleHost.exports and rumbleHost.exports.rumble_importer
if not API or tonumber(API.api) ~= 1 or type(API.createActor) ~= "function" then
  error(MOD_ID..": RUMBLE_MAIN legacy API 1 unavailable",0)
end

local okD, dramaless = pcall(mod.find, "DRAMALESS_SHAPE")
if not okD or not dramaless then error(MOD_ID..": DRAMALESS_SHAPE not found",0) end
local hostLib = dramaless.exports and dramaless.exports.lib
local Voxel3D = hostLib and type(hostLib.require)=="function" and hostLib.require("Voxel3D") or nil
if not Voxel3D or type(Voxel3D.draw)~="function" then error(MOD_ID..": Voxel3D unavailable",0) end
local Mat4 = API.Mat4
if not Mat4 then error(MOD_ID..": Rumble importer Mat4 export unavailable",0) end

local originalCreateActor = API.createActor
local originalLoad = API.load
local textureCache = {}
local dataCache = setmetatable({}, {__mode="v"})
local modelCache = setmetatable({}, {__mode="v"})
local actors = setmetatable({}, {__mode="k"})
local badSpecies = {}

-- Quest toon rendering follows Rumble Unified's global Toon Outline setting.
local function toonEnabled()
  if API and type(API.outlineEnabled)=="function" then
    local ok,v=pcall(API.outlineEnabled)
    if ok then return v~=false end
  end
  return true
end

local function celShade(nx,ny,nz)
  local raw=0.7725 + 0.06*nx + 0.225*ny + 0.11*nz
  if raw < 0.76 then return 0.52
  elseif raw < 0.90 then return 0.76
  else return 1.00 end
end

local function questNormals(part)
  local verts=part.verts or {}
  local n={}
  for i=1,#verts do n[i]={0,0,0} end
  local idx=part.index or {}
  local zeroBased=false
  for _,v in ipairs(idx) do if tonumber(v)==0 then zeroBased=true break end end
  local function vi(v)
    v=tonumber(v) or 0
    if zeroBased then v=v+1 end
    return math.floor(v)
  end
  for k=1,#idx,3 do
    if idx[k+2]~=nil then
      local ia,ib,ic=vi(idx[k]),vi(idx[k+1]),vi(idx[k+2])
      local a,b,c=verts[ia],verts[ib],verts[ic]
      if a and b and c then
        local ux,uy,uz=b[1]-a[1],b[2]-a[2],b[3]-a[3]
        local vx,vy,vz=c[1]-a[1],c[2]-a[2],c[3]-a[3]
        local nx=uy*vz-uz*vy
        local ny=uz*vx-ux*vz
        local nz=ux*vy-uy*vx
        local L=math.sqrt(nx*nx+ny*ny+nz*nz)
        if L>1e-9 then nx,ny,nz=nx/L,ny/L,nz/L end
        for _,ii in ipairs({ia,ib,ic}) do
          if n[ii] then
            n[ii][1]=n[ii][1]+nx
            n[ii][2]=n[ii][2]+ny
            n[ii][3]=n[ii][3]+nz
          end
        end
      end
    end
  end
  local shade={}
  for i=1,#verts do
    local q=n[i]
    local L=math.sqrt(q[1]*q[1]+q[2]*q[2]+q[3]*q[3])
    local nx,ny,nz=0,1,0
    if L>1e-9 then nx,ny,nz=q[1]/L,q[2]/L,q[3]/L end
    n[i]={nx,ny,nz}
    shade[i]=celShade(nx,ny,nz)
  end
  return n,shade
end

local function validDex(v)
  local n=tonumber(v)
  if not n then return nil end
  n=math.floor(n)
  if n<1 or n>151 then return nil end
  return n
end

local function speciesPath(dex)
  return string.format("lib/species/%03d.lua", dex)
end

local function getData(dex)
  if badSpecies[dex] then return nil, badSpecies[dex] end
  local d=dataCache[dex]
  if d then return d end
  local loaded,err=loadSibling(speciesPath(dex))
  if type(loaded)~="table" or type(loaded.parts)~="table" then
    badSpecies[dex]=err or "invalid Quest species data"
    log("warn","Quest data unavailable for Dex #%03d: %s",dex,tostring(badSpecies[dex]))
    return nil,badSpecies[dex]
  end
  dataCache[dex]=loaded
  return loaded
end

local function texFor(c)
  local r=math.floor((c[1] or 1)*255+0.5)
  local g=math.floor((c[2] or 1)*255+0.5)
  local b=math.floor((c[3] or 1)*255+0.5)
  local a=math.floor((c[4] or 1)*255+0.5)
  local key=string.format("%d,%d,%d,%d",r,g,b,a)
  if textureCache[key] then return textureCache[key] end
  if not (love and love.image and love.graphics and love.image.newImageData and love.graphics.newImage) then return nil end
  local ok,imgData=pcall(love.image.newImageData,1,1)
  if not ok or not imgData then return nil end
  pcall(imgData.setPixel,imgData,0,0,c[1] or 1,c[2] or 1,c[3] or 1,c[4] or 1)
  local ok2,img=pcall(love.graphics.newImage,imgData)
  if ok2 and img then
    if img.setFilter then pcall(img.setFilter,img,"nearest","nearest") end
    textureCache[key]=img
    return img
  end
  return nil
end

local function getModel(dex)
  local m=modelCache[dex]
  if m then return m end
  local d,err=getData(dex)
  if not d then return nil,err end
  m={
    _quest=true,
    species=dex,
    shiny=false,
    height=d.height or 1,
    floor=d.floor or 0,
    radius=d.radius or 0.5,
    parts=d.parts,
    anims={
      {name="idle",frames=60,seconds=2.0},
      {name="attack",frames=14,seconds=0.46},
      {name="faint",frames=27,seconds=0.90},
      {name="entrance",frames=19,seconds=0.62},
    },
  }
  modelCache[dex]=m
  return m
end

local function buildRig(model)
  if not (love and love.graphics and love.graphics.newMesh) then return nil,"LOVE mesh API unavailable" end
  local rig={parts={},species=model.species,animName="idle",animTime=0}
  local outlineInflate=math.max(tonumber(model.height) or 1,0.1)*0.035
  for _,p in ipairs(model.parts or {}) do
    local rows,base,outlineRows={},{},{}
    local normals,shades=questNormals(p)
    local toon=toonEnabled()
    for i,v in ipairs(p.verts or {}) do
      local q=normals[i] or {0,1,0}
      local shade=toon and (shades[i] or 1) or 1
      rows[i]={v[1],v[2],v[3],0.5,0.5,shade}
      base[i]={v[1],v[2],v[3],0.5,0.5,v[4] or 1}
      outlineRows[i]={
        v[1]+q[1]*outlineInflate,
        v[2]+q[2]*outlineInflate,
        v[3]+q[3]*outlineInflate,
        0.5,0.5,1
      }
    end
    local ok,mesh=pcall(love.graphics.newMesh,Voxel3D.FORMAT,rows,"triangles","dynamic")
    local okO,outlineMesh=pcall(love.graphics.newMesh,Voxel3D.FORMAT,outlineRows,"triangles","dynamic")
    if ok and mesh then
      pcall(mesh.setVertexMap,mesh,p.index)
      if okO and outlineMesh then pcall(outlineMesh.setVertexMap,outlineMesh,p.index) end
      rig.parts[#rig.parts+1]={
        mesh=mesh,
        outlineMesh=(toon and okO and outlineMesh) and outlineMesh or nil,
        _outlineMesh=(okO and outlineMesh) or nil,
        texture=texFor(p.color),
        base=base,
        rows=rows,
        outlineRows=outlineRows,
        normals=normals,
        shades=shades
      }
    elseif okO and outlineMesh and outlineMesh.release then
      pcall(outlineMesh.release,outlineMesh)
    end
  end
  if #rig.parts==0 then return nil,"no Quest mesh parts created" end

  function rig:release()
    for _,p in ipairs(self.parts or {}) do
      if p.mesh and p.mesh.release then pcall(p.mesh.release,p.mesh) end
      if p._outlineMesh and p._outlineMesh.release then pcall(p._outlineMesh.release,p._outlineMesh) end
    end
    self.parts={}
  end

  -- v0.6 keeps the proven Pidgey local wing deformation and uses safe whole-body
  -- state motion for the rest of the roster.  The original Unity bone clips are
  -- deliberately not guessed here; this keeps all 151 models stable while the
  -- clip decoder is developed independently.
  function rig:animate(name,t)
    self.animName=name or "idle"; self.animTime=t or 0
    local toon=toonEnabled()
    for _,p in ipairs(self.parts or {}) do
      p.outlineMesh=toon and p._outlineMesh or nil
      if p.rows and p.shades then
        for i,row in ipairs(p.rows) do row[6]=toon and (p.shades[i] or 1) or 1 end
        pcall(p.mesh.setVertices,p.mesh,p.rows)
      end
    end
    if self.species~=16 then return true end
    local wa
    if self.animName=="attack" then wa=math.sin(self.animTime*30.0)*0.48
    elseif self.animName=="entrance" then wa=math.sin(self.animTime*24.0)*0.34
    elseif self.animName=="faint" then wa=math.sin(self.animTime*8.0)*0.08
    elseif self.animName=="walk" then wa=math.sin(self.animTime*18.0)*0.24
    else wa=math.sin(self.animTime*8.0)*0.11 end
    local headBob=0
    if self.animName=="idle" then headBob=math.sin(self.animTime*4.5)*0.025
    elseif self.animName=="walk" then headBob=math.sin(self.animTime*12.0)*0.045
    elseif self.animName=="attack" then headBob=math.sin(math.min(1,self.animTime/0.42)*math.pi)*0.055 end
    for _,p in ipairs(self.parts) do
      local rows=p.rows
      for i,b in ipairs(p.base) do
        local x,y,z=b[1],b[2],b[3]
        local ax,ay,az=x,y,z
        if math.abs(x)>0.42 and y>1.22 then
          local side=x<0 and -1 or 1
          local px,py=side*0.30,1.48
          local dx,dy=x-px,y-py
          local a=wa*side
          local c,s=math.cos(a),math.sin(a)
          ax=px+dx*c-dy*s
          ay=py+dx*s+dy*c
        end
        if y>1.68 and math.abs(x)<0.55 then ay=ay+headBob end
        rows[i][1],rows[i][2],rows[i][3]=ax,ay,az
      end
      pcall(p.mesh.setVertices,p.mesh,rows)
    end
    return true
  end

  function rig:skin(_) return true end
  function rig:pose(_,_,_) return true end
  return rig
end

local Actor={}; Actor.__index=Actor
function Actor:setPosition(x,y,z) self.x=x or self.x;self.y=y or self.y;self.z=z or self.z;return self end
function Actor:setYaw(yaw) self.yaw=yaw or 0;return self end
function Actor:setScale(scale) self.scale=scale;return self end
function Actor:setAnimation(name)
  name=name or "idle";self.animName=name;self.time=0
  if self.rig and self.rig.animate then pcall(self.rig.animate,self.rig,name,0) end
  return self
end
function Actor:setVisible(v) self.visible=v~=false;return self end
function Actor:update(dt)
  local d=math.max(0,math.min(0.1,tonumber(dt) or 0));self.time=self.time+d
  local name=self.animName or "idle"
  local durations={attack=0.46,entrance=0.62,faint=0.90}
  local dur=durations[name]
  if dur and self.time>=dur then
    if name=="faint" then self.time=dur else name="idle";self.animName="idle";self.time=0 end
  end
  if self.rig and self.rig.animate then pcall(self.rig.animate,self.rig,name,self.time) end
  return self
end
function Actor:destroy()
  if self.dead then return end
  self.dead=true;actors[self]=nil
  if self.rig then self.rig:release() end
end

local function smoothstep(x) x=math.max(0,math.min(1,x));return x*x*(3-2*x) end
function Actor:matrix()
  local rawH=math.max(tonumber(self.model.height) or 1,1e-6)
  local target=type(API.targetHeight)=="function" and API.targetHeight(rawH) or 14
  local QUEST_SCALE = 0.60
  local k=(self.scale or (target/rawH))*QUEST_SCALE
  local floor=tonumber(self.model.floor) or 0
  local name,t=self.animName or "idle",self.time or 0
  local lift,forward,pitch,roll,sx,sy,sz=0,0,0,0,1,1,1
  if name=="idle" then
    lift=math.sin(t*4.5)*0.022;pitch=math.sin(t*3.0)*0.025
  elseif name=="walk" then
    local step=math.sin(t*12.0)
    local bounce=math.abs(step)
    lift=0.055*bounce
    forward=0.025*math.sin(t*6.0)
    pitch=-0.055+0.025*math.sin(t*12.0)
    roll=0.045*step
    sx=1+0.018*bounce
    sy=1-0.028*bounce
    sz=1+0.012*bounce
  elseif name=="attack" then
    local u=math.max(0,math.min(1,t/0.46));local pulse=math.sin(u*math.pi)
    forward=0.58*pulse;lift=0.10*pulse;pitch=-0.18*pulse
    sx=1+0.05*pulse;sy=1-0.06*pulse;sz=1+0.08*pulse
  elseif name=="entrance" then
    local u=math.max(0,math.min(1,t/0.62));local settle=smoothstep(u)
    lift=(1-settle)*0.62+math.sin(u*math.pi*2.0)*(1-u)*0.12;sy=0.88+0.12*settle
  elseif name=="faint" then
    local u=math.max(0,math.min(1,t/0.90));local q=smoothstep(u)
    lift=-0.44*q;roll=1.22*q;pitch=0.18*q;sy=1-0.20*q
  end
  local base=Mat4.mul(Mat4.translate(self.x,self.y,self.z),Mat4.rotateY(self.yaw))
  base=Mat4.mul(base,Mat4.translate(0,lift,forward))
  if pitch~=0 then base=Mat4.mul(base,Mat4.rotateX(pitch)) end
  if roll~=0 then base=Mat4.mul(base,Mat4.rotateZ(roll)) end
  base=Mat4.mul(base,Mat4.scale(k*sx,k*sy,k*sz))
  base=Mat4.mul(base,Mat4.translate(0,-floor,0))
  return base
end

local function createQuestActor(dex,opts)
  opts=opts or {}
  local model,err=getModel(dex)
  if not model then return nil,err end
  local rig,rerr=buildRig(model)
  if not rig then return nil,rerr end
  local a=setmetatable({model=model,rig=rig,x=opts.x or 0,y=opts.y or 0,z=opts.z or 0,yaw=opts.yaw or 0,scale=opts.scale,visible=opts.visible~=false,manual=opts.manual==true,animName="idle",time=0},Actor)
  actors[a]=true
  return a
end

API.createActor=function(species,opts)
  local dex=validDex(species)
  if dex then
    local made,err=createQuestActor(dex,opts)
    if made then return made end
    log("warn","Quest actor fallback to Rumble for Dex #%03d: %s",dex,tostring(err))
  end
  return originalCreateActor(species,opts)
end

API.load=function(species,shiny)
  local dex=validDex(species)
  if dex then
    local model=getModel(dex)
    if model then return model end
  end
  if type(originalLoad)=="function" then return originalLoad(species,shiny) end
  return nil
end

mod.exports.quest_gen1={
  api=1,version=VERSION,
  first_species=1,last_species=151,
  available=function(species) return validDex(species)~=nil and getData(validDex(species))~=nil end,
  createActor=function(species,opts)
    local dex=validDex(species);if not dex then return nil,"Dex outside 001-151" end
    return createQuestActor(dex,opts)
  end,
  toonEnabled=toonEnabled,
}

log("info","Pokemon Quest Gen 1 override v0.6.7 installed for Dex #001-151 (60% scale, toon toggle, Rumble fallback enabled)")
