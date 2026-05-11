-- VFN.ControllerHelpers
--
-- Two-category shared utility surface for controllers. Split into:
--
--   CH.UI         -- "manipulate visible surfaces": widget access, row
--                    factories + paint facades, workflow dialogs (Confirm,
--                    menu). Implementation in Controller_Helpers_UI.lua.
--
--   CH.Mechanics  -- "talk to the Store": state readers, dispatch wrappers,
--                    domain actions (CloseSet, OpenSet, etc), cycle helpers.
--                    Implementation in Controller_Helpers_Mechanics.lua.
--
-- Controllers idiomatically alias both at the top of the file:
--
--   local CH = VFN.ControllerHelpers
--   local UI, Mech = CH.UI, CH.Mechanics
--
-- "Where does this go?" rule of thumb: if the helper TOUCHES a widget or
-- builds visual surface, it's UI. If it READS/WRITES Store state or talks
-- to Blizzard APIs that aren't UI, it's Mechanics.

VFN = VFN or {}
VFN.ControllerHelpers = VFN.ControllerHelpers or {}
VFN.ControllerHelpers.UI        = VFN.ControllerHelpers.UI or {}
VFN.ControllerHelpers.Mechanics = VFN.ControllerHelpers.Mechanics or {}
