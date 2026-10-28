--- Dataset navigation state --- tab/window guards, dirty detection, resultset access.
local D = require("poste-db.dataset")

local M = {}

function M.get_tab()
  return D.T()
end

function M.get_resultset_tab()
  local tab = D.T()
  if not tab or not tab.meta or tab.meta.type ~= "resultset" then
    return nil
  end
  return tab
end

function M.get_resultset_data_tab()
  local tab = M.get_resultset_tab()
  if not M.has_data(tab) then
    return nil
  end
  return tab
end


function M.is_dirty(tab)
  return tab and tab.edit_state and tab.edit_state.dirty or false
end

function M.has_layout(tab)
  return tab and tab.layout ~= nil
end

function M.has_data(tab)
  return tab and tab.data ~= nil
end

return M
