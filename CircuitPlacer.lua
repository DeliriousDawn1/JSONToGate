--[[
    ============================================================================
    ROBLOX CIRCUIT PLACER - Lua HDL Compiler Integration
    ============================================================================
    
    This module takes compiled gate netlists (JSON from lua_hdl_compiler.py)
    and automatically places and wires gates in the Roblox game world.
    
    Usage:
        local CircuitPlacer = require(game.ServerScriptService.CircuitPlacer)
        CircuitPlacer:PlaceCircuit(netlistJSON, gridOrigin, spacing)
    
    Gate IDs:
        AND = 1, NAND = 2, NOR = 3, NOT = 4, OR = 5, XOR = 8, XNOR = 7
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PlacerBloc = ReplicatedStorage.Events:WaitForChild("PlacerBloc")
local Relier = ReplicatedStorage.Events:WaitForChild("Relier"):WaitForChild("Relier")
local BitBuffer = require(ReplicatedStorage.Modules.BitBuffer)
local BlocMap = require(ReplicatedStorage.Modules.BlocMap)

local CircuitPlacer = {}

-- Gate ID mapping from compiler output to game IDs
local GATE_TYPE_TO_ID = {
    AND = "1",
    NAND = "2",
    NOR = "3",
    NOT = "4",
    OR = "5",
    XOR = "8",
    XNOR = "7",
}

-- Number of inputs/outputs for each gate
local GATE_SIGNATURE = {
    AND = {inputs = 2, outputs = 1},
    NAND = {inputs = 2, outputs = 1},
    NOR = {inputs = 2, outputs = 1},
    NOT = {inputs = 1, outputs = 1},
    OR = {inputs = 2, outputs = 1},
    XOR = {inputs = 2, outputs = 1},
    XNOR = {inputs = 2, outputs = 1},
}

-- Get grid size from game
local GRANDEUR_BLOC = BlocMap.GrandeurBloc or 3

-- ============================================================================
-- Helper: Encode position for server
-- ============================================================================
local function EncodePosition(gridX, gridY, gridZ)
    local posBuffer = BitBuffer:Create()
    posBuffer:WriteUnsigned(8, tonumber(gridX % 256))
    posBuffer:WriteUnsigned(8, tonumber(gridY % 256))
    posBuffer:WriteUnsigned(8, tonumber(gridZ % 256))
    return posBuffer:ToBase64()
end

-- ============================================================================
-- Helper: Encode rotation for server
-- ============================================================================
local function EncodeRotation(rx, ry, rz)
    local rotBuffer = BitBuffer:Create()
    rotBuffer:WriteUnsigned(2, MathRound((math.deg(rx) + 360) / 90) % 4)
    rotBuffer:WriteUnsigned(2, MathRound((math.deg(ry) + 360) / 90) % 4)
    rotBuffer:WriteUnsigned(2, MathRound((math.deg(rz) + 360) / 90) % 4)
    return rotBuffer:ToBase64()
end

-- ============================================================================
-- Helper: Math round
-- ============================================================================
local function MathRound(n)
    return math.floor(n + 0.5)
end

-- ============================================================================
-- Helper: Convert world position to grid coordinates
-- ============================================================================
local function WorldToGrid(worldPos, originPos)
    local gridX = MathRound((worldPos.X - originPos.X) / GRANDEUR_BLOC)
    local gridY = MathRound((worldPos.Y - originPos.Y) / GRANDEUR_BLOC)
    local gridZ = MathRound((worldPos.Z - originPos.Z) / GRANDEUR_BLOC)
    return gridX, gridY, gridZ
end

-- ============================================================================
-- Helper: Convert grid coordinates to world position
-- ============================================================================
local function GridToWorld(gridX, gridY, gridZ, originPos)
    local worldX = originPos.X + (gridX * GRANDEUR_BLOC)
    local worldY = originPos.Y + (gridY * GRANDEUR_BLOC)
    local worldZ = originPos.Z + (gridZ * GRANDEUR_BLOC)
    return Vector3.new(worldX, worldY, worldZ)
end

-- ============================================================================
-- Helper: Place a single gate block
-- ============================================================================
local function PlaceGate(gateID, gateType, gridX, gridY, gridZ)
    local blockID = GATE_TYPE_TO_ID[gateType]
    if not blockID then
        error("Unknown gate type: " .. gateType)
    end
    
    local cframe = CFrame.new(
        gridX * GRANDEUR_BLOC,
        gridY * GRANDEUR_BLOC,
        gridZ * GRANDEUR_BLOC
    )
    
    local encodedPos = EncodePosition(gridX, gridY, gridZ)
    local encodedRot = EncodeRotation(0, 0, 0) -- default rotation
    local gridCellsString = gridX .. "_" .. gridY .. "_" .. gridZ
    
    print("Placing " .. gateType .. " (ID: " .. blockID .. ") at grid (" .. gridX .. ", " .. gridY .. ", " .. gridZ .. ")")
    
    local success = PlacerBloc:InvokeServer(
        blockID,
        encodedPos,
        nil,
        nil,
        gridCellsString,
        encodedRot
    )
    
    if not success then
        warn("Failed to place gate: " .. gateID)
        return false
    end
    
    return true
end

-- ============================================================================
-- Helper: Get gate instance from workspace
-- ============================================================================
local function GetGateInstance(gateID, gateType)
    -- Try multiple naming conventions
    local patterns = {
        gateID,
        gateType .. " " .. gateID,
        gateType .. "_" .. gateID,
        gateID .. "_" .. gateType,
    }
    
    for _, pattern in ipairs(patterns) do
        local block = workspace.Blocs:FindFirstChild(pattern)
        if block then
            return block
        end
    end
    
    -- Fallback: look by gate type
    local typeBlocks = workspace.Blocs:FindFirstChild(gateType)
    if typeBlocks then
        return typeBlocks
    end
    
    warn("Could not find gate instance: " .. gateID .. " (" .. gateType .. ")")
    return nil
end

-- ============================================================================
-- Helper: Get input/output node from gate
-- ============================================================================
local function GetGateNode(gateInstance, nodeType, index)
    --[[
        nodeType: "Input" or "Output"
        index: 1, 2, etc. (for multiple inputs on AND/OR gates)
        
        Single input gates (NOT): just use Input
        Multi-input gates (AND, OR, etc.):
            - Input (primary input)
            - Input1, Input2 (alternative naming)
    ]]
    
    if not gateInstance or not gateInstance:FindFirstChild("Box") then
        return nil
    end
    
    local box = gateInstance.Box
    
    if nodeType == "Input" then
        if index == 1 or index == nil then
            return box:FindFirstChild("Input")
        else
            -- Try Input1, Input2, etc.
            return box:FindFirstChild("Input" .. index)
        end
    elseif nodeType == "Output" then
        return box:FindFirstChild("Output")
    end
    
    return nil
end

-- ============================================================================
-- Helper: Wire two gates together
-- ============================================================================
local function WireGates(sourceGate, sourceIndex, targetGate, targetIndex)
    if not sourceGate or not targetGate then
        warn("Invalid gates to wire")
        return false
    end
    
    local sourceNode = GetGateNode(sourceGate, "Output", sourceIndex)
    local targetNode = GetGateNode(targetGate, "Input", targetIndex)
    
    if not sourceNode or not targetNode then
        warn("Could not find nodes to connect")
        return false
    end
    
    print("Wiring: " .. sourceGate.Name .. ".Output -> " .. targetGate.Name .. ".Input")
    
    Relier:FireServer(targetNode, sourceNode)
    return true
end

-- ============================================================================
-- Main: Parse JSON netlist and place circuit
-- ============================================================================
function CircuitPlacer:PlaceCircuit(netlisted, gridOrigin, spacing)
    --[[
        netlist: The compiled JSON from lua_hdl_compiler.py
        gridOrigin: Vector3 of grid (0, 0, 0) in world coordinates
        spacing: Grid spacing in studs (default: GRANDEUR_BLOC)
    ]]
    
    gridOrigin = gridOrigin or Vector3.new(0, 0, 0)
    spacing = spacing or GRANDEUR_BLOC
    
    if not netlisted then
        error("No netlist provided")
    end
    
    print("\n" .. string.rep("=", 80))
    print("CIRCUIT PLACER - Starting placement")
    print("Module: " .. (netlisted.module or "Unknown"))
    print("Total gates: " .. #netlisted.gates)
    print(string.rep("=", 80) .. "\n")
    
    -- Step 1: Create gate placement map
    -- Gates are placed in a grid, spacing them evenly
    local gateInstances = {}
    local gatePositions = {}
    local col = 0
    local row = 0
    local MAX_COLS = 8 -- gates per row
    
    for i, gate in ipairs(netlisted.gates) do
        local gateX = col * 5 -- 5 studs apart horizontally
        local gateY = 0
        local gateZ = row * 5 -- 5 studs apart vertically
        
        local gridX = gridOrigin.X + gateX
        local gridY = gridOrigin.Y + gateY
        local gridZ = gridOrigin.Z + gateZ
        
        -- Place the gate
        local placed = PlaceGate(gate.id, gate.type, gridX, gridY, gridZ)
        
        if placed then
            gatePositions[gate.id] = {x = gridX, y = gridY, z = gridZ}
            
            -- Wait a bit for the gate to be created
            wait(0.1)
            
            -- Try to get the instance
            local instance = GetGateInstance(gate.id, gate.type)
            if instance then
                gateInstances[gate.id] = instance
                print("✓ Gate placed and found: " .. gate.id)
            else
                warn("✗ Gate placed but instance not found: " .. gate.id)
            end
        else
            warn("✗ Failed to place gate: " .. gate.id)
        end
        
        col = col + 1
        if col >= MAX_COLS then
            col = 0
            row = row + 1
        end
    end
    
    print("\n" .. string.rep("-", 80))
    print("STEP 1 COMPLETE: All gates placed")
    print(string.rep("-", 80) .. "\n")
    
    -- Step 2: Wire gates together based on netlist
    local wireCount = 0
    for gateIndex, gate in ipairs(netlisted.gates) do
        local sourceGate = gateInstances[gate.id]
        if not sourceGate then
            warn("Gate instance not found for: " .. gate.id)
            goto continue_gate
        end
        
        -- Process inputs
        for inputIndex, inputWire in ipairs(gate.in) do
            -- The input wire can be:
            -- 1. Another gate ID (e.g., "g1") - connect output of that gate
            -- 2. A signal name (e.g., "A[0]") - leave unconnected (primary input)
            
            if string.match(inputWire, "^g%d+$") then
                -- This is a gate reference
                local targetGate = gateInstances[inputWire]
                if targetGate then
                    WireGates(targetGate, 1, sourceGate, inputIndex)
                    wireCount = wireCount + 1
                else
                    warn("Referenced gate not found: " .. inputWire)
                end
            else
                -- Primary input from signal (e.g., "A[0]")
                print("Primary input: " .. gate.id .. " <- " .. inputWire)
            end
        end
        
        ::continue_gate::
    end
    
    print("\n" .. string.rep("-", 80))
    print("STEP 2 COMPLETE: Wiring done")
    print(string.rep("-", 80) .. "\n")
    
    -- Step 3: Summary
    print(string.rep("=", 80))
    print("CIRCUIT PLACEMENT SUMMARY")
    print("  Gates placed: " .. #gateInstances)
    print("  Wires created: " .. wireCount)
    print("  Module: " .. (netlisted.module or "Unknown"))
    print(string.rep("=", 80) .. "\n")
    
    return {
        gateInstances = gateInstances,
        gatePositions = gatePositions,
        wireCount = wireCount,
        totalGates = #gateInstances,
    }
end

-- ============================================================================
-- Utility: Print netlist summary
-- ============================================================================
function CircuitPlacer:PrintNetlist(netlist)
    print("\n" .. string.rep("=", 80))
    print("NETLIST SUMMARY: " .. (netlist.module or "Unknown"))
    print(string.rep("=", 80))
    
    print("\nGates:")
    for i, gate in ipairs(netlist.gates) do
        print(string.format("  %2d. %s (ID: %s, Inputs: %d)", i, gate.type, gate.id, #gate.in))
    end
    
    print("\nSignals:")
    for name, sig in pairs(netlist.signals or {}) do
        print(string.format("  %s: %s %d-bit", 
            name, 
            (sig.is_input and "INPUT" or sig.is_output and "OUTPUT" or "INTERNAL"),
            sig.width or 1
        ))
    end
    
    print(string.rep("=", 80) .. "\n")
end

-- ============================================================================
-- Utility: JSON decode (basic implementation)
-- ============================================================================
function CircuitPlacer:DecodeJSON(jsonString)
    -- Use loadstring with a safe JSON parser
    -- For production, use a proper JSON library
    local success, result = pcall(function()
        return game:GetService("HttpService"):JSONDecode(jsonString)
    end)
    
    if success then
        return result
    else
        error("Failed to decode JSON: " .. tostring(result))
    end
end

-- ============================================================================
-- Utility: Load netlist from ReplicatedStorage
-- ============================================================================
function CircuitPlacer:LoadNetlistFromStorage(path)
    local parts = string.split(path, "/")
    local obj = ReplicatedStorage
    
    for _, part in ipairs(parts) do
        obj = obj:FindFirstChild(part)
        if not obj then
            error("Path not found: " .. path)
        end
    end
    
    if obj:IsA("StringValue") then
        return self:DecodeJSON(obj.Value)
    else
        error("Expected StringValue at: " .. path)
    end
end

return CircuitPlacer
