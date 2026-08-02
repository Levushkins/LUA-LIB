-- -@meta

-- -@class VehicleModel
-- -@field name string
-- -@field model number
-- -@field imagePath? string

-- -@class Vehicle
-- -@field serverId? number
-- -@field replace boolean
-- -@field newModel? VehicleModel
-- -@field plate string
-- -@field model VehicleModel

---@meta

---@class Vehicle
---@field replace boolean
---@field name string
---@field numberPlate string
---@field serverId? number
---@field fakeModel? number
---@field fakeModelName? string
---@field imagePath? string

---@class VehicleStreamInData
---@field type number
---@field position Vector3D
---@field rotation number
---@field bodyColor1 number
---@field bodyColor2 number
---@field health number
---@field interiorId number
---@field doorDamageStatus number
---@field panelDamageStatus number
---@field lightDamageStatus number
---@field tireDamageStatus number
---@field addSiren number
---@field paintJob number
---@field interiorColor1 number
---@field interiorColor2 number
---@field modSlots number[]